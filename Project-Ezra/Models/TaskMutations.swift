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
    func touchHuman(now: Date = Date()) {
        lastHumanTouchAt = now
        touch(now: now)
    }

    /// Move the task along the working pipeline (`TaskStage`). Stage is a sub-state of
    /// `.active` — this writes only `stageRaw` (and the touch clock); it NEVER touches
    /// the status. Setting a stage on an inbox/resolved task is harmless: the display
    /// layer ignores stage unless the status is `.active` (see `TaskDisplayStatus`).
    func setStage(_ stage: TaskStage, now: Date = Date()) {
        self.stage = stage
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
        transition(to: .killed, now: now)
        completedAt = now  // "when resolved", for timeToResolution and open-set checks
        killedAt = now
    }

    /// Confirm-Creation: the single human-in-the-loop moment. Moves Inbox →
    /// Active, stamps `confirmedAt`, and clears the flags a creation glance
    /// settles: a low-confidence Needs Decision (the human just validated the
    /// fields) and pending ownership. A JUDGMENT call's flag survives — confirming
    /// that "figure out if X" exists is not making the call; only
    /// `resolveDecision()` clears that (the permanent judgment-category carve-out).
    /// Deliberately does NOT drop blockers — confirming creation is the routine
    /// human moment, not an override; a dependency named at capture survives it.
    func confirm(now: Date = Date()) {
        if !isJudgmentCall { needsDecision = false }
        ownerPending = false
        // A freshly-confirmed task lands ready to work: stamp the default stage the
        // first time only, so a re-confirm never clobbers a stage the user has moved.
        if isStageUnset { stage = TaskStage.defaultOnConfirm }
        confirmedAt = now
        transition(to: .active, now: now)
        touchHuman(now: now)  // transition no-ops if already active; the confirm still counts as a touch
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
    /// another family member (their uuid), or unassign/share it (`nil`) — clearing the
    /// ownership gate. Ownership is its own axis: this never touches the status or the
    /// blocker list. `tasks` is unused (kept for call-site symmetry with the other
    /// graph-aware mutations).
    func claim(ownerID: UUID?, among tasks: [TaskItem]) {
        self.ownerID = ownerID
        self.ownerPending = false
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

    /// Force-unblock: drop every `.blocks` edge (tracked and external alike), leaving
    /// any `.parent`/other edges intact. The detail sheet's "Unblock" action. Leaves
    /// the status alone — the task simply stops reading as blocked on the next
    /// derivation. Human-initiated (a detail/recommended-action tap), so it stamps
    /// both `lastUnblockedAt` (the recently-unblocked fact) and the human clock.
    func unblock(now: Date = Date()) {
        guard !blockers.isEmpty else { return }
        removeRelationships { $0.kind == .blocks }
        lastUnblockedAt = now
        touchHuman(now: now)
    }

    /// Reopen a resolved task, restoring the status it left when it was resolved
    /// (from the state timeline) rather than guessing — a reopened proposal
    /// returns to Inbox. Falls back to `.active` when there's no recorded
    /// history. Dependents re-block automatically: `self` is unresolved again, so
    /// it counts as an active blocker on the next read. `tasks` is unused (kept
    /// for call-site symmetry).
    func reopen(among tasks: [TaskItem]) {
        completedAt = nil
        killedAt = nil
        let restored =
            stateTimeline.last { visit in
                TaskStatus.fold(legacyRaw: visit.state).map { !$0.isResolved } ?? false
            }
            .flatMap { TaskStatus.fold(legacyRaw: $0.state) } ?? .active
        status = restored
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
}

// MARK: - Recommended Action (the derived "one obvious next tap")

/// The single best next move for a task, inferred from its status and the AI's
/// live assessment. Fuses what used to be two parallel switches (button title +
/// behavior) into one value, so the label and the action can never drift apart.
enum RecommendedAction {
    case confirm  // confirm an Inbox item into the working set
    case claim  // take ownership of an unowned one
    case unblock  // drop the blockers holding it
    case resolve  // mark an actionable task done
    case reopen  // bring a resolved task back

    var title: String {
        switch self {
        case .confirm: return "Confirm"
        case .claim: return "That's mine"
        case .unblock: return "Unblock"
        case .resolve: return "Mark done"
        case .reopen: return "Reopen"
        }
    }

    /// The detail sheet dismisses after resolving (the task leaves the working
    /// set); every other action keeps it open so the user sees the result in place.
    var dismissesDetail: Bool { self == .resolve }
}

extension TaskItem {
    /// The recommended next action, derived from status + assessment. Precedence:
    /// a resolved task reopens; a blocked one wants unblocking; an inbox item
    /// wants confirming; an unowned one wants claiming; otherwise it's ready to
    /// finish.
    func recommendedAction(among tasks: [TaskItem]) -> RecommendedAction {
        if status.isResolved { return .reopen }
        if hasActiveBlockers(among: tasks) { return .unblock }
        if status == .inbox { return .confirm }
        if ownerPending { return .claim }
        return .resolve
    }

    /// Run whatever `recommendedAction` currently returns. Callers own `save()`.
    func performRecommendedAction(among tasks: [TaskItem], in context: NSManagedObjectContext) {
        switch recommendedAction(among: tasks) {
        case .confirm: confirm()
        case .claim: claimAndLog(ownerID: UserProfile.currentMemberID(in: context), among: tasks, in: context)
        case .unblock: unblock()
        case .resolve: completeAndResurface(in: context)
        case .reopen: reopenAndReblock(in: context)
        }
    }
}

// MARK: - Dependency chains (auto-resurface / re-block)

extension TaskItem {
    /// Resolution seam used by every list and the detail sheet: complete + resurface
    /// any dependents this frees. Records a reversible HUMAN "completed" entry (only
    /// the user can attest a real-world completion) so it surfaces in the Inbox feed
    /// with the actor's avatar; its undo reopens (never sends to inbox). Returns what
    /// resurfaced so the flow can say so in place. Callers still own `save()`.
    @discardableResult
    func completeAndResurface(in context: NSManagedObjectContext, now: Date = Date()) -> [TaskItem] {
        complete(now: now)
        touchHuman(now: now)  // only a human can attest a real-world completion
        logHumanResolution(action: "completed", verb: "Completed", now: now, in: context)
        return Self.resurfaceDependents(of: self, in: context)
    }

    /// Kill also resolves the dependency — the blocker is settled either way, so
    /// dependents resurface rather than waiting forever on a dead task. Records a
    /// reversible HUMAN "killed" entry for the Inbox feed (undo reopens).
    @discardableResult
    func killAndResurface(in context: NSManagedObjectContext, now: Date = Date()) -> [TaskItem] {
        kill(now: now)
        touchHuman(now: now)  // the manual cancel path (the silent auto-archive calls `kill` directly)
        logHumanResolution(action: "killed", verb: "Canceled", now: now, in: context)
        return Self.resurfaceDependents(of: self, in: context)
    }

    /// The one place a human resolution (complete/cancel) is logged for the Inbox
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
    /// (see `ChangeLogEntry.isInboxVisible`). Snapshot the old value at the call site.
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

    /// Apply one of the six visible Linear states, composing the underlying lifecycle
    /// + stage moves. The SINGLE seam both the row glyph menu and the detail picker
    /// call, so those two can never drift. A resolved/inbox task is first brought into
    /// the working set (reopen, then confirm if it landed back in Inbox), then the
    /// stage is stamped; Done/Canceled route through the resurfacing resolution seams.
    ///
    /// A move between the four active stages is a manual field edit, logged to the task's
    /// timeline (Done/Canceled already log via the resolution seams, so they return early).
    func applyDisplayStatus(_ target: TaskDisplayStatus, in context: NSManagedObjectContext) {
        let previous = displayStatus
        switch target {
        case .backlog:
            ensureActive(in: context)
            setStage(.backlog)
        case .todo:
            ensureActive(in: context)
            setStage(.todo)
        case .inProgress:
            ensureActive(in: context)
            setStage(.inProgress)
        case .inReview:
            ensureActive(in: context)
            setStage(.inReview)
        case .done:
            completeAndResurface(in: context)
            return
        case .canceled:
            killAndResurface(in: context)
            return
        }
        logHumanEdit(
            field: "stage", oldValue: previous.rawValue, newValue: target.rawValue,
            summary: "Moved to \(target.label)", in: context)
    }

    /// Bring a task into the working set from wherever it is: a resolved task reopens
    /// (restoring its prior status via the timeline), and anything still sitting in the
    /// Inbox is confirmed. A task already `.active` is untouched.
    private func ensureActive(in context: NSManagedObjectContext) {
        if status.isResolved { reopenAndReblock(in: context) }
        if status == .inbox { confirm() }
    }

    /// Claim ownership AND record a reversible HUMAN "assigned" entry for the Inbox
    /// feed — old/new owner ids ride in `oldValue`/`newValue` so undo can restore the
    /// previous owner. Used by the detail owner picker and the recommended-action
    /// claim; capture-time ownership (`AppBrain.resolveOwners`) stays unlogged (it's
    /// covered by the "filed" entry).
    func claimAndLog(ownerID newOwner: UUID?, among tasks: [TaskItem], in context: NSManagedObjectContext) {
        let previous = ownerID
        claim(ownerID: newOwner, among: tasks)
        context.insert(
            ChangeLogEntry(
                summary: "Reassigned “\(title)”",
                action: "assigned",
                fieldChanged: "ownerID",
                oldValue: previous?.uuidString,
                newValue: newOwner?.uuidString,
                initiatedBy: .human,
                isReversible: true,
                taskTitle: title,
                taskUUID: uuid,
                actorID: UserProfile.currentMemberID(in: context),
                in: context
            ))
    }

    /// The human explicitly making a judgment call, logged for the Inbox feed — the
    /// UI counterpart to `resolveDecision()` (which had no surface until now). Undo
    /// re-escalates. Only clears the flag (`resolveDecision`), nothing else.
    func resolveDecisionAndLog(in context: NSManagedObjectContext, now: Date = Date()) {
        resolveDecision(now: now)
        context.insert(
            ChangeLogEntry(
                summary: "Decided “\(title)”",
                action: "decided",
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
    /// to mutate. User-initiated, so it isn't logged.
    func reopenAndReblock(in context: NSManagedObjectContext) {
        let all = TaskItem.fetchAll(in: context)
        reopen(among: all)
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
    static func resurfaceDependents(of resolved: TaskItem, in context: NSManagedObjectContext) -> [TaskItem] {
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
            // boost reads it). A fact write only: no touch, so staleness stays honest.
            dependent.lastUnblockedAt = Date()
            freed.append(dependent)
            let detail: String
            if dependent.ownerPending {
                detail = "It was waiting on that; it still needs someone assigned."
            } else if dependent.status == .inbox {
                detail = "It was waiting on that; it still needs your confirm."
            } else {
                detail = "It was waiting on that, so it's back in your list."
            }
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
