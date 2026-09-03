//
//  TaskMutations.swift
//  Project-Ezra
//
//  The single source of truth for how a task changes status. Lists and the
//  detail sheet both mutate through these helpers so behavior can never drift
//  between surfaces. These helpers touch only the *status* axis (and the
//  ownership / blocker inputs the assessment reads) — they never write a derived
//  observation. "Blocked" is computed on read (see `TaskAssessment`), so adding a
//  blocker never disturbs the status.
//
//  Every helper that meaningfully touches a task bumps `updatedAt` — Stale
//  detection (untouched-since) depends on that honesty. `transition(to:)` bumps
//  it itself; helpers that don't transition call `touch(now:)`.
//
//  Dependencies are real references (`TaskItem.blockers`), so "blocked" derives
//  from the *active* (unresolved) blockers at read time. Resolving a task
//  resurfaces the dependents it frees (logged); reopening one re-blocks them
//  automatically — the graph stays honest in both directions.
//
//  Callers keep owning `context.save()`, haptics, and animation — these helpers
//  only touch model state.
//

import Foundation
import CoreData

extension TaskItem {
    /// Fetch every task in the context — the shared form of the
    /// `(try? context.fetch(...)) ?? []` idiom that was copy-pasted across the mutation and
    /// undo seams. (Commit's `?? created` fallback stays inline — it wants a different tail.)
    static func fetchAll(in context: NSManagedObjectContext) -> [TaskItem] {
        (try? context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? []
    }

    /// Bump the untouched-since clock. Called by every mutation that doesn't go
    /// through `transition(to:now:)` (which bumps it itself).
    func touch(now: Date = Date()) {
        updatedAt = now
    }

    /// The HUMAN clock: a human-initiated edit bumps `lastHumanTouchAt` alongside
    /// `updatedAt`. System paths (capture-time edge writes on existing tasks, sweeps)
    /// call plain `touch()` — staleness and the plan-reconcile deferral discriminator
    /// read the human clock only, so a system write can never fake engagement.
    /// The day answer named this task (F-11). Feeds `RequiredAttention.orientation` —
    /// the share of worked tasks the answer never surfaced. Deliberately does NOT bump
    /// `updatedAt` or `lastHumanTouchAt`: being surfaced is something the system did,
    /// not something the person did, and it must move neither staleness nor the
    /// Advisor's fingerprint.
    func markSurfaced(now: Date = Date()) {
        lastSurfacedAt = now
    }

    func touchHuman(now: Date = Date()) {
        lastHumanTouchAt = now
        // Engagement breaks the avoidance streak. `deferralCount` counts times the task
        // was PLANNED AND IGNORED, so it must mean "consecutively", not "ever": the
        // rollover only ever increments it, and nothing else clears it, so without this
        // reset a task that crossed `StallDetector.deferralThreshold` once would show
        // "This keeps sliding" for the rest of its live life — every Unstick action
        // (do it now, defer, break it down) routes through here, so the card would
        // survive the very tap meant to dismiss it. It would also carry the ranking
        // pull-down forever, penalising a task the user has since picked back up.
        // `carriedOverCount` is the lifetime worked-but-unfinished counter and is
        // deliberately NOT reset — the two answer different questions.
        deferralCount = 0
        touch(now: now)
    }

    /// Set the Urgent signal. No-op guard, recompute the attention score (urgent is a
    /// contributor), and log a reversible "edited" row for the task's Activity timeline.
    /// `logHumanEdit` bumps the touch clock and handles coalescing/round-trip deletion.
    func setUrgent(
        _ value: Bool, among tasks: [TaskItem], in context: NSManagedObjectContext, now: Date = Date()
    ) {
        guard value != isUrgent else { return }
        let old = isUrgent
        isUrgent = value
        AttentionEngine.recompute([self], among: tasks, now: now)
        logHumanEdit(
            field: "urgent", oldValue: old ? "true" : "false", newValue: value ? "true" : "false",
            summary: value ? "Marked urgent" : "Cleared urgent", now: now, in: context)
    }

    /// Mark done via the normal completion path. Human-initiated only — the AI
    /// never marks a task complete on the user's behalf; that's a real-world
    /// action only the user can attest to.
    ///
    /// Goes through `transition(to:now:)` so the caller's timestamp lands in the
    /// state timeline too — otherwise the timeline would stamp `Date()` while
    /// `completedAt` said something else.
    func complete(now: Date = Date()) {
        transition(to: .done, now: now)
        completedAt = now
        killedAt = nil
    }

    /// Explicitly kill — resolved, but recorded as a kill so resolution honesty
    /// (done vs. abandoned) is preserved. Human-initiated (manual or via the
    /// retro), or silent past the long stale threshold (auto-archive) — always
    /// reversible via Undo either way.
    func kill(now: Date = Date()) {
        transition(to: .canceled, now: now)
        completedAt = now  // "when resolved", for timeToResolution and open-set checks
        killedAt = now
    }

    // NOTE: there is no `confirm()`. Confirm is no longer a transition a task makes —
    // it is the moment a task comes into existence. `AppBrain.commit` IS the confirm:
    // it turns parked drafts into `TaskItem`s born `.todo`, stamping `confirmedAt` at
    // creation. Before that there is no task, only a parked `Capture`. A judgment
    // call's `needsDecision` still survives creation — confirming that "figure out if
    // X" exists is not making the call; only `resolveDecision()` clears that.

    /// Apply a fresh `WorkIntent` from the classifier.
    ///
    /// A plain write. It used to log a reversible entry when the intent crossed the
    /// *workload boundary* (`action ↔ reference`), because that quietly re-scoped five
    /// operational systems on a model call. With `.reference` retired there is no such
    /// boundary left — every remaining kind counts as work — so a reclassification only
    /// changes which capability the detail offers, which was always the silent case.
    ///
    /// There is no human path any more (2026-08-11): `workIntent` is system-owned —
    /// the type chips and `setWorkIntent` are deleted, and this classifier chain is
    /// the field's only writer. Trust moved from human correction to evaluation
    /// (`RambleEvalTests` scores the kind with a regression floor).
    func reclassify(
        to intent: WorkIntent, in context: NSManagedObjectContext, now: Date = Date()
    ) {
        guard intent != workIntent else { return }
        workIntent = intent
        touch(now: now)
    }

    /// The human explicitly making the call a Needs Decision flag was waiting on.
    /// The only way a judgment call's flag ever clears.
    func resolveDecision(now: Date = Date()) {
        needsDecision = false
        touchHuman(now: now)
    }

    /// Escalate-to-Decision: sets the one visible flag. This IS the ask-tier
    /// mechanism — setting the flag is itself what routes the task to visible
    /// attention; there is no separate confirmation step.
    func escalateToDecision(now: Date = Date()) {
        needsDecision = true
        touch(now: now)
    }

    /// Defer: push the due date (or clear it), resetting the attention clocks.
    /// Human-initiated, from the retro or a swipe.
    func deferTask(until date: Date?, now: Date = Date()) {
        dueDate = date
        touchHuman(now: now)
    }

    /// Set who owns this task — the current user (pass `UserProfile.currentMemberID`),
    /// another family member (their uuid), or hand it back to the household (`nil`).
    /// Ownership is its own axis: this never touches the status or the blocker list.
    /// `tasks` is unused (kept for call-site symmetry with the other graph-aware
    /// mutations).
    ///
    /// **This is a human path, so it stamps `ownerOrigin = .human`** — which is what
    /// the affinity denominator counts. `origin` is a parameter only so
    /// `ChangeLogUndo` can restore the *prior* origin when reverting an `"assigned"`
    /// entry: without that, undoing a reassignment would leave an AI-inferred owner
    /// marked human and quietly pollute the denominator (the undo-completeness rule —
    /// an undo restores every field the action wrote, not just the headline one).
    func claim(ownerID: UUID?, among tasks: [TaskItem], origin: OwnerOrigin = .human) {
        self.ownerID = ownerID
        self.ownerOrigin = origin
        touchHuman()
    }

    // NOTE: there is no `block()`. Blocked is never a status — it is derived
    // from `blockers` (see `TaskAssessment.isBlocked`). To block a task you add a
    // `Blocker` (a tracked task, or an untracked "something else"); to unblock,
    // you remove them. That makes "blocked with nothing blocking it"
    // unrepresentable, and blocking never disturbs the status.

    /// The two graph-write primitives — the structural choke point every edge mutation
    /// funnels through (read-mutate-write + `touch()`), so the DEBUG `Relationship.validate`
    /// (in the setter) and the touch-clock bump live in one place. The kind-specific guards
    /// (self/cycle/dedup/no-op) stay in the public verbs above each call.
    fileprivate func appendRelationship(_ relationship: Relationship, now: Date = Date()) {
        var rels = relationships
        rels.append(relationship)
        relationships = rels
        touch(now: now)
    }

    fileprivate func removeRelationships(where predicate: (Relationship) -> Bool, now: Date = Date()) {
        relationships = relationships.filter { !predicate($0) }
        touch(now: now)
    }

    /// Undo of a force-unblock — the ONLY caller is `ChangeLogUndo`'s `"unblocked"` arm.
    ///
    /// Deliberately not `touchHuman`: reverting a mis-tap is not engagement with the
    /// task, and stamping the human clock here would clear a genuine staleness signal
    /// (and, via `touchHuman`, reset `deferralCount`) as a side effect of undo.
    func restoreBlockerEdges(_ snapshot: UnblockSnapshot, now: Date = Date()) {
        guard !snapshot.removed.isEmpty else { return }
        // Anything re-added since the unblock stays: undo restores what the action
        // removed, it does not roll the graph back to a moment in time.
        let existing = Set(relationships.map(\.id))
        relationships += snapshot.removed.filter { !existing.contains($0.id) }
        lastUnblockedAt = snapshot.priorUnblockedAt
        touch(now: now)
    }

    /// Force-unblock: drop every `.blocks` edge (tracked and external alike), leaving
    /// any `.parent`/other edges intact. The detail sheet's "Unblock" action. Leaves
    /// the status alone — the task simply stops reading as blocked on the next
    /// derivation. Human-initiated (a detail/recommended-action tap), so it stamps
    /// both `lastUnblockedAt` (the recently-unblocked fact) and the human clock.
    ///
    /// Returns what it removed and the `lastUnblockedAt` it overwrote, so
    /// `unblockAndLog` can make the action reversible. Splitting the call by `Origin`
    /// was considered and rejected: `addTaskBlocker`/`addExternalBlocker` both default
    /// to `.human`, so an origin-gated version would prompt on nearly every tap while
    /// still leaving the underlying action irreversible. Reversibility is the fix, and
    /// `unblockAndLog` is the seam every UI caller should use.
    @discardableResult
    func unblock(now: Date = Date()) -> UnblockSnapshot? {
        guard !blockers.isEmpty else { return nil }
        let removed = relationships.filter { $0.kind == .blocks }
        let priorUnblockedAt = lastUnblockedAt
        removeRelationships { $0.kind == .blocks }
        lastUnblockedAt = now
        touchHuman(now: now)
        return UnblockSnapshot(removed: removed, priorUnblockedAt: priorUnblockedAt)
    }

    /// The logged, reversible form — what the detail sheet's "Unblock" CTA runs.
    ///
    /// This used to be the one destructive mutation on the type with no `ChangeLogEntry`
    /// and no undo: a full-width primary button that dropped N edges, human-authored
    /// ones included, with nothing to restore them from. `ActivityVocab` already carried
    /// an `"unblocked"` glyph, tint and word that nothing wrote — the trail entry was
    /// designed and never wired.
    func unblockAndLog(in context: NSManagedObjectContext, now: Date = Date()) {
        guard let snapshot = unblock(now: now) else { return }
        let count = snapshot.removed.count
        context.insert(
            ChangeLogEntry(
                summary: "Unblocked “\(title)”",
                detail: count == 1 ? "Cleared 1 blocker" : "Cleared \(count) blockers",
                action: "unblocked",
                fieldChanged: "blockers",
                oldValue: TaskItem.encodeUnblock(snapshot),
                initiatedBy: .human,
                isReversible: true,
                taskTitle: title,
                taskUUID: uuid,
                actorID: UserProfile.currentMemberID(in: context),
                in: context
            ))
    }

    /// Reopen a resolved task, restoring the live status it left when it was resolved
    /// (from the state timeline) rather than guessing — a task killed mid-flight comes
    /// back `.doing`. Dependents re-block automatically: `self` is unresolved again, so
    /// it counts as an active blocker on the next read. `tasks` is unused (kept for
    /// call-site symmetry).
    ///
    /// **The floor is `.todo`.** The timeline is stored as raw strings and can outlive
    /// an enum change, so an unrecognized or resolved value must never route a task
    /// somewhere unreachable — it lands `.todo`, the state every task is born into.
    func reopen(among tasks: [TaskItem]) {
        completedAt = nil
        killedAt = nil
        let restored =
            stateTimeline.last { visit in
                TaskStatus(rawValue: visit.state).map(\.isLive) ?? false
            }
            .flatMap { TaskStatus(rawValue: $0.state) } ?? .todo
        status = restored.isLive ? restored : .todo
    }

    /// Add a tracked dependency (a `.blocks` edge). No-ops on self, a live duplicate, or
    /// a reference that would close a cycle (so a task can never become infinitely
    /// blocked). `tasks` supplies the graph for the cycle check AND the attention
    /// recompute (the target gains a dependent). `origin` is `.human` by default;
    /// AI sites (capture-time blocker/dependent resolution) pass `.inferred`.
    func addTaskBlocker(
        _ blockerID: UUID, among tasks: [TaskItem], origin: Relationship.Origin = .human
    ) {
        guard let selfID = uuid, blockerID != selfID, !taskBlockerIDs.contains(blockerID) else {
            return
        }
        let map = TaskItem.blockersByUUID(tasks)
        guard !TaskItem.wouldCreateCycle(from: selfID, adding: blockerID, blockersByUUID: map) else {
            return
        }
        appendRelationship(.blocks(taskID: blockerID, origin: origin))
        // The blocker task just gained an open dependent → its graph centrality shifts.
        if let target = tasks.first(where: { $0.uuid == blockerID }) {
            AttentionEngine.recompute([target], among: tasks)
        }
    }

    /// Add an untracked blocker in the user's own words ("the contractor calls back") —
    /// a `.blocks` edge with no target. Nothing auto-resurfaces it. `note` nil reads as
    /// "something else". No cycle risk — an external blocker has no edge, and (having no
    /// target) it never shifts anyone's centrality. `.human` by default; the one
    /// sanctioned AI site (a captured wait that matched no task at commit) passes `.inferred`.
    func addExternalBlocker(
        _ note: String?, among tasks: [TaskItem], origin: Relationship.Origin = .human
    ) {
        appendRelationship(.externalWait(note, origin: origin))
    }

    /// Link this task as a step UNDER `parentID` — a `.parent` edge (Split-Into-Subtasks /
    /// capture child-linking). No-ops on self or a live duplicate.
    func linkParent(_ parentID: UUID, origin: Relationship.Origin = .human) {
        guard let selfID = uuid, parentID != selfID,
            !relationships.contains(where: { $0.kind == .parent && $0.targetID == parentID })
        else { return }
        appendRelationship(.parent(taskID: parentID, origin: origin))
    }

    /// Remove a `.parent` edge to `parentID` (the undo of `linkParent`).
    func unlinkParent(_ parentID: UUID) {
        removeRelationships { $0.kind == .parent && $0.targetID == parentID }
    }

    /// Remove one `.blocks` edge by its id (task or external). Recomputes the ex-target's
    /// attention (it lost a dependent). Stamps `lastUnblockedAt` when this removal is the
    /// one that frees the task (its last ACTIVE blocker) — the edge is gone after this,
    /// so the moment must be recorded here or never. No human-clock bump: callers span
    /// human taps, capture-time upgrades, and undo.
    func removeBlocker(_ blockerID: UUID, among tasks: [TaskItem], now: Date = Date()) {
        let wasBlocked = hasActiveBlockers(among: tasks)
        let exTargetID = relationships.first { $0.id == blockerID }?.targetID
        removeRelationships { $0.id == blockerID && $0.kind == .blocks }
        if wasBlocked && !hasActiveBlockers(among: tasks) { lastUnblockedAt = now }
        if let exTargetID, let target = tasks.first(where: { $0.uuid == exTargetID }) {
            AttentionEngine.recompute([target], among: tasks)
        }
    }

    /// Remove the tracked `.blocks` edge(s) pointing at a specific target task — the shared
    /// "undo of a task-blocker add" that both `ChangeLogUndo` arms (AI "linked" and human
    /// "blockers") did by hand.
    func removeTaskBlockerEdges(to targetID: UUID, among tasks: [TaskItem]) {
        for blocker in blockers where blocker.kind == .task && blocker.taskID == targetID {
            removeBlocker(blocker.id, among: tasks)
        }
    }

    // MARK: - Break this down (the split seam)

    /// Turn accepted breakdown steps into real child tasks.
    ///
    /// Three rules this encodes, each of which is a product invariant rather than an
    /// implementation choice:
    ///
    /// 1. **Children are created, exactly like a capture.** A task comes into existence
    ///    only when a human confirms it, so these are born `.todo` with `confirmedAt`
    ///    stamped — the accept tap IS that confirm. They inherit the parent's owner and
    ///    category, because a step of your work is your work.
    /// 2. **One entry, not N.** The user performed one action; the feed should say so,
    ///    and Undo should reverse the whole split rather than leave a half-decomposed
    ///    parent. The created ids ride in `newValue` so the undo arm can find them.
    /// 3. **The AI never splits on its own.** This is only ever called from an explicit
    ///    accept — the service proposes, the person decides.
    /// 4. **Containment is the ONLY edge written.** The umbrella genuinely cannot be
    ///    finished before its steps, but that fact is DERIVED from the children's own
    ///    `.parent` edges (`openSteps(among:)`), never stored as `.blocks` on the parent.
    ///    Writing it would fuse the two graphs `children(among:)` warns about — `.parent`
    ///    is containment, `.blocks` is sequencing — and every reader of
    ///    `hasActiveBlockers` would inherit the question "obstacle, or container?".
    ///    Deriving also means the wait dies with the step: nothing to unwind in undo, no
    ///    `lastUnblockedAt` to restore, no cycle to check.
    ///
    /// Returns the created children. Callers own `save()`.
    @discardableResult
    func splitInto(
        _ steps: [BreakdownStep], in context: NSManagedObjectContext, now: Date = Date()
    ) -> [TaskItem] {
        guard !steps.isEmpty, let selfID = uuid else { return [] }
        var created: [TaskItem] = []
        for (index, step) in steps.enumerated() {
            let child = TaskItem(
                title: step.title,
                category: category,
                status: .todo,
                creatorID: creatorID,
                confidence: confidence,
                reasoning: "A step of “\(title)”.",
                isUrgent: false,
                ownerID: ownerID,
                ownerOrigin: ownerOrigin,
                effortMinutes: step.effortMinutes,
                captureID: captureID,
                rawCapture: rawCapture,
                createdAt: now,
                in: context)
            child.confirmedAt = now  // the accept tap is the confirm
            // The model's sequence, finally persisted — siblings share one `now`, so
            // without this the order died at the exact write meant to keep it.
            child.sortIndex = Int32(index)
            child.linkParent(selfID)
            context.insert(child)
            created.append(child)
        }
        touchHuman(now: now)
        context.insert(
            ChangeLogEntry(
                summary: "Broke “\(title)” into \(created.count) steps",
                detail: created.map(\.title).joined(separator: " · "),
                action: "split",
                fieldChanged: "children",
                newValue: created.compactMap { $0.uuid?.uuidString }.joined(separator: ","),
                initiatedBy: .human,
                isReversible: true,
                taskTitle: title,
                taskUUID: uuid,
                actorID: UserProfile.currentMemberID(in: context),
                timestamp: now, in: context
            ))
        return created
    }
}

// MARK: - Recommended Action (the derived "one obvious next tap")

/// The single best next move for a task, derived from its lifecycle stage, its
/// obstacles, and who owns it. Fuses what used to be two parallel switches (button
/// title + behavior) into one value, so the label and the action can never drift
/// apart.
enum RecommendedAction: Equatable {
    case claim  // take ownership of one handed back to the household
    case unblock  // drop the blockers holding it
    case start  // pick it up — .todo → .doing
    case resume  // pick it up AGAIN — .todo → .doing on a task with a closed `.doing` visit
    case resolve  // mark an in-flight task done
    case reopen  // bring a resolved task back

