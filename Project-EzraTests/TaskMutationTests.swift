//
//  TaskMutationTests.swift
//  Project-EzraTests
//
//  The shared task mutations are the single source of truth for how a task changes
//  status across lists and the detail sheet. Post-redirect invariants: mutations
//  touch only the status axis (plus the ownership/blocker inputs the assessment
//  reads); "blocked" is derived on read and never moves the status; `needsDecision`
//  is the one stored flag, cleared only by a human decision; and reopen() restores
//  the exact status a task left. @Model instances work pre-insertion, so most of
//  these run without a NSManagedObjectContext.
//

import Foundation
import CoreData
import Testing

@testable import Project_Ezra

@Suite("TaskItem mutations")
struct TaskMutationTests {

    @Test("kill() resolves as killed, with resolution and kill timestamps")
    func killSetsState() {
        let task = TaskItem(title: "x", status: .active)
        task.kill()
        #expect(task.status == .killed)
        #expect(task.status.isResolved)
        #expect(task.completedAt != nil)
        #expect(task.killedAt != nil)
    }

    @Test("complete() resolves as done, not killed")
    func completeSetsState() {
        let task = TaskItem(title: "x", status: .active)
        task.complete()
        #expect(task.status == .done)
        #expect(task.killedAt == nil)
        #expect(task.completedAt != nil)
    }

    @Test("Mutations bump updatedAt — the untouched-since clock stays honest")
    func mutationsBumpUpdatedAt() {
        let born = Date(timeIntervalSinceNow: -10 * 24 * 3600)
        let task = TaskItem(title: "x", status: .active, createdAt: born)
        #expect(task.updatedAt == born)
        task.addExternalBlocker("something", among: [])
        #expect(task.updatedAt > born)
    }

    // MARK: - Reopen restores the prior status (from the state timeline)

