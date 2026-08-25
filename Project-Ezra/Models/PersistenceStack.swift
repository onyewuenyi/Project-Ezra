//
//  PersistenceStack.swift
//  Project-Ezra
//
//  The Core Data foundation. SwiftData was retired in favor of
//  `NSPersistentCloudKitContainer` because SwiftData still has no cross-account
//  CloudKit sharing on iOS 27 (see docs/) — Core Data's CKShare zone sharing is the
//  supported path, and the migration is cheapest pre-release. The domain model and
//  the pure engines are unchanged: the model classes keep their names and computed
//  API, so `HouseholdEngine`/`AppBrain` and the Today pipeline barely notice the swap.
//
//  `PersistenceContext` is the app's alias for the write context — creation and
//  mutation funnel through `AppBrain`/`TaskMutations`, so the persistence type stays
//  out of the rest of the app. All containers share ONE `NSManagedObjectModel` instance
//  (so each `@objc` subclass is claimed once and instantiates as the real class); the
//  convenience inits resolve their entity from the target context, so objects always match
//  their context. Production only ever writes through the app's `viewContext`; the scratch
//  context is for test/preview fixtures alone, so contexts never cross.
//

import CoreData
import OSLog

typealias PersistenceContext = NSManagedObjectContext

extension NSManagedObjectContext {
    /// Save, and never fail in total silence.
    ///
    /// Every mutation seam in the app used to end in a discarded-error save. That reads as
    /// "saving can't meaningfully fail here", but the failure mode it hides is the worst
    /// one this store has: the user taps Done, the row redraws done, and the change is
    /// gone on the next launch. Now that the store holds real daily work, a dropped save
    /// has to leave a trace — so this logs (in every build, including the Release the
    /// device runs) and reports whether it landed.
    ///
    /// Deliberately does NOT roll back: pending changes are the user's work, and
    /// discarding them to "recover" would turn a maybe-transient failure into certain
    /// loss. They stay pending so the next save can carry them.
    @discardableResult
    func saveChanges(_ site: StaticString = #function) -> Bool {
        guard hasChanges else { return true }
        do {
            try save()
            return true
        } catch {
            PersistenceStack.log.error(
                "Core Data save failed at \(String(describing: site), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

enum PersistenceStack {

    /// One logger for the persistence layer — save failures, backups, resets.
    static let log = Logger(subsystem: "com.projectezra.app", category: "persistence")

    /// The CloudKit container id. Nil until the iCloud entitlement is added in Xcode
    /// signing (Phase 2c) — while nil the store is local (fully functional, sim-testable);
    /// set it (and the entitlement) to switch private-DB sync on with no other change.
    static let cloudKitContainerID: String? = nil

    /// The ONE managed object model, loaded once and shared by every container. A single
    /// `@objc` subclass must be claimed by exactly one `NSManagedObjectModel` instance —
    /// loading a separate model per container makes Core Data instantiate a generic
    /// `NSManagedObject` (→ "unrecognized selector" on the real accessors), so all
    /// containers below take this shared instance.
    static let model: NSManagedObjectModel = {
        guard let url = Bundle.main.url(forResource: "ProjectEzra", withExtension: "momd"),
            let model = NSManagedObjectModel(contentsOf: url)
        else { fatalError("Could not load the ProjectEzra Core Data model") }
        return model
    }()

    /// The ONE in-memory context for all ad-hoc / test / `#Preview` object construction.
    /// A single context on a single coordinator: creating a second coordinator on the shared
    /// model makes Core Data hand back generic `NSManagedObject`s (the first coordinator
    /// claims the class binding), so every fixture — pure-engine arrays *and* the integration
    /// tests' `TestStore` — funnels through this one. That makes it **not** thread-safe, so
    /// the test suite runs serially (see the scheme's disabled parallelization).
    /// `var`, not `let`, as a TEST SEAM: `TestStore.makeContext()` repoints this at each
    /// test's fresh container so fixtures built through the default `in:` parameter land
    /// in the same context the test fetches from. Nothing in the app writes it.
    ///
    /// NOTE (iOS 27 beta): never wipe/reset this context or delete its objects en
    /// masse. After a heap-length String attribute has been read, snapshot teardown
    /// of that object crashes (see TestStore.makeContext) — this context is safe
    /// precisely because fixtures only accumulate here and nothing tears them down.
    static var scratch: NSManagedObjectContext = {
        let container = NSPersistentContainer(name: "ProjectEzra", managedObjectModel: model)
        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [desc]
        container.loadPersistentStores { _, error in
            if let error { fatalError("Could not load the scratch store: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container.viewContext
    }()

    /// The app's persistent container. History tracking + remote-change notifications are
    /// on (required for CloudKit and the future CKShare layer). CloudKit sync activates the
    /// moment `cloudKitContainerID` is non-nil and the entitlement exists; until then this
    /// is a local store.
    static func makeContainer(inMemory: Bool = false) -> NSPersistentContainer {
        // Use the plain container until CloudKit is actually enabled — an
        // `NSPersistentCloudKitContainer` mutates the shared model for CloudKit-readiness,
        // which corrupts class binding for the in-memory test containers in the same
        // process. Switch to the CloudKit container the moment `cloudKitContainerID` is set.
        let container: NSPersistentContainer =
            cloudKitContainerID != nil
            ? NSPersistentCloudKitContainer(name: "ProjectEzra", managedObjectModel: model)
            : NSPersistentContainer(name: "ProjectEzra", managedObjectModel: model)
        guard let desc = container.persistentStoreDescriptions.first else {
            fatalError("Container created without a store description")
        }
        if inMemory { desc.url = URL(fileURLWithPath: "/dev/null") }
        desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        desc.setOption(
            true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        // Stated explicitly, not left to the default. These two are what let an ADDITIVE
        // model change (a new optional attribute, a new entity) migrate an existing store
        // instead of failing to open it — and a store that fails to open is destroyed by
        // the self-heal in `Project_EzraApp`. Turning either off silently converts every
        // future model edit into data loss, so they are pinned and commented rather than
        // inherited. Note that lightweight migration also needs the OLD model version to
        // still exist in `ProjectEzra.xcdatamodeld`: never edit the current version in
        // place, always add a new one (see the DEBUG tripwire in `Project_EzraApp`).
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        if let id = cloudKitContainerID {
            desc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: id)
        }
        return container
    }

    /// The store's file name, and the sidecars that must travel with it. A sqlite store
    /// copied WITHOUT its `-wal` is a store missing its most recent writes.
    static let storeFileName = "ProjectEzra.sqlite"
    private static let storeSuffixes = ["", "-wal", "-shm"]

    /// The on-disk store location, for the clean-break reset (delete + recreate on a schema
    /// generation bump — Core Data has no lightweight path for a meaning change here).
    static var storeURL: URL {
        NSPersistentContainer.defaultDirectoryURL().appendingPathComponent(storeFileName)
    }

    // MARK: - Safety copies

    /// Where a store and its safety copies live.
    ///
    /// **Injectable on purpose.** These functions delete files; pointed at the default
    /// location inside a test host they would unlink the sqlite Core Data currently has
    /// open ("BUG IN CLIENT OF libsqlite3: vnode unlinked while in use"), which is a
    /// plausible contributor to the suite's crash-on-exit flakiness. Tests pass a
    /// throwaway location instead.
    struct StoreLocation {
        let storeURL: URL

        /// Sits beside the store, inside the app container: a device backup carries it,
        /// and Xcode ▸ Devices ▸ Download Container pulls it off the phone — which IS
        /// the restore path (there is deliberately no in-app restore; it would need the
        /// store closed and the app relaunched).
        var backupsDirectory: URL {
            storeURL.deletingLastPathComponent()
                .appendingPathComponent("Backups", isDirectory: true)
        }

        var fileName: String { storeURL.lastPathComponent }

        static var `default`: StoreLocation { StoreLocation(storeURL: PersistenceStack.storeURL) }

        /// A throwaway location under the temporary directory, for tests.
        static func temporary(_ name: String) -> StoreLocation {
            StoreLocation(
                storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(PersistenceStack.storeFileName))
        }
    }

    /// The app's safety-copy directory (the default location's).
    static var backupsDirectory: URL { StoreLocation.default.backupsDirectory }

    /// How many safety copies to keep. Bounded so the container can't grow forever.
    static let maxBackups = 5

    /// Copy the store and its sidecars into a timestamped folder, returning the folder's
    /// NAME (never an absolute path — the app container's path changes between installs,
    /// so a stored absolute URL goes stale; resolve against `backupsDirectory` instead).
    ///
    /// This is a cold copy, which is correct at both call sites: on the schema-generation
    /// path the store has not been opened yet, and on the self-heal path it failed to open.
    /// Returns nil when there was nothing to copy or the copy failed — a backup must never
    /// be able to block the reset that keeps the app launchable.
    static func backupStore(now: Date = Date(), at location: StoreLocation = .default) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.storeURL.path) else { return nil }

        let name = backupFolderName(for: now)
        let folder = location.backupsDirectory.appendingPathComponent(name, isDirectory: true)
        let dir = location.storeURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in storeSuffixes {
                let source = dir.appendingPathComponent(location.fileName + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(
                    at: source, to: folder.appendingPathComponent(location.fileName + suffix))
            }
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
        pruneBackups(at: location)
        return name
    }

    /// Existing safety copies, newest first. The name format sorts lexicographically in
    /// timestamp order, so no file-attribute round trip is needed.
    static func backups(at location: StoreLocation = .default) -> [String] {
        let names =
            (try? FileManager.default.contentsOfDirectory(
                atPath: location.backupsDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(backupPrefix) }.sorted(by: >)
    }

    /// Resolve a backup folder name to a URL, if it still exists.
    static func backupURL(named name: String, at location: StoreLocation = .default) -> URL? {
        let url = location.backupsDirectory.appendingPathComponent(name, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A backup as ONE shareable file, because a backup is a folder (sqlite + `-wal` +
    /// `-shm`) and `ShareLink` on a directory does not reliably produce anything usable
    /// — which would be worse than offering nothing, since the whole point here is not
    /// giving false confidence about recoverable data.
    ///
    /// `NSFileCoordinator`'s `.forUploading` is the supported way to zip a directory
    /// without a third-party archiver; its coordinated URL is torn down when the block
    /// exits, so the archive is copied out first.
    static func zippedBackup(named name: String) -> URL? {
        guard let folder = backupURL(named: name) else { return nil }
        var coordinationError: NSError?
        var archive: URL?
        NSFileCoordinator().coordinate(
            readingItemAt: folder, options: [.forUploading], error: &coordinationError
        ) { zipped in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(name + ".zip")
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: zipped, to: destination)) != nil {
                archive = destination
            }
        }
        return coordinationError == nil ? archive : nil
    }

    private static let backupPrefix = "store-"

    private static func backupFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return backupPrefix + formatter.string(from: date)
    }

    private static func pruneBackups(at location: StoreLocation) {
        for stale in backups(at: location).dropFirst(maxBackups) {
            try? FileManager.default.removeItem(
                at: location.backupsDirectory.appendingPathComponent(stale, isDirectory: true))
        }
    }

    // MARK: - Destructive reset

    /// Delete the local store and its sidecars — the deterministic reset backing the
    /// `schemaGeneration` bump and the load-failure self-heal. **Always takes a safety copy
    /// first**, and returns the record describing what happened so the caller can surface
    /// it. The reason is required, not defaulted: a wipe with no explanation is exactly the
    /// failure this exists to prevent.
    @discardableResult
    static func destroyStore(
        reason: StoreResetReason, now: Date = Date(), at location: StoreLocation = .default
    ) -> StoreResetRecord {
        // Whether anything was actually destroyed, captured BEFORE the backup: a nil
        // `backupName` is ambiguous on its own (no store to copy, or a copy that failed),
        // and those two want opposite handling. A first launch must stay silent; a wipe
        // whose backup failed is precisely when the user most needs telling.
        let storeExisted = FileManager.default.fileExists(atPath: location.storeURL.path)
        let backupName = backupStore(now: now, at: location)
        let dir = location.storeURL.deletingLastPathComponent()
        for suffix in storeSuffixes {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(location.fileName + suffix))
        }
        return StoreResetRecord(
            reason: reason, date: now, backupName: backupName, destroyedData: storeExisted)
    }

    // MARK: - Model-change tripwire

    /// A digest of the model's shape, stable across launches (unlike `hashValue`, which is
    /// per-process seeded). Compared at launch to catch the one mistake that silently eats
    /// real data: editing the CURRENT `.xcdatamodel` version in place, which leaves Core
    /// Data no source model to migrate from.
    static var modelDigest: String { digest(of: model) }

    /// Every model version compiled into the app, digested. This is what lets the
    /// tripwire tell the two kinds of model change apart, which a single digest
    /// cannot: **adding a NEW version** leaves the previous version's digest in this
    /// set (its `.mom` still ships, so lightweight migration has its source model —
    /// safe, silent), while **editing the current version in place** removes it (the
    /// shape the on-disk store was built against no longer exists as authored — the
    /// disaster the tripwire exists for). Before this, the correct act and the
    /// mistake produced the same assertion, and the documented remedy was clearing
    /// `appModelDigest` from UserDefaults by hand — a tripwire that cries wolf on
    /// the safe path teaches exactly the reflex that later eats the store.
    static var bundledModelVersionDigests: Set<String> {
        var digests: Set<String> = [modelDigest]
        let urls =
            Bundle.main.urls(forResourcesWithExtension: "mom", subdirectory: "ProjectEzra.momd")
            ?? []
        for url in urls {
            if let version = NSManagedObjectModel(contentsOf: url) {
                digests.insert(digest(of: version))
            }
        }
        return digests
    }

    private static func digest(of model: NSManagedObjectModel) -> String {
        model.entityVersionHashesByName
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.base64EncodedString())" }
            .joined(separator: "|")
    }
}
