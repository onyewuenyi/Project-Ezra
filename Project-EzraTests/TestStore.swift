//
//  TestStore.swift
//  Project-EzraTests
//
//  A clean in-memory Core Data context for the commit/sweep integration tests — the
//  replacement for the old in-memory SwiftData `ModelContainer`. It hands back the ONE
//  shared scratch context (a second coordinator triggers cross-context / generic-object
//  errors, so every fixture — pure-engine arrays and these integration tests alike — must
//  funnel through the single scratch context). Each call wipes it clean so the test starts
//  isolated. Relies on serial execution (pass `-parallel-testing-enabled NO`; see CLAUDE.md).
//

import CoreData

@testable import Project_Ezra

enum TestStore {
    /// Retired per-test containers, kept alive for the life of the test process ON
    /// PURPOSE. The iOS 27 beta simulator has a Core Data bug (bisected in
    /// `CorruptionBisectTests`' history): after a heap-length String attribute is read
    /// off a managed object, any later snapshot teardown of that object — `reset()`,
    /// `deleteObject:`, fault clearing, context dealloc — retains/releases a non-pointer
    /// value and dies with EXC_BAD_ACCESS (~70 crash reports since 2026-08-07, previously
    /// mis-filed as an environmental sim flake). The only reliable defense is to never
    /// touch a read object again: each test gets a FRESH container, and the previous
    /// one is parked here so deallocation can't fault its objects.
    private static var retired: [NSPersistentContainer] = []
    private static var current: NSPersistentContainer?

    /// A fresh, empty context for the calling test.
    ///
    /// One container per test on the ONE shared `PersistenceStack.model` (a model may
    /// serve many coordinators; what must never happen is a second `NSManagedObjectModel`
    /// instance claiming the same `@objc` classes). SQLite in the temp directory rather
    /// than in-memory so `NSBatchDeleteRequest` works in tests exactly as it does against
    /// the app's store; the files are tiny, PID+counter-scoped, and left to the OS's
    /// temp cleanup.
    static func makeContext() -> NSManagedObjectContext {
        if let current { retired.append(current) }
        let container = NSPersistentContainer(
            name: "ProjectEzra", managedObjectModel: PersistenceStack.model)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ezra-test-\(ProcessInfo.processInfo.processIdentifier)-\(retired.count).sqlite")
        try? FileManager.default.removeItem(at: url)
        let desc = NSPersistentStoreDescription(url: url)
        desc.type = NSSQLiteStoreType
        container.persistentStoreDescriptions = [desc]
        container.loadPersistentStores { _, error in
            if let error { fatalError("Could not load a test store: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        // Half two of the defense: objects must live exactly as long as their (parked)
        // container. Without this, a test's objects deallocate when its locals go out of
        // scope, unregistering from the coordinator — whose row cache then releases the
        // poisoned row values on its own queue (crash observed on T6 in
        // `_NSQLRow_dealloc_standard` ← `decrementRefCountForObjectID`).
        container.viewContext.retainsRegisteredObjects = true
        current = container
        // Repoint the default-fixture seam: `TaskItem(title:)` and friends default their
        // `in:` parameter to `PersistenceStack.scratch`, and a fixture built there must
        // land in THIS test's container or `context.insert(task)` crosses contexts.
        PersistenceStack.scratch = container.viewContext
        return container.viewContext
    }
}
