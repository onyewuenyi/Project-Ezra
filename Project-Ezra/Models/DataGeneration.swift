//
//  DataGeneration.swift
//  Project-Ezra
//
//  How the app notices that the store was emptied underneath it.
//
//  **Why a counter and not a Core Data notification (2026-09-19).** "Clear all tasks"
//  deletes every row with an `NSBatchDeleteRequest`, which is the only deletion this
//  runtime survives: a batch delete happens inside the persistent store and never
//  materialises, snapshots or tears down a single in-memory object. Every mechanism that
//  WOULD tell the live context about it — merging the deleted ids, `reset()`,
//  `refreshAllObjects()` — walks the objects the screen is holding and takes a property
//  snapshot of each, and that snapshot is the crash: `_establishEventSnapshotsForObject`
//  → `objc_retain` → EXC_BAD_ACCESS, the same teardown-after-read fault the test host has
//  worked around since 2026-08-07 (see `TestStore`).
//
//  So the deletion is silent by necessity, and a silent deletion leaves every
//  `@FetchRequest` on screen showing rows that no longer exist. Measured: the store was
//  empty and the list still listed ten tasks. That is the shape the user reports as
//  "clearing does nothing", and tapping one of those rows would fault a deleted row.
//
//  The counter closes that gap without touching a single object. Bumping it changes the
//  root view's `id`, SwiftUI discards the whole tree, and every `@FetchRequest` in the new
//  one runs a fresh fetch against the emptied store. Nothing is refreshed, invalidated or
//  deleted in memory — the old objects are simply never referenced again.
//
//  Never torn down, though, is a promise the app has to keep: see `DataReset.park`.
//

import CoreData
import Observation

/// One number, bumped when the store's contents were replaced wholesale rather than
/// changed row by row. The root view keys its identity on it.
@Observable final class DataGeneration {

    @MainActor static let shared = DataGeneration()

    /// Starts at zero; only a destructive clear moves it.
    private(set) var value = 0

    /// Rebuild the interface against the store as it now stands.
    ///
    /// Call this AFTER the clear has saved and after the user has seen its receipt —
    /// the rebuild dismisses whatever is on screen, so doing it mid-flow would take the
    /// "your data was cleared, here is the backup" card away with it.
    func rebuild() {
        value += 1
    }
}
