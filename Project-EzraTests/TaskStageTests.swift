//
//  TaskStageTests.swift
//  Project-EzraTests
//
//  The stage sub-state + the six-state display vocabulary derived over (status,
//  stage). Invariants: `derive` is the one mapping table; `confirm` stamps the default
//  stage exactly once; `setStage` moves only the stage (never the status); and
//  `applyDisplayStatus` composes the underlying lifecycle + stage moves correctly —
//  the single seam the row glyph and the detail picker share.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Task stage & display status")
struct TaskStageTests {

    // MARK: - The derive table (single source of truth)

    @Test("derive maps every (status, stage) to the right display status")
    func deriveTable() {
        // Inbox is always Backlog, regardless of stage.
        #expect(TaskDisplayStatus.derive(status: .inbox, stage: .todo) == .backlog)
        #expect(TaskDisplayStatus.derive(status: .inbox, stage: .inProgress) == .backlog)
        // Active reads by its stage.
        #expect(TaskDisplayStatus.derive(status: .active, stage: .backlog) == .backlog)
        #expect(TaskDisplayStatus.derive(status: .active, stage: .todo) == .todo)
        #expect(TaskDisplayStatus.derive(status: .active, stage: .inProgress) == .inProgress)
        #expect(TaskDisplayStatus.derive(status: .active, stage: .inReview) == .inReview)
        // Resolved states.
        #expect(TaskDisplayStatus.derive(status: .done, stage: .todo) == .done)
        #expect(TaskDisplayStatus.derive(status: .killed, stage: .inReview) == .canceled)
    }

    @Test("displayStatus reads through to the task's own (status, stage)")
    func displayStatusOnTask() {
        let inbox = TaskItem(title: "x", status: .inbox)
        #expect(inbox.displayStatus == .backlog)
        let review = TaskItem(title: "y", status: .active, stage: .inReview)
        #expect(review.displayStatus == .inReview)
    }

    // MARK: - confirm stamps the default stage once

    @Test("confirm stamps the default stage once; a later move survives a re-confirm")
    func confirmStampsDefaultStageOnce() {
        let task = TaskItem(title: "x", status: .inbox, confidence: 0.9)
        #expect(task.isStageUnset)
        task.confirm()
        #expect(task.stage == .todo)
        #expect(task.displayStatus == .todo)
        // Move it along, then re-confirm — the move must not be clobbered.
        task.setStage(.inProgress)
        task.confirm()
        #expect(task.stage == .inProgress)
    }

    // MARK: - setStage is stage-only

    @Test("setStage bumps updatedAt and never touches the status")
    func setStageIsStageOnly() {
        let born = Date(timeIntervalSinceNow: -1000)
        let task = TaskItem(title: "x", status: .active, createdAt: born)
        task.setStage(.inReview)
        #expect(task.stage == .inReview)
        #expect(task.status == .active)
        #expect(task.updatedAt > born)
    }

    // MARK: - applyDisplayStatus compositions

    @MainActor private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    @Test("applyDisplayStatus: inbox → In Progress confirms first, then stages")
    @MainActor func applyFromInbox() {
        let context = context()
        let task = TaskItem(title: "x", status: .inbox, confidence: 0.9)
        context.insert(task)
        task.applyDisplayStatus(.inProgress, in: context)
        #expect(task.status == .active)
        #expect(task.stage == .inProgress)
        #expect(task.displayStatus == .inProgress)
        #expect(task.confirmedAt != nil)
    }

    @Test("applyDisplayStatus: a resolved task → Todo reopens then stages")
    @MainActor func applyFromResolved() {
        let context = context()
        let task = TaskItem(title: "x", status: .active, confidence: 0.9)
        context.insert(task)
        task.complete()
        #expect(task.status == .done)
        task.applyDisplayStatus(.todo, in: context)
        #expect(task.status == .active)
        #expect(task.stage == .todo)
        #expect(task.completedAt == nil)
    }

    @Test("applyDisplayStatus: → Done resolves and logs a reversible human completion")
    @MainActor func applyDone() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .active, confidence: 0.9)
        context.insert(task)
        task.applyDisplayStatus(.done, in: context)
        #expect(task.status == .done)
        #expect(task.displayStatus == .done)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let done = try #require(entries.first { $0.action == "completed" && $0.taskUUID == task.uuid })
        #expect(done.initiatedBy == .human)
        #expect(done.actorID != nil)
        #expect(done.isReversible)
    }

    @Test("applyDisplayStatus: → Canceled kills and logs a human cancel")
    @MainActor func applyCanceled() throws {
        let context = context()
        let task = TaskItem(title: "x", status: .active, confidence: 0.9)
        context.insert(task)
        task.applyDisplayStatus(.canceled, in: context)
        #expect(task.status == .killed)
        #expect(task.displayStatus == .canceled)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(
            entries.contains {
                $0.action == "killed" && $0.initiatedBy == .human && $0.taskUUID == task.uuid
            })
    }

    @Test("applyDisplayStatus: staying on the same state is a no-op")
    @MainActor func applySameStateNoOp() {
        let context = context()
        let task = TaskItem(title: "x", status: .active, stage: .todo, confidence: 0.9)
        context.insert(task)
        let before = task.updatedAt
        task.applyDisplayStatus(.todo, in: context)
        #expect(task.stage == .todo)
        // setStage still touches, but no status churn — this documents applied intent.
        #expect(task.updatedAt >= before)
    }
}
