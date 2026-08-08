//
//  TaskStatusTests.swift
//  Project-EzraTests
//
//  The collapsed lifecycle axis. Replaces `TaskStageTests`, which existed to guard a
//  `(status, stage) → display` mapping table — with one four-case `TaskStatus` there
//  is no table left to drift, so what is worth testing changed: the axis's own
//  predicates, the single write seam, and the two places a value could route a task
//  somewhere unreachable.
//

import CoreData
import Testing

@testable import Project_Ezra

@MainActor
struct TaskStatusTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    // MARK: - The axis

    @Test("isLive and isResolved partition the four states exactly")
    func predicatesPartition() {
        for status in TaskStatus.allCases {
            #expect(status.isLive != status.isResolved)
        }
        #expect(TaskStatus.allCases.filter(\.isLive) == [.todo, .doing])
        #expect(TaskStatus.allCases.filter(\.isResolved) == [.done, .canceled])
    }

    @Test("There is no pre-confirm state — a task is born Todo")
    func bornTodo() {
        let task = TaskItem(title: "x")
        #expect(task.status == .todo)
        // The retired `.inbox` raw value must not decode into anything live: a store
        // that somehow carried one falls back to `.todo`, never to a ghost state.
        #expect(TaskStatus(rawValue: "inbox") == nil)
        #expect(TaskStatus(rawValue: "active") == nil)
        #expect(TaskStatus(rawValue: "killed") == nil)
    }

    @Test("Display is 1:1 with the axis — every state has a distinct glyph and label")
    func displayIsOneToOne() {
        let symbols = Set(TaskStatus.allCases.map(\.symbol))
        let labels = Set(TaskStatus.allCases.map(\.label))
        #expect(symbols.count == TaskStatus.allCases.count)
        #expect(labels.count == TaskStatus.allCases.count)
        // Everything is pickable — there is no unselectable birth state any more.
        #expect(Set(TaskStatus.pickable) == Set(TaskStatus.allCases))
    }

    // MARK: - setStatus, the single write seam

    @Test("A todo ↔ doing move logs a coalescing 'edited' entry, kept out of the Inbox feed")
    func liveMoveLogsEdit() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, in: context)
        context.insert(task)

        task.setStatus(.doing, in: context)
        #expect(task.status == .doing)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let edit = try #require(entries.first { $0.fieldChanged == "status" })
        #expect(edit.action == ChangeLogEntry.editedAction)
        #expect(edit.oldValue == "todo")
        #expect(edit.newValue == "doing")
        // Nudging a task in and out of flight is not household news.
        #expect(!edit.isInboxVisible)
    }

    @Test("Resolving through setStatus routes to the resolution seams, not an edit entry")
    func resolveRoutesToResolutionSeam() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .doing, in: context)
        context.insert(task)

        task.setStatus(.done, in: context)
        #expect(task.status == .done)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(entries.contains { $0.action == "completed" })
        #expect(!entries.contains { $0.fieldChanged == "status" })
    }

    @Test("Moving a resolved task back to live reopens it first")
    func resolvedMoveReopens() {
        let context = context()
        let task = TaskItem(title: "x", status: .doing, in: context)
        context.insert(task)
        task.complete()

        task.setStatus(.doing, in: context)
        #expect(task.status == .doing)
        #expect(task.completedAt == nil)
    }

    // MARK: - Reopen's floor (the hole the verb table opened)

    @Test("Reopen restores the live status it left")
    func reopenRestoresPriorLive() {
        let task = TaskItem(title: "x", status: .todo)
        task.transition(to: .doing)
        task.kill()
        task.reopen(among: [])
        #expect(task.status == .doing)
    }

    @Test("Reopen floors at Todo — no timeline value can route a task below it")
    func reopenFloorsAtTodo() {
        let task = TaskItem(title: "x", status: .todo)
        task.kill()
        // Forge a timeline carrying a retired raw value, as a store written by an older
        // generation could. It must not resolve to anything, and the floor must hold.
        task.stateTimeline = [StateVisit(state: "inbox", enteredAt: .distantPast, exitedAt: nil)]
        task.reopen(among: [])
        #expect(task.status == .todo)
    }

    // MARK: - The type axis

    @Test("WorkIntent carries three kinds — waiting and reference are both retired")
    func retiredCasesAreGone() {
        // `waiting` duplicated the derived blocked flag; `reference` existed only to be
        // excluded from the workload systems, and removing it collapsed all five gates.
        #expect(WorkIntent(rawValue: "waiting") == nil)
        #expect(WorkIntent(rawValue: "reference") == nil)
        #expect(WorkIntent(rawValue: "decision") == nil)  // retired type; decode() remaps
        #expect(Set(WorkIntent.allCases) == [.action, .planning])
    }
}
