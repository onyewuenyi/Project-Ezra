//
//  DataReset.swift
//  Project-Ezra
//
//  The wipe the USER asks for — the fourth destructive path, and the only one that is
//  not a repair. The other three (`schemaGeneration`, the load-failure self-heal, the
//  `-SeedTodayFixtures` seam) destroy the store file itself because they run before or
//  around a store that won't open. This one runs against a store that is open and in
//  use, so it empties the graph through the context instead: the view context stays
//  consistent, every `@FetchRequest` on screen updates, and no relaunch is needed.
//
//  Two scopes, because "clear" means two different things. `.work` deletes what you
//  captured and keeps who you are — no re-onboarding to get an empty list. `.everything`
//  also takes identity, preferences and diagnostics, leaving first-launch state.
//
//  It inherits the data-safety rules the store has held since daily use began: a safety
//  copy is taken first, and the clear is reported (`Receipt`) rather than performed in
//  silence. What it deliberately does NOT write is a `StoreResetRecord` — that card
//  exists to explain a wipe the user did not choose, and warning someone about the
//  button they just pressed is noise, not honesty.
//

import CoreData
import Foundation

extension Notification.Name {
    /// Posted after `DataReset.clear` empties the store. Core Data's own change
    /// notifications cover every fetched view for free; this exists for the surfaces
    /// holding a DECODED SNAPSHOT of work that no longer exists — today's cached
    /// briefing, which lives in `UserDefaults` and names task ids by hand.
    static let ezraDataCleared = Notification.Name("ezra.dataCleared")
}

enum DataReset {

    /// How far a clear goes.
    enum Scope {
        /// Tasks, captures, activity, corrections, capacity, and the learned
        /// suppression/embedding caches. Profile and household roster survive.
        case work
        /// Also identity, preferences, the first-run flag and the local diagnostics —
        /// what a fresh install would have.
        case everything
    }

    /// What happened, so the caller can say so and hand back the safety copy.
    struct Receipt: Equatable {
        let scope: Scope
        let date: Date
        /// The safety copy's folder name inside `PersistenceStack.backupsDirectory`, or
        /// nil when there was nothing to copy or the copy failed. **Nil is the case worth
        /// surfacing** — it means the data is gone with no fallback.
        let backupName: String?
    }

    /// Entities that describe WHO you are rather than what you captured. Everything else
    /// in the model counts as work — derived from the model at runtime rather than listed,
    /// so a future entity is cleared by both scopes without anyone remembering this file.
    private static let identityEntities: Set<String> = [
        "UserProfile", "FamilyMember", "Household", "HouseholdSettings",
        "HouseholdMemory", "HouseholdAIContext", "Invitation",
    ]

    /// Defaults that MIRROR the store. They go with the work they describe: a cached
    /// briefing naming deleted tasks is the one wrong thing a clear could leave on screen.
    private static let workKeys = [
        "today.planCache", "today.recapCutoff", "brainSweeps.lastRunAt", "lastInboxSeenAt",
    ]

    /// Defaults that belong to the person, not the work. `hasOnboarded` is here because
    /// a factory reset that skips the first run isn't one.
    private static let identityKeys = ["hasOnboarded"]

    /// Empty the store at `scope`. Returns the receipt; never throws — a clear the user
    /// asked for must not be blockable by a failed copy or a failed save.
    ///
    /// `metrics`/`planMetrics` are passed in rather than reached for: they are instances
    /// owned by `AppBrain`, and both cache their counters in memory, so clearing their
    /// `UserDefaults` keys alone would leave the numbers on screen until relaunch. Nil in
    /// tests. `location` is injectable for the same reason `PersistenceStack`'s is — these
    /// functions write and delete real files.
    @discardableResult
    static func clear(
        _ scope: Scope, in context: NSManagedObjectContext,
        metrics: MetricsRecorder? = nil, planMetrics: PlanMetrics? = nil,
        defaults: UserDefaults = .standard, now: Date = Date(),
        at location: PersistenceStack.StoreLocation = .default
    ) -> Receipt {
        // A copy first, always — the same rule `destroyStore` holds. Best-effort by
        // design, and weaker here than there: this copies a store that is currently OPEN,
        // so the sqlite may lag its `-wal`. The stronger safety net is the JSON export
        // sitting directly above this button in Settings.
        let backupName = PersistenceStack.backupStore(now: now, at: location)

        // Image bytes live beside the store as files keyed by `Capture.imageRef`;
        // deleting the row alone would orphan them in the container forever.
        let captures = (try? context.fetch(NSFetchRequest<Capture>(entityName: "Capture"))) ?? []
        for ref in captures.compactMap(\.imageRef) { CaptureImageStore.delete(ref) }

        for name in entityNames(for: scope, in: context) {
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            (try? context.fetch(request))?.forEach(context.delete)
        }
        context.saveChanges()

        for key in workKeys { defaults.removeObject(forKey: key) }

        if scope == .everything {
            for key in identityKeys { defaults.removeObject(forKey: key) }
            // The pending-reset card describes a store that no longer exists.
            StoreResetLog.clear(in: defaults)
            metrics?.reset(now: now)
            planMetrics?.reset()
            ModelMetrics.shared.reset()
            CapabilityMetrics.shared.reset()
            // Never leave the app without an identity: this is exactly what a first
            // launch creates, and `currentMemberID` is read from ownership to Today.
            _ = UserProfile.bootstrapIdentity(in: context)
            context.saveChanges()
        }

        NotificationCenter.default.post(name: .ezraDataCleared, object: nil)
        return Receipt(scope: scope, date: now, backupName: backupName)
    }

    private static func entityNames(for scope: Scope, in context: NSManagedObjectContext) -> [String] {
        let all = (context.persistentStoreCoordinator?.managedObjectModel.entities ?? [])
            .compactMap(\.name)
        switch scope {
        case .work: return all.filter { !identityEntities.contains($0) }
        case .everything: return all
        }
    }
}
