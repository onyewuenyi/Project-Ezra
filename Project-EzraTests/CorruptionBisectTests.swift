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

    @Test("D: split + SAVE + fetch + read newValue, then wipe")
    func savedReadThenWipe() throws {
        let context = TestStore.makeContext()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        _ = parent.splitInto(steps(["A", "B", "C"]), in: context)
        context.saveChanges()
        let splits = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
            .filter { $0.action == "split" }
        let entry = try #require(splits.first)
        let s = entry.newValue ?? ""
        #expect(s.count > 10)
        _ = TestStore.makeContext()
    }

    @Test("E: app path — read long titles, then DataReset.clear")
    func appClearAfterLongStringReads() throws {
        let context = TestStore.makeContext()
        let defaults = UserDefaults(suiteName: "CorruptionBisectTests.E")!
        defaults.removePersistentDomain(forName: "CorruptionBisectTests.E")
        for i in 0..<5 {
            let task = TaskItem(
                title: "A deliberately long task title that lives on the heap #\(i)",
                in: context)
            context.insert(task)
        }
        context.saveChanges()
        // The poison: read the heap-length strings back, the way the app's UI does all day.
        let all = try context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))
        #expect(all.map(\.title).allSatisfy { $0.count > 20 })
        // The detonator candidate: the Settings clear deletes every object of every entity.
        DataReset.clear(
            .work, in: context, defaults: defaults,
            at: .temporary("corruption-bisect-e"))
        let count =
            (try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "TaskItem"))) ?? -1
        #expect(count == 0)
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
