//
//  UnblockUndoTests.swift
//  Project-EzraTests
//
//  The force-unblock's reversibility. `unblock()` drops EVERY `.blocks` edge — tracked
//  and external, human-authored and inferred alike — from behind a full-width primary
//  CTA, so it is the most destructive single tap in the detail sheet. It used to write
//  no `ChangeLogEntry` at all and could not be undone.
//
//  These pin the undo-completeness rule from `ChangeLogUndo`'s header: an arm restores
//  EVERY field its action wrote. `unblock` writes two — the edge list AND
//  `lastUnblockedAt` — and the second one is invisible, which is exactly why it needs a
//  test: `TaskRanking.recentUnblockBoost` reads it, so an arm that restored only the
//  edges would leave a task reading as blocked again while still being lifted up the
//  stack by an unblock the user had just taken back.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Force-unblock is reversible")
@MainActor
struct UnblockUndoTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func entries(in context: NSManagedObjectContext) throws -> [ChangeLogEntry] {
        try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    }

    /// A task waiting on a tracked blocker AND an external phrase — the mixed case, so
    /// the round trip has to carry both edge shapes.
    private func blockedTask(in context: NSManagedObjectContext) -> (TaskItem, TaskItem) {
        let blocker = TaskItem(title: "renew passport", status: .todo, in: context)
        let task = TaskItem(title: "book flights", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])
        task.addExternalBlocker("waiting on the landlord", among: [task, blocker])
        return (task, blocker)
    }

    @Test("unblockAndLog writes one reversible human entry")
    func writesEntry() throws {
        let context = context()
        let (task, _) = blockedTask(in: context)
        #expect(task.blockers.count == 2)

        task.unblockAndLog(in: context)
        try context.save()

        let logged = try entries(in: context).filter { $0.action == "unblocked" }
        #expect(logged.count == 1)
        let entry = try #require(logged.first)
        #expect(entry.initiatedBy == .human)
        #expect(entry.isReversible)
        // Reachable by the per-task timeline AND by `linkedTask` in the undo — the
        // failure mode the "planned" entry demonstrated is an entry that offers an Undo
        // its own missing link fields can never honour.
        #expect(entry.taskUUID == task.uuid)
        #expect(entry.isActivityVisible)
        #expect(task.blockers.isEmpty)
    }

    @Test("A no-op unblock logs nothing")
    func noOpLogsNothing() throws {
        let context = context()
        let task = TaskItem(title: "nothing in the way", status: .todo, in: context)

        task.unblockAndLog(in: context)
        try context.save()

        #expect(try entries(in: context).filter { $0.action == "unblocked" }.isEmpty)
    }

    @Test("Undo restores every edge — tracked and external, human and inferred")
    func undoRestoresEdges() throws {
        let context = context()
        let (task, blocker) = blockedTask(in: context)
        // An inferred edge alongside the two human ones: the force-unblock does not
        // discriminate by origin, so neither may the undo.
        let inferredBlocker = TaskItem(title: "confirm dates", status: .todo, in: context)
        task.addTaskBlocker(
            inferredBlocker.uuid!, among: [task, inferredBlocker],
            origin: .inferred(confidence: 0.7))
        let before = task.relationships.filter { $0.kind == .blocks }
        #expect(before.count == 3)

        task.unblockAndLog(in: context)
        try context.save()
        #expect(task.blockers.isEmpty)

        let entry = try #require(try entries(in: context).first { $0.action == "unblocked" })
        ChangeLogUndo.revert(entry, in: context)

        let after = task.relationships.filter { $0.kind == .blocks }
        #expect(after.count == 3)
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
        // Origins survive: a human edge must not come back marked inferred, or the graph
        // would quietly relabel authorship on every undo.
        #expect(after.filter { $0.origin.isHuman }.count == 2)
        #expect(after.filter { !$0.origin.isHuman }.count == 1)
        // The external wait keeps its phrase — the user's own words.
        #expect(after.contains { $0.targetID == nil && $0.note == "waiting on the landlord" })
        #expect(after.contains { $0.targetID == blocker.uuid })
    }

    @Test("Undo restores lastUnblockedAt, not just the edges")
    func undoRestoresTheStamp() throws {
        let context = context()
        let (task, _) = blockedTask(in: context)
        #expect(task.lastUnblockedAt == nil)

        task.unblockAndLog(in: context)
        try context.save()
        #expect(task.lastUnblockedAt != nil)  // the unblock stamped it

        let entry = try #require(try entries(in: context).first { $0.action == "unblocked" })
        ChangeLogUndo.revert(entry, in: context)

        // Undo-completeness. Left stamped, `TaskRanking.recentUnblockBoost` would keep
        // lifting a task that is blocked again.
        #expect(task.lastUnblockedAt == nil)
    }

    @Test("Undo restores a PRIOR stamp rather than blindly clearing it")
    func undoRestoresAnEarlierStamp() throws {
        let context = context()
        let (task, _) = blockedTask(in: context)
        let earlier = Date(timeIntervalSinceReferenceDate: 1_000)
        task.lastUnblockedAt = earlier

        task.unblockAndLog(in: context)
        try context.save()
        let entry = try #require(try entries(in: context).first { $0.action == "unblocked" })
        ChangeLogUndo.revert(entry, in: context)

        #expect(task.lastUnblockedAt == earlier)
    }

    @Test("Undo keeps a blocker added after the unblock")
    func undoDoesNotDestroyLaterWork() throws {
        let context = context()
        let (task, _) = blockedTask(in: context)
        task.unblockAndLog(in: context)
        try context.save()

        // The user unblocked, then discovered a new dependency. Undo restores what the
        // action removed; it does not roll the graph back to a moment in time.
        let fresh = TaskItem(title: "get visa", status: .todo, in: context)
        task.addTaskBlocker(fresh.uuid!, among: [task, fresh])

        let entry = try #require(try entries(in: context).first { $0.action == "unblocked" })
        ChangeLogUndo.revert(entry, in: context)

        #expect(task.blockers.count == 3)
        #expect(task.taskBlockerIDs.contains(fresh.uuid!))
    }

    @Test("A payload that can't decode reverts nothing rather than partially")
    func undecodablePayloadIsInert() throws {
        let context = context()
        let (task, _) = blockedTask(in: context)
        task.unblockAndLog(in: context)
        try context.save()

        let entry = try #require(try entries(in: context).first { $0.action == "unblocked" })
        entry.oldValue = "{ not json"
        ChangeLogUndo.revert(entry, in: context)

        // Still unblocked, and — critically — NOT routed to the default arm, which would
        // have reset the status of a task whose status the unblock never touched.
        #expect(task.blockers.isEmpty)
        #expect(task.status == .todo)
    }

    @Test("The unblock never disturbs the status or non-blocking edges")
    func unblockIsScoped() throws {
        let context = context()
        let parent = TaskItem(title: "trip", status: .todo, in: context)
        let (task, _) = blockedTask(in: context)
        task.relationships += [.parent(taskID: parent.uuid!)]
        task.setStatus(.doing, in: context)

        task.unblockAndLog(in: context)
        try context.save()

        #expect(task.status == .doing)
        #expect(task.parentTaskID == parent.uuid!)
    }
}
