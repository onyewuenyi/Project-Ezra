//
//  BreakdownSplitTests.swift
//  Project-EzraTests
//
//  What accepting a breakdown actually does. This is the one capability that COMMITS —
//  the Thinking Partner changes nothing, a split creates real tasks — so the guarantees
//  worth pinning are the commit semantics, the single reversible entry, and the ranking
//  consequence of a task becoming a container.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct BreakdownSplitTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func steps(_ titles: [String]) -> [BreakdownStep] {
        titles.map { BreakdownStep(title: $0, effortMinutes: 30) }
    }

    private func entries(in context: NSManagedObjectContext) throws -> [ChangeLogEntry] {
        try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    }

    // MARK: - The split

    @Test("Children are born Todo and confirmed — creation IS the accept tap")
    func childrenAreBornConfirmed() {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)

        let created = parent.splitInto(steps(["Book flights", "Book the hotel"]), in: context)

        #expect(created.count == 2)
        for child in created {
            #expect(child.status == .todo)
            #expect(child.confirmedAt != nil)  // the accept tap is the confirm
            #expect(child.parentTaskID == parent.uuid)
        }
    }

    @Test("Children inherit the parent's owner and category — your work stays yours")
    func childrenInheritOwnership() {
        let context = context()
        let me = UUID()
        let parent = TaskItem(
            title: "Plan the trip", category: "Travel", status: .todo, ownerID: me, in: context)
        context.insert(parent)

        let created = parent.splitInto(steps(["Book flights"]), in: context)
        #expect(created.first?.ownerID == me)
        #expect(created.first?.category == "Travel")
    }

    @Test("One entry for one action, carrying every created id")
    func oneReversibleEntry() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)

        let created = parent.splitInto(steps(["A", "B", "C"]), in: context)

        let splits = try entries(in: context).filter { $0.action == "split" }
        #expect(splits.count == 1)  // one action the user took → one line in the feed
        let entry = try #require(splits.first)
        #expect(entry.isReversible)
        #expect(entry.initiatedBy == .human)  // the AI proposes; the person accepts
        let ids = (entry.newValue ?? "").split(separator: ",").map(String.init)
        #expect(Set(ids) == Set(created.compactMap { $0.uuid?.uuidString }))
    }

    @Test("An empty accept does nothing at all")
    func emptyAcceptIsANoOp() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        #expect(parent.splitInto([], in: context).isEmpty)
        #expect(try entries(in: context).isEmpty)
    }

    // MARK: - Undo

    @Test("Undo removes the children and their edges, leaving the parent untouched")
    func undoRemovesChildren() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        parent.splitInto(steps(["Book flights", "Book the hotel"]), in: context)
        try context.save()

        let entry = try #require(try entries(in: context).first { $0.action == "split" })
        ChangeLogUndo.revert(entry, in: context)
        try context.save()

        let remaining = TaskItem.fetchAll(in: context)
        #expect(remaining.count == 1)  // the children are gone…
        #expect(remaining.first?.uuid == parent.uuid)  // …and the parent survived
        #expect(parent.status == .todo)
        // The `.parent` edge lived on each child, so removing them removed it.
        #expect(parent.children(among: remaining).isEmpty)
    }

    @Test("Undo does NOT reclaim a step the user has since worked on")
    func undoSparesTouchedChildren() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        let created = parent.splitInto(steps(["Book flights", "Book the hotel"]), in: context)
        try context.save()

        // Read the ids up front. Once the undo below deletes the untouched child and the
        // context is saved, that object is gone from the store — reading any property of
        // it is a use-after-delete on a managed object, which faults and kills the host.
        let touchedID = try #require(created[0].uuid)
        let reclaimedID = try #require(created[1].uuid)

        // One step is real work now — completed. Undo promised to reverse the split,
        // not to destroy something the user has since acted on.
        //
        // `complete()`, not `completeAndResurface(in:)`: the arm keys off `status.isResolved`,
        // so resurfacing dependents is setup this case never reads.
        created[0].complete()
        try context.save()

        let entry = try #require(try entries(in: context).first { $0.action == "split" })
        ChangeLogUndo.revert(entry, in: context)
        try context.save()

        let remaining = TaskItem.fetchAll(in: context)
        #expect(remaining.contains { $0.uuid == touchedID })  // kept
        #expect(!remaining.contains { $0.uuid == reclaimedID })  // reclaimed
    }

    // MARK: - Ranking: the umbrella steps back

    @Test("A parent with open children ranks below the same task without them")
    func containerRecedes() {
        let context = context()
        let now = Date()
        let plain = TaskItem(title: "Renew passport", status: .todo, createdAt: now, in: context)
        let parent = TaskItem(title: "Plan the trip", status: .todo, createdAt: now, in: context)
        context.insert(plain)
        context.insert(parent)
        parent.splitInto(steps(["Book flights"]), in: context)

        let all = TaskItem.fetchAll(in: context)
        let keys = TaskRanking.rankKeys(for: all, now: now)
        let parentKey = try? #require(keys[parent.uuid!])
        let plainKey = try? #require(keys[plain.uuid!])
        // Surfacing the umbrella alongside its own steps double-bills the same work.
        #expect((parentKey?.effectiveAttention ?? 0) < (plainKey?.effectiveAttention ?? 0))
    }

    @Test("The recede lifts once every child resolves — it reads the OPEN set")
    func containerLiftsWhenChildrenResolve() {
        let context = context()
        let now = Date()
        let parent = TaskItem(title: "Plan the trip", status: .todo, createdAt: now, in: context)
        context.insert(parent)
        let created = parent.splitInto(steps(["Book flights"]), in: context)

        let before = TaskRanking.rankKeys(for: TaskItem.fetchAll(in: context), now: now)
        created[0].complete(now: now)
        let after = TaskRanking.rankKeys(for: TaskItem.fetchAll(in: context), now: now)

        let id = parent.uuid!
        #expect((after[id]?.effectiveAttention ?? 0) > (before[id]?.effectiveAttention ?? 0))
    }
}