    /// **The verb may only promise what this button actually does, which is move the
    /// lifecycle.** The intent-voiced verbs are gone, one at a time and for the same
    /// reason: `.planning`'s "Break it down" was a lie (every arm runs
    /// `setStatus(.doing)`; the breakdown belongs to its capability card), and
    /// `.decision`'s "Decide" retired with the Decision type itself (2026-08-08 —
    /// choosing is a capability the system brings, not a kind of work the button
    /// voices). What remains is the truth: Start.
    var title: String {
        switch self {
        case .claim: return "That's mine"
        case .unblock: return "Unblock"
        case .start: return "Start"
        case .resume: return "Resume"
        case .resolve: return "Mark done"
        case .reopen: return "Reopen"
        }
    }

    /// The icon for the same verb, so a surface that shows one shows the other — the
    /// record row's leading swipe reveals `symbol` + `title` together, and it must read
    /// as the same action the detail's pinned CTA would perform, because it is: both go
    /// through `performRecommendedAction`.
    var symbol: String {
        switch self {
        case .claim: return "person.crop.circle"
        case .unblock: return "lock.open"
        case .start, .resume: return "play.fill"
        case .resolve: return "checkmark"
        case .reopen: return "arrow.uturn.backward"
        }
    }

    /// The detail sheet dismisses after resolving (the task leaves the working
    /// set); every other action keeps it open so the user sees the result in place.
    /// `.start` deliberately stays — the button relabels to "Mark done" underneath
    /// the tap, which is how the lifecycle teaches itself.
    var dismissesDetail: Bool { self == .resolve }
}

extension TaskItem {
    /// The recommended next action — nil when this surface has no honest move to
    /// offer. Read as a tree, not a ladder: *is it settled → is it even a to-do →
    /// is it mine → can it be worked on → what stage is it in.*
    ///
    /// The nil arm is the point. A task owned by someone else is not yours to advance
    /// — offering it a primary CTA means offering a button that is wrong by
    /// construction. Its proxy actions live in the "…" menu, and the empty slot is
    /// reserved for Nudge/Comment once `HouseholdSync` makes those real.
    ///
    /// Claim precedes unblock on purpose: you take the thing before you clear its path.
    ///
    /// Takes `currentUserID` (`UserProfile.linkedMemberID`) rather than a context on
    /// purpose — this is read during view body evaluation, and `currentMemberID(in:)`
    /// bootstraps an identity, so passing a context here would insert and save mid-render.
    /// A nil id (no profile yet) falls through to the normal lifecycle CTA rather than
    /// blanking the button: hide the slot only when the owner is *known* to be someone
    /// else.
    func recommendedAction(among tasks: [TaskItem], currentUserID: UUID?) -> RecommendedAction? {
        if status.isResolved { return .reopen }
        if ownerID == nil { return .claim }
        if let currentUserID, !isMine(currentUserID: currentUserID) { return nil }
        if hasActiveBlockers(among: tasks) { return .unblock }
        switch status {
        // A task with a closed `.doing` visit has been here before — "Resume" says the
        // more useful thing: you are picking something back up.
        case .todo: return hasBeenStarted ? .resume : .start
        case .doing: return .resolve
        case .done, .canceled: return .reopen  // unreachable — `isResolved` caught these
        }
    }

