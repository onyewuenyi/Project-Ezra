//
//  TaskAdvisorFactsTests.swift
//  Project-EzraTests
//
//  The fingerprint contract, pinned field by field: every entry is a cache-invalidation
//  decision (a flip = the Advisor re-judges), and every exclusion is a calm decision
//  (the raw staleness clock ticking must NOT give the AI a different opinion each
//  open). Plus the prompt block — the facts the model may use are exactly the facts
//  the sensors used, `UnstickNarrationTests`-style.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Task Advisor — facts and fingerprint")
struct TaskAdvisorFactsTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func fingerprint(_ task: TaskItem, among: [TaskItem], now: Date = Date()) -> Int {
        TaskAdvisorFacts.make(task: task, among: among, now: now).fingerprint
    }

    @Test("Each meaningful fact flips the fingerprint")
    func meaningfulFactsFlip() {
        let context = context()
        let now = Date()
        let task = TaskItem(title: "Renew passport", status: .todo, in: context)
        let base = fingerprint(task, among: [task], now: now)

        task.title = "Renew both passports"
        #expect(fingerprint(task, among: [task], now: now) != base)
        task.title = "Renew passport"
        #expect(fingerprint(task, among: [task], now: now) == base)

        task.notes = "Photos are in the drawer"
        #expect(fingerprint(task, among: [task], now: now) != base)
        task.notes = nil

        task.effortMinutes = 90
        #expect(fingerprint(task, among: [task], now: now) != base)
        task.effortMinutes = nil

        task.dueDate = now.addingTimeInterval(5 * 86_400)
        #expect(fingerprint(task, among: [task], now: now) != base)
        task.dueDate = nil

        task.isUrgent = true
        #expect(fingerprint(task, among: [task], now: now) != base)
        task.isUrgent = false

        task.needsDecision = true
        #expect(fingerprint(task, among: [task], now: now) != base)
        task.needsDecision = false

        task.deferralCount = 3
        #expect(fingerprint(task, among: [task], now: now) != base)
        task.deferralCount = 0

        task.status = .doing
        #expect(fingerprint(task, among: [task], now: now) != base)
    }

    @Test("Abandoning a start flips the fingerprint; the clock inside it does not")
    func abandonedStartFlips() {
        // The depth router's third input (2026-09-12). It belongs in the fingerprint
        // where the two clocks beside it do not, and the difference is the rule: putting
        // a task back down is a discrete human act that changes what the right reading
        // IS, so it should buy a new judgment; a counter that ticks with the calendar
        // must not.
        let context = context()
        let now = Date()
        let task = TaskItem(title: "Sort the loft", status: .todo, in: context)
        let base = fingerprint(task, among: [task], now: now)

        // Picked up — a status change, which already flips.
        task.status = .doing
        let started = fingerprint(task, among: [task], now: now)
        #expect(started != base)

        // Put back down. Same STATUS as the base, so without `abandonedStarts` in the
        // fingerprint this would collide with it and serve the pre-attempt reading back.
        task.status = .todo
        #expect(task.abandonedStartCount == 1)
        #expect(fingerprint(task, among: [task], now: now) != base)

        // And the same state an hour later is the same judgment.
        let later = now.addingTimeInterval(3_600)
        #expect(
            fingerprint(task, among: [task], now: later)
                == fingerprint(task, among: [task], now: now))
    }

    @Test("Gaining a blocker, a child, or a completed step flips the fingerprint")
    func graphChangesFlip() {
        let context = context()
        let now = Date()
        let task = TaskItem(title: "Fix the boiler", status: .todo, in: context)
        let other = TaskItem(title: "Get the part", status: .todo, in: context)
        let base = fingerprint(task, among: [task, other], now: now)

        task.addTaskBlocker(other.uuid!, among: [task, other])
        let blocked = fingerprint(task, among: [task, other], now: now)
        #expect(blocked != base)
        task.removeBlocker(other.uuid!, among: [task, other])

        other.linkParent(task.uuid!)
        let withChild = fingerprint(task, among: [task, other], now: now)
        #expect(withChild != base)

        // A step completing ELSEWHERE must re-judge the umbrella — the open-step
        // count is a fingerprint field precisely because no edge changes.
        other.complete()
        #expect(fingerprint(task, among: [task, other], now: now) != withChild)
    }

    @Test("The clock alone never flips it — calm by construction")
    func clockDoesNotFlip() {
        let context = context()
        let now = Date()
        let task = TaskItem(title: "Sort the garage", status: .todo, in: context)
        let base = fingerprint(task, among: [task], now: now)

        // Hours later, nothing else changed: same judgment. (A DAY boundary can flip
        // the stall diagnosis via the quiet threshold — that case-flip is the fact
        // that matters, and it is the diagnosis field that carries it.)
        let later = now.addingTimeInterval(6 * 3_600)
        #expect(fingerprint(task, among: [task], now: later) == base)
    }

    @Test("Owner and category are deliberately excluded")
    func excludedFields() {
        let context = context()
        let now = Date()
        let task = TaskItem(title: "Renew passport", status: .todo, in: context)
        let base = fingerprint(task, among: [task], now: now)

        task.ownerID = UUID()
        task.category = "Travel"
        #expect(fingerprint(task, among: [task], now: now) == base)
    }

    @Test("The prompt block carries the sensor readings as fixed fact lines")
    func promptBlockCarriesSensors() {
        let context = context()
        let now = Date()
        let task = TaskItem(
            title: "Renew passport", status: .todo, effortMinutes: 90, in: context)
        task.deferralCount = 4

        let facts = TaskAdvisorFacts.make(task: task, among: [task], now: now)
        let block = facts.promptBlock
        #expect(block.hasPrefix("FACTS:"))  // the prewarm prefix
        #expect(block.contains("TASK: Renew passport"))
        #expect(block.contains("SENSOR: stalled — too big to start"))
        #expect(block.contains("SENSOR: looks decomposable — this is a long one"))
        #expect(block.contains("Set aside 4 times in a row"))
    }

    @Test("The full deferral count reaches the prompt — this IS the stall surface")
    func fullDeferralCount() {
        let context = context()
        let task = TaskItem(title: "Call the plumber", status: .todo, in: context)
        task.deferralCount = 7
        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        #expect(facts.deferralCount == 7)
        #expect(facts.promptBlock.contains("Set aside 7 times in a row"))
    }

    @Test("Future due date renders in the prompt block via precomputed daysUntilDue")
    func futureDueDateInPromptBlock() {
        let context = context()
        let now = Date()
        let task = TaskItem(title: "File taxes", status: .todo, in: context)
        task.dueDate = now.addingTimeInterval(3 * 86_400)
        let facts = TaskAdvisorFacts.make(task: task, among: [task], now: now)
        #expect(facts.daysUntilDue == 3)
        #expect(facts.promptBlock.contains("DUE: in 3 days"))
    }

    @Test("workIntent rides the prompt as an INTERNAL line, never a user-facing fact")
    func workIntentIsInternal() {
        let context = context()
        let task = TaskItem(title: "Plan the move", status: .todo, in: context)
        task.workIntent = .planning
        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        #expect(facts.promptBlock.contains("INTERNAL: planning work"))
        // …and it must never reach the user through "Why this?" — axis 2 is
        // system-owned, and internal reasoning signals must not become accidental UI.
        #expect(!facts.userVisibleEvidence.contains { $0.lowercased().contains("planning") })
    }

    @Test("Evidence is the facts in the user's terms — traceable, never narrative")
    func evidenceIsFacts() {
        let context = context()
        let now = Date()
        let task = TaskItem(title: "Fix the boiler", status: .todo, in: context)
        let blocker = TaskItem(title: "Get the part quote", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])
        task.deferralCount = 4
        task.isUrgent = true
        task.dueDate = now.addingTimeInterval(-2 * 86_400)

        let evidence = TaskAdvisorFacts.make(task: task, among: [task, blocker], now: now)
            .userVisibleEvidence

        #expect(evidence.contains("You've set this aside 4 times in a row"))
        #expect(evidence.contains("It's waiting on “Get the part quote”"))
        #expect(evidence.contains("It's 2 days overdue"))
        #expect(evidence.contains("You marked it urgent"))
    }

    @Test("A clean task has no evidence to show — nothing to explain")
    func cleanTaskHasNoEvidence() {
        let context = context()
        let task = TaskItem(title: "Call the dentist", status: .todo, effortMinutes: 15, in: context)
        #expect(TaskAdvisorFacts.make(task: task, among: [task]).userVisibleEvidence.isEmpty)
    }
}
