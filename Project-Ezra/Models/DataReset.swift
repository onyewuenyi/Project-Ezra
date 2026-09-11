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
//  copy is taken first, and the clear is reported rather than performed in silence — through
//  the SAME `StoreResetRecord` + `StoreResetLog` the involuntary wipes use. That reuse is
//  the point. A first pass minted a `Receipt` of its own, on the reasoning that the reset
//  card is a warning and warning someone about the button they just pressed is noise; the
//  reasoning was right about the TONE and wrong about the STORAGE. A UI-local receipt dies
//  with the sheet, and "where did my backup go?" is asked hours later. So the record is
//  shared and durable, and only the card's tone branches (`StoreResetReason.isVoluntary`).
//

import CoreData
import Foundation

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

    /// Empty the store at `scope`. Returns the same `StoreResetRecord` the involuntary
    /// wipes write — durable, backup-carrying — and never throws: a clear the user asked
    /// for must not be blockable by a failed copy.
    ///
    /// **`destroyedData` is the answer to "did it work?"** A failed save returns
    /// `destroyedData: false` and writes NO receipt — nothing was destroyed, so there is
    /// nothing to receipt, and the caller has the one fact it needs to say so instead of
    /// reporting a wipe that did not happen.
    ///
    /// **The receipt is written to `StoreResetLog`, not just returned.** A UI-local return
    /// value dies with the sheet, and "where did my backup go?" is a question asked hours
    /// later. Reusing the existing record is also what keeps ONE reset-reporting path in
    /// the app instead of two that can drift.
    ///
    /// `metrics`/`planMetrics` are passed in rather than reached for: they are instances
    /// owned by `AppBrain`, and both cache their counters in memory, so clearing their
    /// `UserDefaults` keys alone would leave the numbers on screen until relaunch. Nil in
    /// tests. `location` and the three sidecar stores (`provenance`/`readings`/`verdicts`)
    /// are injectable for the same reason `PersistenceStack`'s is — these functions write
    /// and delete real files, and a test reaching for `.shared` would unlink the
    /// developer's own.
    @discardableResult
    static func clear(
        _ scope: Scope, in context: NSManagedObjectContext,
        metrics: MetricsRecorder? = nil,
        defaults: UserDefaults = .standard, now: Date = Date(),
        at location: PersistenceStack.StoreLocation = .default,
        provenance: CaptureProvenanceStore? = nil,
        verdicts: HumanVerdictStore? = nil,
        readings: AdvisorReadingCache? = nil
    ) -> StoreResetRecord {
        // A copy first, always — the same rule `destroyStore` holds. Best-effort by
        // design, and weaker here than there: this copies a store that is currently OPEN,
        // so the sqlite may lag its `-wal`. The stronger safety net is the JSON export
        // sitting directly above this button in Settings.
        let backupName = PersistenceStack.backupStore(now: now, at: location)

        // Image bytes live beside the store as files keyed by `Capture.imageRef`;
        // deleting the row alone would orphan them in the container forever. Read BEFORE
        // the rows go, deleted only after the save lands (below) — a file unlinked ahead
        // of a save that then fails is data destroyed by a clear that didn't happen.
        let captures = (try? context.fetch(NSFetchRequest<Capture>(entityName: "Capture"))) ?? []
        let imageRefs = captures.compactMap(\.imageRef)

        for name in entityNames(for: scope, in: context) {
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            (try? context.fetch(request))?.forEach(context.delete)
        }

        // **The save's result IS the clear's result.** Discarded, a failure was invisible
        // twice over: the context kept the pending deletions, so every later save
        // (`SettingsView`'s `.onDisappear`, the next capture) re-attempted and re-failed
        // them — and the caller still got a receipt saying the data was gone, while the
        // store on disk was untouched and every task came back on relaunch. That is
        // exactly the "clearing does nothing" shape. Roll the deletions back so the app is
        // left consistent, and hand back a record that says nothing was destroyed.
        guard context.saveChanges() else {
            context.rollback()
            return StoreResetRecord(
                reason: .userRequested(clearedIdentity: scope == .everything), date: now,
                backupName: backupName, destroyedData: false)
        }

        // The three file sidecars, cleared only once the rows they describe are actually
        // gone. Each is keyed to something BOTH scopes delete — provenance and the
        // Advisor's cached judgments to `Capture`/`TaskItem` ids, the human's verdicts to
        // readings and drafts whose Core Data half (`Correction`, `SuppressionRecord`)
        // just went with them — so a scope that spared them would leave half a learning
        // corpus about work that no longer exists, and a "reset everything" that still
        // remembers what you told it. Passed in rather than reached for, like `metrics`:
        // they delete real files, and a test reaching `.shared` would unlink the
        // developer's own.
        for ref in imageRefs { CaptureImageStore.delete(ref) }
        provenance?.reset()
        readings?.reset()
        verdicts?.reset()

        for key in workKeys { defaults.removeObject(forKey: key) }

        if scope == .everything {
            for key in identityKeys { defaults.removeObject(forKey: key) }
            metrics?.reset(now: now)
            ModelMetrics.shared.reset()
            AdvisorMetrics.shared.reset()
            IntelligenceLedger.shared.reset(now: now)
            // Never leave the app without an identity: this is exactly what a first
            // launch creates, and `currentMemberID` is read from ownership to Today.
            _ = UserProfile.bootstrapIdentity(in: context)
            context.saveChanges()
        }

        // Written LAST, and after the `.everything` branch, so a factory reset can wipe
        // every other key without erasing the receipt for the wipe itself.
        let record = StoreResetRecord(
            reason: .userRequested(clearedIdentity: scope == .everything), date: now,
            backupName: backupName, destroyedData: true)
        StoreResetLog.write(record, to: defaults)
        return record
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