    /// Run an already-resolved action, so the label the user tapped and the mutation
    /// that runs are the same decision rather than two independent derivations.
    /// Callers own `save()`.
    /// Returns any dependents the action freed, so the caller can name them in an undo
    /// notice ("Completed X — unblocked Y"). Only `.resolve` can free anything; every
    /// other arm returns `[]`. Returning it here rather than re-deriving at the call
    /// site keeps the resurfacing chain readable from exactly one place.
    @discardableResult
    func performRecommendedAction(
        _ action: RecommendedAction, among tasks: [TaskItem], in context: NSManagedObjectContext
    ) -> [TaskItem] {
        switch action {
        case .claim:
            claimAndLog(ownerID: UserProfile.currentMemberID(in: context), among: tasks, in: context)
        // Through the logged seam: dropping every blocker at once is destructive and
        // human-authored edges are among the casualties, so it owes a trail row and an
        // undo like every other mutation here.
        case .unblock: unblockAndLog(in: context)
        // Through the shared seam: records the StateVisit, logs a coalescing human
        // edit that self-deletes on a round-trip, stays out of the Activity feed, and
        // bumps the human clock so picking a task up resets its staleness.
        case .start, .resume: setStatus(.doing, in: context)
        case .resolve: return completeAndResurface(in: context)
        case .reopen: reopenAndReblock(in: context)
        }
        return []
    }
}

// MARK: - Dependency chains (auto-resurface / re-block)

extension TaskItem {
    /// Resolution seam used by every list and the detail sheet: complete + resurface
    /// any dependents this frees. Records a reversible HUMAN "completed" entry (only
    /// the user can attest a real-world completion) so it surfaces in the Activity feed
    /// with the actor's avatar; its undo reopens (never sends to inbox). Returns what
    /// resurfaced so the flow can say so in place. Callers still own `save()`.
    @discardableResult
    func completeAndResurface(in context: NSManagedObjectContext, now: Date = Date()) -> [TaskItem] {
        complete(now: now)
        touchHuman(now: now)  // only a human can attest a real-world completion
        logHumanResolution(action: "completed", verb: "Completed", now: now, in: context)
        return Self.resurfaceDependents(of: self, in: context, now: now)
    }

