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

    @Test("workIntent rides the prompt as an INTERNAL line, never a user-facing fact")
    func workIntentIsInternal() {
        let context = context()
        let task = TaskItem(title: "Plan the move", status: .todo, in: context)
        task.workIntent = .planning
        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        #expect(facts.promptBlock.contains("INTERNAL: planning work"))
    }
}
