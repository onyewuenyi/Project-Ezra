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
    /// The shared in-memory context, wiped clean so the calling test starts isolated.
    static func makeContext() -> NSManagedObjectContext {
        let context = PersistenceStack.scratch
        // Delete everything a prior test left behind — registered objects (unsaved inserts
        // from pure-engine fixtures) and any saved rows — so this test starts isolated.
        // `context.reset()` is deliberately avoided: it disrupts the shared context's
        // entity/class binding for the next object created in it.
        for object in context.registeredObjects { context.delete(object) }
        for entity in context.persistentStoreCoordinator?.managedObjectModel.entities ?? [] {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            (try? context.fetch(request))?.forEach(context.delete)
        }
        try? context.save()
        return context
    }
}