    /// Kill also resolves the dependency — the blocker is settled either way, so
    /// dependents resurface rather than waiting forever on a dead task. Records a
    /// reversible HUMAN "killed" entry for the Activity feed (undo reopens).
    @discardableResult
    func killAndResurface(in context: NSManagedObjectContext, now: Date = Date()) -> [TaskItem] {
        kill(now: now)
        touchHuman(now: now)  // the manual cancel path (the silent auto-archive calls `kill` directly)
        logHumanResolution(action: "killed", verb: "Canceled", now: now, in: context)
        return Self.resurfaceDependents(of: self, in: context, now: now)
    }

    /// The one place a human resolution (complete/cancel) is logged for Activity
    /// feed. Stamps the current user as `actorID` so the feed can render their avatar.
    private func logHumanResolution(
        action: String, verb: String, now: Date, in context: NSManagedObjectContext
    ) {
        context.insert(
            ChangeLogEntry(
                summary: "\(verb) “\(title)”",
                action: action,
                initiatedBy: .human,
                isReversible: true,
                taskTitle: title,
                taskUUID: uuid,
                actorID: UserProfile.currentMemberID(in: context),
                timestamp: now,
                in: context
            ))
    }

    /// Record a reversible HUMAN field edit (priority, title, due date, category, effort,
    /// description, stage, blockers) for the task's own Activity timeline. Sits alongside
    /// `logHumanResolution`/`claimAndLog` and shares their convention (`.human`, current
    /// user as `actorID`), but its `editedAction` verb keeps it OUT of the global Inbox
    /// (see `ChangeLogEntry.isActivityVisible`). Snapshot the old value at the call site.
    ///
    /// Two behaviors every call site gets for free:
    /// - **No-op guard**: identical old/new logs nothing (re-picking the current value).
    /// - **Coalescing**: a rapid burst of same-field edits by the same actor (priority
    ///   low→high→urgent while deciding) folds into ONE entry — the pre-burst `oldValue`
    ///   is preserved so Undo restores the true prior state; a round-trip back to that
    ///   value deletes the entry (the burst netted out to nothing). Pass `coalescable:
    ///   false` for collection fields (blockers) where each add/remove is a distinct event.
    func logHumanEdit(
        field: String, oldValue: String?, newValue: String?, summary: String,
        reversible: Bool = true, coalescable: Bool = true, now: Date = Date(),
        in context: NSManagedObjectContext
    ) {
        guard oldValue != newValue else { return }
        touchHuman(now: now)  // a real human field edit — keep both clocks honest
        let actor = UserProfile.currentMemberID(in: context)

        if coalescable,
            let recent = recentCoalescableEdit(field: field, actor: actor, now: now, in: context)
        {
            if recent.oldValue == newValue {
                // Round-tripped back to where the burst started — nothing net changed.
                context.delete(recent)
            } else {
                recent.newValue = newValue
                recent.summary = summary
                recent.timestamp = now
            }
            return
        }

        context.insert(
            ChangeLogEntry(
                summary: summary,
                action: ChangeLogEntry.editedAction,
                fieldChanged: field,
                oldValue: oldValue,
                newValue: newValue,
                initiatedBy: .human,
                isReversible: reversible,
                taskTitle: title,
                taskUUID: uuid,
                actorID: actor,
                timestamp: now,
                in: context
            ))
    }

