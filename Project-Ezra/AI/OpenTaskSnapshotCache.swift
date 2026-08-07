//
//  OpenTaskSnapshotCache.swift
//  Project-Ezra
//
//  The open working set as value snapshots, rebuilt on CHANGE instead of on read
//  (the capture audit's A3). Every parse used to rebuild `[OpenTaskSnapshot]` from
//  the live store — an O(N) pass with a relationships-blob decode per task —
//  producing an identical result unless a task actually changed between reads. The
//  rolling parse cadence multiplied the read rate (a chained parse per ~1.2s of
//  continuous input), so rebuild-per-read became a recurring tax on the thread the
//  keyboard shares.
//
//  Invalidation listens to the context's objects-did-change notification, filtered
//  to `TaskItem`. That choice over per-callsite hooks in the mutation helpers is
//  deliberate: the detail screen edits tasks through direct `@Bindable` bindings
//  that never route through `TaskMutations`, and a cache those edits can't
//  invalidate would serve stale titles to the next capture. The notification sees
//  every attribute write, helper or not. Saves of OTHER entities (the park write's
//  `Capture` row, `EmbeddingCache` inserts — both fired mid-capture by design)
//  don't invalidate.
//

import CoreData
import Foundation

@MainActor
final class OpenTaskSnapshotCache {

    static let shared = OpenTaskSnapshotCache()

    /// Per-context cache state. Contexts are weak keys — a scratch or test context
    /// that goes away takes its entry with it.
    private final class Entry {
        var snapshots: [OpenTaskSnapshot]?
        var observer: (any NSObjectProtocol)?
    }

    private let entries = NSMapTable<NSManagedObjectContext, Entry>.weakToStrongObjects()

    /// How many times a snapshot set was actually built — the cache's test seam.
    private(set) var buildCount = 0

    /// The open working set for `context`, cached until a `TaskItem` changes.
    func snapshots(in context: NSManagedObjectContext) -> [OpenTaskSnapshot] {
        let entry = self.entry(for: context)
        if let cached = entry.snapshots { return cached }
        let built = Self.build(in: context)
        entry.snapshots = built
        buildCount += 1
        return built
    }

    /// Drop the cached set for `context` — the observer's job, callable directly
    /// where a caller knows better (tests, an explicit store reset).
    func invalidate(in context: NSManagedObjectContext) {
        entries.object(forKey: context)?.snapshots = nil
    }

    private func entry(for context: NSManagedObjectContext) -> Entry {
        if let existing = entries.object(forKey: context) { return existing }
        let entry = Entry()
        entry.observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange, object: context, queue: .main
        ) { [weak self] note in
            guard Self.touchesTaskItems(note) else { return }
            // Delivered on `.main` and the cache is main-actor isolated.
            MainActor.assumeIsolated {
                guard let context = note.object as? NSManagedObjectContext else { return }
                self?.invalidate(in: context)
            }
        }
        entries.setObject(entry, forKey: context)
        return entry
    }

    /// Did this change notification involve any `TaskItem` — inserted, deleted,
    /// updated, or refreshed? Anything else (a park's `Capture` row, an
    /// `EmbeddingCache` insert) leaves the cache standing.
    private nonisolated static func touchesTaskItems(_ note: Notification) -> Bool {
        let keys = [
            NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey,
        ]
        for key in keys {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            if objects.contains(where: { $0 is TaskItem }) { return true }
        }
        return false
    }

    /// One snapshot per open task. The unresolved-id `Set` is hoisted (the old
    /// per-task rebuild was the O(N²) the audit's F3 flagged) and each task's
    /// relationships blob decodes exactly once.
    private static func build(in context: NSManagedObjectContext) -> [OpenTaskSnapshot] {
        let request = NSFetchRequest<TaskItem>(entityName: "TaskItem")
        let all = (try? context.fetch(request)) ?? []
        let open = all.filter { !$0.status.isResolved }
        let openIDs = Set(open.compactMap(\.uuid))
        let titlesByID = Dictionary(
            uniqueKeysWithValues: open.compactMap { task in task.uuid.map { ($0, task.title) } })
        return open.compactMap { task in
            guard let id = task.uuid else { return nil }
            let rels = task.relationships
            let active = TaskItem.activeBlockers(from: rels, openIDs: openIDs)
            return OpenTaskSnapshot(
                id: id,
                title: task.title,
                externalBlockerNotes: active.filter { $0.kind == .external }.compactMap(\.note),
                category: task.category,
                updatedAt: task.updatedAt,
                dueDate: task.dueDate,
                isBlocked: !active.isEmpty,
                parentTitle: TaskItem.parentTaskID(from: rels).flatMap { titlesByID[$0] }
            )
        }
    }
}
