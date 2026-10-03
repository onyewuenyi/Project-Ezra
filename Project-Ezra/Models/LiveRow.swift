//
//  LiveRow.swift
//  Project-Ezra
//
//  One question every view asks of a fetched row before it derives anything from it:
//  is this object still real?
//
//  **Why this exists (2026-09-18).** "Clear all tasks" crashed the app, every time, with
//  SIGSEGV. The mechanism was not the deletion — it was the RENDER that follows it. A
//  destructive clear deletes `TaskItem`, `ChangeLogEntry` and `Correction` while the
//  screen performing it holds a live `@FetchRequest` for each, and SwiftUI re-runs the
//  body before those fetches have caught up. Every derivation in that pass — a metrics
//  line, an activation count, a row's identity — then read an object Core Data had
//  already torn down, and reading a torn-down object is a jump through freed memory
//  (`_establishEventSnapshotsForObject` in the report), not a nil.
//
//  A deleted object is not data any more. It leaves the derivation, which is also
//  exactly what the clear means — so the guard is not defensive noise, it is the
//  honest reading of the store at that instant.
//
//  Two conditions, because a row can stop being real in two different ways: `isDeleted`
//  covers a delete pending in this context, and a nil `managedObjectContext` covers one
//  already saved, merged or turned back into a fault by a batch delete.
//

import CoreData

extension NSManagedObject {
    /// Whether this row is still backed by something real, and therefore safe to read.
    ///
    /// Use it wherever a view derives from a `FetchedResults` collection that a
    /// destructive path can empty underneath it. It is cheap — two property reads, no
    /// fault fired — so a per-render `filter` over a personal store costs nothing
    /// measurable.
    var isLiveRow: Bool {
        !isDeleted && managedObjectContext != nil
    }
}