    @Test("reopen() restores the exact status the task left")
    func reopenRestoresStatus() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9)
        task.complete()
        task.reopen(among: [])
        #expect(task.status == .active)
        #expect(task.completedAt == nil)
    }

    @Test("reopen() on a judgment call resolved from Inbox returns to Inbox (still Needs Decision)")
    func reopenJudgmentCallRestoresInbox() {
        let task = TaskItem(
            title: "should I quit", status: .inbox, confidence: 1.0, isJudgmentCall: true,
            needsDecision: true)
        task.complete()  // resolved straight from the Inbox
        task.reopen(among: [])
        #expect(task.status == .inbox)
        #expect(task.assessment(isBlocked: false).needsDecision == .humanJudgment)
    }

    @Test("reopen() falls back to Active when there is no recorded prior status")
    func reopenFallsBackToActive() {
        // Constructed directly as done: its only recorded visit is `.done`, so there's
        // no earlier status to restore — fall back to Active.
        let task = TaskItem(title: "x", status: .done, confidence: 0.9)
        task.reopen(among: [])
        #expect(task.status == .active)
    }

    @Test("reopen() after a kill clears killedAt")
    func reopenClearsKilledAt() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9)
        task.kill()
        task.reopen(among: [])
        #expect(task.status == .active)
        #expect(task.killedAt == nil)
        #expect(task.completedAt == nil)
    }

    // MARK: - Blocked is a derived observation, never a status

    @Test("An external blocker reads as blocked; unblock() clears it, status untouched")
    func externalBlockThenUnblock() {
        let task = TaskItem(title: "book flights", status: .active, confidence: 0.9)
        task.addExternalBlocker("the travel agent", among: [])
        #expect(task.hasActiveBlockers(among: []))
        #expect(task.taskBlockerIDs.isEmpty)  // untracked — no graph edge
        #expect(task.status == .active)  // blocking never moved the status
        task.unblock()
        #expect(!task.hasActiveBlockers(among: []))
        #expect(task.status == .active)
        #expect(task.blockers.isEmpty)
    }

    @Test("The invariant: reads as blocked iff there is an active blocker")
    func blockedIffActiveBlocker() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9)
        #expect(!task.hasActiveBlockers(among: []))
        task.addExternalBlocker(nil, among: [])
        #expect(task.hasActiveBlockers(among: []))
        task.removeBlocker(task.blockers[0].id, among: [])
        #expect(!task.hasActiveBlockers(among: []))
        #expect(task.status == .active)  // through it all, the status never changed
    }

    @Test("A judgment call stays Needs Decision through block/unblock — the flag is independent")
    func judgmentCallSurvivesBlockUnblock() {
        let task = TaskItem(
            title: "should I move", status: .inbox, confidence: 1.0, isJudgmentCall: true,
            needsDecision: true)
        task.addExternalBlocker(nil, among: [])
        #expect(task.assessment(isBlocked: true).needsDecision == .humanJudgment)
        task.unblock()
        #expect(task.assessment(isBlocked: false).needsDecision == .humanJudgment)
        #expect(task.status == .inbox)
    }

    // MARK: - Confirm-Creation (the single human-in-the-loop moment)

    @Test("confirm() moves Inbox → Active, stamps confirmedAt, clears needsDecision")
    func confirmMovesToActive() {
        let task = TaskItem(title: "x", status: .inbox, confidence: 0.3, needsDecision: true)
        task.confirm()
        #expect(task.status == .active)
        #expect(task.confirmedAt != nil)
        #expect(!task.needsDecision)
        #expect(task.assessment(isBlocked: false).needsDecision == nil)
        // Autonomy is derived, not forced — a low-confidence item is still `.ask` tier
        // even once confirmed; that's honest provenance, not a status concern.
        #expect(task.autonomy == .ask)
    }

    @Test("confirm() KEEPS blockers — confirming creation is routine, not an override")
    func confirmKeepsBlockers() {
        let blocker = TaskItem(title: "blocker", status: .active, confidence: 0.9)
        let task = TaskItem(title: "x", status: .inbox, confidence: 0.9)
        task.addTaskBlocker(blocker.uuid!, among: [blocker, task])
        task.confirm()
        #expect(task.status == .active)
        #expect(task.hasActiveBlockers(among: [blocker, task]))
    }

    @Test("confirm() clears ownerPending — a later block/unblock never resurfaces unowned")
    func confirmClearsOwnerPendingRegression() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9, ownerPending: true)
        task.confirm()
        #expect(task.status == .active)
        #expect(!task.ownerPending)
        // Block then unblock must not resurface the unowned flag.
        task.addExternalBlocker(nil, among: [])
        task.unblock()
        #expect(!task.ownerPending)
        #expect(task.status == .active)
    }

    @Test("escalateToDecision() sets the one visible flag; confirm() clears it")
    func escalateThenConfirm() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9)
        #expect(task.assessment(isBlocked: false).needsDecision == nil)
        task.escalateToDecision()
        #expect(task.needsDecision)
        #expect(task.assessment(isBlocked: false).needsDecision == .lowConfidence)
        task.confirm()
        #expect(!task.needsDecision)
    }

    @Test("A resolved task never reads as Needs Decision, even with the flag still set")
    func resolvedNeverNeedsDecision() {
        let task = TaskItem(title: "x", status: .inbox, confidence: 0.3, needsDecision: true)
        task.kill()
        #expect(task.assessment(isBlocked: false).needsDecision == nil)
    }

    // MARK: - Ownership (claim clears the unowned flag; nothing else)

    @Test("claim() clears ownerPending, leaving the status at Active")
    func claimClearsUnowned() {
        let me = UUID()
        let task = TaskItem(title: "x", status: .active, confidence: 0.9, ownerPending: true)
        task.claim(ownerID: me, among: [])
        #expect(task.status == .active)
        #expect(!task.ownerPending)
        #expect(task.isMine(currentUserID: me))  // claiming it to yourself makes it mine
    }

    @Test("claim() on a task with an active task-blocker still reads as blocked")
    func claimOnBlockedTaskStaysBlocked() {
        let blocker = TaskItem(title: "blocker", status: .active, confidence: 0.9)
        let task = TaskItem(title: "x", status: .active, confidence: 0.9, ownerPending: true)
        task.addTaskBlocker(blocker.uuid!, among: [blocker, task])
        task.claim(ownerID: nil, among: [blocker, task])
        #expect(task.hasActiveBlockers(among: [blocker, task]))
        #expect(!task.ownerPending)
    }

    @Test("An external blocker survives claim() and task-blocker churn")
    func externalBlockerSurvivesChurn() {
        let other = TaskItem(title: "other", status: .active, confidence: 0.9)
        let task = TaskItem(title: "x", status: .active, confidence: 0.9, ownerPending: true)
        task.addExternalBlocker("the contractor", among: [task, other])
        #expect(task.hasActiveBlockers(among: [task, other]))

        task.claim(ownerID: nil, among: [task, other])
        #expect(task.hasActiveBlockers(among: [task, other]))

        // Adding then removing a *task* blocker must not disturb the external one.
        task.addTaskBlocker(other.uuid!, among: [task, other])
        task.removeBlocker(task.blockers.first { $0.kind == .task }!.id, among: [task, other])
        #expect(task.hasActiveBlockers(among: [task, other]))

        // Only clearing the external blocker frees it.
        task.removeBlocker(task.blockers[0].id, among: [task, other])
        #expect(!task.hasActiveBlockers(among: [task, other]))
    }

    @Test("reopen() with ownerPending still set restores the status and reads as unowned")
    func reopenWithOwnerPendingReadsUnowned() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9, ownerPending: true)
        task.complete()
        task.reopen(among: [])
        #expect(task.status == .active)
        #expect(task.assessment(isBlocked: false).isUnowned)
    }

    // MARK: - Flags: Overdue / Stale / Blocking (derived, never stored)

    @Test("Overdue: a past due date on an open task; never on a resolved one")
    func overdueDerivation() {
        let overdue = TaskItem(
            title: "late", status: .active, dueDate: Date(timeIntervalSinceNow: -2 * 24 * 3600))
        #expect(overdue.isOverdue())
        overdue.complete()
        #expect(!overdue.isOverdue())
        let future = TaskItem(
            title: "later", status: .active, dueDate: Date(timeIntervalSinceNow: 2 * 24 * 3600))
        #expect(!future.isOverdue())
    }

    @Test("Stale: undated + untouched past the threshold; a due date exempts it (that's Overdue's job)")
    func staleDerivation() {
        let old = Date(timeIntervalSinceNow: -10 * 24 * 3600)
        let stale = TaskItem(title: "x", status: .active, createdAt: old)
        #expect(stale.isStale())
        // A SYSTEM touch does NOT reset the clock — staleness reads the human clock,
        // so a capture-time edge write can't fake engagement…
        stale.touch()
        #expect(stale.isStale())
        // …a HUMAN touch does.
        stale.touchHuman()
        #expect(!stale.isStale())
        // A dated task is never stale — it goes overdue instead.
        let dated = TaskItem(
            title: "y", status: .active, dueDate: Date(timeIntervalSinceNow: 30 * 24 * 3600),
            createdAt: old)
        #expect(!dated.isStale())
        // Past the longer threshold → auto-archive eligible.
        let ancient = TaskItem(
            title: "z", status: .active, createdAt: Date(timeIntervalSinceNow: -30 * 24 * 3600))
        #expect(ancient.isStale(threshold: StalePolicy.archiveThreshold))
    }

    @Test("Blocking: derived from the reverse edge; resolved dependents don't count")
    func blockingDerivation() {
        let blocker = TaskItem(title: "A", status: .active, confidence: 0.9)
        let dependent = TaskItem(
            title: "B", status: .active, confidence: 0.9,
            blockedBy: [blocker.uuid].compactMap { $0 })
        let all = [blocker, dependent]
        #expect(blocker.isBlocking(among: all))
        #expect(!dependent.isBlocking(among: all))
        dependent.complete()
        #expect(!blocker.isBlocking(among: all))  // nothing open waits on it any more
    }

    // MARK: - Blocker display (active blockers + summary)

    @Test("activeBlockers counts only unresolved references; summary adds +N")
    func activeBlockersAndSummary() {
        let a = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        let b = TaskItem(title: "Book flights", status: .active, confidence: 0.9)
        let done = TaskItem(title: "Old thing", status: .active, confidence: 0.9)
        done.complete()
        let visa = TaskItem(
            title: "Apply for visa", status: .active, confidence: 0.9,
            blockedBy: [a.uuid, b.uuid, done.uuid].compactMap { $0 })
        let all = [a, b, done, visa]

        // The done reference stays on the model but isn't "active".
        #expect(visa.taskBlockerIDs.count == 3)
        #expect(visa.activeBlockers(among: all).count == 2)
        #expect(visa.blockerSummary(among: all) == "after Renew passport +1")

        // With one active blocker, no "+N" — and the summary carries its preposition.
        let single = TaskItem(
            title: "Solo", status: .active, confidence: 0.9, blockedBy: [a.uuid].compactMap { $0 })
        #expect(single.blockerSummary(among: [a, single]) == "after Renew passport")
        // An untracked wait reads with its own preposition.
        let external = TaskItem(title: "Quote", status: .active, confidence: 0.9)
        external.addExternalBlocker("the contractor", among: [external])
        #expect(external.blockerSummary(among: [external]) == "waiting on the contractor")
        // Nothing active → nil (a card shows no blocker line).
        #expect(visa.blockerSummary(among: [done, visa]) == nil)
    }

    // MARK: - Dependency matching (pure)

    @Test("A short blocker matches the full title it refers to")
    func blockerMatchesContainment() {
        #expect(TaskItem.blockerMatches("passport", resolvedTitle: "Renew my passport"))
        #expect(TaskItem.blockerMatches("the Q3 deck", resolvedTitle: "Finish the Q3 deck"))
        #expect(TaskItem.blockerMatches("passport is done", resolvedTitle: "Renew passport"))
    }

    @Test("Unrelated titles never match")
    func blockerMatchesRejectsUnrelated() {
        #expect(!TaskItem.blockerMatches("call mom", resolvedTitle: "Email dad"))
        #expect(!TaskItem.blockerMatches("passport", resolvedTitle: "Pay the water bill"))
        #expect(!TaskItem.blockerMatches("", resolvedTitle: "Renew passport"))
        #expect(!TaskItem.blockerMatches("the", resolvedTitle: "The report"))
    }

    // MARK: - Cycle prevention (pure)

    @Test("wouldCreateCycle catches direct and transitive loops, allows clean edges")
    func cycleDetection() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // A→B→C (each waits on the next). Adding C→A closes a 3-cycle.
        let map: [UUID: [UUID]] = [a: [b], b: [c], c: []]
        #expect(TaskItem.wouldCreateCycle(from: c, adding: a, blockersByUUID: map))  // transitive
        #expect(TaskItem.wouldCreateCycle(from: a, adding: a, blockersByUUID: map))  // self
        #expect(TaskItem.wouldCreateCycle(from: b, adding: a, blockersByUUID: map))  // direct A↔B
        #expect(!TaskItem.wouldCreateCycle(from: a, adding: c, blockersByUUID: map))  // clean (dupe edge)
    }

    @Test("addTaskBlocker no-ops on self, duplicate, and a cycle-closing reference")
    func addBlockerGuards() {
        let a = TaskItem(title: "A", status: .active, confidence: 0.9)
        let b = TaskItem(title: "B", status: .active, confidence: 0.9)
        let all = [a, b]
        a.addTaskBlocker(b.uuid!, among: all)  // A waits on B
        #expect(a.taskBlockerIDs == [b.uuid!])
        #expect(a.hasActiveBlockers(among: all))
        b.addTaskBlocker(a.uuid!, among: all)  // would close A↔B — must no-op
        #expect(b.taskBlockerIDs.isEmpty)
        a.addTaskBlocker(a.uuid!, among: all)  // self — no-op
        a.addTaskBlocker(b.uuid!, among: all)  // duplicate — no-op
        #expect(a.taskBlockerIDs == [b.uuid!])
    }

    @Test("An external blocker never joins the graph — cycles and chains ignore it")
    func externalBlockerHasNoEdge() {
        let a = TaskItem(title: "A", status: .active, confidence: 0.9)
        a.addExternalBlocker("something", among: [a])
        #expect(a.taskBlockerIDs.isEmpty)  // no edge
        #expect(TaskItem.blockersByUUID([a])[a.uuid!] == [])
    }

    // MARK: - Auto-resurface / re-block (needs a NSManagedObjectContext)

    @MainActor private func makeContext() throws -> NSManagedObjectContext {
        return TestStore.makeContext()
    }

    @Test("Completing a blocker frees dependents, keeps the ref, and logs the change log")
    @MainActor func resurfaceOnComplete() throws {
        let context = try makeContext()
        let blocker = TaskItem(title: "Renew my passport", status: .active, confidence: 0.9)
        let dependent = TaskItem(
            title: "Book flights", status: .active, confidence: 0.9,
            blockedBy: [blocker.uuid].compactMap { $0 })
        context.insert(blocker)
        context.insert(dependent)
        #expect(dependent.hasActiveBlockers(among: [blocker, dependent]))

        blocker.completeAndResurface(in: context)

        #expect(!dependent.hasActiveBlockers(among: [blocker, dependent]))
        // The reference is durable — kept so a reopen can re-block.
        #expect(dependent.taskBlockerIDs == [blocker.uuid!])
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(entries.contains { $0.taskUUID == dependent.uuid && !$0.undone && $0.initiatedBy == .ai })
    }

    @Test("A freed dependent that's still unowned logs the 'needs someone assigned' copy")
    @MainActor func resurfaceUnownedTrailCopy() throws {
        let context = try makeContext()
        let blocker = TaskItem(title: "Renew my passport", status: .active, confidence: 0.9)
        let dependent = TaskItem(
            title: "Book flights", status: .active, confidence: 0.9,
            blockedBy: [blocker.uuid].compactMap { $0 }, ownerPending: true)
        context.insert(blocker)
        context.insert(dependent)

        blocker.completeAndResurface(in: context)

        #expect(!dependent.hasActiveBlockers(among: [blocker, dependent]))
        #expect(dependent.assessment(among: [blocker, dependent]).isUnowned)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(
            entries.contains { $0.taskUUID == dependent.uuid && $0.detail?.contains("assigned") == true })
    }

    @Test("A task stays blocked until ALL its blockers are done")
    @MainActor func unblocksOnlyWhenAllClear() throws {
        let context = try makeContext()
        let a = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        let b = TaskItem(title: "Book flights", status: .active, confidence: 0.9)
        let visa = TaskItem(
            title: "Apply for visa", status: .active, confidence: 0.9,
            blockedBy: [a.uuid, b.uuid].compactMap { $0 })
        [a, b, visa].forEach(context.insert)

        a.completeAndResurface(in: context)
        #expect(visa.hasActiveBlockers(among: [a, b, visa]))  // b still open

        b.completeAndResurface(in: context)
        #expect(!visa.hasActiveBlockers(among: [a, b, visa]))  // now all clear
    }

    @Test("Killing a blocker also frees dependents; an externally-blocked task stays put")
    @MainActor func resurfaceOnKillIsScoped() throws {
        let context = try makeContext()
        let blocker = TaskItem(title: "Finish the Q3 deck", status: .active, confidence: 0.9)
        let dependent = TaskItem(
            title: "Send deck to client", status: .active, confidence: 0.9,
            blockedBy: [blocker.uuid].compactMap { $0 })
        let unrelated = TaskItem(title: "Book flights", status: .active, confidence: 0.9)
        unrelated.addExternalBlocker(nil, among: [unrelated])  // untracked wait, no ref
        [blocker, dependent, unrelated].forEach(context.insert)

        blocker.killAndResurface(in: context)

        #expect(!dependent.hasActiveBlockers(among: [blocker, dependent, unrelated]))
        #expect(unrelated.hasActiveBlockers(among: [blocker, dependent, unrelated]))  // untouched
    }

    @Test("A freed judgment call keeps its Needs Decision flag, status unchanged")
    @MainActor func resurfaceKeepsJudgmentInvariant() throws {
        let context = try makeContext()
        let blocker = TaskItem(title: "Hear back from the recruiter", status: .active, confidence: 0.9)
        let dependent = TaskItem(
            title: "Decide whether to change jobs", status: .inbox, confidence: 0.95,
            isJudgmentCall: true, needsDecision: true, blockedBy: [blocker.uuid].compactMap { $0 })
        context.insert(blocker)
        context.insert(dependent)

        blocker.completeAndResurface(in: context)

        #expect(!dependent.hasActiveBlockers(among: [blocker, dependent]))
        #expect(dependent.status == .inbox)
        #expect(dependent.assessment(among: [blocker, dependent]).needsDecision == .humanJudgment)
    }

    @Test("Reopening a completed blocker re-blocks the dependents it had freed")
    @MainActor func reopenReblocksDependents() throws {
        let context = try makeContext()
        let blocker = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        let dependent = TaskItem(
            title: "Book flights", status: .active, confidence: 0.9,
            blockedBy: [blocker.uuid].compactMap { $0 })
        context.insert(blocker)
        context.insert(dependent)

        blocker.completeAndResurface(in: context)
        #expect(!dependent.hasActiveBlockers(among: [blocker, dependent]))

        blocker.reopenAndReblock(in: context)
        #expect(blocker.status == .active)  // blocker itself is open again
        #expect(dependent.hasActiveBlockers(among: [blocker, dependent]))  // dependent re-blocks
    }

    @Test("A done task with a still-open blocker reopens to its prior status, reading as blocked")
    @MainActor func reopenIntoBlocked() throws {
        let context = try makeContext()
        let blocker = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        let dependent = TaskItem(
            title: "Book flights", status: .active, confidence: 0.9,
            blockedBy: [blocker.uuid].compactMap { $0 })
        context.insert(blocker)
        context.insert(dependent)

        dependent.complete()  // resolve it while its blocker is still open
        #expect(dependent.status == .done)

        dependent.reopenAndReblock(in: context)
        #expect(dependent.status == .active)  // prior status restored
        #expect(dependent.hasActiveBlockers(among: [blocker, dependent]))  // blocker still open → reads blocked
    }
}

