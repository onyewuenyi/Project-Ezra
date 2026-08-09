//
//  CapabilityTests.swift
//  Project-EzraTests
//
//  The three capabilities and their triggers. Every one of these is a PURE test — no
//  model call anywhere — because the deciding half of each capability is deterministic
//  by design. Only the *content* (framed options, proposed steps) needs the model, and
//  that is what makes the cards absent rather than broken off-device.
//
//  The test this file exists to protect is `breakdownIgnoresSmallPlanning`: the trigger
//  is COMPLEXITY, not work type. If that inverts back, "plan birthday dinner" starts
//  offering a breakdown and "renew passport" stops.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CapabilityTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func task(
        _ title: String, effort: Int? = nil, intent: WorkIntent? = nil,
        status: TaskStatus = .todo, in context: NSManagedObjectContext
    ) -> TaskItem {
        let task = TaskItem(title: title, status: status, effortMinutes: effort, in: context)
        task.workIntent = intent
        return task
    }

    // MARK: - Break this down: complexity triggers it, type only biases

    @Test("A long task qualifies whatever its type — size is the signal")
    func longTaskQualifies() {
        let context = context()
        let task = task("Renew passport", effort: 90, intent: .action, in: context)
        #expect(BreakdownEligibility.evaluate(task, among: [task]) == .largeEffort)
    }

    @Test("A SMALL planning task does not qualify — the inversion, stated as a test")
    func breakdownIgnoresSmallPlanning() {
        let context = context()
        // "Plan birthday dinner" is planning and needs no help. Keying the trigger off
        // `workIntent == .planning` would offer it a breakdown and withhold one from
        // the 90-minute action above — exactly backwards.
        let task = task("Plan birthday dinner", effort: 15, intent: .planning, in: context)
        #expect(BreakdownEligibility.evaluate(task, among: [task]) == nil)
    }

    @Test("A planning task qualifies once it is big enough, or unsized")
    func planningQualifiesAboveTheBar() {
        let context = context()
        let sized = task("Plan the Lisbon trip", effort: 30, intent: .planning, in: context)
        #expect(BreakdownEligibility.evaluate(sized, among: [sized]) == .planningIntent)

        // No estimate on planning work is itself a sign nobody has sized it yet.
        let unsized = task("Plan the move", intent: .planning, in: context)
        #expect(BreakdownEligibility.evaluate(unsized, among: [unsized]) == .planningIntent)
    }

    @Test("A compound title qualifies; an ordinary one does not")
    func compoundTitles() {
        #expect(BreakdownEligibility.isCompound("Book the venue and send the invites"))
        #expect(BreakdownEligibility.isCompound("Call the vet then pick up the food"))
        // The false positives that would staple a breakdown onto a single errand.
        #expect(!BreakdownEligibility.isCompound("Buy salt and pepper for the recipe"))
        #expect(!BreakdownEligibility.isCompound("Pick up milk and eggs"))
        #expect(!BreakdownEligibility.isCompound("Call the school about the transfer"))
    }

    @Test("A task that already has children is suppressed — nothing left to break down")
    func alreadySplitIsSuppressed() {
        let context = context()
        let parent = task("Plan the Lisbon trip", effort: 120, in: context)
        let child = task("Book the flights", in: context)
        child.linkParent(parent.uuid!)
        #expect(BreakdownEligibility.evaluate(parent, among: [parent, child]) == nil)
    }

    @Test("`children` is containment, not the blocking edge")
    func childrenIsNotDependents() {
        let context = context()
        let big = task("Renew passport", effort: 90, in: context)
        let waiting = task("Book flights", in: context)
        // `waiting` is BLOCKED BY `big` — a `.blocks` edge, not a `.parent` one. Using
        // `dependents` here would wrongly suppress the card on any task that blocks
        // another, which has nothing to do with whether it can be broken down.
        waiting.addTaskBlocker(big.uuid!, among: [big, waiting])
        #expect(!big.dependents(among: [big, waiting]).isEmpty)
        #expect(big.children(among: [big, waiting]).isEmpty)
        #expect(BreakdownEligibility.evaluate(big, among: [big, waiting]) == .largeEffort)
    }

    // MARK: - Unstick: silent when healthy, diagnostic when not

    @Test("A healthy task gets nothing")
    func healthyTaskIsSilent() {
        let context = context()
        let task = task("Call the plumber", in: context)
        #expect(StallDetector.diagnose(task, among: [task]) == nil)
    }

    @Test("Deferred past the threshold, the diagnosis names the cause — most actionable first")
    func diagnosisOrder() {
        let context = context()
        let now = Date()

        // Blocked outranks everything: the blocker is the work.
        let blocked = task("Fix the boiler", effort: 90, in: context)
        blocked.deferralCount = 3
        blocked.addExternalBlocker("the engineer", among: [blocked])
        #expect(StallDetector.diagnose(blocked, among: [blocked], now: now) == .blocked)

        // Then size — and it carries the breakdown's own reason so the card can route.
        let big = task("Renew passport", effort: 90, in: context)
        big.deferralCount = 3
        #expect(StallDetector.diagnose(big, among: [big], now: now) == .tooBig(.largeEffort))

        // Then wording that reads as a choice.
        let choice = task("Should I switch dentists", in: context)
        choice.deferralCount = 3
        #expect(StallDetector.diagnose(choice, among: [choice], now: now) == .reallyADecision)

        // Otherwise: it is simply being avoided.
        let dying = task("Call the plumber", in: context)
        dying.deferralCount = 3
        #expect(StallDetector.diagnose(dying, among: [dying], now: now) == .dying)
    }

    @Test("Below the threshold nothing fires, however big or decision-shaped")
    func belowThresholdIsSilent() {
        let context = context()
        let big = task("Renew passport", effort: 90, in: context)
        big.deferralCount = 2
        #expect(StallDetector.diagnose(big, among: [big]) == nil)
    }

    @Test("A task already flagged Needs Decision is suppressed — one card per task")
    func flaggedTaskIsSuppressed() {
        let context = context()
        let task = task("Should I quit the gym", in: context)
        task.deferralCount = 5
        task.needsDecision = true
        // The decision section is already saying something more specific; two cards
        // competing to explain the same task is the clutter the surface refuses.
        #expect(StallDetector.diagnose(task, among: [task]) == nil)
    }

    @Test("Quiet for long enough also counts, with no deferrals at all")
    func stalenessAlsoStalls() {
        let context = context()
        let now = Date()
        let task = task("Sort the garage", in: context)
        task.lastHumanTouchAt = now.addingTimeInterval(-StalePolicy.archiveThreshold)
        #expect(task.deferralCount == 0)
        #expect(StallDetector.diagnose(task, among: [task], now: now) == .dying)
    }

    // MARK: - Composition (the capabilities are not islands)

    @Test("A big STALLED task gets one card, not two")
    func stalledBigTaskDoesNotDuplicate() {
        let context = context()
        let task = task("Renew passport", effort: 90, in: context)
        task.deferralCount = 3
        let capabilities = TaskCapabilities.available(for: task, among: [task])
        // Unstick subsumes the breakdown and routes into it — a bare "break this down"
        // card sitting above a "this keeps sliding" card that says "break it into
        // steps" is the same advice twice.
        #expect(capabilities == [.unstick(.tooBig(.largeEffort))])
    }

    @Test("A big HEALTHY task is offered the breakdown proactively")
    func healthyBigTaskGetsBreakdown() {
        let context = context()
        let task = task("Renew passport", effort: 90, in: context)
        #expect(TaskCapabilities.available(for: task, among: [task]) == [.breakDown(.largeEffort)])
    }

    @Test("A big decision gets both — they answer different questions")
    func decisionAndBreakdownCompose() {
        let context = context()
        let task = task("Should we move to Lisbon", effort: 120, intent: .planning, in: context)
        let capabilities = TaskCapabilities.available(for: task, among: [task])
        #expect(capabilities.contains(.thinkingPartner))
        #expect(capabilities.contains(.breakDown(.largeEffort)))
    }

    @Test("A resolved task is offered nothing at all")
    func resolvedTaskGetsNothing() {
        let context = context()
        let task = task("Renew passport", effort: 90, in: context)
        task.complete()
        #expect(TaskCapabilities.available(for: task, among: [task]).isEmpty)
    }

    @Test("A resolved DECISION is offered nothing either — the type outlives the task")
    func resolvedDecisionGetsNothing() {
        let context = context()
        // `workIntent` survives resolution by design (a decision you made was still a
        // decision), and `needsDecision` can too. Neither may reopen the Thinking
        // Partner on a settled task — it would offer to frame a choice already made,
        // and spend a model call doing it.
        let done = task("Should we move to Lisbon", intent: .planning, in: context)
        done.needsDecision = true
        done.complete()
        #expect(TaskCapabilities.available(for: done, among: [done]).isEmpty)

        let dropped = task("Should we get a dog", intent: .planning, in: context)
        dropped.kill()
        #expect(TaskCapabilities.available(for: dropped, among: [dropped]).isEmpty)
    }

    // MARK: - The stall clears when the user engages

    @Test("Acting on a stalled task dismisses the card that asked")
    func engagementClearsTheStall() {
        let context = context()
        let now = Date()
        let task = task("Call the plumber", in: context)
        context.insert(task)
        task.deferralCount = 4
        #expect(StallDetector.diagnose(task, among: [task], now: now) == .dying)

        // "Do it now" — the card's own action. It must clear the condition that raised
        // the card, or Unstick survives the very tap meant to dismiss it and nags for
        // the rest of the task's live life.
        task.setStatus(.doing, in: context)
        #expect(task.deferralCount == 0)
        #expect(StallDetector.diagnose(task, among: [task], now: now) == nil)
    }

    @Test("The deferral count is consecutive, not lifetime — and only a HUMAN clears it")
    func deferralCountIsConsecutive() {
        let now = Date()
        let task = TaskItem(title: "Sort the garage", status: .todo, createdAt: now)
        task.deferralCount = 3

        // A system write (a capture-time edge, a sweep) bumps only the machine clock, so
        // it must NOT look like engagement — otherwise the AI could clear the user's own
        // avoidance signal on their behalf.
        task.touch(now: now)
        #expect(task.deferralCount == 3)

        task.touchHuman(now: now)
        #expect(task.deferralCount == 0)
        // The worked-but-unfinished counter answers a different question and survives.
        #expect(task.carriedOverCount == 0)
    }
    @Test("One intervention per problem: with the partner card visible, the choice rung folds")
    func choiceRungFoldsUnderPartner() {
        let context = context()
        // Choice-worded, stalled (quiet past the threshold), unblocked, not flagged —
        // the exact task that used to get the same advice twice.
        let task = task("Decide whether to switch schools", in: context)
        task.deferralCount = 4

        let capabilities = TaskCapabilities.available(
            for: task, among: [task], partnerCardVisible: true)
        #expect(capabilities.contains(.thinkingPartner))
        #expect(capabilities.contains(.unstick(.dying)))  // folded through, card survives
        #expect(!capabilities.contains(.unstick(.reallyADecision)))
    }

    @Test("Off-device (partner not drawn) the choice rung survives — the escalate arm stays")
    func choiceRungSurvivesWithoutPartner() {
        let context = context()
        let task = task("Decide whether to switch schools", in: context)
        task.deferralCount = 4

        let capabilities = TaskCapabilities.available(
            for: task, among: [task], partnerCardVisible: false)
        #expect(capabilities.contains(.unstick(.reallyADecision)))
    }
}

