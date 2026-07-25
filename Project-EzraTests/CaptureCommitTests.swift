//
//  CaptureCommitTests.swift
//  Project-EzraTests
//
//  Capture Graph Awareness at commit: an accepted duplicate FOLDS into the target (no new
//  task, a reversible "merged" entry that Undo resurrects); a rejected duplicate creates
//  the task and writes pair-owned suppression records (capture-form + symmetric pair —
//  never an edge); an accepted child becomes a reversible `.parent` edge; and the
//  previously-undiffed reverse-dependency removal is now a Correction.
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
            title: title, category: "Admin", confidence: 0.9,
            autonomy: .silent, isJudgmentCall: false, reasoning: "")
        d.edgeProposals = edges
        return d
    }

    @Test("Accepted duplicate folds into the target — no new task, undo resurrects it")
    func mergeFoldAndUndo() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .todo, in: context)
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
        #expect(tasks.contains { $0.title == "Renew the passport" && $0.status == .todo })
    }

    @Test("A merge records a duplicate-accepted Correction")
    func mergeRecordsCorrection() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .todo, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.95, decision: .accepted)
        _ = brain.commit([draft("Renew the passport", edges: [dup])], rawCapture: "", into: context)

        let corrections = try context.fetch(NSFetchRequest<Correction>(entityName: "Correction"))
        #expect(corrections.contains { $0.fieldCorrected == "duplicate" && $0.userValue == "accepted" })
    }

    @Test("Rejected duplicate creates the task and writes suppression records, never an edge")
    func rejectedSuppression() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .todo, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.9, decision: .rejected)
        let created = brain.commit(
            [draft("Renew passport again", edges: [dup])], rawCapture: "", into: context)
        #expect(created.count == 1)
        // The rejection is pair-owned suppression, never an edge on either task.
        #expect(created[0].relationships.isEmpty)
        #expect(created[0].blockers.isEmpty)
        #expect(created[0].parentTaskID == nil)

        let suppressions = SuppressionStore.load(
            in: context, existingTaskIDs: Set([existing.uuid!, created[0].uuid!]))
        // Capture form: keyed on the normalized draft title against the target — the key
        // that fires when the same text is captured again next week (a fresh draft id).
        #expect(
            suppressions.contains {
                $0.suppresses(
                    kind: .duplicateMerge, targetID: existing.uuid!,
                    normalizedTitle: RelationshipSuppression.normalizeTitle("Renew passport again"))
            })
        // Pair form: symmetric by construction — matches from either direction.
        #expect(
            suppressions.contains {
                $0.suppressesPair(kind: .duplicateMerge, created[0].uuid!, existing.uuid!)
            })
        #expect(
            suppressions.contains {
                $0.suppressesPair(kind: .duplicateMerge, existing.uuid!, created[0].uuid!)
            })
    }

    @Test("Accepted child creates a parent edge with a reversible linked entry")
    func childLinkAndUndo() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
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

    @Test("Rejected duplicate is keyed on the AI's original title, not the user-edited title")
    func rejectedSuppressionUsesAIOriginalTitle() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .todo, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.9, decision: .rejected)
        var d = draft("A totally renamed title", edges: [dup])
        // The resolver checks suppression against `normalizeTitle(intent.title)` — the AI's
        // ORIGINAL title — so the record must be keyed on it too, or a renamed-then-rejected
        // duplicate re-surfaces pre-accepted next capture. The user renamed the draft.
        d.aiOriginal = AIFieldSnapshot(
            title: "Renew passport again", category: d.category, dueDate: nil, isUrgent: false,
            ownerName: nil, effortMinutes: nil, blocksIDs: [], edgeProposals: [])
        let created = brain.commit([d], rawCapture: "", into: context)

        let suppressions = SuppressionStore.load(
            in: context, existingTaskIDs: Set([existing.uuid!, created[0].uuid!]))
        #expect(
            suppressions.contains {
                $0.suppresses(
                    kind: .duplicateMerge, targetID: existing.uuid!,
                    normalizedTitle: RelationshipSuppression.normalizeTitle("Renew passport again"))
            })
        #expect(
            !suppressions.contains {
                $0.suppresses(
                    kind: .duplicateMerge, targetID: existing.uuid!,
                    normalizedTitle: RelationshipSuppression.normalizeTitle("A totally renamed title"))
            })
    }

    @Test("Undoing an AI blocker-link doesn't fabricate a recently-unblocked boost")
    func undoLinkedClearsUnblockStamp() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Start renovation", status: .todo, in: context)
        context.insert(existing)
        try context.save()
        #expect(existing.lastUnblockedAt == nil)

        // A newly-captured task that an existing open task should wait on → an AI "linked"
        // reverse-dependency edge makes `existing` blocked by the new task.
        var d = draft("Pick a contractor")
        d.blocks = [OpenTaskSnapshot(id: existing.uuid!, title: existing.title)]
        _ = brain.commit([d], rawCapture: "", into: context)
        #expect(existing.hasActiveBlockers(among: TaskItem.fetchAll(in: context)))

        // Undo the mis-added edge. Removing `existing`'s last active blocker would normally
        // stamp `lastUnblockedAt` — but undoing a wrong edge must not hand the +12 boost.
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let linked = try #require(
            entries.first { $0.action == "linked" && $0.fieldChanged == "blockers" })
        ChangeLogUndo.revert(linked, in: context)
        linked.undone = true
        #expect(!existing.hasActiveBlockers(among: TaskItem.fetchAll(in: context)))  // edge gone
        #expect(existing.lastUnblockedAt == nil)  // NOT fabricated by the undo
    }

    @Test("Suppression hygiene: rows expire past maxAge and prune when their target is gone")
    func suppressionHygiene() throws {
        let context = TestStore.makeContext()
        let live = TaskItem(title: "live", status: .todo, in: context)
        context.insert(live)
        try context.save()

        let expired = Date().addingTimeInterval(-SuppressionStore.maxAge - 86_400)
        SuppressionStore.recordRejectedDuplicate(
            draftTitle: "expired one", createdID: nil, targetID: live.uuid!, in: context, now: expired)
        SuppressionStore.recordRejectedDuplicate(
            draftTitle: "orphaned one", createdID: nil, targetID: UUID(), in: context)
        SuppressionStore.recordRejectedDuplicate(
            draftTitle: "kept one", createdID: nil, targetID: live.uuid!, in: context)

        let loaded = SuppressionStore.load(in: context, existingTaskIDs: [live.uuid!])
        #expect(loaded.count == 1)
        #expect(
            loaded.first?.normalizedTitle == RelationshipSuppression.normalizeTitle("kept one"))
        // The stale rows were physically pruned, not just filtered.
        let rows = try context.fetch(NSFetchRequest<SuppressionRecord>(entityName: "SuppressionRecord"))
        #expect(rows.count == 1)
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
