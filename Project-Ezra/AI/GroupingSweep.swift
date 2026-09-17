//
//  GroupingSweep.swift
//  Project-Ezra
//
//  **The model names membership; the person decides; the app keeps the receipt.**
//
//  Tasks that belong to one outcome but arrived on different days — "Book flights to
//  Lagos" on Monday, "Renew passport" on Wednesday, "Pack for Lagos" on Friday — sit as
//  three loose rows in Todo. Capture-time grouping only sees the capture in hand
//  (`AppBrain.commit(groupTitle:)`), so nothing ever proposes the umbrella across days.
//  This sweep does, on the on-device model, and it PROPOSES rather than acts: a group is
//  structure, and structure the person never asked for is the deck view's whole
//  argument against a visible umbrella. So the output is a `GroupProposal` in memory —
//  one quiet row at the top of My Tasks (`GroupProposalRow`), gone on accept, reject or
//  a fresh launch — never an edge.
//
//  Containment, layered, the `DuplicateSweep` shape:
//  - Deterministic prefilter: loose open tasks (no umbrella, not waiting) that share a
//    significant word of four letters or more cluster together; rejected sibling pairs
//    are cut from the graph before clustering, so a "no" never re-forms the same group
//    through a third task; clusters of 2–5, best-linked first, capped per run.
//  - The model judges one cluster at a time through `ModelRun` (background deadline,
//    `maxJudgmentsPerRun`), absent off-device like every proposal feature.
//  - **The judgment is untrusted transport**: `validated(_:shown:)` accepts only member
//    titles that were shown (one invented title rejects the whole judgment), at least two
//    of them, a 1–6 word outcome title that is not itself a member, and confidence at the
//    `childOf` tier (≥ 0.5, the same non-destructive tier capture-time parent links use).
//  - Accepting writes the umbrella and the `.parent` edges exactly as the confirm card's
//    group does, as ONE reversible `"grouped"` entry — the existing undo arm unlinks the
//    steps and removes an untouched umbrella. Rejecting writes a `siblingGroup`
//    suppression per member pair, so the sweep never asks the same question twice.
//

import CoreData
import Foundation
import FoundationModels

/// The model's verdict on one candidate cluster.
@Generable
struct GroupJudgment {
    @Guide(description: "true only if these to-do items are steps toward ONE shared outcome or project")
    var belongsTogether: Bool
    @Guide(description: "confidence 0...1 that they serve one outcome")
    var confidence: Double
    @Guide(description: "a 2 to 5 word name for that outcome, like 'Lagos trip' or 'Kitchen renovation'")
    var outcomeTitle: String
    @Guide(
        description: "the EXACT titles, copied verbatim, of the items that belong; leave out any that do not")
    var memberTitles: [String]
}

/// A validated proposal — what the row shows and what accept/reject act on. A value,
/// never a store write: the person's answer is the only thing that touches the store.
struct GroupProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let memberIDs: [UUID]
    let memberTitles: [String]
    let confidence: Double

    /// Identity of the QUESTION, not the proposal: the same member set is the same ask,
    /// whatever title the model chose this time.
    var memberKey: String { memberIDs.map(\.uuidString).sorted().joined(separator: ",") }
}

/// The proposals waiting for an answer, in memory for this launch — a proposal is a
/// question, and a question nobody answered is not a record.
@MainActor
@Observable
final class GroupProposals {
    static let shared = GroupProposals()

    private(set) var pending: [GroupProposal] = []
    /// Member sets the person said "not now" to this launch — hidden, not suppressed.
    private var deferred: Set<String> = []

    func offer(_ proposal: GroupProposal) {
        guard !deferred.contains(proposal.memberKey),
            !pending.contains(where: { $0.memberKey == proposal.memberKey })
        else { return }
        pending.append(proposal)
    }

    func remove(_ proposal: GroupProposal) {
        pending.removeAll { $0.id == proposal.id }
    }

    func dismissForNow(_ proposal: GroupProposal) {
        deferred.insert(proposal.memberKey)
        remove(proposal)
    }

    #if DEBUG
    func seed(_ proposals: [GroupProposal]) { pending = proposals }
    #endif
}

enum GroupingSweep {

    // MARK: - Tuning (containment constants, named)

    static let minClusterSize = 2
    static let maxClusterSize = 5
    static let maxClustersPerRun = 5
    static let maxJudgmentsPerRun = 3
    /// A shared word this short ("pay", "the") links everything to everything.
    static let minSharedWordLength = 4
    /// The `childOf` tier — a proposed parent link is non-destructive and asks the person.
    static let acceptThreshold = 0.5
    static let maxTitleWords = 6