// MARK: - Commit blocker resolution

@Suite("Commit blocker resolution")
@MainActor
struct CommitBlockerResolutionTests {

    private func makeContext() throws -> NSManagedObjectContext {
        return TestStore.makeContext()
    }

    private func draft(_ title: String, blockedBy: String? = nil) -> TaskDraft {
        TaskDraft(
            title: title, category: "Travel", proposedStatus: .active, confidence: 0.9,
            autonomy: .silent, isJudgmentCall: false, reasoning: "", dueDate: nil,
            blockedBy: blockedBy)
    }

    @Test("An in-batch blocker phrase resolves to a real reference and reads as blocked")
    func resolvesIntraBatch() throws {
        let context = try makeContext()
        let brain = AppBrain()
        let created = brain.commit(
            [draft("Renew passport"), draft("Book flights", blockedBy: "passport")],
            rawCapture: "", into: context)
        let passport = created.first { $0.title == "Renew passport" }!
        let flights = created.first { $0.title == "Book flights" }!
        #expect(flights.taskBlockerIDs == [passport.uuid!])
        #expect(flights.hasActiveBlockers(among: created))
        // The AI only ever authors tracked blockers — never an untracked one.
        #expect(created.allSatisfy { task in task.blockers.allSatisfy { $0.kind == .task } })
    }

