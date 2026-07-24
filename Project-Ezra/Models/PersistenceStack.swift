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

typealias PersistenceContext = NSManagedObjectContext

enum PersistenceStack {

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
    static let scratch: NSManagedObjectContext = {
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
        if let id = cloudKitContainerID {
            desc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: id)
        }
        return container
    }

    /// The on-disk store location, for the clean-break reset (delete + recreate on a schema
    /// generation bump — Core Data has no lightweight path for a meaning change here).
    static var storeURL: URL {
        NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("ProjectEzra.sqlite")
    }

    /// Delete the local store and its sidecars — the deterministic reset backing the
    /// `schemaGeneration` bump.
    static func destroyStore() {
        let dir = storeURL.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("ProjectEzra.sqlite" + suffix))
        }
    }
}
