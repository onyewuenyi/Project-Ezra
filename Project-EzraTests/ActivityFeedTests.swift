//
//  ActivityFeedTests.swift
//  Project-EzraTests
//
//  The Activity feed's action-aware Undo (`ChangeLogUndo`) and the human-actor logging
//  that feeds it. The load-bearing rule: a HUMAN "completed"/"killed" undo REOPENS the
//  task (restoring its prior status) — it must never fall through to the AI's inbox
//  revert, which would strand a finished task awaiting re-confirm.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Activity feed")
@MainActor
struct ActivityFeedTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    // MARK: - Human resolution logging

    @Test("completeAndResurface logs a reversible human 'completed' with an actorID")
    func completeLogsHumanEntry() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        task.completeAndResurface(in: context)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let entry = try #require(entries.first { $0.action == "completed" && $0.taskUUID == task.uuid })
        #expect(entry.initiatedBy == .human)
        #expect(entry.actorID != nil)
        #expect(entry.isReversible)
    }

    // MARK: - Action-aware revert

    @Test("A human 'completed' undo reopens the task — never sends it to Activity")
    func completedRevertReopens() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        task.completeAndResurface(in: context)
        try? context.save()
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let completed = try #require(entries.first { $0.action == "completed" })

        ChangeLogUndo.revert(completed, in: context)
        #expect(task.status.isLive)  // reopened, NOT .inbox
        #expect(!task.status.isResolved)
    }

    @Test("A human 'killed' undo reopens the task, not to Activity")
    func killedRevertReopens() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9)
        context.insert(task)
        task.killAndResurface(in: context)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let killed = try #require(entries.first { $0.action == "killed" })

        ChangeLogUndo.revert(killed, in: context)
        #expect(task.status.isLive)
    }

    @Test("An 'assigned' undo restores the previous owner (old/new ride the entry)")
    func assignedRevertRestoresOwner() throws {
        let context = context()
        let me = UUID()
        let maya = UUID()
        let task = TaskItem(title: "x", status: .todo, confidence: 0.9, ownerID: me)
        context.insert(task)
        task.claimAndLog(ownerID: maya, among: [task], in: context)
        #expect(task.ownerID == maya)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let assigned = try #require(entries.first { $0.action == "assigned" })
        // Old/new carry the ORIGIN alongside the id. Without it, undo would restore the
        // owner but leave the origin reading `.human`, polluting the affinity denominator
        // with an ownership no human established (the undo-completeness rule).
        #expect(TaskItem.decodeOwnership(assigned.oldValue).ownerID == me)
        #expect(TaskItem.decodeOwnership(assigned.newValue).ownerID == maya)

        ChangeLogUndo.revert(assigned, in: context)
        #expect(task.ownerID == me)
        #expect(task.ownerOrigin == .inferred)  // restored, not left marked human
    }

    @Test("A 'decided' undo re-escalates the open decision")
    func decidedRevertReescalates() throws {
        let context = context()
        let task = TaskItem(
            title: "x", status: .todo, confidence: 0.95, isJudgmentCall: true, needsDecision: true)
        context.insert(task)
        task.resolveDecisionAndLog(in: context)
        #expect(!task.needsDecision)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let decided = try #require(entries.first { $0.action == "decided" })
        ChangeLogUndo.revert(decided, in: context)
        #expect(task.needsDecision)
    }

    @Test("Deciding WITH a choice keeps the answer — log detail, notes line, undo-complete")
    func decidedChoiceIsKept() throws {
        let context = context()
        let task = TaskItem(
            title: "Switch insurance?", status: .todo, confidence: 0.95, isJudgmentCall: true,
            needsDecision: true)
        task.notes = "Compare by Friday"
        context.insert(task)

        task.resolveDecisionAndLog(in: context, choice: "Switch providers")
        #expect(!task.needsDecision)
        // The outcome lives ON the task, not only in the trail…
        #expect(task.notes == "Compare by Friday\nDecided → Switch providers")

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let decided = try #require(entries.first { $0.action == "decided" })
        // …and the trail says WHAT was chosen, not just that something was.
        #expect(decided.detail == "Chose: Switch providers")

        // Undo restores every field the action wrote: the flag comes back AND exactly
        // the appended line leaves the notes — the user's own note survives.
        ChangeLogUndo.revert(decided, in: context)
        #expect(task.needsDecision)
        #expect(task.notes == "Compare by Friday")
    }

    @Test("A 'filed' entry is informational — no Undo button, so no false rejection signal")
    func filedIsNotReversible() throws {
        let context = context()
        let brain = AppBrain()
        let draft = TaskDraft(
            title: "Renew passport", category: "Travel", confidence: 0.9, autonomy: .silent,
            isJudgmentCall: false, reasoning: "Filed under Travel.")
        _ = brain.commit([draft], rawCapture: "renew passport", into: context)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let filed = try #require(entries.first { $0.action == "filed" })
        // The Activity renders Undo on `isReversible && !undone`. There is nothing to restore
        // (commit IS the confirm; the task never held a pre-AI category), and the old arm
        // just set `.todo` on a task born `.todo`.
        #expect(!filed.isReversible)
        // …and because the button is gone, it can never be tapped into a false rejection:
        // acceptanceRate counts `!undone` AI entries, so a dead undo scored against the AI.
        #expect(Metrics.acceptanceRate(entries: entries) == 1.0)
    }

    @Test("A 'linked' entry undo removes exactly that dependency edge")
    func linkedRevertRemovesEdge() throws {
        let context = context()
        let blocker = TaskItem(title: "passport", status: .todo, confidence: 0.9)
        let dependent = TaskItem(title: "flights", status: .todo, confidence: 0.9)
        context.insert(blocker)
        context.insert(dependent)
        dependent.addTaskBlocker(blocker.uuid!, among: [blocker, dependent])
        #expect(dependent.hasActiveBlockers(among: [blocker, dependent]))

        let entry = ChangeLogEntry(
            summary: "linked", action: "linked", newValue: blocker.uuid!.uuidString,
            initiatedBy: .ai, isReversible: true, taskTitle: dependent.title,
            taskUUID: dependent.uuid, in: context)
        context.insert(entry)

        ChangeLogUndo.revert(entry, in: context)
        #expect(!dependent.hasActiveBlockers(among: [blocker, dependent]))
    }
}