    @Test("An unresolved blocker phrase becomes an EXTERNAL blocker — the captured wait is never lost")
    func unresolvedBecomesExternal() throws {
        let context = try makeContext()
        let brain = AppBrain()
        // Unresolved phrase (matches no task): confirm-sanctioned external wait,
        // in the user's own words, deriving as blocked on read.
        let a = brain.commit(
            [draft("Submit expenses", blockedBy: "receipts from the trip")],
            rawCapture: "", into: context)[0]
        let external = a.blockers.filter { $0.kind == .external }
        #expect(external.count == 1)
        #expect(external.first?.note == "receipts from the trip")
        #expect(a.hasActiveBlockers(among: [a]))
        #expect(a.taskBlockerIDs.isEmpty)  // no phantom task reference
        // Nil phrase — nothing invented; a reference-less blocked stays unrepresentable.
        let b = brain.commit(
            [draft("Call the plumber", blockedBy: nil)],
            rawCapture: "", into: context)[0]
        #expect(b.blockers.isEmpty && b.status == .active)
    }

    @Test("Commit stamps every created task's author (the current user's member id)")
    func commitStampsCreator() throws {
        let context = try makeContext()
        let brain = AppBrain()
        let me = UserProfile.currentMemberID(in: context)
        let created = brain.commit(
            [draft("Renew passport"), draft("Book flights")], rawCapture: "", into: context)
        #expect(created.allSatisfy { $0.creatorID == me })
    }

