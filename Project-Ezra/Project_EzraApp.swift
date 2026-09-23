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
    /// Bumped by a destructive clear; rebuilds the interface against the emptied store.
    @State private var generation = DataGeneration.shared
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
        // **The clean-break budget is SPENT (2026-09-12).** `HouseholdSync.isLive` flipped,
        // and with it the wipe-on-mismatch escape hatch closed: a deployed CloudKit
        // schema is additive-only, with no server-side reset, so a local wipe would only
        // re-download the same records with the same meaning. `schemaGeneration` is now
        // `frozenSchemaGeneration`, pinned by `SchemaFreezeTests`; every model change from
        // here is a NEW `.xcdatamodel` version (v4 was the first under the freeze — the
        // household edges on TaskItem/ChangeLogEntry, `Invitation.memberID`/`acceptedAt`,
        // `FamilyMember.uuid` optional for CloudKit), and a meaning change is expressed as
        // a new field beside the old one, never a re-reading of stored values.
        //
        // The mismatch path below stays for the ONE install that could still be behind
        // (a device on generation 9 updating), and it still wipes with a safety copy and a
        // `StoreResetRecord` that Settings surfaces until acknowledged.
        let schemaGeneration = Self.frozenSchemaGeneration
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
        // **Per STORE, because there are two of them (2026-09-20).** This handler runs
        // once for every store description, and the self-heal underneath it used to
        // destroy every store file in the container and then reload the whole container.
        // So a shared mirror that would not open — the one of the two that depends on
        // CloudKit's mood, another person's account and a schema deployed in a console —
        // took the private store with it, and the private store is every task the person
        // has ever captured. A repair for one store must not be a wipe of the other.
        //
        // The failure is also survivable in one direction only. Without the private store
        // there is no app; without the shared mirror there is an app that cannot accept
        // an invitation, which is a degrade the rest of the code already handles
        // (`sharedStore(in:)` returning nil means "nothing can be accepted"). So the
        // private store keeps its `fatalError` and the shared one keeps quiet.
        container.loadPersistentStores { description, error in
            guard let error else { return }
            let isPrivate = description.url == PersistenceStack.storeURL
            let record = PersistenceStack.destroyStore(
                reason: .loadFailure(error.localizedDescription),
                only: description.url?.lastPathComponent)
            if record.destroyedData { StoreResetLog.write(record) }
            // Re-add THIS description only. Reloading the container would run every
            // description again, including ones that opened perfectly well a moment ago.
            container.persistentStoreCoordinator.addPersistentStore(with: description) {
                _, retryError in
                guard let retryError else { return }
                if isPrivate {
                    fatalError("Could not load the store even after reset: \(retryError)")
                }
                // A shared mirror that will not open after a reset: the household half
                // is off for this launch, the person's own work is untouched, and
                // `SyncHealth` is where that shows up rather than in a crash.
                SyncHealth.shared.recordSetupFailure(retryError)
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        // Which store a new object lands in — private or the shared household — decided
        // once, at save, for every creation site at once.
        storeAffinityObserver = HouseholdStoreAffinity.install(on: container.viewContext)
        // Whether the second copy of the user's data is actually being made. Watches the
        // same event stream `HouseholdSharing` does, but keeps the FAILURES — which
        // nothing did until 2026-09-20, so a container that had never once exported a
        // record looked identical to one with nothing to send (`SyncHealth`).
        SyncHealth.shared.observe(container)
        // The invite flow's owner-side (make a link) and invitee-side (accept, link identity).
        HouseholdSharing.shared.configure(container: container, context: container.viewContext)
        return container
    }()

    /// The schema generation, FROZEN at 10 the day sync went live (see the container's
    /// header comment). Moving this number is a wipe of every device's local store under a
    /// CloudKit schema that cannot follow, so `SchemaFreezeTests` pins it while
    /// `HouseholdSync.isLive` is true.
    static let frozenSchemaGeneration = 10

    /// Keeps the store-affinity observer alive for the life of the process (see
    /// `HouseholdStoreAffinity`). Installed once, below, after the container loads.
    nonisolated(unsafe) private static var storeAffinityObserver: NSObjectProtocol?

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
            // The one thing that empties every `@FetchRequest` at once. A destructive
            // clear deletes in the STORE and tells the live context nothing (telling it
            // is what crashed the app — `DataGeneration` has the mechanism), so the
            // interface has to be rebuilt rather than refreshed. Bumped only by a clear
            // the user asked for; in every other second of the app's life this is a
            // constant and costs nothing.
            .id(generation.value)
            .environment(brain)
            .environment(\.managedObjectContext, container.viewContext)
            .preferredColorScheme(.dark)  // dark-first reads premium; matches the "quiet" thesis
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // A foreground the Sunday digest solicited is NOT a self-initiated
                    // open (the one notification, carve-out 2026-09-12); every other
                    // foreground is, by construction.
                    if !WeeklyDigestScheduler.shared.consumeNotificationOpen() {
                        brain.metrics.recordOpen()
                    }
                    // Hourly-debounced maintenance: the reversible stale auto-archive.
                    brain.runMaintenanceSweepsIfDue(in: container.viewContext)
                    // An accepted household whose records landed while the app was away.
                    HouseholdSharing.shared.retryPendingLink()
                    refreshDigest()
                default:
                    break
                }
            }
            // Clear any notification a PREVIOUS build scheduled (the retired daily
            // briefing nudge) — everything except the one request this build owns, so
            // the digest `refreshDigest` just scheduled is not swept with it.
            .task {
                let center = UNUserNotificationCenter.current()
                let pending = await center.pendingNotificationRequests().map(\.identifier)
                center.removePendingNotificationRequests(
                    withIdentifiers: pending.filter { $0 != WeeklyDigest.identifier })
                #if DEBUG
                initializeCloudKitSchemaIfRequested()
                #endif
            }
    }

    #if DEBUG
    /// `-InitializeCloudKitSchema` pushes the CURRENT model up as CloudKit record
    /// types, in the container's DEVELOPMENT environment.
    ///
    /// **The half of the schema gate that is not a button (2026-09-20).** Deploying
    /// to Production copies whatever Development holds — so if Development was last
    /// initialised before model v4 added the household edges, `Invitation.memberID`
    /// and `FamilyMember.uuid`, then pressing Deploy Schema Changes ships a schema
    /// that does not match the app, and every sync involving those fields fails in
    /// production with an error nobody can reproduce locally. Core Data creates
    /// record types lazily from whatever it happens to save, so "it worked on my
    /// phone" proves only that the fields you exercised exist.
    ///
    /// This makes the Development environment complete and current by construction,
    /// which is the precondition the console step assumes and never checks. Run it
    /// once after every new `.xcdatamodel` version, then deploy. It is idempotent,
    /// additive, and Apple's documented use is exactly this.
    ///
    /// DEBUG only and argument-gated twice over, because the API is explicitly not
    /// for a production environment — and a distribution build has no way to reach
    /// it anyway, which is the point.
    private func initializeCloudKitSchemaIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-InitializeCloudKitSchema"),
            let cloud = container as? NSPersistentCloudKitContainer
        else { return }
        do {
            try cloud.initializeCloudKitSchema(options: [])
            print("CLOUDKIT-SCHEMA ok — development environment now matches the model.")
            print("CLOUDKIT-SCHEMA next: CloudKit Console ▸ Schema ▸ Deploy Schema Changes ▸ Production.")
        } catch {
            print("CLOUDKIT-SCHEMA FAILED — \(error)")
            print("CLOUDKIT-SCHEMA a signed-in iCloud account on this device is required.")
        }
    }
    #endif

    /// Recompose the Sunday digest from the store as it stands now. Cheap (one fetch of
    /// the working set) and idempotent, so it runs on every foreground.
    private func refreshDigest() {
        let context = container.viewContext
        let caretakers =
            Household.existing(in: context).map(HouseholdActivation.caretakerIDs).map(\.count) ?? 1
        WeeklyDigestScheduler.shared.refresh(
            tasks: TaskItem.fetchAll(in: context), caretakerCount: caretakers)
    }
}
