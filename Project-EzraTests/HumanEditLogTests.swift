//
//  HumanEditLogTests.swift
//  Project-EzraTests
//
//  The manual-field-edit trail behind the task detail's Activity timeline: `logHumanEdit`
//  records a HUMAN "edited" entry per field change (with the no-op guard + burst
//  coalescing), `ChangeLogUndo` restores the prior value, and these entries are kept OUT
//  of the global Inbox (feed + unread badge) via the shared `isInboxVisible` seam while
//  still reachable by `taskUUID` for the per-task timeline.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Human field edits")
@MainActor
struct HumanEditLogTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func editedEntries(
        for task: TaskItem, in context: NSManagedObjectContext
    ) throws
        -> [ChangeLogEntry]
    {
        try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == ChangeLogEntry.editedAction && $0.taskUUID == task.uuid }
    }

    // MARK: - One entry per field, stamped as a human edit

    @Test("A status move logs one reversible human .edited. entry with old/new + actor")
    func statusMoveLogsEditedEntry() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        task.setStatus(.doing, in: context)

        let entries = try editedEntries(for: task, in: context)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.initiatedBy == .human)
        #expect(entry.fieldChanged == "status")
        #expect(entry.oldValue == "todo")
        #expect(entry.newValue == "doing")
        #expect(entry.actorID != nil)
        #expect(entry.isReversible)
    }

    @Test("Editing urgent / due / title / notes / category / effort each logs one edit")
    func scalarEditsEachLogOnce() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)

        task.isUrgent = true
        task.logHumanEdit(
            field: "urgent", oldValue: "false", newValue: "true", summary: "Marked urgent",
            in: context)
        task.title = "y"
        task.logHumanEdit(
            field: "title", oldValue: "x", newValue: "y", summary: "Renamed task", in: context)

        let entries = try editedEntries(for: task, in: context)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.initiatedBy == .human && $0.actorID != nil })
        #expect(Set(entries.map(\.fieldChanged)) == ["urgent", "title"])
    }

    // MARK: - No-op guard

    @Test("Re-picking the current value logs nothing")
    func noOpGuardInsertsNothing() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)

        task.logHumanEdit(
            field: "priority", oldValue: "high", newValue: "high", summary: "no-op", in: context)

        #expect(try editedEntries(for: task, in: context).isEmpty)
    }

    // MARK: - Coalescing

    @Test("Two same-field edits in the window fold into one; oldValue is the pre-burst value")
    func coalesceWithinWindow() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

        task.logHumanEdit(
            field: "priority", oldValue: "low", newValue: "high", summary: "Set priority to High",
            now: t0, in: context)
        try context.save()
        task.logHumanEdit(
            field: "priority", oldValue: "high", newValue: "urgent", summary: "Set priority to Urgent",
            now: t0.addingTimeInterval(30), in: context)
        try context.save()

        let entries = try editedEntries(for: task, in: context)
        #expect(entries.count == 1)
        #expect(entries.first?.oldValue == "low")  // pre-burst preserved for a true undo
        #expect(entries.first?.newValue == "urgent")
    }

    @Test("An edit past the window opens a new entry")
    func outsideWindowInsertsNew() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

        task.logHumanEdit(
            field: "priority", oldValue: "low", newValue: "high", summary: "High", now: t0, in: context)
        try context.save()
        task.logHumanEdit(
            field: "priority", oldValue: "high", newValue: "urgent", summary: "Urgent",
            now: t0.addingTimeInterval(600), in: context)
        try context.save()

        #expect(try editedEntries(for: task, in: context).count == 2)
    }

    @Test("A round-trip back to the pre-burst value deletes the coalesced entry")
    func roundTripDeletes() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

        task.logHumanEdit(
            field: "priority", oldValue: "low", newValue: "high", summary: "High", now: t0, in: context)
        try context.save()
        task.logHumanEdit(
            field: "priority", oldValue: "high", newValue: "low", summary: "Low",
            now: t0.addingTimeInterval(20), in: context)
        try context.save()

        #expect(try editedEntries(for: task, in: context).isEmpty)
    }

    @Test("A same-field edit by a different actor does not coalesce")
    func differentActorDoesNotCoalesce() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

        // A prior "edited" entry attributed to someone else.
        let foreign = ChangeLogEntry(
            summary: "someone else", action: ChangeLogEntry.editedAction, fieldChanged: "priority",
            oldValue: "low", newValue: "medium", initiatedBy: .human, taskTitle: task.title,
            taskUUID: task.uuid, actorID: UUID(), timestamp: t0, in: context)
        context.insert(foreign)
        try context.save()

        task.logHumanEdit(
            field: "priority", oldValue: "medium", newValue: "high", summary: "High",
            now: t0.addingTimeInterval(30), in: context)
        try context.save()

        #expect(try editedEntries(for: task, in: context).count == 2)
    }

    @Test("Blocker add/remove never coalesce — each is a distinct event")
    func blockersDoNotCoalesce() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        let a = TaskItem(title: "a", status: .todo, confidence: 0.9)
        let b = TaskItem(title: "b", status: .todo, confidence: 0.9)
        [task, a, b].forEach(context.insert)
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

        task.addTaskBlocker(a.uuid!, among: [task, a, b])
        task.logHumanEdit(
            field: "blockers", oldValue: nil, newValue: a.uuid!.uuidString, summary: "Added blocker",
            coalescable: false, now: t0, in: context)
        try context.save()
        task.addTaskBlocker(b.uuid!, among: [task, a, b])
        task.logHumanEdit(
            field: "blockers", oldValue: nil, newValue: b.uuid!.uuidString, summary: "Added blocker",
            coalescable: false, now: t0.addingTimeInterval(10), in: context)
        try context.save()

        #expect(try editedEntries(for: task, in: context).count == 2)
    }

    // MARK: - Undo restores each field

    @Test("Undo restores the Urgent signal")
    func undoRestoresUrgent() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        task.isUrgent = true
        task.logHumanEdit(
            field: "urgent", oldValue: "false", newValue: "true", summary: "Marked urgent", in: context)

        let entry = try #require(try editedEntries(for: task, in: context).first)
        ChangeLogUndo.revert(entry, in: context)
        #expect(!task.isUrgent)
    }

    @Test("Undo restores a due date (and a cleared due date)")
    func undoRestoresDueDate() throws {
        let context = context()
        let due = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        task.dueDate = due
        context.insert(task)

        task.dueDate = nil
        task.logHumanEdit(
            field: "dueDate", oldValue: ChangeLogEntry.encodeDate(due),
            newValue: ChangeLogEntry.encodeDate(nil), summary: "Cleared due date", in: context)

        let entry = try #require(try editedEntries(for: task, in: context).first)
        ChangeLogUndo.revert(entry, in: context)
        #expect(task.dueDate == due)
    }

    @Test("Undo restores the prior lifecycle state")
    func undoRestoresStatus() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        task.setStatus(.doing, in: context)
        #expect(task.status == .doing)

        let entry = try #require(try editedEntries(for: task, in: context).first)
        ChangeLogUndo.revert(entry, in: context)
        #expect(task.status == .todo)
    }

    @Test("Undo of a coalesced entry restores the pre-burst value")
    func undoCoalescedRestoresPreBurst() throws {
        let context = context()
        // Category is a scalar with several distinct values — ideal for exercising a
        // same-field coalescing burst (the boolean signals can only round-trip).
        let task = TaskItem(title: "x", category: "Admin", status: .todo, confidence: 0.9)
        context.insert(task)
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

        task.category = "Work"
        task.logHumanEdit(
            field: "category", oldValue: "Admin", newValue: "Work", summary: "Work", now: t0, in: context)
        try context.save()
        task.category = "Finance"
        task.logHumanEdit(
            field: "category", oldValue: "Work", newValue: "Finance", summary: "Finance",
            now: t0.addingTimeInterval(30), in: context)
        try context.save()

        let entry = try #require(try editedEntries(for: task, in: context).first)
        ChangeLogUndo.revert(entry, in: context)
        #expect(task.category == "Admin")  // all the way back to before the burst
    }

    @Test("Undo of a blocker add removes exactly that edge")
    func undoBlockerAddRemovesEdge() throws {
        let context = context()
        let dependent = TaskItem(title: "flights", status: .todo, confidence: 0.9)
        let blocker = TaskItem(title: "passport", status: .todo, confidence: 0.9)
        [dependent, blocker].forEach(context.insert)

        dependent.addTaskBlocker(blocker.uuid!, among: [dependent, blocker])
        dependent.logHumanEdit(
            field: "blockers", oldValue: nil, newValue: blocker.uuid!.uuidString,
            summary: "Added blocker", coalescable: false, in: context)
        #expect(dependent.hasActiveBlockers(among: [dependent, blocker]))

        let entry = try #require(try editedEntries(for: dependent, in: context).first)
        ChangeLogUndo.revert(entry, in: context)
        #expect(!dependent.hasActiveBlockers(among: [dependent, blocker]))
    }

    // MARK: - Inbox exclusion (feed + badge share one seam)

    @Test("'edited' entries are excluded from the Inbox but reachable by taskUUID")
    func editedExcludedFromInbox() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        let filed = ChangeLogEntry(
            summary: "Filed", action: "filed", initiatedBy: .ai, taskTitle: task.title,
            taskUUID: task.uuid, in: context)
        context.insert(filed)
        task.logHumanEdit(
            field: "urgent", oldValue: "false", newValue: "true", summary: "Marked urgent", in: context)
        try context.save()

        // Feed / badge seam: the predicate keeps "filed", drops "edited".
        let visibleRequest = NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")
        visibleRequest.predicate = ChangeLogEntry.inboxVisiblePredicate
        let visible = try context.fetch(visibleRequest)
        #expect(visible.contains { $0.action == "filed" })
        #expect(!visible.contains { $0.action == ChangeLogEntry.editedAction })

        // The in-memory mirror the unread badge uses agrees.
        #expect(filed.isInboxVisible)
        let edit = try #require(try editedEntries(for: task, in: context).first)
        #expect(!edit.isInboxVisible)

        // Still present on the task's own timeline (fetched by taskUUID, no predicate).
        #expect(try editedEntries(for: task, in: context).count == 1)
    }

    /// The Today plan's generation entry is the app's OWN background work, not an action
    /// anyone took — so it must not badge the Inbox tab. It used to, on first open, on
    /// every Replan, and on every self-heal upgrade, which turned a re-entrant background
    /// job into an engagement signal the guardrails refuse.
    ///
    /// Both forms are asserted because they are the drift risk: the fetch predicate and
    /// the in-memory mirror are read by different call sites (`InboxView` vs
    /// `RootTabView.unreadInboxCount`), and a verb excluded from one but not the other
    /// shows a feed and a badge that disagree.
    @Test("'planned' entries are excluded from the Inbox by both forms of the seam")
    func plannedExcludedFromInbox() throws {
        let context = context()
        let planned = ChangeLogEntry(
            summary: "Planned 3 actions for today (rules)",
            action: ChangeLogEntry.plannedAction, initiatedBy: .ai, isReversible: false,
            in: context)
        context.insert(planned)
        let filed = ChangeLogEntry(
            summary: "Filed", action: "filed", initiatedBy: .ai, in: context)
        context.insert(filed)
        try context.save()

        let visibleRequest = NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")
        visibleRequest.predicate = ChangeLogEntry.inboxVisiblePredicate
        let visible = try context.fetch(visibleRequest)
        #expect(!visible.contains { $0.action == ChangeLogEntry.plannedAction })
        #expect(visible.contains { $0.action == "filed" })

        #expect(!planned.isInboxVisible)
        #expect(filed.isInboxVisible)
    }

    /// Not reversible, and deliberately so: there is no `"planned"` arm in
    /// `ChangeLogUndo` and the entry carries no `taskUUID` for `linkedTask` to resolve,
    /// so an Undo button on it struck the row through and then did nothing. If an action
    /// has no honest arm, the fix is to stop offering the button.
    @Test("'planned' entries never offer an Undo")
    func plannedIsNotReversible() throws {
        let context = context()
        let planned = ChangeLogEntry(
            summary: "Planned 0 actions for today (rules)",
            action: ChangeLogEntry.plannedAction, initiatedBy: .ai, isReversible: false,
            in: context)
        context.insert(planned)
        try context.save()

        #expect(!planned.isReversible)
        #expect(planned.taskUUID == nil)
    }
}
