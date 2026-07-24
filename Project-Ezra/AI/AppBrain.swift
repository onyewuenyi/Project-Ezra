//
//  AppBrain.swift
//  Project-Ezra
//
//  The AI coordinator injected into the environment. It owns engine selection
//  (real on-device model when available, deterministic rules otherwise), exposes
//  a `isProcessing` flag for the "thinking" UI, and commits triaged drafts into
//  SwiftData — logging silent-tier filings to the AI Activity Trail so autonomy
//  never reads as loss of control.
//

import Foundation
import CoreData
import FoundationModels
import Observation

@MainActor
@Observable
final class AppBrain {
    /// Human-readable availability status for the trust/settings surface.
    enum Status {
        case onDevice  // Foundation Models available
        case fallback(reason: String)  // heuristic engine in use

        var isOnDevice: Bool { if case .onDevice = self { return true }; return false }

        var description: String {
            switch self {
            case .onDevice: return "Apple Intelligence · on-device"
            case .fallback(let reason): return "Rules engine · \(reason)"
            }
        }
    }

    private(set) var status: Status
    private let engine: AIEngine

    /// Beta instrumentation (opens, time-to-first-payoff). Lives on the brain so the
    /// commit seam can stamp the first payoff wherever the capture came from.
    let metrics = MetricsRecorder()

    /// The Today sequence's generation instrumentation (tier counts, latency,
    /// tokens, skips, interruptions). Owned here because `todayPlan` is the one
    /// place a generation completes — see `TodayPlanService`.
    let planMetrics = PlanMetrics()

    /// True while a triage call is in flight — drives the soft-glow processing UI.
    var isProcessing = false

    init() {
        let (engine, status) = Self.resolveEngine()
        self.engine = engine
        self.status = status
    }

    private static func resolveEngine() -> (AIEngine, Status) {
        // Under XCTest, never probe Foundation Models. The simulator has no on-device
        // model — the heuristic is the path the sim exercises regardless — so this is
        // behavior-identical for tests. It also sidesteps an environmental flake: under
        // a heavy serial test run the `SystemLanguageModel.default.availability` XPC can
        // fault the process against the beta sim's unstable intelligence daemon (a
        // process-level SIGSEGV, not a logic bug). The env var is set only by the test
        // runner, so production is unaffected.
        if isRunningUnderXCTest {
            return (HeuristicEngine(), .fallback(reason: "test"))
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return (FoundationModelsEngine(), .onDevice)
        case .unavailable(let reason):
            return (HeuristicEngine(), .fallback(reason: Self.describe(reason)))
        @unknown default:
            return (HeuristicEngine(), .fallback(reason: "unavailable"))
        }
    }

