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

    /// The file sidecars are the half of the store that isn't in the store. Both are keyed
    /// to rows BOTH scopes delete, so a clear that spared them would leave the Advisor
    /// holding judgments about tasks that are gone, and the learner holding half a corpus
    /// of "no"s — a `.everything` that still remembers what you told it is not a reset.
    @Test("Both scopes clear the sidecars keyed to the work they delete")
    func clearingDropsTheFileSidecars() {
        let context = TestStore.makeContext()
        let verdicts = HumanVerdictStore(fileURL: nil)
        let readings = AdvisorReadingCache(fileURL: nil)

        for scope in [DataReset.Scope.work, .everything] {
            seed(in: context)
            let taskID = UUID()
            verdicts.record(
                HumanVerdict(subject: .reading(taskID: taskID, fingerprint: 1), verdict: .declined))
            readings.store(.silence, taskID: taskID, fingerprint: 1)
            #expect(verdicts.all.count == 1)
            #expect(readings.all.count == 1)

            DataReset.clear(
                scope, in: context, defaults: makeDefaults("sidecars"),
                at: location("sidecars"), verdicts: verdicts, readings: readings)

            #expect(verdicts.all.isEmpty)
            #expect(readings.all.isEmpty)
        }
    }

    /// A clear that lands says so through `destroyedData`, which is what `SettingsView`
    /// now reads before it reports a wipe. The failure arm is deliberately not simulated
    /// — forcing a Core Data save failure needs a contrived model — so what is pinned is
    /// the fact the UI branches on: a clear that worked is legible as one.
    @Test("A clear that lands reports that it destroyed data")
    func aLandedClearReportsDestruction() {
        let context = TestStore.makeContext()
        seed(in: context)

        let record = DataReset.clear(
            .work, in: context, defaults: makeDefaults("landed"), at: location("landed"))

        #expect(record.destroyedData)
        #expect(count("TaskItem", in: context) == 0)
    }

}
