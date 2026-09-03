//
//  Project_EzraApp.swift
//  Project-Ezra
//
//  Managing Chaos, Effortlessly — an AI-managed personal task system.
//

import CoreData
import SwiftUI
import UserNotifications

@main
struct Project_EzraApp: App {
    /// Configures Firebase at launch — see `AppDelegate` for why the cloud rung's
    /// availability is a consequence of this line having run.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// One AppBrain for the whole app: owns engine selection + processing state.
    @State private var brain = AppBrain()
    /// The single daily nudge. Constructed at launch because it must be the
    /// notification-centre delegate before any tap can arrive.
    @Environment(\.scenePhase) private var scenePhase

    let container: NSPersistentContainer = {
        // Bump whenever a model change alters the *meaning* of stored data (renamed
        // enum raw values, repurposed fields), not just its shape. Core Data has no
        // lightweight path for a meaning change here, so this deterministic reset is the
        // clean-break policy. Generation 2 = the status/priority/flags redirect;
        // Generation 3 = the multi-user ownership inversion (`ownerID == nil` flips from
        // "you" to "shared"); Generation 4 = the SwiftData → Core Data + CloudKit swap;
        // Generation 5 = the attention-surface → Today-sequence redirect (adds the
        // `CapacityLog` entity; retro/attention data retired). Generation 6 = the Linear
        // redesign (adds TaskItem `stageRaw`/`creatorID` + ChangeLogEntry `actorID` — the
        // stage sub-state, task authorship, and human-actor attribution for Activity
        // feed). Generation 7 = the attention-substrate redirect: retires user-facing
        // Priority (drops TaskItem `priorityRaw`/`parentTaskID`/`blockersData`) for the
        // `isUrgent`/`isPinned` signals + a persisted `attentionData` score and a
        // `relationshipsData` graph blob (absorbing blockers + parent edges), plus a
        // `workIntentRaw` classification. Generation 8 = retires the Pinned signal
        // (drops TaskItem `isPinned`), leaving `isUrgent` as the only user Signal — a
        // manual float-to-top override competed with the computed attention score.
        // Generation 9 = the relevance + suppression substrate: TaskItem gains the
        // deferral/engagement facts (`deferralCount`/`carriedOverCount`/`lastSurfacedAt`/
        // `lastUnblockedAt`/`lastHumanTouchAt`), `relationshipsData` moves to v2
        // (`Origin` replaces provenance+confidence; dismissed tombstones leave the
        // type for the pair-owned suppression store), and two entities land —
        // `SuppressionRecord` and `EmbeddingCache`.
        // Generation 10 = the four-axis model (`docs/task-model.md`). The lifecycle
        // collapses from two stored fields into one: TaskItem drops `stageRaw`, and
        // `statusRaw`'s vocabulary changes meaning — `.inbox` is GONE (a ghost state
        // nothing ever rested in, now replaced by a parked `Capture`), `active` splits
        // into `todo`/`doing`, and `killed` is renamed `canceled`. `ownerPending` is
        // retired ("unowned" now has exactly one spelling, `ownerID == nil`) in favour
        // of `ownerOriginRaw`, which records whether a HUMAN established the ownership
        // — the affinity denominator depends on that distinction. `workIntentRaw` loses
        // `waiting` (it duplicated the derived blocked flag). `Capture` gains
        // `draftsData` + `committedAt` so an abandoned capture parks instead of
        // evaporating.
        //
        // **This spends most of the remaining clean-break budget.** The wipe-on-mismatch
        // escape hatch closes the day `HouseholdSync.isLive` flips: a deployed CloudKit
        // schema is additive-only, with no server-side reset. Treat everything after
        // this as additive-in-practice, and run a schema-freeze review gated to that
        // flip rather than declaring a final generation now — real usage of this model
        // is exactly what is most likely to reveal a shape mistake.
        //
        // Wipes existing stores — accepted under the clean-break policy, but NO LONGER
        // silently: every reset takes a safety copy first (`PersistenceStack.backupStore`)
        // and leaves a `StoreResetRecord` that Settings surfaces until acknowledged. The
        // store now holds real captured work, so an invisible wipe is indistinguishable
        // from the app losing it.
        let schemaGeneration = 10
        let generationKey = "appSchemaGeneration"
        let storedGeneration = UserDefaults.standard.integer(forKey: generationKey)
        if storedGeneration != schemaGeneration {
            // A first launch has no store and nothing to explain — only report a reset
            // that actually destroyed something.
            let record = PersistenceStack.destroyStore(
                reason: .schemaGeneration(from: storedGeneration, to: schemaGeneration))
            if record.destroyedData { StoreResetLog.write(record) }
            UserDefaults.standard.set(schemaGeneration, forKey: generationKey)
        }

        // Tripwire for the failure mode that eats data without any generation bump:
        // editing the CURRENT `.xcdatamodel` version in place. Lightweight migration needs
        // the OLD version to still exist in the `.xcdatamodeld`; without it the store
        // simply fails to open and the self-heal below destroys it. Always add a NEW model
        // version (Xcode ▸ Editor ▸ Add Model Version, or hand-author the directory).
        //
        // The wire distinguishes the safe act from the mistake by membership, not by
        // change: a digest that moved because a NEW version was added leaves the old
        // digest in `bundledModelVersionDigests` (its .mom still ships — migration has
        // its source), so it passes silently. A digest that moved because the current
        // version was edited in place is in NO shipped version, and that is the assert.
        // The first shape of this check compared only the current digest, so doing the
        // RIGHT thing trapped every DEBUG launch until `appModelDigest` was cleared by
        // hand — training exactly the dismiss-the-alarm reflex that later eats a store.
        let digestKey = "appModelDigest"
        let digest = PersistenceStack.modelDigest
        let knownDigest = UserDefaults.standard.string(forKey: digestKey)
        if let knownDigest, knownDigest != digest, storedGeneration == schemaGeneration,
            !PersistenceStack.bundledModelVersionDigests.contains(knownDigest)
        {
            assertionFailure(
                """
                The Core Data model changed and the version this store was built against \
                no longer exists in the bundle. If you edited the current .xcdatamodel \
                version IN PLACE, the store can no longer be migrated and is about to be \
                destroyed. Restore the old version and add a NEW one instead.
                """)
        }
        UserDefaults.standard.set(digest, forKey: digestKey)

        let container = PersistenceStack.makeContainer()
        container.loadPersistentStores { _, error in
            if let error {
                // Container-open failure on an incompatible shape change: self-heal by
                // resetting the store and retrying once. Backed by a safety copy and
                // reported — this is the path that used to lose data in total silence.
                let record = PersistenceStack.destroyStore(
                    reason: .loadFailure(error.localizedDescription))
                if record.destroyedData { StoreResetLog.write(record) }
                container.loadPersistentStores { _, retryError in
                    if let retryError {
                        fatalError("Could not load the store even after reset: \(retryError)")
                    }
                }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return container
    }()

    /// True when this process is the unit-test host. The host keeps its container (tests
    /// never touch it) but boots an empty scene: the live app UI doing its normal work
    /// during a suite — Today generation writing `today.planCache`, maintenance sweeps,
    /// `ModelMetrics`/`MetricsRecorder` counters — all lands in the same standard
    /// `UserDefaults` and singletons the tests read, and a second Core Data stack
    /// actively working the shared model alongside `PersistenceStack.scratch` is the
    /// multi-coordinator pattern this codebase avoids everywhere else. (Ruled out as the
    /// cause of the suite's makeContext EXC_BAD_ACCESS — that reproduced with this guard
    /// active — but the interference is real regardless.)
    ///
    /// `AppDelegate` reads this too, to skip `FirebaseApp.configure()` under a suite —
    /// which is what keeps the cloud rung dormant in tests. Not private for that reason.
    static let isHostingUnitTests = NSClassFromString("XCTestCase") != nil

    var body: some Scene {
        WindowGroup {
            if Self.isHostingUnitTests {
                Color.clear
            } else {
                appContent
            }
        }
    }

    private var appContent: some View {
        ContentView()
            .environment(brain)
            .environment(\.managedObjectContext, container.viewContext)
            .preferredColorScheme(.dark)  // dark-first reads premium; matches the "quiet" thesis
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // Every foreground is a self-initiated open by construction: the app
                    // sends no notifications (the one carve-out closed with the Brief,
                    // 2026-09-02), so there is nothing that could have solicited it.
                    brain.metrics.recordOpen()
                    // Hourly-debounced maintenance: the reversible stale auto-archive.
                    brain.runMaintenanceSweepsIfDue(in: container.viewContext)
                default:
                    break
                }
            }
            // Clear any notification a PREVIOUS build scheduled. The daily briefing nudge
            // retired with the Brief; without this the requests survive the update and
            // keep firing at a surface that no longer exists. Idempotent, so it just runs.
            .task {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            }
    }
}
