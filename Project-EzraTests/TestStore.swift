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
    ///
    /// The wipe DISCARDS the previous test's leftovers wholesale — `reset()` drops every
    /// registered object without touching it, and swapping the in-memory store drops all
    /// saved rows without faulting one. The old object-by-object wipe (delete every
    /// registered object, then fetch-and-delete every entity, then save) forced Core Data
    /// to fault and snapshot each leftover — and on the iOS 27 beta simulator that
    /// detonated on rows whose object-typed slots held garbage (EXC_BAD_ACCESS in
    /// `objc_retain` under `deleteObject:`/`save:`; ~70 identical crash reports since
    /// Aug 7, previously mis-filed as the "environmental sim flake"). Discarding instead
    /// of deleting never reads the poisoned slots, and gives a genuinely fresh store.
    ///
    /// The context and coordinator are deliberately KEPT — only the store is replaced.
    /// The one-context/one-coordinator rule (class/entity binding is claimed by the first
    /// coordinator on the shared model) is untouched by a store swap.
    static func makeContext() -> NSManagedObjectContext {
        let context = PersistenceStack.scratch
        context.reset()
        if let coordinator = context.persistentStoreCoordinator {
            for store in coordinator.persistentStores {
                let url = store.url
                try? coordinator.remove(store)
                if let url {
                    try? coordinator.destroyPersistentStore(
                        at: url, ofType: NSSQLiteStoreType, options: nil)
                    _ = try? coordinator.addPersistentStore(
                        ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
                }
            }
        }
        return context
    }
}