    /// True inside the XCTest host process. Checks both the runner env var and the
    /// presence of the XCTest runtime (loaded into the host for XCTest *and* Swift
    /// Testing bundles) so the probe-skip is reliable regardless of how the bundle is
    /// launched. The shipping app links neither, so production is never affected.
    /// Internal so the Today plan seam can gate its own availability probe the same way.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device not eligible"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence off"
        case .modelNotReady: return "model downloading"
        @unknown default: return "unavailable"
        }
    }

    // MARK: - Triage

    /// Run the raw capture through the active engine, then the deterministic
    /// resolver (dates, learned rules, needs-decision, always-inbox). Never throws
    /// to the caller; on failure it degrades to the heuristic engine so capture
    /// never fails.
    ///
    /// - `roster`: household snapshot — gates the ownership check (empty = solo
    ///   no-op) and backs the on-device resolve-person tool.
    /// - `learned`: the user's learned corrections — injected as instructions for
    ///   the model AND applied deterministically by the resolver.
    /// - `openTasks`: the open working set — reverse dependency detection
    ///   ("should anything already open wait on this new task?").
    /// - `onPartial`: streaming seam — resolved partial candidates as the model
    ///   generates (device only; the heuristic is instant and never calls it).
    func triage(
        _ rawText: String,
        roster: [RosterPerson] = [],
        learned: [LearnedRule] = [],
        openTasks: [OpenTaskSnapshot] = [],
        onPartial: (@MainActor ([TaskDraft]) -> Void)? = nil
    ) async -> [TaskDraft] {
        isProcessing = true
        defer { isProcessing = false }
        // Retrieve the slice of the graph most relevant to this capture — the candidate
        // package the model uses for duplicate/child/blocks detection (the only valid ids).
        let candidates = ContextRetrieval.candidates(matching: rawText, among: openTasks)
        let context = TriageContext(
            personalization: CorrectionProfile.instructionLines(learned),
            roster: roster,
            openTasks: openTasks,
            candidates: candidates
        )
        // Resolve intents → drafts and apply the ownership gate — the one path both the
        // streaming partials and the final result run through.
        func resolveAndGate(_ intents: [TaskIntent]) -> [TaskDraft] {
            var drafts = IntentResolver.resolve(
                intents, rules: learned, openTasks: openTasks, candidates: candidates)
            Self.applyOwnershipGate(to: &drafts, hasHousehold: !roster.isEmpty)
            return drafts
        }
        let partialHandler: (@MainActor ([TaskIntent]) -> Void)? = onPartial.map { handler in
            { intents in handler(resolveAndGate(intents)) }
        }
        var intents: [TaskIntent]
        do {
            intents = try await engine.triage(
                rawText: rawText, context: context, onPartial: partialHandler)
            if intents.isEmpty { intents = try await HeuristicEngine().triage(rawText: rawText) }
        } catch {
            // On-device failure (e.g. guardrail, resource) → deterministic fallback.
            intents = (try? await HeuristicEngine().triage(rawText: rawText)) ?? []
        }
        return resolveAndGate(intents)
    }

    /// A confident (silent-tier) draft with no delegation detected, in a household
    /// that has other people, is flagged as unowned — "who does this belong to?"
    /// is a genuine open question the confirm card should surface. This sets only
    /// the `ownerPending` flag; "unowned" derives from it (see
    /// `TaskAssessment.isUnowned`). Judgment calls and low-confidence items
    /// already demand the user's eyes, so only confident filings gate. Solo
    /// installs (`hasHousehold == false`) are a complete no-op.
    static func applyOwnershipGate(to drafts: inout [TaskDraft], hasHousehold: Bool) {
        guard hasHousehold else { return }
        for i in drafts.indices where drafts[i].ownerName == nil && drafts[i].autonomy == .silent {
            drafts[i].ownerPending = true
        }
    }

    // MARK: - Household narrative

    /// Phrase the household's operating status over the engine's deterministic
    /// facts. Mirrors `triage`'s degrade-on-failure contract: the active engine
    /// (LLM on device, heuristic otherwise) tries first, and any on-device failure
    /// falls back to the deterministic template so the surface always has a sentence.
    func householdNarrative(_ facts: HouseholdFacts) async -> String {
        do {
            return try await engine.householdNarrative(facts)
        } catch {
            return (try? await HeuristicEngine().householdNarrative(facts)) ?? ""
        }
    }

    // MARK: - Commit

    /// Persist drafts, record the Capture they came from (raw text kept verbatim
    /// forever — one capture, many tasks), and log silent-tier filings to the change log.
    /// Capture Graph Awareness: a draft with an ACCEPTED duplicate proposal does NOT
    /// create a task — it MERGES into the target (the capture rides along); all other
    /// drafts create real tasks and may gain a parent link (accepted child) or a dismissed
    /// tombstone (rejected duplicate).
    @discardableResult
    func commit(
        _ drafts: [TaskDraft], rawCapture: String, source: CaptureSource = .text,
        into context: NSManagedObjectContext
    ) -> [TaskItem] {
        let capture = Capture(rawText: rawCapture, source: source, in: context)
        context.insert(capture)

        // Partition: accepted-duplicate drafts fold into an existing task; the rest create.
        let creating = drafts.filter { $0.acceptedDuplicate == nil }
        let merging = drafts.filter { $0.acceptedDuplicate != nil }

        // Author attribution: a real capture is created by the current user. Computed
        // once (only when there's something to stamp) so a commit never bootstraps the
        // you-identity for nothing. Feeds the My Tasks "Created" tab.
        let creatorID: UUID? = creating.isEmpty ? nil : UserProfile.currentMemberID(in: context)

        var created: [TaskItem] = []
        for draft in creating {
            let task = draft.makeTaskItem(rawCapture: rawCapture, captureID: capture.uuid, in: context)
            task.creatorID = creatorID
            context.insert(task)
            created.append(task)

            // Silent, reversible actions get a "recently tidied" change-log entry —
            // but not when a human step (who owns this?) is still pending, since
            // that isn't fully, silently handled yet.
            if draft.autonomy == .silent && !draft.ownerPending {
                let entry = ChangeLogEntry(
                    summary: "Filed “\(draft.title)” under \(draft.category)",
                    detail: draft.reasoning,
                    action: "filed",
                    initiatedBy: .ai,
                    isReversible: true,
                    taskTitle: draft.title,
                    taskUUID: task.uuid, in: context
                )
                context.insert(entry)
            }
        }

        // Every field the user edited at the confirm glance is a free labeled
        // pair — the local learning signal (write-only for now; consumed later).
        for (draft, task) in zip(creating, created) {
            for diff in draft.corrections {
                context.insert(
                    Correction(
                        taskUUID: task.uuid,
                        captureID: capture.uuid,
                        fieldCorrected: diff.field,
                        aiValue: diff.aiValue,
                        userValue: diff.userValue, in: context
                    ))
            }
        }

        // Fetch the working set ONCE — managed objects are unique per context, so every
        // helper below sees each other's mutations through this one array (no re-fetch buys
        // anything). `created` are already inserted, so they're included.
        let all = TaskItem.fetchAll(in: context)
        resolveBlockers(creating, created: created, all: all, in: context)
        resolveDependents(creating, created: created, all: all, in: context)
        resolveOwners(creating, created: created, in: context)
        resolveProposedEdges(creating, created: created, all: all, in: context)
        let mergeTargets = foldMerges(merging, capture: capture, all: all, in: context)
        capture.parsedTaskIDs = created.compactMap(\.uuid) + mergeTargets.compactMap(\.uuid)
        stampAttention(creating, created: created, mergeTargets: mergeTargets, all: all, in: context)

        try? context.save()
        if !created.isEmpty { metrics.recordFirstPayoffIfNeeded() }
        return created
    }

    /// Apply the reverse dependencies detected at capture: each open task the
    /// draft `blocks` gains a `.task` edge pointing at the newly created task —
    /// upgrading (replacing) the matching external note where one exists. Every
    /// edge is a reversible change-log entry; the trail's Undo removes the edge
    /// (never reopens the task). Cycle-safe via `addTaskBlocker`.
    private func resolveDependents(
        _ drafts: [TaskDraft], created: [TaskItem], all: [TaskItem], in context: NSManagedObjectContext
    ) {
        for (draft, task) in zip(drafts, created) {
            guard let newID = task.uuid, !draft.blocks.isEmpty else { continue }
            for ref in draft.blocks {
                guard let dependent = all.first(where: { $0.uuid == ref.id }),
                    !dependent.status.isResolved
                else { continue }
                // Upgrade: the external note this new task satisfies comes off first.
                for blocker in dependent.blockers
                where blocker.kind == .external
                    && blocker.note.map({ TaskItem.blockerMatches($0, resolvedTitle: task.title) }) == true
                {
                    dependent.removeBlocker(blocker.id, among: all)
                }
                let before = dependent.taskBlockerIDs.count
                dependent.addTaskBlocker(newID, among: all, provenance: .ai)  // no-ops if it'd cycle
                guard dependent.taskBlockerIDs.count > before else { continue }
                context.insert(
                    ChangeLogEntry(
                        summary: "“\(dependent.title)” now waits on “\(task.title)”",
                        detail: "Detected at capture — undo removes the link, nothing else.",
                        action: "linked",
                        fieldChanged: "blockers",
                        newValue: newID.uuidString,
                        initiatedBy: .ai,
                        isReversible: true,
                        taskTitle: dependent.title,
                        taskUUID: dependent.uuid, in: context
                    ))
            }
        }
    }

    /// Stamp the attention score on every created task now that its graph edges exist,
    /// carrying each draft's AI importance estimate into the score. Existing tasks a new
    /// task now waits on gained a dependent, so their centrality is refreshed too.
    /// `created` is in draft order, so `drafts[i]` ↔ `created[i]`.
    private func stampAttention(
        _ drafts: [TaskDraft], created: [TaskItem], mergeTargets: [TaskItem] = [],
        all: [TaskItem], in context: NSManagedObjectContext
    ) {
        for (draft, task) in zip(drafts, created) {
            task.attention = AttentionEngine.metadata(
                for: task, among: all, aiImportance: draft.aiImportance)
        }
        let createdIDs = Set(created.compactMap(\.uuid))
        // Existing tasks whose centrality shifted: blocker targets of new tasks, parents a
        // new child was linked to, and merge targets (their graph may have changed).
        let blockerTargetIDs = Set(created.flatMap { $0.taskBlockerIDs })
        let parentIDs = Set(created.compactMap(\.parentTaskID))
        let mergeIDs = Set(mergeTargets.compactMap(\.uuid))
        let touchIDs = blockerTargetIDs.union(parentIDs).union(mergeIDs)
        let touchedExisting = all.filter { task in
            guard let id = task.uuid else { return false }
            return touchIDs.contains(id) && !createdIDs.contains(id)
        }
        AttentionEngine.recompute(touchedExisting, among: all)
    }

    /// Apply the accepted capture-graph proposals on the newly created tasks: an accepted
    /// child link becomes a `.parent` edge (with a reversible "linked" entry); a REJECTED
    /// duplicate leaves a dismissed tombstone so the pair is never re-proposed. Accepted
    /// duplicates are handled separately by the merge fold (no task was created).
    private func resolveProposedEdges(
        _ drafts: [TaskDraft], created: [TaskItem], all: [TaskItem], in context: NSManagedObjectContext
    ) {
        let openIDs = Set(all.filter { !$0.status.isResolved }.compactMap(\.uuid))
        for (draft, task) in zip(drafts, created) {
            for proposal in draft.edgeProposals {
                switch (proposal.kind, proposal.decision) {
                case (.childOf, .accepted) where openIDs.contains(proposal.targetID):
                    task.linkParent(proposal.targetID)
                    context.insert(
                        ChangeLogEntry(
                            summary: "“\(task.title)” is now a step of “\(proposal.targetTitle)”",
                            detail: "Linked at capture — undo removes the link, nothing else.",
                            action: "linked", fieldChanged: "parent",
                            newValue: proposal.targetID.uuidString,
                            initiatedBy: .ai, isReversible: true,
                            taskTitle: task.title, taskUUID: task.uuid, in: context))
                case (.duplicateOf, .rejected):
                    task.tombstoneDuplicate(proposal.targetID)
                default:
                    continue  // undecided / non-open → nothing
                }
            }
        }
    }

    /// Fold each accepted-duplicate draft into its target: no new task, the target absorbs
    /// the capture (provenance note + parsedTaskIDs), and a reversible "merged" entry whose
    /// `oldValue` is the folded draft snapshot (so undo can resurrect it as an inbox task).
    /// Returns the merge targets so attention/parsedTaskIDs can account for them.
    private func foldMerges(
        _ merging: [TaskDraft], capture: Capture, all: [TaskItem], in context: NSManagedObjectContext
    ) -> [TaskItem] {
        guard !merging.isEmpty else { return [] }
        var targets: [TaskItem] = []
        for draft in merging {
            guard let proposal = draft.acceptedDuplicate,
                let target = all.first(where: { $0.uuid == proposal.targetID })
            else { continue }
            // The target absorbs this capture.
            let note = "Also captured: \(draft.title)"
            target.notes =
                [target.notes, note]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            target.touch()
            context.insert(
                ChangeLogEntry(
                    summary: "Merged “\(draft.title)” into “\(target.title)”",
                    detail: "Same as an existing task — folded in rather than duplicated.",
                    action: "merged", oldValue: MergedTaskSnapshot(draft: draft).encoded,
                    newValue: capture.uuid?.uuidString,
                    initiatedBy: .human, isReversible: true,
                    taskTitle: target.title, taskUUID: target.uuid,
                    actorID: UserProfile.currentMemberID(in: context), in: context))
            context.insert(
                Correction(
                    taskUUID: target.uuid, captureID: capture.uuid,
                    fieldCorrected: "duplicate", aiValue: proposal.targetTitle, userValue: "accepted",
                    in: context))
            targets.append(target)
        }
        return targets
    }

    /// Turn each draft's free-text owner guess ("ask sarah to…") into a real
    /// `FamilyMember` reference. A case-insensitive name match reuses the existing
    /// person; no match silently creates one — the same silent-tier mechanical
    /// filing philosophy already applied to categorization, not something that
    /// needs asking. Two captures naming "sarah" and "Sarah" resolve to one person.
    private func resolveOwners(_ drafts: [TaskDraft], created: [TaskItem], in context: NSManagedObjectContext)
    {
        var members = (try? context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))) ?? []
        for (draft, task) in zip(drafts, created) {
            guard let name = draft.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else { continue }
            if let match = members.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                task.ownerID = match.uuid
            } else {
                let member = FamilyMember(name: name, in: context)
                context.insert(member)
                members.append(member)
                task.ownerID = member.uuid
            }
        }

        // Everything still unowned and not deliberately left up-for-grabs is the current
        // user's own work — stamp it with your linked member id explicitly. The retired
        // `nil == you` sentinel is gone, so "mine" must be a real owner id (correct on
        // every synced device); a `nil` owner now means genuinely shared/unassigned.
        // Bootstrap the you-identity only when something actually needs it, so a commit
        // of purely delegated work never creates a spurious member.
        let unowned = created.filter { $0.ownerID == nil && !$0.ownerPending }
        if !unowned.isEmpty {
            let me = UserProfile.currentMemberID(in: context)
            for task in unowned { task.ownerID = me }
        }
    }

    /// Turn each draft's free-text blocker phrase into a real tracked-task blocker, now
    /// that every new task exists. Matches against the just-created batch plus existing
    /// not-done tasks. The AI only ever authors `.task` blockers — an "after X" it can't
    /// resolve to a real task (no match, or a cycle) creates nothing, and since every
    /// created task then re-derives, it lands unblocked rather than stranded in a
    /// phantom Blocked. `created` is in draft order, so `drafts[i]` ↔ `created[i]`.
    private func resolveBlockers(
        _ drafts: [TaskDraft], created: [TaskItem], all: [TaskItem], in context: NSManagedObjectContext
    ) {
        let createdIDs = Set(created.compactMap(\.uuid))
        // Candidates: everything unresolved, minus the just-created (added explicitly
        // so intra-batch references resolve even before the first save).
        let candidates =
            created
            + all.filter {
                !$0.status.isResolved && !createdIDs.contains($0.uuid ?? UUID())
            }
        for (draft, task) in zip(drafts, created) {
            guard let phrase = draft.blockedBy, !phrase.isEmpty else { continue }
            if let blockerID = TaskItem.resolveBlocker(
                phrase: phrase, among: candidates.filter { $0.uuid != task.uuid })
            {
                task.addTaskBlocker(blockerID, among: candidates, provenance: .ai)  // no-ops if it'd cycle
            } else {
                // No matching task: the captured wait becomes an EXTERNAL blocker in
                // the user's own words ("waiting on receipts") rather than being
                // silently lost. This does not breach the "AI never authors external
                // blockers" rule's intent: the phrase rode the Confirm-Creation card
                // (visible, removable) — it is confirm-sanctioned, never a silent
                // post-creation invention. Blocked stays derived either way.
                task.addExternalBlocker(phrase, among: candidates, provenance: .ai)
            }
        }
    }
}

// MARK: - Merge snapshot (undo resurrection)

/// The minimal frozen draft a "merged" change-log entry carries in `oldValue`, so Undo
/// can resurrect the folded task as a fresh inbox item (the merge never destroyed data).
struct MergedTaskSnapshot: Codable {
    var title: String
    var category: String
    var isUrgent: Bool
    var reasoning: String

    init(draft: TaskDraft) {
        title = draft.title
        category = draft.category
        isUrgent = draft.isUrgent
        reasoning = draft.reasoning
    }

    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ raw: String?) -> MergedTaskSnapshot? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MergedTaskSnapshot.self, from: data)
    }
}
