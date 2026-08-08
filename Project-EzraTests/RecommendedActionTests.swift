//
//  RecommendedActionTests.swift
//  Project-EzraTests
//
//  The detail sheet's primary CTA is the one control that has to be right without
//  the user thinking: one slot, computed from lifecycle + obstacles + ownership,
//  and ABSENT rather than wrong when there's no honest move. These tests pin the
//  resolution tree — read as *is it settled → is it even a to-do → is it mine →
//  can it be worked on → what stage is it in* — plus the intent-voiced verbs and
//  the dismissal contract the pager depends on.
//
//  The derivation is pure — it takes the current user's id rather than a context,
//  because it runs during view body evaluation and `currentMemberID(in:)` bootstraps.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Recommended action (the one obvious next tap)")
struct RecommendedActionTests {

    /// The device user's member id.
    private func me(_ context: NSManagedObjectContext) -> UUID {
        UserProfile.currentMemberID(in: context)
    }

    /// A task owned by the device's user — the common case every stage test wants.
    private func mine(
        _ context: NSManagedObjectContext, status: TaskStatus = .todo, intent: WorkIntent? = .action
    ) -> TaskItem {
        let task = TaskItem(title: "x", status: status, in: context)
        task.ownerID = me(context)
        task.workIntent = intent
        return task
    }

    // MARK: - The stage arms (the point of the change)

    @Test("A todo task offers Start, never Mark done — the CTA can't skip a state")
    func todoOffersStart() {
        let context = TestStore.makeContext()
        let task = mine(context)
        let action = task.recommendedAction(among: [task], currentUserID: me(context))
        #expect(action == .start)
        #expect(action?.title == "Start")
    }

    @Test("An in-progress task offers Mark done")
    func doingOffersResolve() {
        let context = TestStore.makeContext()
        let task = mine(context, status: .doing)
        #expect(task.recommendedAction(among: [task], currentUserID: me(context)) == .resolve)
    }

    @Test("Start → Mark done: the same button, relabeled, without leaving the page")
    func startThenResolveInPlace() {
        let context = TestStore.makeContext()
        let task = mine(context)

        let first = try! #require(task.recommendedAction(among: [task], currentUserID: me(context)))
        #expect(first.title == "Start")
        // Start must NOT dismiss — the relabel in place is how the lifecycle teaches
        // itself, and the pager would otherwise advance off the task you just picked up.
        #expect(first.dismissesDetail == false)

        task.performRecommendedAction(first, among: [task], in: context)
        #expect(task.status == .doing)

        let second = try! #require(task.recommendedAction(among: [task], currentUserID: me(context)))
        #expect(second.title == "Mark done")
        #expect(second.dismissesDetail)
    }

    @Test("The planning verb is gone — the CTA may only promise what it does")
    func planningReadsStart() {
        let context = TestStore.makeContext()
        let task = mine(context, intent: .planning)
        // "Break it down" was a lie: every arm of performRecommendedAction runs
        // setStatus(.doing), and breaking work into steps belongs to the capability card.
        #expect(task.recommendedAction(among: [task], currentUserID: me(context))?.title == "Start")
    }

    // MARK: - Resume (the trail knows you have been here)

    @Test("A task with a closed .doing visit offers Resume, not Start")
    func priorVisitOffersResume() {
        let context = TestStore.makeContext()
        let task = mine(context)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        task.transition(to: .doing, now: t0)
        task.transition(to: .todo, now: t0.addingTimeInterval(3600))

        #expect(task.hasBeenStarted)
        let action = task.recommendedAction(among: [task], currentUserID: me(context))
        #expect(action == .resume)
        #expect(action?.title == "Resume")
        // Same mutation as Start — only the word the user reads changes.
        task.performRecommendedAction(.resume, among: [task], in: context)
        #expect(task.status == .doing)
    }

