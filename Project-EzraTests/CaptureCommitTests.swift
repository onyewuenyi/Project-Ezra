//
//  CaptureCommitTests.swift
//  Project-EzraTests
//
//  Capture Graph Awareness at commit: an accepted duplicate FOLDS into the target (no new
//  task, a reversible "merged" entry that Undo resurrects); a rejected duplicate creates
//  the task and leaves a dismissed tombstone; an accepted child becomes a reversible
//  `.parent` edge; and the previously-undiffed reverse-dependency removal is now a
//  Correction.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Capture commit — graph edges")
struct CaptureCommitTests {

    private func draft(
        _ title: String, edges: [EdgeProposal] = []
    ) -> TaskDraft {
        var d = TaskDraft(
            title: title, category: "Admin", proposedStatus: .inbox, confidence: 0.9,
            autonomy: .silent, isJudgmentCall: false, reasoning: "")
        d.edgeProposals = edges
        return d
    }

    @Test("Accepted duplicate folds into the target — no new task, undo resurrects it")
    func mergeFoldAndUndo() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .active, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.95, decision: .accepted)
        let created = brain.commit(
            [draft("Renew the passport", edges: [dup])], rawCapture: "renew passport", into: context)
        #expect(created.isEmpty)  // merged, not created

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let merged = try #require(entries.first { $0.action == "merged" })
        #expect(merged.isReversible)

        merged.undone = true
        ChangeLogUndo.revert(merged, in: context)
        let tasks = try context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))
        #expect(tasks.contains { $0.title == "Renew the passport" && $0.status == .inbox })
    }

    @Test("A merge records a duplicate-accepted Correction")
    func mergeRecordsCorrection() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .active, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.95, decision: .accepted)
        _ = brain.commit([draft("Renew the passport", edges: [dup])], rawCapture: "", into: context)

        let corrections = try context.fetch(NSFetchRequest<Correction>(entityName: "Correction"))
        #expect(corrections.contains { $0.fieldCorrected == "duplicate" && $0.userValue == "accepted" })
    }

    @Test("Rejected duplicate creates the task and leaves a dismissed tombstone")
    func rejectedTombstone() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .active, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.9, decision: .rejected)
        let created = brain.commit(
            [draft("Renew passport again", edges: [dup])], rawCapture: "", into: context)
        #expect(created.count == 1)
        #expect(
            created[0].relationships.contains {
                $0.kind == .duplicate && $0.dismissed && $0.targetID == existing.uuid!
            })
        // The tombstone carries no live semantics (not a blocker, not a parent).
        #expect(created[0].blockers.isEmpty)
        #expect(created[0].parentTaskID == nil)
    }

    @Test("Accepted child creates a parent edge with a reversible linked entry")
    func childLinkAndUndo() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let parent = TaskItem(title: "Plan the trip", status: .active, in: context)
        context.insert(parent)
        try context.save()

        let child = EdgeProposal(
            kind: .childOf, targetID: parent.uuid!, targetTitle: "Plan the trip",
            confidence: 0.9, decision: .accepted)
        let created = brain.commit([draft("Book flights", edges: [child])], rawCapture: "", into: context)
        #expect(created.first?.parentTaskID == parent.uuid!)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let linked = try #require(entries.first { $0.action == "linked" && $0.fieldChanged == "parent" })
        linked.undone = true
        ChangeLogUndo.revert(linked, in: context)
        #expect(created.first?.parentTaskID == nil)
    }

    @Test("Removing a proposed reverse-dependency is now diffed as a Correction")
    func blocksNowDiffed() {
        var d = draft("New task")
        let openTask = OpenTaskSnapshot(id: UUID(), title: "Existing")
        d.blocks = [openTask]
        d.aiOriginal = AIFieldSnapshot(
            title: d.title, category: d.category, dueDate: nil, isUrgent: false, ownerName: nil,
            effortMinutes: nil, blocksIDs: [openTask.id], edgeProposals: [])
        d.blocks = []  // user removed it
        #expect(d.corrections.contains { $0.field == "blocks" })
    }
}