    @Test("Commit records one Capture with the raw text and every parsed task id")
    func commitRecordsCapture() throws {
        let context = try makeContext()
        let brain = AppBrain()
        let created = brain.commit(
            [draft("Renew passport"), draft("Book flights")],
            rawCapture: "renew passport, book flights", source: .voice, into: context)
        let captures = try context.fetch(NSFetchRequest<Capture>(entityName: "Capture"))
        #expect(captures.count == 1)
        let capture = try #require(captures.first)
        #expect(capture.rawText == "renew passport, book flights")
        #expect(capture.source == .voice)
        #expect(capture.processingPath == .localOnly)
        #expect(Set(capture.parsedTaskIDs) == Set(created.compactMap(\.uuid)))
        #expect(created.allSatisfy { $0.captureID == capture.uuid })
    }

    @Test("A new task upgrades a matching external wait on an open task into a real edge")
    func reverseDependencyUpgradesExternal() throws {
        let context = try makeContext()
        let brain = AppBrain()
        // "Book flights" was captured earlier, waiting on a passport that wasn't a task yet.
        let flights = brain.commit(
            [draft("Book flights", blockedBy: "passport")], rawCapture: "", into: context)[0]
        #expect(flights.activeBlockers(among: [flights]).allSatisfy { $0.kind == .external })

        // Now the passport task is captured; the composer's open-task snapshot rides in.
        var passportDraft = draft("Renew my passport")
        passportDraft.blocks = [
            OpenTaskSnapshot(
                id: flights.uuid!, title: flights.title, externalBlockerNotes: ["passport"])
        ]
        let passport = brain.commit([passportDraft], rawCapture: "", into: context)[0]

        let all = [flights, passport]
        // The external note upgraded to a real, cycle-safe task edge…
        #expect(flights.taskBlockerIDs == [passport.uuid!])
        #expect(flights.blockers.allSatisfy { $0.kind == .task })
        #expect(flights.hasActiveBlockers(among: all))
        // …with a reversible AI change-log entry recording the link.
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let linked = try #require(entries.first { $0.action == "linked" })
        #expect(linked.taskUUID == flights.uuid)
        #expect(linked.newValue == passport.uuid?.uuidString)
        #expect(linked.isReversible && linked.initiatedBy == .ai)
        // Completing the passport frees the flights — the chain works end-to-end.
        passport.completeAndResurface(in: context)
        #expect(!flights.hasActiveBlockers(among: all))
    }

