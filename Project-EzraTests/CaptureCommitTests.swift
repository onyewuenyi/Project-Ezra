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

    @Test("Proposal rationales survive commit inside the persisted reasoning")
    func rationalesSurviveCommit() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        var d = draft("Pay the water bill")
        d.reasoning = "Filed under Admin."
        d.dueDate = Date()
        d.dueReason = "Bills usually land at month end."

        let created = brain.commit([d], rawCapture: "pay the water bill", into: context)

        let task = try #require(created.first)
        // The confirm card could answer "why this date?"; now the detail can too —
        // the rationale rides the same reasoning field the categorization uses.
        #expect(task.reasoning.contains("Filed under Admin."))
        #expect(task.reasoning.contains("Proposed due date: Bills usually land at month end."))
    }

    @Test("A group made at the confirm card is born at commit, in card order, and undoes whole")
    func groupAtCommitAndUndo() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let created = brain.commit(
            [draft("Renew passport"), draft("Book flights"), draft("Request time off")],
            rawCapture: "lagos trip: renew passport, book flights, request time off",
            groupTitle: "  Trip to Lagos ", into: context)

        // Three steps plus the umbrella, born at the publish boundary and nowhere before.
        #expect(created.count == 4)
        let umbrella = try #require(created.last)
        #expect(umbrella.title == "Trip to Lagos")
        #expect(umbrella.confirmedAt != nil)
        #expect(umbrella.category == "Admin")  // every step is Admin here; ties go to the first step
        let all = TaskItem.fetchAll(in: context)
        let steps = umbrella.children(among: all)
        #expect(steps.map(\.title) == ["Renew passport", "Book flights", "Request time off"])
        #expect(umbrella.nextOpenStep(among: all)?.title == "Renew passport")

        // Logged as the person's own reversible act; undo unlinks the steps and removes
        // the untouched umbrella, leaving the three tasks as they were captured.
        let entry = try #require(
            try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
                .first { $0.action == "grouped" })
        #expect(entry.initiatedBy == .human && entry.isReversible)
        ChangeLogUndo.revert(entry, in: context)
        let after = TaskItem.fetchAll(in: context)
        #expect(after.count == 3)
        #expect(after.allSatisfy { $0.parentTaskID == nil })
    }

    @Test("One card is never a group, and a blank title groups nothing")
    func groupNeedsTwoAndATitle() {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        #expect(brain.commit([draft("a")], rawCapture: "a", groupTitle: "Trip", into: context).count == 1)
        #expect(
            brain.commit([draft("b"), draft("c")], rawCapture: "b c", groupTitle: "  ", into: context)
                .count == 2)
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

    @Test("An edited-then-merged card still teaches — its diffs land on the merge target")
    func mergingDraftStillWritesCorrections() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .todo, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.95, decision: .accepted)
        var d = draft("Renew the passport", edges: [dup])
        d.aiOriginal = AIFieldSnapshot(
            title: "Renew the passport", category: "Admin", dueDate: nil, isUrgent: false,
            ownerName: nil, effortMinutes: nil, blocksIDs: [], edgeProposals: [dup])
        // The user fixed the category and flagged it urgent, THEN let the merge stand.
        d.category = "Travel"
        d.isUrgent = true

        _ = brain.commit([d], rawCapture: "", into: context)

        let corrections = try context.fetch(NSFetchRequest<Correction>(entityName: "Correction"))
        // The merge decides where the work lands, not whether the correction happened.
        let category = try #require(corrections.first { $0.fieldCorrected == "category" })
        #expect(category.aiValue == "Admin")
        #expect(category.userValue == "Travel")
        #expect(category.taskUUID == existing.uuid)  // attached to the merge TARGET
        #expect(corrections.contains { $0.fieldCorrected == "urgent" && $0.userValue == "true" })
        // …alongside the merge's own accepted-duplicate signal, which is unchanged.
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
        // Mark, then revert: the order every undo path uses. Writing to an entry AFTER
        // `revert` has read its strings snapshots them, and that is the Core Data fault
        // `TestStore` documents (this test crashed 3/3 in the other order, 2026-10-03).
        linked.undone = true
        ChangeLogUndo.revert(linked, in: context)
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

    @Test("A rejected duplicate is logged, and its undo lifts BOTH suppression forms")
    func rejectionIsLoggedAndReversible() throws {
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

        // The 180-day veto is now visible: one entry, the human's (not the AI's, or one
        // tap would score twice in acceptanceRate), naming the task it was kept apart from.
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let suppressed = try #require(entries.first { $0.action == "suppressed" })
        #expect(suppressed.initiatedBy == .human)
        #expect(suppressed.isReversible)
        #expect(suppressed.summary.contains("Renew passport"))
        // …and it stays out of the AI trust number entirely — not in the numerator when
        // kept, not in the denominator when undone. One tap must not score twice.
        #expect(Metrics.acceptanceRate(entries: entries) == 1.0)

        let ids = Set([existing.uuid!, created[0].uuid!])
        #expect(!SuppressionStore.load(in: context, existingTaskIDs: ids).isEmpty)

        ChangeLogUndo.revert(suppressed, in: context)
        suppressed.undone = true
        // Undo-completeness: the capture form AND the pair form are both gone, so the
        // next capture can propose the merge again from either direction.
        let after = SuppressionStore.load(in: context, existingTaskIDs: ids)
        #expect(
            !after.contains {
                $0.suppresses(
                    kind: .duplicateMerge, targetID: existing.uuid!,
                    normalizedTitle: RelationshipSuppression.normalizeTitle("Renew passport again"))
            })
        #expect(
            !after.contains { $0.suppressesPair(kind: .duplicateMerge, created[0].uuid!, existing.uuid!) })
        #expect(
            !after.contains { $0.suppressesPair(kind: .duplicateMerge, existing.uuid!, created[0].uuid!) })
        // Undoing a HUMAN rejection must not read as rejecting the AI: the rate is
        // unmoved because the entry was never in the AI set to begin with.
        #expect(Metrics.acceptanceRate(entries: entries) == 1.0)
    }

    @Test("A rejected parent link is logged and reversible the same way")
    func rejectedParentIsLoggedAndReversible() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        try context.save()

        let child = EdgeProposal(
            kind: .childOf, targetID: parent.uuid!, targetTitle: "Plan the trip",
            confidence: 0.9, decision: .rejected)
        let created = brain.commit([draft("Book flights", edges: [child])], rawCapture: "", into: context)
        #expect(created.first?.parentTaskID == nil)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let suppressed = try #require(entries.first { $0.action == "suppressed" })
        #expect(suppressed.fieldChanged == RelationshipSuppression.SuppressionKind.parentLink.rawValue)

        let ids = Set([parent.uuid!, created[0].uuid!])
        #expect(!SuppressionStore.load(in: context, existingTaskIDs: ids).isEmpty)
        ChangeLogUndo.revert(suppressed, in: context)
        // Parent suppression is directional, so both forms are keyed child→parent.
        let after = SuppressionStore.load(in: context, existingTaskIDs: ids)
        #expect(
            !after.contains {
                $0.suppresses(
                    kind: .parentLink, targetID: parent.uuid!,
                    normalizedTitle: RelationshipSuppression.normalizeTitle("Book flights"))
            })
        #expect(!after.contains { $0.suppressesPair(kind: .parentLink, created[0].uuid!, parent.uuid!) })
    }

    @Test("Undoing one rejection leaves an unrelated rejection's rows standing")
    func undoRejectionIsScopedToItsOwnRows() throws {
        let context = TestStore.makeContext()
        let keep = TaskItem(title: "Keep me", status: .todo, in: context)
        context.insert(keep)
        try context.save()

        SuppressionStore.recordRejectedDuplicate(
            draftTitle: "lifted", createdID: nil, targetID: keep.uuid!, in: context)
        SuppressionStore.recordRejectedDuplicate(
            draftTitle: "untouched", createdID: nil, targetID: keep.uuid!, in: context)

        SuppressionStore.undoRejection(
            SuppressionUndoPayload(
                kind: RelationshipSuppression.SuppressionKind.duplicateMerge.rawValue,
                targetID: keep.uuid!,
                normalizedTitle: RelationshipSuppression.normalizeTitle("lifted"),
                createdID: nil),
            in: context)

        let after = SuppressionStore.load(in: context, existingTaskIDs: [keep.uuid!])
        #expect(after.count == 1)
        #expect(after.first?.normalizedTitle == RelationshipSuppression.normalizeTitle("untouched"))
    }

    // MARK: - The confirm's receipt

    @Test("Commit reports what it produced, merges named")
    func commitSummaryReportsOutcome() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let existing = TaskItem(title: "Renew passport", status: .todo, in: context)
        context.insert(existing)
        try context.save()

        let dup = EdgeProposal(
            kind: .duplicateOf, targetID: existing.uuid!, targetTitle: "Renew passport",
            confidence: 0.95, decision: .accepted)
        _ = brain.commit(
            [draft("Book dentist"), draft("Call mom"), draft("Renew the passport", edges: [dup])],
            rawCapture: "", into: context)

        let summary = try #require(brain.lastCommitSummary)
        #expect(summary.created == 2)
        // A merge names its target — that's the answer to "where did my thought go?".
        #expect(summary.message == "Added 2 tasks · 1 merged into “Renew passport”")
    }

    @Test("Summary copy: singular, merge-only, and many-merge forms")
    func commitSummaryCopyForms() {
        #expect(CommitSummary(created: 1, mergedTitles: []).message == "Added 1 task")
        #expect(CommitSummary(created: 3, mergedTitles: []).message == "Added 3 tasks")
        #expect(
            CommitSummary(created: 0, mergedTitles: ["Renew passport"]).message
                == "Merged into “Renew passport”")
        #expect(CommitSummary(created: 1, mergedTitles: ["a", "b"]).message == "Added 1 task · 2 merged")
        // Nothing produced → nothing claimed. The notice never fires on an empty commit.
        #expect(CommitSummary(created: 0, mergedTitles: []).isEmpty)
    }

    @Test("The post-dismiss toast says only what the ✓ receipt couldn't")
    func residualMessageIsMergeOnly() {
        // A plain creation is fully reported by the Create moment's ✓ — repeating the
        // count in a toast ends the arc twice.
        #expect(CommitSummary(created: 5, mergedTitles: []).messageBeyondReceipt == nil)
        #expect(CommitSummary(created: 0, mergedTitles: []).messageBeyondReceipt == nil)
        // A merge is the one outcome the count leaves open — name the target.
        #expect(
            CommitSummary(created: 2, mergedTitles: ["Renew passport"]).messageBeyondReceipt
                == "Merged into “Renew passport”")
        #expect(
            CommitSummary(created: 0, mergedTitles: ["a", "b"]).messageBeyondReceipt
                == "2 merged into existing tasks")
    }

    // MARK: - Owner resolution (the chip must not promise what commit can't deliver)

    @Test("An owner name absent from the roster commits UNOWNED — the no-mint policy")
    func unmatchedOwnerNameCommitsUnowned() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        var d = draft("Book the venue")
        d.ownerName = "Maya"  // nobody by that name exists
        let created = brain.commit([d], rawCapture: "", into: context)

        // No phantom member is conjured — a misheard name must never become a person
        // who can accrue category ownership and be proposed for future work.
        let members = try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))
        #expect(!members.contains { $0.name.caseInsensitiveCompare("Maya") == .orderedSame })
        // …so the task lands shared. This is correct, and it is exactly why the confirm
        // card must say "not in household" rather than show a confident owner chip.
        #expect(created[0].ownerID == nil)
    }

    @Test("Adding the name to the roster first makes commit resolve it — the card's escape hatch")
    func addedOwnerNameResolvesAtCommit() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        // What the chip's "Add Maya to household…" does before the user taps Add tasks.
        let maya = FamilyMember(name: "Maya", in: context)
        context.insert(maya)
        try context.save()

        var d = draft("Book the venue")
        d.ownerName = "maya"  // case-insensitive, as `resolveOwners` matches
        let created = brain.commit([d], rawCapture: "", into: context)
        #expect(created[0].ownerID == maya.uuid)
    }

    @Test("Confirm clears the low-confidence Needs Decision; a judgment call keeps its flag")
    func confirmClearsLowConfidenceDecisionFlag() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()

        var unsure = TaskDraft(
            title: "Something vague", category: "Admin", confidence: 0.4,
            autonomy: .ask, isJudgmentCall: false, reasoning: "")
        // Pre-confirm the draft DOES read as needing a decision — that's the honest
        // reading of the AI's uncertainty while nobody has looked at it yet.
        #expect(unsure.needsDecision)
        unsure.title = "Something vague"

        var judgment = TaskDraft(
            title: "Should I quit the gym", category: "Health", confidence: 0.9,
            autonomy: .ask, isJudgmentCall: true, reasoning: "")
        judgment.workIntent = .planning

        let created = brain.commit([unsure, judgment], rawCapture: "", into: context)
        #expect(created.count == 2)
        // The human reviewed every field at the confirm glance — the low-confidence half
        // of the flag is what that review answers.
        #expect(!created[0].needsDecision)
        #expect(created[0].confidence == 0.4)  // the uncertainty itself is still recorded
        // The judgment carve-out is untouched: confirming it exists isn't making the call.
        #expect(created[1].needsDecision)
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