    struct Cluster: Equatable {
        var members: [OpenTaskSnapshot]
        /// Total shared-word links inside the cluster — the ranking.
        var links: Int
    }

    // MARK: - Prefilter (pure, deterministic, tested)

    /// Loose open tasks that share a significant word, clustered; suppressed sibling
    /// pairs cut first; sized and capped. Order is deterministic: best-linked first,
    /// then by the first member's id.
    static func clusters(
        among snapshots: [OpenTaskSnapshot], suppressions: [RelationshipSuppression]
    ) -> [Cluster] {
        let loose = snapshots.filter { $0.parentTitle == nil && !$0.isBlocked }
        struct Prepared {
            let snapshot: OpenTaskSnapshot
            let words: Set<String>
        }
        let prepared: [Prepared] = loose.compactMap { snapshot in
            let words = CorrectionProfile.significantWords(snapshot.title)
                .filter { $0.count >= minSharedWordLength }
            guard !words.isEmpty else { return nil }
            return Prepared(snapshot: snapshot, words: words)
        }
        // Union-find over the shared-word relation, minus rejected pairs.
        var parent = Array(prepared.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var degree = Array(repeating: 0, count: prepared.count)
        for i in prepared.indices {
            for j in prepared.indices where j > i {
                guard !prepared[i].words.isDisjoint(with: prepared[j].words) else { continue }
                let a = prepared[i].snapshot.id
                let b = prepared[j].snapshot.id
                guard !suppressions.contains(where: { $0.suppressesPair(kind: .siblingGroup, a, b) }) else {
                    continue
                }
                degree[i] += 1
                degree[j] += 1
                let (ri, rj) = (find(i), find(j))
                if ri != rj { parent[ri] = rj }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in prepared.indices { groups[find(i), default: []].append(i) }
        let clusters: [Cluster] = groups.values.compactMap { indices in
            guard indices.count >= minClusterSize else { return nil }
            // Oversized clusters keep their best-connected members; the rest wait for
            // another run, once these have an umbrella to join.
            let kept = indices.sorted {
                if degree[$0] != degree[$1] { return degree[$0] > degree[$1] }
                return prepared[$0].snapshot.id.uuidString < prepared[$1].snapshot.id.uuidString
            }
            .prefix(maxClusterSize)
            let members = kept.map { prepared[$0].snapshot }
            return Cluster(members: members, links: kept.reduce(0) { $0 + degree[$1] } / 2)
        }
        return
            clusters
            .sorted {
                if $0.links != $1.links { return $0.links > $1.links }
                return $0.members[0].id.uuidString < $1.members[0].id.uuidString
            }
            .prefix(maxClustersPerRun)
            .map { $0 }
    }

    /// **Bare chains are candidates too — first.** Dependency-linked open tasks with no
    /// umbrella render as a deck whose caption is the arrow story ("RENEW PASSPORT → BOOK
    /// FLIG…"), truncated at the width of a phone; a named outcome is the caption the deck
    /// was built for. The chain's own shape already says "one outcome" — the judge only has
    /// to say what to call it, and the person still decides. A chain with any rejected pair
    /// is left alone.
    static func chainClusters(in tasks: [TaskItem], suppressions: [RelationshipSuppression]) -> [Cluster] {
        let open = tasks.filter { !$0.status.isResolved }
        let (chains, _) = TaskChainGrouping.computeChains(in: open)
        return chains.compactMap { chain -> Cluster? in
            guard chain.umbrella == nil, chain.members.count >= minClusterSize else { return nil }
            let ids = chain.members.compactMap(\.uuid)
            for i in ids.indices {
                for j in ids.indices where j > i {
                    if suppressions.contains(where: { $0.suppressesPair(kind: .siblingGroup, ids[i], ids[j]) }
                    ) {
                        return nil
                    }
                }
            }
            let members = chain.members.prefix(maxClusterSize).map {
                OpenTaskSnapshot(id: $0.uuid ?? UUID(), title: $0.title, category: $0.category)
            }
            return Cluster(members: Array(members), links: members.count)
        }
        .sorted { $0.members[0].id.uuidString < $1.members[0].id.uuidString }
    }

    /// Everything one run may ask about, in the order it asks: the chains on screen, then
    /// the word-sharing clusters. Shared by the sweep and its eval's store printout.
    static func candidates(
        in tasks: [TaskItem], snapshots: [OpenTaskSnapshot], suppressions: [RelationshipSuppression]
    ) -> [Cluster] {
        let chained = chainClusters(in: tasks, suppressions: suppressions)
        let chainedIDs = Set(chained.flatMap { $0.members.map(\.id) })
        let loose = clusters(
            among: snapshots.filter { !chainedIDs.contains($0.id) }, suppressions: suppressions)
        return Array((chained + loose).prefix(maxClustersPerRun))
    }

    // MARK: - The sweep

    /// Judge the best clusters and OFFER what validates. Returns the proposals offered.
    @discardableResult
    static func run(in context: NSManagedObjectContext, now: Date = Date()) async -> [GroupProposal] {
        guard AppBrain.onDeviceModelAvailable() else { return [] }
        let snapshots = OpenTaskSnapshotCache.shared.snapshots(in: context)
        guard snapshots.count >= minClusterSize else { return [] }
        let all = TaskItem.fetchAll(in: context)
        let suppressions = SuppressionStore.load(in: context, existingTaskIDs: Set(all.compactMap(\.uuid)))
        let candidates = candidates(in: all, snapshots: snapshots, suppressions: suppressions)
        var offered: [GroupProposal] = []
        for cluster in candidates.prefix(maxJudgmentsPerRun) {
            // On-device only, hard-capped, never the cloud rung — background work nobody
            // is waiting on has no business costing money. Metered so that stays a fact.
            IntelligenceLedger.shared.record(.onDevice, for: .sweeps)
            guard case .success(let judgment) = await judge(cluster),
                let proposal = validated(judgment, shown: cluster.members)
            else { continue }
            GroupProposals.shared.offer(proposal)
            offered.append(proposal)
        }
        return offered
    }

    /// THE judgment — one cluster in, the model's verdict out, no side effect. Lifted so an
    /// eval measures the judge the product uses, never a copy of it.
    static func judge(_ cluster: Cluster) async -> ModelResult<GroupJudgment> {
        await ModelRun.perform(.groupingSweep, deadline: ModelDeadline.seconds(for: .background)) {
            let session = LanguageModelSession(instructions: Self.judgeInstructions)
            return try await session.respond(to: Self.judgePrompt(cluster), generating: GroupJudgment.self)
                .content
        }
    }

    static let judgeInstructions = """
        You look at a few to-do items from one person's task list and decide whether \
        they are steps toward ONE shared outcome — a trip, an event, a project, a \
        move. Items that merely share a word ("pay the water bill" / "pay the phone \
        bill") or a category are NOT one outcome; recurring chores are not a project; \
        two DIFFERENT events or occasions are two outcomes even when they share a word \
        ("the wedding caterer" / "caterer for the reunion" are not one outcome). Judge \
        conservatively: when unsure, they do not belong together. When they do, name \
        the outcome in two to five plain words and copy the belonging items' titles \
        exactly.
        """

    static func judgePrompt(_ cluster: Cluster) -> String {
        let lines = cluster.members.map { "- \($0.title) (category \($0.category))" }
        return "Items:\n" + lines.joined(separator: "\n") + "\n\nAre these steps toward one shared outcome?"
    }

    // MARK: - The validator (the trust boundary)

    /// The proposal a judgment earns, or nil. Every member title must be one the model
    /// was shown, verbatim after trimming and case; one invented title rejects the whole
    /// judgment — a group with a phantom member is not a smaller group, it is a wrong
    /// one. At least two members; a 1–6 word title that is not itself a member.
    static func validated(
        _ judgment: GroupJudgment, shown: [OpenTaskSnapshot], threshold: Double = acceptThreshold
    ) -> GroupProposal? {
        guard judgment.belongsTogether, judgment.confidence >= threshold else { return nil }
        let byTitle = Dictionary(
            shown.map { (normalize($0.title), $0) }, uniquingKeysWith: { a, _ in a })
        var members: [OpenTaskSnapshot] = []
        var seen = Set<UUID>()
        for raw in judgment.memberTitles {
            guard let match = byTitle[normalize(raw)] else { return nil }
            if seen.insert(match.id).inserted { members.append(match) }
        }
        guard members.count >= minClusterSize else { return nil }
        let title = judgment.outcomeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = title.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= maxTitleWords, !title.contains("\n") else { return nil }
        guard byTitle[normalize(title)] == nil else { return nil }
        return GroupProposal(
            id: UUID(), title: title, memberIDs: members.map(\.id), memberTitles: members.map(\.title),
            confidence: judgment.confidence)
    }

    private static func normalize(_ title: String) -> String {
        RelationshipSuppression.normalizeTitle(title)
    }

    // MARK: - The person's answer

    /// Accept: the umbrella and its `.parent` edges, exactly as the confirm card's group
    /// writes them, as one reversible `"grouped"` entry. Returns the umbrella, or nil when
    /// fewer than two members are still open and loose (the household moved on).
    @discardableResult
    static func apply(
        _ proposal: GroupProposal, currentUserID: UUID?, in context: NSManagedObjectContext,
        now: Date = Date()
    ) -> TaskItem? {
        let all = TaskItem.fetchAll(in: context)
        let byID = Dictionary(
            all.compactMap { task in task.uuid.map { ($0, task) } }, uniquingKeysWith: { a, _ in a })
        let steps = proposal.memberIDs.compactMap { byID[$0] }
            .filter { !$0.status.isResolved && $0.parentTaskID == nil }
        guard steps.count >= minClusterSize else { return nil }
        var counts: [String: Int] = [:]
        for step in steps { counts[step.category, default: 0] += 1 }
        let category =
            steps.map(\.category).max { a, b in
                (counts[a] ?? 0, -(steps.firstIndex { $0.category == a } ?? 0))
                    < (counts[b] ?? 0, -(steps.firstIndex { $0.category == b } ?? 0))
            } ?? steps[0].category
        // The outcome belongs to whoever holds most of its steps; ties to the first.
        var owners: [UUID: Int] = [:]
        for step in steps { if let owner = step.ownerID { owners[owner, default: 0] += 1 } }
        let owner =
            steps.compactMap(\.ownerID).max { a, b in
                (owners[a] ?? 0, -(steps.firstIndex { $0.ownerID == a } ?? 0))
                    < (owners[b] ?? 0, -(steps.firstIndex { $0.ownerID == b } ?? 0))
            } ?? currentUserID
        let umbrella = TaskItem(
            title: proposal.title, category: category, status: .todo, creatorID: currentUserID,
            confidence: proposal.confidence, reasoning: "Grouped by Ezra's suggestion — you accepted.",
            in: context)
        umbrella.ownerID = owner
        umbrella.confirmedAt = now
        context.insert(umbrella)
        guard let umbrellaID = umbrella.uuid else { return nil }
        for (index, step) in steps.enumerated() {
            step.sortIndex = Int32(index)
            step.linkParent(umbrellaID, origin: .inferred(confidence: proposal.confidence))
        }
        context.insert(
            ChangeLogEntry(
                summary: "Grouped \(steps.count) tasks as “\(proposal.title)”",
                detail: steps.map(\.title).joined(separator: " · "),
                action: "grouped",
                newValue: steps.compactMap { $0.uuid?.uuidString }.joined(separator: ","),
                initiatedBy: .ai,
                isReversible: true,
                taskTitle: proposal.title,
                taskUUID: umbrellaID,
                actorID: currentUserID,
                timestamp: now,
                in: context))
        AttentionEngine.recompute([umbrella] + steps, among: TaskItem.fetchAll(in: context))
        context.saveChanges()
        GroupProposals.shared.remove(proposal)
        return umbrella
    }

    /// The trail's verb for a rejected proposal; `ChangeLogUndo` keys its arm on it.
    static let rejectedAction = "rejectedGroup"

    /// Reject: a `siblingGroup` suppression per member pair, so the sweep never asks
    /// this question again, and ONE reversible trail entry for the whole set — a veto
    /// with no way back is the undo-completeness rule broken; the proposal leaves the row.
    static func reject(
        _ proposal: GroupProposal, currentUserID: UUID? = nil, in context: NSManagedObjectContext,
        now: Date = Date()
    ) {
        let ids = proposal.memberIDs
        for i in ids.indices {
            for j in ids.indices where j > i {
                SuppressionStore.recordRejectedSiblings(ids[i], ids[j], in: context, now: now)
            }
        }
        context.insert(
            ChangeLogEntry(
                summary: "Said no to grouping \(ids.count) tasks as “\(proposal.title)”",
                detail: proposal.memberTitles.joined(separator: " · ")
                    + ". Undo lets the suggestion come back.",
                action: rejectedAction,
                newValue: ids.map(\.uuidString).joined(separator: ","),
                initiatedBy: .human,
                isReversible: true,
                taskTitle: proposal.title,
                actorID: currentUserID,
                timestamp: now,
                in: context))
        context.saveChanges()
        GroupProposals.shared.remove(proposal)
    }
}
