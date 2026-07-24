//
//  InboxFeedTests.swift
//  Project-EzraTests
//
//  The Inbox feed's action-aware Undo (`ChangeLogUndo`) and the human-actor logging
//  that feeds it. The load-bearing rule: a HUMAN "completed"/"killed" undo REOPENS the
//  task (restoring its prior status) — it must never fall through to the AI's inbox
//  revert, which would strand a finished task awaiting re-confirm.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Inbox feed")
@MainActor
struct InboxFeedTests {

  private func context() -> NSManagedObjectContext { TestStore.makeContext() }

  // MARK: - Human resolution logging

  @Test("completeAndResurface logs a reversible human 'completed' with an actorID")
  func completeLogsHumanEntry() throws {
    let context = context()
    let task = TaskItem(title: "x", status: .active, confidence: 0.9)
    context.insert(task)
    task.completeAndResurface(in: context)
    let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    let entry = try #require(entries.first { $0.action == "completed" && $0.taskUUID == task.uuid })
    #expect(entry.initiatedBy == .human)
    #expect(entry.actorID != nil)
    #expect(entry.isReversible)
  }

  // MARK: - Action-aware revert

  @Test("A human 'completed' undo reopens the task — never sends it to the Inbox")
  func completedRevertReopens() throws {
    let context = context()
    let task = TaskItem(title: "x", status: .active, confidence: 0.9)
    context.insert(task)
    task.completeAndResurface(in: context)
    try? context.save()
    let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    let completed = try #require(entries.first { $0.action == "completed" })

    ChangeLogUndo.revert(completed, in: context)
    #expect(task.status == .active)  // reopened, NOT .inbox
    #expect(!task.status.isResolved)
  }

  @Test("A human 'killed' undo reopens the task, not to the Inbox")
  func killedRevertReopens() throws {
    let context = context()
    let task = TaskItem(title: "x", status: .active, confidence: 0.9)
    context.insert(task)
    task.killAndResurface(in: context)
    let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    let killed = try #require(entries.first { $0.action == "killed" })

    ChangeLogUndo.revert(killed, in: context)
    #expect(task.status == .active)
  }

  @Test("An 'assigned' undo restores the previous owner (old/new ride the entry)")
  func assignedRevertRestoresOwner() throws {
    let context = context()
    let me = UUID()
    let maya = UUID()
    let task = TaskItem(title: "x", status: .active, confidence: 0.9, ownerID: me)
    context.insert(task)
    task.claimAndLog(ownerID: maya, among: [task], in: context)
    #expect(task.ownerID == maya)

    let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    let assigned = try #require(entries.first { $0.action == "assigned" })
    #expect(assigned.oldValue == me.uuidString)
    #expect(assigned.newValue == maya.uuidString)

    ChangeLogUndo.revert(assigned, in: context)
    #expect(task.ownerID == me)
  }

  @Test("A 'decided' undo re-escalates the open decision")
  func decidedRevertReescalates() throws {
    let context = context()
    let task = TaskItem(
      title: "x", status: .active, confidence: 0.95, isJudgmentCall: true, needsDecision: true)
    context.insert(task)
    task.resolveDecisionAndLog(in: context)
    #expect(!task.needsDecision)

    let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    let decided = try #require(entries.first { $0.action == "decided" })
    ChangeLogUndo.revert(decided, in: context)
    #expect(task.needsDecision)
  }

  @Test("A 'filed' AI entry undo returns the task to the Inbox (the default path)")
  func filedRevertToInbox() throws {
    let context = context()
    let task = TaskItem(title: "x", status: .active, confidence: 0.9)
    context.insert(task)
    let entry = ChangeLogEntry(
      summary: "Filed", action: "filed", initiatedBy: .ai, isReversible: true,
      taskTitle: task.title, taskUUID: task.uuid, in: context)
    context.insert(entry)

    ChangeLogUndo.revert(entry, in: context)
    #expect(task.status == .inbox)
  }

  @Test("A 'linked' entry undo removes exactly that dependency edge")
  func linkedRevertRemovesEdge() throws {
    let context = context()
    let blocker = TaskItem(title: "passport", status: .active, confidence: 0.9)
    let dependent = TaskItem(title: "flights", status: .active, confidence: 0.9)
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
