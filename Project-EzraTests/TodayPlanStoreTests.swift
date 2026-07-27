//
//  TodayPlanStoreTests.swift
//  Project-EzraTests
//
//  The store owns "plays once a day": the single reset predicate, the resting-plan
//  cache, the docket-changed signal, and the day-rollover reconciliation that turns
//  yesterday's plan into one CapacityLog row. Tested against a scratch UserDefaults
//  suite (the MetricsRecorder idiom) and the shared in-memory context.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Today plan store")
struct TodayPlanStoreTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "today-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func cache(
        for date: Date, tier: PlanTier = .deterministic, actions: [PlannedAction] = [],
        signature: [UUID] = []
    ) -> TodayPlanCache {
        TodayPlanCache(
            dateKey: TodayPlanStore.dayKey(for: date), tier: tier, headline: nil, tradeoffs: nil,
            risks: nil, actions: actions, generatedAt: date, docketSignature: signature,
            completedAt: nil)
    }

    // MARK: - shouldReplay + cache access

    @Test("Fresh store replays; a cache for today rests; a new day replays")
    func shouldReplay() {
        let store = TodayPlanStore(defaults: freshDefaults())
        #expect(store.shouldReplay(now: now))  // no cache

        store.save(cache(for: now))
        #expect(!store.shouldReplay(now: now))
        #expect(store.cache(for: now) != nil)

        let tomorrow = now.addingTimeInterval(24 * 3600)
        #expect(store.shouldReplay(now: tomorrow))
        #expect(store.cache(for: tomorrow) == nil)  // stale cache is not returned as resting
    }

    @Test("The cache round-trips through UserDefaults across store instances")
    func cachePersists() {
        let defaults = freshDefaults()
        let store = TodayPlanStore(defaults: defaults)
        store.save(cache(for: now, tier: .onDevice))
        let reloaded = TodayPlanStore(defaults: defaults)
        #expect(reloaded.cache?.tier == .onDevice)
        #expect(!reloaded.shouldReplay(now: now))
    }

    // MARK: - Docket-changed signal

    @Test("Docket-changed fires only when a new open id is absent from the signature")
    func docketChanged() {
        let store = TodayPlanStore(defaults: freshDefaults())
        let a = UUID()
        let b = UUID()
        store.save(cache(for: now, signature: [a]))
        #expect(!store.hasDocketChanged(currentOpenDocketIDs: [a]))
        #expect(store.hasDocketChanged(currentOpenDocketIDs: [a, b]))
        // A shrinking docket (nothing new) is not a "changed" signal in V0.
        #expect(!store.hasDocketChanged(currentOpenDocketIDs: []))
    }

    // MARK: - Sequence completion

    @Test("Completing the sequence advances the recap cutoff and stamps the cache")
    func markComplete() {
        let store = TodayPlanStore(defaults: freshDefaults())
        #expect(store.recapCutoff == nil)
        store.save(cache(for: now))
        store.markSequenceComplete(now: now)
        #expect(store.recapCutoff == now)
        #expect(store.cache?.completedAt == now)
    }

    @Test("A same-day replan does not advance the recap cutoff past what the Recap covered")
    func replanKeepsFirstCutoff() {
        let store = TodayPlanStore(defaults: freshDefaults())
        store.save(cache(for: now))
        store.markSequenceComplete(now: now)

        // Replan five hours later. Anything the user finished in between was NOT in the
        // morning Recap, so moving the cutoff here would swallow it — those completions
        // would never appear in tomorrow's Recap either.
        let later = now.addingTimeInterval(5 * 3600)
        var replanned = cache(for: later)
        replanned.completedAt = store.cache?.completedAt
        store.save(replanned)
        store.markSequenceComplete(now: later)

        #expect(store.recapCutoff == now)
        #expect(store.cache?.completedAt == now)

        // A genuine new day does advance it.
        let tomorrow = now.addingTimeInterval(24 * 3600)
        store.save(cache(for: tomorrow))
        store.markSequenceComplete(now: tomorrow)
        #expect(store.recapCutoff == tomorrow)
    }

    // MARK: - Day-rollover reconciliation

    @Test("Rollover writes one CapacityLog from yesterday's plan, then clears the cache")
    func reconciliationWritesLog() throws {
        let context = TestStore.makeContext()
        let store = TodayPlanStore(defaults: freshDefaults())

        let done1 = TaskItem(title: "d1", status: .todo)
        done1.complete(now: now)
        let open = TaskItem(title: "o", status: .todo)
        let done2 = TaskItem(title: "d2", status: .todo)
        done2.complete(now: now)
        let tasks = [done1, open, done2]

        let yesterday = now.addingTimeInterval(-24 * 3600)
        let actions = tasks.map { PlannedAction(taskID: $0.uuid!, rationale: nil) }
        store.save(cache(for: yesterday, actions: actions))

        store.reconcileIfNeeded(context: context, tasks: tasks, now: now)

        let logs = try context.fetch(NSFetchRequest<CapacityLog>(entityName: "CapacityLog"))
        #expect(logs.count == 1)
        let log = try #require(logs.first)
        // Capacity is vestigial now (the input is gone) — logged as .steady.
        #expect(log.capacity == .steady)
        #expect(log.planCount == 3)
        #expect(log.completedCount == 2)
        #expect(log.skippedCount == 1)
        // The stale cache is cleared so today can start fresh.
        #expect(store.cache == nil)
    }

    @Test("Rollover discriminates deferral from carried-over by the HUMAN clock, once per day")
    func rolloverDeferralDiscrimination() throws {
        let context = TestStore.makeContext()
        let store = TodayPlanStore(defaults: freshDefaults())
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let birth = yesterday.addingTimeInterval(-3600)

        let untouched = TaskItem(title: "untouched", status: .todo, createdAt: birth)
        let worked = TaskItem(title: "worked", status: .todo, createdAt: birth)
        let systemTouched = TaskItem(title: "system", status: .todo, createdAt: birth)
        let finished = TaskItem(title: "finished", status: .todo, createdAt: birth)
        let tasks = [untouched, worked, systemTouched, finished]
        for task in tasks { task.lastSurfacedAt = yesterday }

        worked.touchHuman(now: now.addingTimeInterval(-3600))  // real engagement after surfacing
        systemTouched.touch(now: now.addingTimeInterval(-3600))  // a system bump must NOT count
        finished.complete(now: now.addingTimeInterval(-3600))

        store.save(
            cache(for: yesterday, actions: tasks.map { PlannedAction(taskID: $0.uuid!, rationale: nil) }))
        store.reconcileIfNeeded(context: context, tasks: tasks, now: now)

        #expect(untouched.deferralCount == 1 && untouched.carriedOverCount == 0)
        #expect(worked.carriedOverCount == 1 && worked.deferralCount == 0)
        #expect(systemTouched.deferralCount == 1 && systemTouched.carriedOverCount == 0)
        #expect(finished.deferralCount == 0 && finished.carriedOverCount == 0)  // resolved → neither

        // Once per day: the cache was cleared, so a second reconcile is a no-op.
        store.reconcileIfNeeded(context: context, tasks: tasks, now: now)
        #expect(untouched.deferralCount == 1)
    }

    @Test("No reconciliation when the cache is already today's")
    func reconciliationSkipsToday() throws {
        let context = TestStore.makeContext()
        let store = TodayPlanStore(defaults: freshDefaults())
        let task = TaskItem(title: "t", status: .todo)
        task.complete(now: now)
        store.save(cache(for: now, actions: [PlannedAction(taskID: task.uuid!, rationale: nil)]))

        store.reconcileIfNeeded(context: context, tasks: [task], now: now)

        let logs = try context.fetch(NSFetchRequest<CapacityLog>(entityName: "CapacityLog"))
        #expect(logs.isEmpty)
        #expect(store.cache != nil)  // today's cache is untouched
    }

    @Test("A day with no planned actions is not logged")
    func reconciliationSkipsEmptyPlan() throws {
        let context = TestStore.makeContext()
        let store = TodayPlanStore(defaults: freshDefaults())
        let yesterday = now.addingTimeInterval(-24 * 3600)
        store.save(cache(for: yesterday, actions: []))

        store.reconcileIfNeeded(context: context, tasks: [], now: now)

        let logs = try context.fetch(NSFetchRequest<CapacityLog>(entityName: "CapacityLog"))
        #expect(logs.isEmpty)
        #expect(store.cache == nil)  // still cleared
    }
}