    /// The most recent same-field "edited" entry on this task that a new edit should fold
    /// into: same actor, not undone, and within the 5-minute coalescing window. A
    /// different actor (someone else touched the same field) never coalesces.
    private func recentCoalescableEdit(
        field: String, actor: UUID?, now: Date, in context: NSManagedObjectContext
    ) -> ChangeLogEntry? {
        guard let uuid else { return nil }
        let request = NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")
        request.predicate = NSPredicate(
            format: "taskUUID == %@ AND action == %@ AND fieldChanged == %@ AND undone == NO",
            uuid as CVarArg, ChangeLogEntry.editedAction, field)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)
        ]
        request.fetchLimit = 1
        request.includesPendingChanges = true
        guard let recent = try? context.fetch(request).first, recent.actorID == actor else {
            return nil
        }
        let elapsed = now.timeIntervalSince(recent.timestamp)
        guard elapsed >= 0, elapsed <= 300 else { return nil }
        return recent
    }

    /// Apply a lifecycle state. The SINGLE seam both the row glyph menu and the detail
    /// picker call, so those two can never drift. Done/Canceled route through the
    /// resurfacing resolution seams (which log their own entries and return early);
    /// a resolved task moved back to live work reopens first.
    ///
    /// A `todo ↔ doing` move is a manual field edit, logged with `logHumanEdit` so it
    /// coalesces, self-deletes on a round-trip, and stays OUT of the Activity feed —
    /// nudging a task in and out of flight while you work is not household news.
    func setStatus(_ target: TaskStatus, in context: NSManagedObjectContext) {
        let previous = status
        switch target {
        case .todo, .doing:
            ensureLive(in: context)
            guard status != target else { return }
            transition(to: target)
        case .done:
            completeAndResurface(in: context)
            return
        case .canceled:
            killAndResurface(in: context)
            return
        }
        logHumanEdit(
            field: "status", oldValue: previous.rawValue, newValue: target.rawValue,
            summary: "Moved to \(target.label)", in: context)
    }

    /// Bring a task back into the working set: a resolved task reopens, restoring the
    /// live status it left via the timeline. A task already live is untouched. (There
    /// is no confirm step any more — a task that exists was created by one.)
    private func ensureLive(in context: NSManagedObjectContext) {
        if status.isResolved { reopenAndReblock(in: context) }
    }

    /// Claim ownership AND record a reversible HUMAN "assigned" entry for Activity
    /// feed. Used by the detail owner picker and the recommended-action claim;
    /// capture-time ownership (`AppBrain.resolveOwners`) stays unlogged — it is
    /// covered by the "filed" entry.
    ///
    /// **Undo-completeness:** the entry records the previous `ownerOrigin` alongside
    /// the previous owner id (`"<uuid>|<origin>"`), because `claim` stamps
    /// `.human` and the affinity denominator counts `.human` only. Without it,
    /// AI-infers-Maya → human-reassigns-to-Alex → undo would restore Maya as owner but
    /// leave the origin reading `.human`, silently polluting the denominator with an
    /// ownership no human ever established.
    func claimAndLog(ownerID newOwner: UUID?, among tasks: [TaskItem], in context: NSManagedObjectContext) {
        let previous = ownerID
        let previousOrigin = ownerOrigin
        claim(ownerID: newOwner, among: tasks)
        context.insert(
            ChangeLogEntry(
                summary: "Reassigned “\(title)”",
                action: "assigned",
                fieldChanged: "ownerID",
                oldValue: TaskItem.encodeOwnership(previous, previousOrigin),
                newValue: TaskItem.encodeOwnership(newOwner, .human),
                initiatedBy: .human,
                isReversible: true,
                taskTitle: title,
                taskUUID: uuid,
                actorID: UserProfile.currentMemberID(in: context),
                in: context
            ))
    }

    /// The `"unblocked"` payload: every edge the force-unblock dropped, plus the
    /// `lastUnblockedAt` it overwrote.
    ///
    /// **Undo-completeness** (see `ChangeLogUndo`'s header): restoring the edges alone
    /// would leave the task stamped as recently-unblocked, so `TaskRanking`'s
    /// `recentUnblockBoost` would keep lifting it for an unblock that was taken back.
    /// An action that writes two fields owes an undo that restores two fields.
    struct UnblockSnapshot: Codable {
        var removed: [Relationship]
        var priorUnblockedAt: Date?
    }

    /// Kept beside `unblockAndLog` and `ChangeLogUndo`'s `"unblocked"` arm — the only
    /// two readers — so the pair can never drift. A payload that fails to decode
    /// reverts nothing rather than reverting partially.
    static func encodeUnblock(_ snapshot: UnblockSnapshot) -> String? {
        (try? JSONEncoder().encode(snapshot)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeUnblock(_ raw: String?) -> UnblockSnapshot? {
        guard let data = raw?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UnblockSnapshot.self, from: data)
    }

    /// The `"assigned"` old/new codec: `"<uuid>|<origin>"`, or `"|<origin>"` when the
    /// owner is nil (handed back to the household). Kept beside `claimAndLog` and
    /// `ChangeLogUndo`'s `"assigned"` arm — the only two readers — so the pair can
    /// never drift.
    static func encodeOwnership(_ ownerID: UUID?, _ origin: OwnerOrigin) -> String {
        "\(ownerID?.uuidString ?? "")|\(origin.rawValue)"
    }

    /// Decode an ownership stamp. Tolerates a bare uuid (or empty string) with no
    /// separator, so an entry written before the origin was recorded still reverts —
    /// it just falls back to `.inferred`, the safe direction for the denominator.
    static func decodeOwnership(_ raw: String?) -> (ownerID: UUID?, origin: OwnerOrigin) {
        guard let raw else { return (nil, .inferred) }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        let id = parts.first.flatMap { UUID(uuidString: String($0)) }
        let origin = parts.count > 1 ? OwnerOrigin(rawValue: String(parts[1])) : nil
        return (id, origin ?? .inferred)
    }

    /// The human explicitly making a judgment call, logged for the Activity feed — the
    /// UI counterpart to `resolveDecision()`. Undo re-escalates.
    ///
    /// `choice` is WHAT was decided — the option the user tapped on the Thinking
    /// Partner. Before this, the answer was discarded: the trail said "you decided
    /// something" and the something was gone (the July finding, aggravated once the
    /// framing started naming a Best fit). The choice now lands in the entry's
    /// `detail` AND on the task's notes — the outcome lives on the task, not only in
    /// the trail. The exact appended line rides `newValue` so the undo arm can strip
    /// precisely it (undo-completeness: an arm restores every field its action wrote).
    func resolveDecisionAndLog(
        in context: NSManagedObjectContext, now: Date = Date(), choice: String? = nil
    ) {
        resolveDecision(now: now)
        var appendedLine: String?
        if let choice, !choice.isEmpty {
            let line = "Decided → \(choice)"
            appendedLine = line
            notes = notes.map { $0.isEmpty ? line : $0 + "\n" + line } ?? line
        }
        context.insert(
            ChangeLogEntry(
                summary: "Decided “\(title)”",
                detail: choice.map { "Chose: \($0)" },
                action: "decided",
                newValue: appendedLine,
                initiatedBy: .human,
                isReversible: true,
                taskTitle: title,
                taskUUID: uuid,
                actorID: UserProfile.currentMemberID(in: context),
                timestamp: now,
                in: context
            ))
    }

    /// Reopen seam (the inverse of resurface): reopen self against its live blockers.
    /// Dependents that reference self re-block automatically — self is unresolved
    /// again, so it counts as an active blocker on the next read; there is nothing
    /// to mutate. User-initiated (every caller is a human tap or an Undo), so it stamps
    /// the HUMAN clock — a revival resets staleness, or an undone stale auto-archive would
    /// read as stale again on the next hourly sweep and be re-killed indefinitely.
    func reopenAndReblock(in context: NSManagedObjectContext, now: Date = Date()) {
        let all = TaskItem.fetchAll(in: context)
        reopen(among: all)
        touchHuman(now: now)
        // Self re-entered the open set → every task it waits on regains a dependent, and
        // self's own centrality returns. Recompute those in place.
        AttentionEngine.recompute(dependentTargets(among: all) + [self], among: all)
    }

    /// The open tasks THIS task waits on (its `.blocks` targets), whose graph centrality
    /// shifts whenever this task enters or leaves the open set. Shared by the
    /// resolve/reopen recompute seams.
    fileprivate func dependentTargets(among all: [TaskItem]) -> [TaskItem] {
        let targetIDs = Set(taskBlockerIDs)
        return all.filter { $0.uuid.map(targetIDs.contains) ?? false }
    }

    /// A task that actually loses its last active blocker when `resolved` is
    /// settled is the silent Resolve-Blocker action: purely mechanical, no
    /// judgment involved, hence silent — logged to the change log as a reversible
    /// AI action and returned so the flow can surface it. Blocked is derived, so
    /// no dependent is mutated; we report the ones that just came free.
    @discardableResult
    static func resurfaceDependents(
        of resolved: TaskItem, in context: NSManagedObjectContext, now: Date = Date()
    ) -> [TaskItem] {
        guard let resolvedID = resolved.uuid else { return [] }
        let all = TaskItem.fetchAll(in: context)
        var freed: [TaskItem] = []
        for dependent in all
        where dependent.uuid != resolvedID
            && !dependent.status.isResolved
            && dependent.taskBlockerIDs.contains(resolvedID)
        {
            // The dependent referenced `resolved`, which was active until just now, so
            // it *was* blocked. It comes free iff nothing else still blocks it.
            guard !dependent.hasActiveBlockers(among: all) else { continue }
            // The blocker cleared just now — record the fact (the recently-unblocked
            // boost reads it) against the threaded `now`, not wall-clock. A fact write
            // only: no touch, so staleness stays honest.
            dependent.lastUnblockedAt = now
            freed.append(dependent)
            let detail =
                dependent.ownerID == nil
                ? "It was waiting on that; it still needs someone to pick it up."
                : "It was waiting on that, so it's back in your list."
            context.insert(
                ChangeLogEntry(
                    summary: "Unblocked \"\(dependent.title)\" — \"\(resolved.title)\" is resolved",
                    detail: detail,
                    action: "unblocked",
                    initiatedBy: .ai,
                    isReversible: true,
                    taskTitle: dependent.title,
                    taskUUID: dependent.uuid
                ))
        }
        // Attention: `resolved` left the open set, so every task it waited on loses a
        // dependent and its own centrality collapses. Recompute those in place.
        AttentionEngine.recompute(resolved.dependentTargets(among: all) + [resolved], among: all)
        return freed
    }

    /// Resolve a free-text blocker phrase (from AI triage) to a real task reference
    /// among `candidates`, reusing the significant-word match. Returns the matched
    /// task's uuid, or nil when nothing matches (the caller then leaves it unblocked).
    static func resolveBlocker(phrase: String, among candidates: [TaskItem]) -> UUID? {
        candidates.first { blockerMatches(phrase, resolvedTitle: $0.title) }?.uuid
    }

    /// Whether a free-text blocker ("passport", "the Q3 deck") refers to a task's
    /// title. Significant-word containment in either direction: strict enough that
    /// "call mom" never matches "email dad", loose enough that "passport" matches
    /// "Renew my passport". Still used to resolve AI-inferred phrases at commit.
    static func blockerMatches(_ blocker: String, resolvedTitle: String) -> Bool {
        let blockerWords = significantWords(blocker)
        let resolvedWords = significantWords(resolvedTitle)
        guard !blockerWords.isEmpty, !resolvedWords.isEmpty else { return false }
        return blockerWords.isSubset(of: resolvedWords) || resolvedWords.isSubset(of: blockerWords)
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "my", "our", "your", "their", "his", "her", "its",
        "is", "are", "was", "be", "been", "get", "gets", "got", "getting",
        "to", "of", "for", "on", "in", "at", "up", "out", "with", "from",
        "it", "this", "that", "i", "we", "and", "or",
        "done", "finished", "complete", "completed", "resolved", "sorted", "back", "first",
    ]

    private static func significantWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !stopWords.contains($0) }
        )
    }
}
