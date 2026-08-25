//
//  TaskShapeTests.swift
//  Project-EzraTests
//
//  The page's shape is derived from facts, and these tests are the fence around what
//  may derive it. Two rules matter more than the mapping itself:
//
//  1. **A signal is not a shape.** Wording, breakdown-eligibility, staleness and
//     urgency ride ON a shape; none may pick one. `DecisionShape` in particular is
//     lexical — under the old design a false positive cost one dismissible card, and
//     under this one it would cost the whole layout.
//  2. **Shape ⊆ fingerprint.** Every input to the shape is hashed by
//     `TaskAdvisorFacts.fingerprint`, so the layout can only change when the reading
//     was going to change anyway — the one-interpretation-per-fingerprint calm
//     extends to the page for free.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Task shape — facts pick the page")
struct TaskShapeTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    @Test("Each shape fires on its own trigger; plain work is action")
    func triggers() {
        let context = context()
        let plain = TaskItem(title: "Call the dentist", status: .todo, in: context)
        #expect(TaskShape.of(plain, among: [plain]) == .action)

        let flagged = TaskItem(title: "Pick a school", status: .todo, in: context)
        flagged.needsDecision = true
        #expect(TaskShape.of(flagged, among: [flagged]) == .deciding)

        let blocker = TaskItem(title: "Send the numbers", status: .todo, in: context)
        let blocked = TaskItem(title: "Sign the contract", status: .todo, in: context)
        blocked.addTaskBlocker(blocker.uuid!, among: [blocked, blocker])
        #expect(TaskShape.of(blocked, among: [blocked, blocker]) == .waiting)

        let waiting = TaskItem(title: "Sign the lease", status: .todo, in: context)
        waiting.addExternalBlocker("the landlord", among: [waiting])
        #expect(TaskShape.of(waiting, among: [waiting]) == .waiting)

        let parent = TaskItem(title: "Vendor contract review", status: .todo, in: context)
        let created = parent.splitInto(
            [BreakdownStep(title: "Review pricing", effortMinutes: 15)], in: context)
        #expect(created.count == 1)
        let all = [parent] + created
        #expect(TaskShape.of(parent, among: all) == .container)
    }

    @Test("Precedence: deciding outranks waiting outranks container")
    func precedence() {
        let context = context()
        let blocker = TaskItem(title: "The other thing", status: .todo, in: context)
        let task = TaskItem(title: "Sort the estate", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])
        task.needsDecision = true
        #expect(TaskShape.of(task, among: [task, blocker]) == .deciding)

        task.needsDecision = false
        let steps = task.splitInto(
            [BreakdownStep(title: "List the accounts", effortMinutes: 15)], in: context)
        let all = [task, blocker] + steps
        // Blocked + has steps → the blocker outranks the container: nothing inside
        // can move until the outside clears.
        #expect(TaskShape.of(task, among: all) == .waiting)
    }

    @Test("Wording never picks a shape — only the human-owned flag does")
    func wordingNeverPicksAShape() {
        let context = context()
        // The widened lexicon ("is it worth", "choose", "whether") matches all of
        // these; none carries the flag, so all stay action.
        for title in [
            "Choose a paint colour for the hall",
            "Is it worth renewing the subscription",
            "Figure out whether to keep the gym membership",
        ] {
            let task = TaskItem(title: title, status: .todo, in: context)
            #expect(DecisionShape.reads(title: title))
            #expect(TaskShape.of(task, among: [task]) == .action, "\(title) leaked into a shape")
        }
    }

    @Test("Resolved is always action — a done page has no problem to be the spine")
    func resolvedIsAction() {
        let context = context()
        let task = TaskItem(title: "Pick a school", status: .todo, in: context)
        task.needsDecision = true
        task.complete()
        #expect(TaskShape.of(task, among: [task]) == .action)
    }

    @Test("The two constructors always agree — shape is a function of the facts")
    func constructorsAgree() {
        let context = context()
        let blocker = TaskItem(title: "Send the numbers", status: .todo, in: context)
        let flagged = TaskItem(title: "Pick a school", status: .todo, in: context)
        flagged.needsDecision = true
        let blocked = TaskItem(title: "Sign the contract", status: .todo, in: context)
        blocked.addTaskBlocker(blocker.uuid!, among: [blocked, blocker])
        let waiting = TaskItem(title: "Sign the lease", status: .todo, in: context)
        waiting.addExternalBlocker("the landlord", among: [waiting])
        let parent = TaskItem(title: "Contract review", status: .todo, in: context)
        let steps = parent.splitInto(
            [BreakdownStep(title: "Review pricing", effortMinutes: 15)], in: context)
        let plain = TaskItem(title: "Call the dentist", status: .todo, in: context)

        let all = [blocker, flagged, blocked, waiting, parent, plain] + steps
        for task in all {
            let fromTask = TaskShape.of(task, among: all)
            let fromFacts = TaskShape.of(TaskAdvisorFacts.make(task: task, among: all))
            #expect(fromTask == fromFacts, "\(task.title): \(fromTask) ≠ \(fromFacts)")
        }
    }

    @Test("Shape ⊆ fingerprint: fields outside the fingerprint never change the shape")
    func shapeIsInsideTheFingerprint() {
        let context = context()
        let task = TaskItem(title: "Sign the contract", status: .todo, in: context)
        let before = TaskShape.of(task, among: [task])
        // None of these are fingerprint inputs; none may reshape the page.
        task.category = "Legal"
        task.isUrgent = true  // in the fingerprint, but not a shape input — see below
        task.rawCapture = "sign the contract with the vendor"
        task.reasoning = "Filed under Legal."
        #expect(TaskShape.of(task, among: [task]) == before)
    }

    @Test("Four shapes, and a signal must never become a fifth")
    func fourShapes() {
        #expect(
            TaskShape.allCases.count == 4,
            Comment(rawValue:
                "A signal is not a shape: breakdown-eligibility, staleness, urgency and "
                + "decision-shaped wording ride ON a shape. Adding a case here needs a "
                + "product decision, not a detector branch."))
    }
}
