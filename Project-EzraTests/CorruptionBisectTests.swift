//
//  CorruptionBisectTests.swift
//  Project-EzraTests
//
//  TEMPORARY diagnostic suite — bisects the operation that poisons the shared scratch
//  context (the makeContext EXC_BAD_ACCESS crash history). Each test performs one
//  increment of BreakdownSplitTests.oneReversibleEntry's body, then calls
//  TestStore.makeContext() ITSELF, so a poisoned object detonates inside the same test
//  and the crash attributes to the exact increment. Delete this file once the culprit
//  is found.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CorruptionBisectTests {

    private func steps(_ titles: [String]) -> [BreakdownStep] {
        titles.map { BreakdownStep(title: $0, effortMinutes: 30) }
    }

    @Test("A: split only, then wipe")
    func splitOnlyThenWipe() {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        _ = TestStore.makeContext()
    }

    @Test("B: split + fetch entries, then wipe")
    func splitPlusFetchThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        let all = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(!all.isEmpty)
        _ = TestStore.makeContext()
    }

    @Test("C1: split + fetch + filter on action, then wipe")
    func filterOnActionThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        let splits = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == "split" }
        #expect(splits.count == 1)
        _ = TestStore.makeContext()
    }

    @Test("C2: + isReversible and initiatedBy reads, then wipe")
    func scalarAndEnumReadsThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        let splits = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == "split" }
        let entry = try #require(splits.first)
        #expect(entry.isReversible)
        #expect(entry.initiatedBy == .human)
        _ = TestStore.makeContext()
    }

    @Test("C3a: newValue plain read, then wipe")
    func newValuePlainReadThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        let splits = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == "split" }
        let entry = try #require(splits.first)
        let s = entry.newValue ?? ""
        #expect(s.count > 10)
        _ = TestStore.makeContext()
    }

    @Test("C3b: newValue split discarded, then wipe")
    func newValueSplitDiscardedThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        let splits = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == "split" }
        let entry = try #require(splits.first)
        let parts = (entry.newValue ?? "").split(separator: ",")
        #expect(parts.count == 3)
        _ = TestStore.makeContext()
    }

    @Test("C3c: newValue components(separatedBy:), then wipe")
    func newValueComponentsThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        let splits = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == "split" }
        let entry = try #require(splits.first)
        let ids = (entry.newValue ?? "").components(separatedBy: ",")
        #expect(ids.count == 3)
        _ = TestStore.makeContext()
    }

    @Test("C4: + child uuid reads, then wipe")
    func childUUIDReadsThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        let created = parent.splitInto(steps(["A", "B", "C"]), in: context)
        #expect(Set(created.compactMap { $0.uuid?.uuidString }).count == 3)
        _ = TestStore.makeContext()
    }
}
