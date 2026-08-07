//
//  OpenTaskSnapshotCacheTests.swift
//  Project-EzraTests
//
//  The change-invalidated open-set cache (capture audit A3). The contract under
//  test: repeated reads are free, any TaskItem change — helper-routed or a direct
//  binding write — rebuilds with the new reading, and writes to OTHER entities
//  (the park path's Capture row) leave the cache standing, because those fire
//  mid-capture by design. `processPendingChanges()` stands in for the runloop
//  turn that delivers the change notification in the app.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct OpenTaskSnapshotCacheTests {

    private let cache = OpenTaskSnapshotCache.shared

    private func makeContext() -> NSManagedObjectContext {
        let context = TestStore.makeContext()
        // The wipe above is itself a TaskItem change; settle it so each test
        // starts from a clean, invalidated slate.
        context.processPendingChanges()
        return context
    }

    @Test("Repeated reads serve the cached set without rebuilding")
    func repeatedReadsAreCached() {
        let context = makeContext()
        context.insert(TaskItem(title: "Renew passport", status: .todo))
        context.insert(TaskItem(title: "Call the vet", status: .doing))
        context.processPendingChanges()

        let first = cache.snapshots(in: context)
        let builds = cache.buildCount
        let second = cache.snapshots(in: context)

        #expect(first.count == 2)
        #expect(second == first)
        #expect(cache.buildCount == builds)
    }

    @Test("A direct title edit — no mutation helper — rebuilds with the new reading")
    func directEditInvalidates() {
        let context = makeContext()
        let task = TaskItem(title: "Book dentist", status: .todo)
        context.insert(task)
        context.processPendingChanges()
        _ = cache.snapshots(in: context)

        // The detail screen writes through @Bindable exactly like this, never
        // touching TaskMutations — the invalidation path must not depend on helpers.
        task.title = "Book the pediatric dentist"
        context.processPendingChanges()

        let titles = cache.snapshots(in: context).map(\.title)
        #expect(titles == ["Book the pediatric dentist"])
    }

    @Test("Resolution removes the task from the open set")
    func resolutionLeavesTheSet() {
        let context = makeContext()
        let done = TaskItem(title: "Water plants", status: .todo)
        let open = TaskItem(title: "Renew passport", status: .todo)
        context.insert(done)
        context.insert(open)
        context.processPendingChanges()
        #expect(cache.snapshots(in: context).count == 2)

        done.complete()
        context.processPendingChanges()

        #expect(cache.snapshots(in: context).map(\.title) == ["Renew passport"])
    }

    @Test("Writes to other entities leave the cache standing")
    func unrelatedWritesDoNotInvalidate() {
        let context = makeContext()
        context.insert(TaskItem(title: "Renew passport", status: .todo))
        context.processPendingChanges()
        _ = cache.snapshots(in: context)
        let builds = cache.buildCount

        // The park write — a Capture row saved after every completed parse. If this
        // invalidated, the cache would rebuild at exactly the cadence it exists to
        // absorb.
        let capture = Capture(rawText: "renew passport", source: .text, in: context)
        capture.parkedDrafts = []
        context.insert(capture)
        context.processPendingChanges()

        _ = cache.snapshots(in: context)
        #expect(cache.buildCount == builds)
    }

    @Test("A helper-routed blocker write reflects in the blocked flag")
    func blockerWriteInvalidates() {
        let context = makeContext()
        let blocked = TaskItem(title: "Book flights", status: .todo)
        let blocker = TaskItem(title: "Renew passport", status: .todo)
        context.insert(blocked)
        context.insert(blocker)
        context.processPendingChanges()
        #expect(cache.snapshots(in: context).allSatisfy { !$0.isBlocked })

        blocked.addTaskBlocker(blocker.uuid!, among: [blocked, blocker], origin: .human)
        context.processPendingChanges()

        let flags = Dictionary(
            uniqueKeysWithValues: cache.snapshots(in: context).map { ($0.title, $0.isBlocked) })
        #expect(flags["Book flights"] == true)
        #expect(flags["Renew passport"] == false)
    }
}
