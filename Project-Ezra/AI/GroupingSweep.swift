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
    /// The EXISTING outcome the members would join, when the proposal is "add these to
    /// that" rather than "make these a group". `title` is then the umbrella's own.
    var umbrellaID: UUID? = nil

    var isAttach: Bool { umbrellaID != nil }

    /// Identity of the QUESTION, not the proposal: the same member set under the same
    /// outcome is the same ask, whatever title the model chose this time.
    var memberKey: String {
        (memberIDs.map(\.uuidString).sorted() + [umbrellaID?.uuidString ?? ""]).joined(separator: ",")
    }
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
    /// The attach question's own tier, above the group's. A false ask costs trust; a
    /// missed attach costs nothing (the row stays loose). Measured 2026-09-17: the true
    /// attach accepted at 0.90 under the shipped prompt, and the looser prompts' false
    /// accepts sat at 0.60 — see `judgePrompt`. `-GroupingSweepEval` prints every
    /// confidence so the next run can move this.
    static let attachAcceptThreshold = 0.7
    /// **The attach shape is built and OFF.** Four measured configurations on 2026-09-17
    /// and none reached FALSE ACCEPT 0 on the labeled attach set — the last accepted "Plan
    /// the weekend trip" under "Trip Preparation" at 0.90. A group asks "are these one
    /// thing?"; an attach asks "is this THAT thing?", and the on-device model reads any
    /// shared word as yes. The prefilter, judge, validator, row, undo and eval stay
    /// reachable (`-GroupingSweepEval` still judges the labeled cases and prints the
    /// store's attach candidates) so the next run can flip this over a clean report — a
    /// human's call, like the boundary pass.
    static let attachIsEnabled = false
    static let maxTitleWords = 6

    struct Cluster: Equatable {
        var members: [OpenTaskSnapshot]
        /// Total shared-word links inside the cluster — the ranking.
        var links: Int
        /// An EXISTING outcome the members are candidates to join, with a few of its
        /// steps for context. Nil for a "make these a group" cluster.
        var umbrella: OpenTaskSnapshot? = nil
        var steps: [OpenTaskSnapshot] = []
    }
    /// How many loose candidates one attach question may hold, and how many of the
    /// outcome's steps it shows for context.
    static let maxAttachCandidates = 3
    static let maxContextSteps = 3

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

    /// **A loose task beside an existing outcome.** "Pack for Lagos" captured a week after
    /// "Lagos trip" was made sits loose in Todo while its outcome has a deck two rows
    /// down — capture-time `childOf` only sees the capture in hand, and misses. For each
    /// open outcome (an open task with an open step), the loose open tasks sharing a
    /// ≥4-letter word with the outcome's title or any step's title are candidates; a
    /// candidate the person already refused for that outcome (`parentLink`, directional)
    /// is not. The judge is shown the outcome and a few of its steps and asked which
    /// candidates are steps of it.
    static func attachClusters(
        in tasks: [TaskItem], snapshots: [OpenTaskSnapshot], suppressions: [RelationshipSuppression]
    ) -> [Cluster] {
        let open = tasks.filter { !$0.status.isResolved }
        let snapshotByID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let loose = snapshots.filter { $0.parentTitle == nil && !$0.isBlocked }
        func words(_ title: String) -> Set<String> {
            CorrectionProfile.significantWords(title).filter { $0.count >= minSharedWordLength }
        }
        var out: [Cluster] = []
        for umbrella in open {
            guard let umbrellaID = umbrella.uuid, let umbrellaSnapshot = snapshotByID[umbrellaID] else { continue }
            let steps = umbrella.children(among: open)
            guard !steps.isEmpty else { continue }
            let stepIDs = Set(steps.compactMap(\.uuid))
            var vocabulary = words(umbrella.title)
            for step in steps { vocabulary.formUnion(words(step.title)) }
            guard !vocabulary.isEmpty else { continue }
            let candidates = loose.filter { candidate in
                candidate.id != umbrellaID && !stepIDs.contains(candidate.id)
                    && !words(candidate.title).isDisjoint(with: vocabulary)
                    && !suppressions.contains(where: {
                        $0.suppressesPair(kind: .parentLink, candidate.id, umbrellaID)
                    })
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .prefix(maxAttachCandidates)
            guard !candidates.isEmpty else { continue }
            out.append(
                Cluster(
                    members: Array(candidates), links: candidates.count, umbrella: umbrellaSnapshot,
                    steps: steps.prefix(maxContextSteps).compactMap { $0.uuid.flatMap { snapshotByID[$0] } }))
        }
        return out.sorted { $0.umbrella!.id.uuidString < $1.umbrella!.id.uuidString }
    }

    /// Everything one run may ask about, in the order it asks: the chains on screen, the
    /// loose tasks beside an existing outcome, then the word-sharing clusters — each task in
    /// at most one question. Shared by the sweep and its eval's store printout.
    static func candidates(
        in tasks: [TaskItem], snapshots: [OpenTaskSnapshot], suppressions: [RelationshipSuppression],
        includingAttach: Bool = attachIsEnabled
    ) -> [Cluster] {
        let chained = chainClusters(in: tasks, suppressions: suppressions)
        var taken = Set(chained.flatMap { $0.members.map(\.id) })
        // An outcome is never a member: an umbrella word-clustered with a loose task would
        // be proposed as a step of a NEW group, and the person would be asked to file an
        // outcome under a smaller outcome.
        let open = tasks.filter { !$0.status.isResolved }
        taken.formUnion(open.filter { !$0.children(among: open).isEmpty }.compactMap(\.uuid))
        let attach = (includingAttach ? attachClusters(in: tasks, snapshots: snapshots, suppressions: suppressions) : [])
            .compactMap { cluster -> Cluster? in
                var trimmed = cluster
                trimmed.members = cluster.members.filter { !taken.contains($0.id) }
                guard !trimmed.members.isEmpty else { return nil }
                taken.formUnion(trimmed.members.map(\.id))
                return trimmed
            }
        let loose = clusters(among: snapshots.filter { !taken.contains($0.id) }, suppressions: suppressions)
        return Array((chained + attach + loose).prefix(maxClustersPerRun))
    }

    // MARK: - The sweep

    /// The moment a group forms is the capture that completes it, so the sweep also runs
    /// shortly after a Confirm — not only on the hourly foreground debounce — but no more
    /// often than `commitRunInterval`, because every capture is not a new question.
    static let commitRunDelaySeconds: Double = 20
    static let commitRunInterval: TimeInterval = 600
    private static var lastCommitRunAt: Date?

    static func runSoonAfterCommit(in context: NSManagedObjectContext, now: Date = Date()) {
        if let last = lastCommitRunAt, now.timeIntervalSince(last) < commitRunInterval { return }
        lastCommitRunAt = now
        Task {
            try? await Task.sleep(for: .seconds(commitRunDelaySeconds))
            await run(in: context)
        }
    }

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
                let proposal = validated(judgment, shown: cluster.members, umbrella: cluster.umbrella)
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
        if let umbrella = cluster.umbrella {
            // The steps stay in the prompt. Measured 2026-09-17 three ways: with a
            // dedicated candidates-only answer type the judge accepted two non-members at
            // 0.60; with the steps removed it accepted three at 0.80–0.90; with the shared
            // answer type and the steps shown it accepted none across two runs — at the
            // cost of sometimes naming the steps instead of a candidate, which the
            // validator reads as "none" (a missed attach, the cheap error).
            let steps = cluster.steps.map { "- \($0.title)" }
            return "Outcome: \(umbrella.title)\nIts steps so far:\n" + steps.joined(separator: "\n")
                + "\n\nCandidate items:\n" + lines.joined(separator: "\n")
                + "\n\nWhich CANDIDATE items are steps of that outcome? Answer with the candidate titles only, "
                + "copied exactly — never the outcome or its existing steps — and leave out any candidate that is not."
        }
        return "Items:\n" + lines.joined(separator: "\n") + "\n\nAre these steps toward one shared outcome?"
    }

    // MARK: - The validator (the trust boundary)

    /// The proposal a judgment earns, or nil. Every member title must be one the model
    /// was shown, verbatim after trimming and case; one invented title rejects the whole
    /// judgment — a group with a phantom member is not a smaller group, it is a wrong
    /// one. At least two members; a 1–6 word title that is not itself a member.
    static func validated(
        _ judgment: GroupJudgment, shown: [OpenTaskSnapshot], umbrella: OpenTaskSnapshot? = nil,
        threshold: Double = acceptThreshold
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
        // An attach question: the outcome already has its name; one grounded member is a
        // proposal. The model's own title is ignored — it was not asked for one.
        if let umbrella {
            guard !members.isEmpty, judgment.confidence >= attachAcceptThreshold else { return nil }
            return GroupProposal(
                id: UUID(), title: umbrella.title, memberIDs: members.map(\.id),
                memberTitles: members.map(\.title), confidence: judgment.confidence, umbrellaID: umbrella.id)
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

    /// Accept. A GROUP: the umbrella and its `.parent` edges, exactly as the confirm card's
    /// group writes them, as one reversible `"grouped"` entry. An ATTACH: one `.parent`
    /// edge per member onto the existing outcome, each its own reversible `"linked"`
    /// entry — the arm capture-time parent links already have. Returns the trail entries
    /// written (the Undo pill reverts them), empty when the household moved on (fewer
    /// than two loose members for a group, none for an attach, the outcome resolved).
    @discardableResult
    static func apply(
        _ proposal: GroupProposal, currentUserID: UUID?, in context: NSManagedObjectContext,
        now: Date = Date()
    ) -> [ChangeLogEntry] {
        let all = TaskItem.fetchAll(in: context)
        let byID = Dictionary(
            all.compactMap { task in task.uuid.map { ($0, task) } }, uniquingKeysWith: { a, _ in a })
        let steps = proposal.memberIDs.compactMap { byID[$0] }
            .filter { !$0.status.isResolved && $0.parentTaskID == nil }
        if let umbrellaID = proposal.umbrellaID {
            guard let umbrella = byID[umbrellaID], !umbrella.status.isResolved, !steps.isEmpty else { return [] }
            var next = Int32(umbrella.children(among: all).count)
            var entries: [ChangeLogEntry] = []
            for step in steps {
                step.sortIndex = next
                next += 1
                step.linkParent(umbrellaID, origin: .inferred(confidence: proposal.confidence))
                let entry = ChangeLogEntry(
                    summary: "“\(step.title)” is now a step of “\(umbrella.title)”",
                    detail: "Suggested by Ezra, accepted by you — undo removes the link, nothing else.",
                    action: "linked", fieldChanged: "parent",
                    newValue: umbrellaID.uuidString,
                    initiatedBy: .ai, isReversible: true,
                    taskTitle: step.title, taskUUID: step.uuid,
                    actorID: currentUserID, timestamp: now, in: context)
                context.insert(entry)
                entries.append(entry)
            }
            AttentionEngine.recompute([umbrella] + steps, among: TaskItem.fetchAll(in: context))
            context.saveChanges()
            GroupProposals.shared.remove(proposal)
            return entries
        }
        guard steps.count >= minClusterSize else { return [] }
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
        guard let umbrellaID = umbrella.uuid else { return [] }
        for (index, step) in steps.enumerated() {
            step.sortIndex = Int32(index)
            step.linkParent(umbrellaID, origin: .inferred(confidence: proposal.confidence))
        }
        let entry = ChangeLogEntry(
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
            in: context)
        context.insert(entry)
        AttentionEngine.recompute([umbrella] + steps, among: TaskItem.fetchAll(in: context))
        context.saveChanges()
        GroupProposals.shared.remove(proposal)
        return [entry]
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
        if let umbrellaID = proposal.umbrellaID {
            // "Not under that outcome": directional, like every parent refusal.
            for id in ids { SuppressionStore.recordRejectedParentLink(child: id, parent: umbrellaID, in: context, now: now) }
        } else {
            for i in ids.indices {
                for j in ids.indices where j > i {
                    SuppressionStore.recordRejectedSiblings(ids[i], ids[j], in: context, now: now)
                }
            }
        }
        context.insert(
            ChangeLogEntry(
                summary: proposal.isAttach
                    ? "Said no to adding \(ids.count == 1 ? "“\(proposal.memberTitles[0])”" : "\(ids.count) tasks") to “\(proposal.title)”"
                    : "Said no to grouping \(ids.count) tasks as “\(proposal.title)”",
                detail: proposal.memberTitles.joined(separator: " · ")
                    + ". Undo lets the suggestion come back.",
                action: rejectedAction,
                oldValue: proposal.umbrellaID?.uuidString,
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