    @Test("A reverse dependency never closes a cycle")
    func reverseDependencyCycleSafe() throws {
        let context = try makeContext()
        let brain = AppBrain()
        // New task B arrives already waiting on open task A ("after …"), while
        // also claiming A should wait on it — the cycle half must no-op.
        let a = brain.commit([draft("Renew passport")], rawCapture: "", into: context)[0]
        var b = draft("Book flights", blockedBy: "passport")
        b.blocks = [OpenTaskSnapshot(id: a.uuid!, title: a.title)]
        let created = brain.commit([b], rawCapture: "", into: context)[0]

        // Forward edge exists (B waits on A); the reverse edge was refused.
        #expect(created.taskBlockerIDs == [a.uuid!])
        #expect(a.taskBlockerIDs.isEmpty)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(!entries.contains { $0.action == "linked" })  // refused edges log nothing
    }

    @Test("Completing a task blocker does NOT free a task still holding an external blocker")
    func externalKeepsBlockedAfterTaskBlockerClears() throws {
        let context = try makeContext()
        let blocker = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        let task = TaskItem(title: "Book flights", status: .active, confidence: 0.9)
        context.insert(blocker)
        context.insert(task)
        task.addTaskBlocker(blocker.uuid!, among: [blocker, task])
        task.addExternalBlocker("the travel agent", among: [blocker, task])
        #expect(task.hasActiveBlockers(among: [blocker, task]))

        blocker.completeAndResurface(in: context)
        // The task blocker cleared, but the external one still stands.
        #expect(task.hasActiveBlockers(among: [blocker, task]))
        #expect(task.activeBlockers(among: [blocker, task]).allSatisfy { $0.kind == .external })
    }
}