    @Test("Resume outranks Start — picking it back up is the more useful fact")
    func resumeBeatsIntentVoicing() {
        let context = TestStore.makeContext()
        let task = mine(context, intent: .planning)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        task.transition(to: .doing, now: t0)
        task.transition(to: .todo, now: t0.addingTimeInterval(3600))
        #expect(task.recommendedAction(among: [task], currentUserID: me(context))?.title == "Resume")
    }

    @Test("A never-started task is not Resume, and an OPEN .doing visit is not either")
    func openVisitIsNotResume() {
        let context = TestStore.makeContext()
        let fresh = mine(context)
        #expect(fresh.hasBeenStarted == false)

        // In flight right now: the visit is open, so this is "Mark done", not "Resume".
        let inFlight = mine(context, status: .todo)
        inFlight.transition(to: .doing, now: Date())
        #expect(inFlight.hasBeenStarted == false)
        #expect(inFlight.recommendedAction(among: [inFlight], currentUserID: me(context)) == .resolve)
    }

    // MARK: - The verb never voices the type (the intent-voiced verbs are all retired)

    @Test(
        "Every intent reads Start — 'Break it down' lied, and 'Decide' retired with the type",
        arguments: [WorkIntent.action, .planning])
    func everyIntentReadsStart(intent: WorkIntent) {
        let context = TestStore.makeContext()
        let task = mine(context, intent: intent)
        #expect(task.recommendedAction(among: [task], currentUserID: me(context))?.title == "Start")
    }

    @Test("Nil intent (heuristic path / Apple Intelligence off) still reads Start")
    func nilIntentReadsStart() {
        let context = TestStore.makeContext()
        let task = mine(context, intent: nil)
        let action = task.recommendedAction(among: [task], currentUserID: me(context))
        #expect(action == .start)
        #expect(action?.title == "Start")
    }

    // MARK: - The nil arm (fewer buttons, not more)

    @Test("Someone else's live task gets no CTA — you don't attest their completions")
    func otherOwnerHasNoCTA() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Pay the water bill", status: .todo, in: context)
        task.ownerID = UUID()  // emphatically not the current member
        task.workIntent = .action
        #expect(task.recommendedAction(among: [task], currentUserID: me(context)) == nil)
    }

    @Test("No profile yet: fall through to the lifecycle CTA rather than blanking it")
    func unknownIdentityKeepsTheButton() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "x", status: .todo, in: context)
        task.ownerID = UUID()
        task.workIntent = .action
        // Hide the slot only when the owner is KNOWN to be someone else.
        #expect(task.recommendedAction(among: [task], currentUserID: nil) == .start)
    }

    // MARK: - Ordering

    @Test("Unowned wins over blocked: you take the thing before you clear its path")
    func claimPrecedesUnblock() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "x", status: .todo, in: context)
        task.ownerID = nil
        task.addExternalBlocker("waiting on the plumber", among: [])
        #expect(task.hasActiveBlockers(among: [task]))
        #expect(task.recommendedAction(among: [task], currentUserID: me(context)) == .claim)
    }

    @Test("Blocked own work offers Unblock, not Start — blockers are a precondition")
    func blockedOffersUnblock() {
        let context = TestStore.makeContext()
        let task = mine(context)
        task.addExternalBlocker("waiting on the plumber", among: [])
        #expect(task.recommendedAction(among: [task], currentUserID: me(context)) == .unblock)
    }

    @Test("A resolved task reopens, whatever else is true of it")
    func resolvedReopens() {
        let context = TestStore.makeContext()
        let task = mine(context, status: .doing)
        task.complete()
        #expect(task.recommendedAction(among: [task], currentUserID: me(context)) == .reopen)
    }

    // MARK: - Dismissal contract

    @Test("Only resolving dismisses the detail — every other action stays in place")
    func onlyResolveDismisses() {
        #expect(RecommendedAction.resolve.dismissesDetail)
        for action: RecommendedAction in [
            .claim, .unblock, .reopen, .start, .resume,
        ] {
            #expect(action.dismissesDetail == false)
        }
    }
}
