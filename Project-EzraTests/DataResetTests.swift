//
//  DataResetTests.swift
//  Project-EzraTests
//
//  The two scopes of the user's own wipe. The invariant worth pinning is the SPLIT:
//  `.work` must leave identity standing (or an empty task list costs you your name and
//  your household), and `.everything` must leave none of it — while still leaving the
//  app with an identity to run on.
//
//  A throwaway store location is passed everywhere: `DataReset` takes a safety copy, and
//  a test that writes into the app's real container is a test that can delete real data.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct DataResetTests {

    /// Isolated defaults per test, so clearing keys can't disturb the host's.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "DataResetTests.\(name)")!
        defaults.removePersistentDomain(forName: "DataResetTests.\(name)")
        return defaults
    }

    private func location(_ name: String) -> PersistenceStack.StoreLocation {
        .temporary("data-reset-tests-\(name)")
    }

    private func seed(in context: NSManagedObjectContext) {
        _ = UserProfile.bootstrapIdentity(in: context)
        _ = TaskItem(title: "Renew passport", category: "Admin", in: context)
        _ = Capture(rawText: "renew passport", in: context)
        _ = ChangeLogEntry(summary: "Created Renew passport", action: "created", in: context)
        context.saveChanges()
    }

    private func count(_ entity: String, in context: NSManagedObjectContext) -> Int {
        (try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))) ?? 0
    }

    @Test("Clearing work deletes the work and keeps who you are")
    func workScopeKeepsIdentity() {
        let context = TestStore.makeContext()
        seed(in: context)

        DataReset.clear(
            .work, in: context, defaults: makeDefaults("work"), at: location("work"))

        #expect(count("TaskItem", in: context) == 0)
        #expect(count("Capture", in: context) == 0)
        #expect(count("ChangeLogEntry", in: context) == 0)
        #expect(count("UserProfile", in: context) == 1)
        #expect(count("FamilyMember", in: context) == 1)
    }

    @Test("Resetting everything takes identity too — but leaves one to run on")
    func everythingScopeRebootstrapsIdentity() {
        let context = TestStore.makeContext()
        seed(in: context)
        let originalProfile = UserProfile.current(in: context).id

        DataReset.clear(
            .everything, in: context, defaults: makeDefaults("all"), at: location("all"))

        #expect(count("TaskItem", in: context) == 0)
        // Re-bootstrapped, not merely emptied: half the app reads `currentMemberID`, so a
        // reset that leaves no identity leaves a broken app, not a fresh one.
        #expect(count("UserProfile", in: context) == 1)
        #expect(count("FamilyMember", in: context) == 1)
        #expect(UserProfile.current(in: context).id != originalProfile)
        #expect(UserProfile.current(in: context).displayName == nil)
    }

    @Test("The day cache goes with the work it describes")
    func clearingWorkDropsTheCachedBriefing() {
        let context = TestStore.makeContext()
        let defaults = makeDefaults("cache")
        seed(in: context)
        let store = TodayPlanStore(defaults: defaults)
        store.save(
            TodayPlanCache(
                dateKey: TodayPlanStore.dayKey(for: Date()), tier: .deterministic,
                headline: "Your day", tradeoffs: nil, risks: nil, actions: [],
                generatedAt: Date(), docketSignature: []))
        #expect(defaults.data(forKey: "today.planCache") != nil)

        DataReset.clear(.work, in: context, defaults: defaults, at: location("cache"))

        #expect(defaults.data(forKey: "today.planCache") == nil)
        #expect(defaults.object(forKey: "today.recapCutoff") == nil)
    }

    @Test("Only the factory reset touches identity preferences")
    func onboardingFlagSurvivesAWorkClear() {
        let context = TestStore.makeContext()
        let defaults = makeDefaults("onboarding")
        seed(in: context)
        defaults.set(true, forKey: "hasOnboarded")

        DataReset.clear(.work, in: context, defaults: defaults, at: location("onboarding"))
        #expect(defaults.bool(forKey: "hasOnboarded"))

        DataReset.clear(.everything, in: context, defaults: defaults, at: location("onboarding"))
        #expect(defaults.bool(forKey: "hasOnboarded") == false)
    }

    @Test("The receipt is durable, and survives the factory reset that wrote it")
    func clearWritesADurableReceipt() throws {
        let context = TestStore.makeContext()
        let defaults = makeDefaults("receipt")
        seed(in: context)

        let record = DataReset.clear(
            .everything, in: context, defaults: defaults, at: location("receipt"))

        #expect(record.reason == .userRequested(clearedIdentity: true))
        #expect(record.reason.isVoluntary)
        #expect(record.destroyedData)
        // Written to the log, not merely returned: "where is my backup?" is asked after the
        // sheet is closed. And written AFTER the `.everything` key sweep, or the reset
        // would erase the receipt for itself.
        let pending = try #require(StoreResetLog.pending(in: defaults))
        #expect(pending == record)

        // A work-only clear says so, so the card can name what actually went.
        let work = DataReset.clear(.work, in: context, defaults: defaults, at: location("receipt"))
        #expect(work.reason == .userRequested(clearedIdentity: false))
        #expect(work.reason.explanation.contains("cleared all tasks"))
    }

    @Test("Counted signals are wiped in memory, not just on disk")
    func factoryResetClearsCachedMetrics() {
        let context = TestStore.makeContext()
        let defaults = makeDefaults("metrics")
        seed(in: context)
        let metrics = MetricsRecorder(defaults: defaults)
        let plan = PlanMetrics(defaults: defaults)
        metrics.recordOpen()
        metrics.recordFirstPayoffIfNeeded()
        plan.recordGeneration(tier: .onDevice, latencyMs: 900, promptTokens: 10, outputTokens: 20)

        DataReset.clear(
            .everything, in: context, metrics: metrics, planMetrics: plan, defaults: defaults,
            at: location("metrics"))

        #expect(metrics.selfInitiatedOpens == 0)
        #expect(metrics.timeToFirstPayoff == nil)
        #expect(plan.onDeviceCount == 0)
        #expect(plan.lastLatencyMs == -1)
    }
}
