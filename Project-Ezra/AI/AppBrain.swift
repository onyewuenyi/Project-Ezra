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

    /// Warm everything the first capture parse of a session pays for: the shared
    /// on-device model (a no-op off-device / under tests), the `NLEmbedding`
    /// first-touch, and the persisted-vector warm-up — all currently costs that
    /// otherwise land inside the first debounce, on the thread the keyboard needs.
    /// Fire at the moment intent-to-capture is declared (the FAB, `openCapture`,
    /// `resumeCapture`), so the sheet-presentation animation absorbs the cost —
    /// the same trick the Today sequence plays behind its Recap cover.
    static func prewarmCapture(in context: NSManagedObjectContext) {
        ModelWarmup.prewarmSharedSession()
        _ = EmbeddingStore.sentenceEmbedding
        EmbeddingStore.warmUp(in: context)
    }

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
        suppressions: [RelationshipSuppression] = [],
        ownership: OwnershipContext = .none,
        onPartial: (@MainActor ([TaskDraft]) -> Void)? = nil
    ) async -> [TaskDraft] {
        isProcessing = true
        defer { isProcessing = false }
        // Retrieve the slice of the graph most relevant to this capture — the candidate
        // package the model uses for duplicate/child/blocks detection (the only valid ids).
        // Detached: the ranking runs up to 21 sentence-embedding inferences, and they
        // used to land on the main actor in the window right after the user's pause —
        // exactly when typing resumes. Pure over value snapshots; results come back here.
        let candidates = await Task.detached(priority: .userInitiated) {
            ContextRetrieval.candidates(matching: rawText, among: openTasks)
        }.value
        let context = TriageContext(
            personalization: CorrectionProfile.instructionLines(learned),
            roster: roster,
            openTasks: openTasks,
            candidates: candidates,
            suppressions: suppressions
        )
        // Resolve intents → drafts and propose an owner for each — the one path both
        // the streaming partials and the final result run through.
        func resolveAndGate(_ intents: [TaskIntent]) -> [TaskDraft] {
            var drafts = IntentResolver.resolve(
                intents, rules: learned, openTasks: openTasks, candidates: candidates,
                suppressions: suppressions)
            Self.proposeOwners(to: &drafts, ownership: ownership)
            return drafts
        }
        let partialHandler: (@MainActor ([TaskIntent]) -> Void)? = onPartial.map { handler in
            { intents in handler(resolveAndGate(intents)) }
        }
        var intents: [TaskIntent]
        if status.isOnDevice {
            // The on-device parse is bounded (`cardSeconds` — the user is watching the
            // composer) with streamed-partial salvage, and it is the one place capture
            // metrics are recorded: completed calls only, so debounce cancellations
            // can't pollute the deadline-tuning evidence.
            let started = Date()
            let outcome = await CaptureTriageRace.run(
                deadline: ModelDeadline.cardSeconds, onPartial: partialHandler
            ) { tee in
                try await self.engine.triage(rawText: rawText, context: context, onPartial: tee)
            }
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            switch outcome {
            case .finished(let value):
                ModelMetrics.shared.record(.captureTriage, .success, latencyMs: latency)
                intents = value
            case .salvaged(let value):
                // The deadline DID fire — record it (that's the tuning evidence) but
                // keep the streamed work instead of discarding it for a heuristic wipe.
                ModelMetrics.shared.record(.captureTriage, .timedOut, latencyMs: latency)
                intents = value
            case .timedOutEmpty:
                ModelMetrics.shared.record(.captureTriage, .timedOut, latencyMs: latency)
                intents = []
            case .cancelled:
                // Debounce supersession — the caller already dropped this generation.
                return []
            case .failed(let error):
                ModelMetrics.shared.record(
                    .captureTriage, .failed(Self.errorLabel(error)), latencyMs: latency)
                intents = []
            }
            // Model found nothing / timed out empty / failed → deterministic fallback,
            // exactly the degrade the old unbounded path promised.
            if intents.isEmpty {
                intents = (try? await HeuristicEngine().triage(rawText: rawText)) ?? []
            }
        } else {
            // Heuristic path: synchronous string work, no deadline needed, zero overhead
            // — and the branch every capture test exercises (XCTest forces this engine).
            do {
                intents = try await engine.triage(
                    rawText: rawText, context: context, onPartial: partialHandler)
                if intents.isEmpty {
                    intents = try await HeuristicEngine().triage(rawText: rawText)
                }
            } catch {
                intents = (try? await HeuristicEngine().triage(rawText: rawText)) ?? []
            }
        }
        return resolveAndGate(intents)
    }

    // MARK: - Parking (the durable half of capture)

    /// Park an in-flight capture so dismissing the composer cannot destroy it.
    ///
    /// Writes/updates ONE `Capture` row per composer session, carrying the verbatim raw
    /// text plus the current drafts. Returns the row so the session can keep updating
    /// it as the user types and hand it to `commit` on confirm.
    ///
    /// A parked capture is not a task and must never behave like one — see `Capture`.
    @discardableResult
    func park(
        _ drafts: [TaskDraft], rawCapture: String, source: CaptureSource,
        into existing: Capture?, in context: NSManagedObjectContext
    ) -> Capture? {
        let trimmed = rawCapture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        // Defense in depth for the one-row-per-event invariant: a deleted row can't be
        // updated (fall through and mint a fresh one — the thought still survives), and
        // a committed row is spent history (re-parking it would rewrite the verbatim
        // record of an event that already produced tasks — refuse, unchanged).
        let live: Capture? = existing.flatMap { row in
            guard row.managedObjectContext != nil, !row.isDeleted else { return nil }
            return row
        }
        if let live, live.committedAt != nil { return live }
        let capture = live ?? Capture(rawText: trimmed, source: source, in: context)
        if live == nil { context.insert(capture) }
        capture.rawText = trimmed
        capture.source = source
        capture.parkedDrafts = drafts
        context.saveChanges()
        return capture
    }

    /// Every capture still waiting to be confirmed, newest first.
    ///
    /// The `draftsData != nil` half of "parked" is filtered IN MEMORY, deliberately:
    /// Core Data cannot evaluate a fetch predicate against a Binary Data attribute, and
    /// attempting it throws at the store layer rather than returning empty. The
    /// uncommitted set is tiny by construction, so the predicate narrows on the cheap
    /// date attribute and `isParked` does the rest.
    static func parkedCaptures(in context: NSManagedObjectContext) -> [Capture] {
        let request = NSFetchRequest<Capture>(entityName: "Capture")
        request.predicate = NSPredicate(format: "committedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return ((try? context.fetch(request)) ?? []).filter(\.isParked)
    }

    /// The user explicitly throwing a capture away. The ONLY destructive path —
    /// swipe-to-dismiss parks, so nothing is lost by accident.
    static func discard(_ capture: Capture, in context: NSManagedObjectContext) {
        context.delete(capture)
        context.saveChanges()
    }

    /// Give every draft an owner. Replaces the retired `applyOwnershipGate`, which did
    /// the opposite — it flagged a confident household draft `ownerPending` and made
    /// the card ask. Every other field already reaches the confirm card populated and
    /// editable; owner is no longer the exception. See `OwnerProposer` for the ladder
    /// and for why load can only ever adjust a choice, never make one.
    ///
    /// The proposal writes `ownerName`, `ownerReason`, and `ownerBasis` — nothing is
    /// published and nobody is notified here. **Assignment side effects bind to the
    /// Confirm event, not to this field being populated** (see `commit`).
    static func proposeOwners(to drafts: inout [TaskDraft], ownership: OwnershipContext) {
        for i in drafts.indices {
            let proposal = OwnerProposer.propose(
                draft: drafts[i], roster: ownership.candidates,
                adjacentOwners: adjacentOwnerNames(for: drafts[i], in: ownership),
                history: ownership.history)
            drafts[i].ownerName = proposal.memberName
            drafts[i].ownerReason = proposal.reason
            drafts[i].ownerBasis = proposal.basis
        }
    }

    /// Owner names reachable through a draft's capture-graph proposals, in preference
    /// order: a duplicate target is literally the same work, a parent is the umbrella
    /// it belongs under. **Blockers are absent by design** — a blocker is frequently
    /// owned by someone else precisely *because* they are the bottleneck, so it points
    /// the wrong way as often as not.
    private static func adjacentOwnerNames(
        for draft: TaskDraft, in ownership: OwnershipContext
    ) -> [String] {
        let ordered =
            draft.edgeProposals.filter { $0.kind == .duplicateOf }
            + draft.edgeProposals.filter { $0.kind == .childOf }
        return ordered.compactMap { proposal in
            proposal.decision == .rejected ? nil : ownership.ownersByTaskID[proposal.targetID]
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

    /// **This IS Confirm.** A `TaskItem` comes into existence here and nowhere else —
    /// there is no pre-confirm task state to transition out of. Before this runs, the
    /// capture is single-player: parked on the capturer's device as raw text plus
    /// drafts, invisible to everyone else even when the inferred owner is somebody
    /// else.
    ///
    /// **Assignment side effects bind to this event, never to the owner field being
    /// populated** — see `publishAssignments`. That distinction is the seam a future
    /// "Confirm all" fast-path would otherwise leak a notification through.
    ///
    /// Persists drafts, records the Capture they came from (raw text kept verbatim
    /// forever — one capture, many tasks), and logs silent-tier filings to the change
    /// log. Capture Graph Awareness: a draft with an ACCEPTED duplicate proposal does
    /// NOT create a task — it MERGES into the target (the capture rides along); all
    /// other drafts create real tasks and may gain a parent link (accepted child) or
    /// write suppression records (rejected duplicate/child — see `SuppressionStore`).
    @discardableResult
    func commit(
        _ drafts: [TaskDraft], rawCapture: String, source: CaptureSource = .text,
        parked: Capture? = nil,
        into context: NSManagedObjectContext
    ) -> [TaskItem] {
        // The Capture row is written at PARSE time now (`park`), so a commit usually
        // ADOPTS the existing row rather than creating one — otherwise a parked capture
        // that is then confirmed would leave two rows for one event. Creating one here
        // is the path for callers with no composer session (onboarding, seeds).
        let capture: Capture
        if let parked {
            capture = parked
        } else {
            capture = Capture(rawText: rawCapture, source: source, in: context)
            context.insert(capture)
        }
        // Committed: no longer parked, and its derived drafts are spent.
        capture.committedAt = Date()
        capture.parkedDrafts = nil

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

            // A "recently tidied" change-log entry for confident filings. This records
            // that the CATEGORIZATION was the AI's, not that any card was skipped —
            // every task here is human-confirmed by construction, because commit is
            // the confirm.
            if draft.autonomy == .silent {
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
        publishAssignments(created, in: context)  // the ONE place assignment side effects fire
        resolveProposedEdges(creating, created: created, all: all, in: context)
        let mergeTargets = foldMerges(merging, capture: capture, all: all, in: context)
        capture.parsedTaskIDs = created.compactMap(\.uuid) + mergeTargets.compactMap(\.uuid)
        stampAttention(creating, created: created, mergeTargets: mergeTargets, all: all, in: context)

        context.saveChanges()
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
                // This upgrade churns the blocker set (drop the external note, add the new
                // task edge). If the external was the dependent's LAST active blocker,
                // `removeBlocker` stamps `lastUnblockedAt` — but the very next line re-blocks
                // it, so that "just unblocked" fact is spurious (it would hand a still-blocked
                // task the +12 recently-unblocked boost). Snapshot the fact and restore it
                // whenever the dependent ends this upgrade still blocked.
                let priorUnblockedAt = dependent.lastUnblockedAt
                // Upgrade: the external note this new task satisfies comes off first.
                for blocker in dependent.blockers
                where blocker.kind == .external
                    && blocker.note.map({ TaskItem.blockerMatches($0, resolvedTitle: task.title) }) == true
                {
                    dependent.removeBlocker(blocker.id, among: all)
                }
                let before = dependent.taskBlockerIDs.count
                dependent.addTaskBlocker(newID, among: all, origin: .inferred(confidence: 0.9))  // no-ops if it'd cycle
                if dependent.hasActiveBlockers(among: all) { dependent.lastUnblockedAt = priorUnblockedAt }
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
    /// proposal writes `SuppressionRecord`s (capture-form keyed on the normalized draft
    /// title so the same rejection sticks across captures, plus the pair form for
    /// both-tasks-exist consumers) so the pairing is never re-proposed. Accepted
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
                    SuppressionStore.recordRejectedDuplicate(
                        draftTitle: suppressionKeyTitle(for: draft), createdID: task.uuid,
                        targetID: proposal.targetID, in: context)
                case (.childOf, .rejected):
                    SuppressionStore.recordRejectedParent(
                        draftTitle: suppressionKeyTitle(for: draft), createdID: task.uuid,
                        parentID: proposal.targetID, in: context)
                default:
                    continue  // undecided / non-open → nothing
                }
            }
        }
    }

    /// The stable title a rejection is keyed on: the resolver builds its capture-form
    /// suppression key against the AI's ORIGINAL title (`normalizeTitle(intent.title)`), so
    /// the record must too — keying on the user-edited `draft.title` would let a
    /// renamed-then-rejected duplicate re-surface pre-accepted on the next capture.
    private func suppressionKeyTitle(for draft: TaskDraft) -> String {
        draft.aiOriginal?.title ?? draft.title
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
            target.touchHuman()  // the merge rode the user's confirm tap — real engagement
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

    /// Turn each draft's owner name into a real `FamilyMember` reference, by
    /// case-insensitive match. Two captures naming "sarah" and "Sarah" resolve to one
    /// person.
    ///
    /// **An unmatched name creates nothing.** This used to silently mint a
    /// `FamilyMember`, which looked like the same mechanical-filing philosophy applied
    /// to categorization — but a category is a label and a person is not. A phantom
    /// minted from a misheard name becomes an *existing* member: it can accrue
    /// category ownership, feed the affinity denominator, and be proposed as an owner
    /// for future work. So an unresolved name leaves the task shared (`ownerID == nil`)
    /// and the confirm card's existing "Add person…" is the explicit human step that
    /// grows the roster.
    private func resolveOwners(_ drafts: [TaskDraft], created: [TaskItem], in context: NSManagedObjectContext)
    {
        let members = (try? context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))) ?? []
        for (draft, task) in zip(drafts, created) {
            guard let name = draft.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else { continue }
            if let match = members.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                task.ownerID = match.uuid
            }
        }

        // Everything the proposer left as the capturer's own work gets the linked
        // member id explicitly. The retired `nil == you` sentinel is gone, so "mine"
        // must be a real owner id (correct on every synced device); a `nil` owner means
        // genuinely shared. Bootstrap the you-identity only when something actually
        // needs it, so a commit of purely delegated work never creates a spurious member.
        let mine = zip(drafts, created).filter {
            $0.1.ownerID == nil && $0.0.ownerName == nil
        }
        if !mine.isEmpty {
            let me = UserProfile.currentMemberID(in: context)
            for (_, task) in mine { task.ownerID = me }
        }
    }

    /// The publish boundary. Called once per commit, AFTER ownership is resolved, and
    /// it is the ONLY place an assignment may have an outward effect.
    ///
    /// Nothing fires today: there is no sync (`PersistenceStack.cloudKitContainerID`
    /// is nil, the entitlement's container list is empty) and no notification
    /// machinery, so the interim behavior is a silent publish. The seam exists now
    /// because the *rule* is the load-bearing part — assignment side effects bind to
    /// Confirm, never to the owner field being populated — and a future "Confirm all"
    /// fast-path must have one obvious place to respect it.
    ///
    /// When delivery lands, the target behavior is three-part (see `docs/task-model.md`):
    /// one notification per assignment bound to this event, re-notify only on a genuine
    /// reassignment, and copy that names the source ("Charles assigned you: …").
    private func publishAssignments(_ created: [TaskItem], in context: NSManagedObjectContext) {
        guard HouseholdSync.isLive else { return }
        let me = UserProfile.currentMemberID(in: context)
        let handedOff = created.filter { $0.ownerID != nil && $0.ownerID != me }
        guard !handedOff.isEmpty else { return }
        // Delivery lands here. Deliberately unimplemented rather than stubbed with a
        // local notification: notifying yourself about a task you just created is
        // theater, and the guardrails refuse notification-driven re-engagement.
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
                task.addTaskBlocker(blockerID, among: candidates, origin: .inferred(confidence: 0.9))  // no-ops if it'd cycle
            } else {
                // No matching task: the captured wait becomes an EXTERNAL blocker in
                // the user's own words ("waiting on receipts") rather than being
                // silently lost. This does not breach the "AI never authors external
                // blockers" rule's intent: the phrase rode the Confirm-Creation card
                // (visible, removable) — it is confirm-sanctioned, never a silent
                // post-creation invention. Blocked stays derived either way.
                task.addExternalBlocker(phrase, among: candidates, origin: .inferred(confidence: 0.9))
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
