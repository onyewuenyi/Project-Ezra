//
//  TodaySequenceRolloverTests.swift
//  Project-EzraTests
//
//  "The briefing plays once a day" used to hold only across cold launches. The sequence
//  model anchored `now` at construction and guarded on a one-shot `started` flag, so a
//  phone left running — or, far more common, backgrounded overnight and reopened from the
//  morning nudge — kept resting on yesterday's briefing, and the rollover reconciliation
//  that turns yesterday's plan into a `CapacityLog` + deferral counts never ran at all.
//
//  `restartIfDayRolledOver` closes that, routed through `TodayPlanStore.shouldReplay` so
//  the single reset predicate stays the only place the date is tested.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Today sequence day rollover")
struct TodaySequenceRolloverTests {

    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "today-rollover-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Wait for the background generation kicked off by `start` to land. The test host has
    /// no on-device model, so this resolves on the deterministic tail — fast and certain.
    private func settle(_ sequence: BriefSequenceModel) async {
        for _ in 0..<300 {
            if !sequence.isGenerating, sequence.plan != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A live app crossing midnight re-arms the sequence; the same day does not")
    func rollover() async throws {
        let context = TestStore.makeContext()
        let store = TodayPlanStore(defaults: freshDefaults())
        let brain = AppBrain()

        let task = TaskItem(title: "Renew car insurance", status: .todo, dueDate: day1)
        let sequence = BriefSequenceModel(brain: brain, store: store, now: day1)

        sequence.start(tasks: [task], logs: [], context: context)
        await settle(sequence)
        #expect(sequence.started)
        #expect(store.cache?.dateKey == TodayPlanStore.dayKey(for: day1))

        // Same day, hours later: the briefing has already played, nothing to re-arm.
        #expect(
            !sequence.restartIfDayRolledOver(
                now: day1.addingTimeInterval(5 * 3600), tasks: [task], logs: [], context: context))
        #expect(sequence.now == day1)

        // A new calendar day: re-armed, re-anchored, and a fresh briefing generated —
        // rather than yesterday's resting on screen all day.
        let day2 = day1.addingTimeInterval(24 * 3600)
        #expect(
            sequence.restartIfDayRolledOver(
                now: day2, tasks: [task], logs: [], context: context))
        #expect(sequence.now == day2)
        #expect(!sequence.resting)

        await settle(sequence)
        #expect(store.cache?.dateKey == TodayPlanStore.dayKey(for: day2))
    }

    @Test("The rollover runs yesterday's reconciliation — the CapacityLog row is not skipped")
    func rolloverReconciles() async throws {
        let context = TestStore.makeContext()
        let store = TodayPlanStore(defaults: freshDefaults())
        let brain = AppBrain()

        // Born before the briefing surfaced it and never touched since — `humanTouchedAt`
        // falls back to `createdAt`, so this is the true "deferred" shape.
        let task = TaskItem(
            title: "Submit the expense report", status: .todo, dueDate: day1,
            createdAt: day1.addingTimeInterval(-3600))
        let sequence = BriefSequenceModel(brain: brain, store: store, now: day1)
        sequence.start(tasks: [task], logs: [], context: context)
        await settle(sequence)

        let day2 = day1.addingTimeInterval(24 * 3600)
        sequence.restartIfDayRolledOver(now: day2, tasks: [task], logs: [], context: context)
        await settle(sequence)

        let logs = try context.fetch(NSFetchRequest<CapacityLog>(entityName: "CapacityLog"))
        #expect(logs.count == 1)
        // Untouched planned work reads as a deferral, not as carried-over.
        #expect(task.deferralCount == 1)
    }

    @Test("A sequence that never started is never restarted out from under its own launch")
    func neverStarted() {
        let store = TodayPlanStore(defaults: freshDefaults())
        let sequence = BriefSequenceModel(brain: AppBrain(), store: store, now: day1)
        let context = TestStore.makeContext()
        #expect(
            !sequence.restartIfDayRolledOver(
                now: day1.addingTimeInterval(48 * 3600), tasks: [], logs: [], context: context))
    }
}
