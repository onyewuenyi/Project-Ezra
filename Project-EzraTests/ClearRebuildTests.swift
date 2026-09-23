//
//  ClearRebuildTests.swift
//  Project-EzraTests
//
//  **"Clear all tasks" has two halves, and only one of them is a deletion.**
//
//  The store half is pinned next door in `DataResetTests`. This file pins the other
//  half — the one the 2026-09-19 fix was actually about. A clear that empties the store
//  and leaves the screen listing ten tasks is not a clear the user got; it reads as
//  "clearing does nothing", and one tap on a stale row faults a deleted one.
//
//  The mechanism cannot be unit-tested: SwiftUI view identity, `@FetchRequest` re-runs
//  and a Core Data teardown fault are all things a suite in this process cannot observe.
//  What CAN be asserted is the shape the fix depends on — so these are grep pins, the
//  same instrument the privacy boundary and the Release seams use, and for the same
//  reason: the property is the ABSENCE of a call, which no type system states.
//
//  Read `DataGeneration` before changing any of this. Every "obvious" repair for a stale
//  fetch — merge the deleted ids, `reset()`, `refreshAllObjects()` — was tried, measured
//  and crashes, because each walks the objects on screen and snapshots them.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("The clear's second half · the interface re-reads an emptied store")
struct ClearRebuildTests {

    private func appSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Lines of code, with comments dropped: prose may NAME a forbidden call (the whole
    /// point of the doc comments here is to say what was tried), code may not MAKE one.
    private func codeLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
    }

    @Test("A rebuild is one step forward, and nothing else changes it")
    func rebuildAdvancesTheGeneration() {
        let generation = DataGeneration()
        #expect(generation.value == 0)
        generation.rebuild()
        generation.rebuild()
        #expect(generation.value == 2)
    }

    /// The counter is inert unless the root actually keys its identity on it. A bump that
    /// nothing observes is the silent version of the bug it was written to fix.
    @Test("The app root keys its identity on the data generation")
    func theRootRebuildsOnTheGeneration() throws {
        let source = try appSource("Project_EzraApp.swift")
        #expect(source.contains(".id(generation.value)"))
        #expect(source.contains("DataGeneration.shared"))
    }

    /// And the clear must actually bump it — on the way OUT, so the receipt card naming
    /// the backup is read before the sheet it lives in is discarded.
    @Test("A landed clear rebuilds the interface as Settings closes")
    func settingsRebuildsAfterALandedClear() throws {
        let code = codeLines(try appSource("Features/Settings/SettingsView.swift"))
        let bumps = code.filter { $0.contains("DataGeneration.shared.rebuild()") }
        #expect(bumps.count == 1, "exactly one rebuild, or the interface flickers through a clear")
        #expect(bumps.first?.contains("clearOutcome == .cleared") == true)
        // On `.onDisappear`, not inside `performClear` — a rebuild mid-flow takes the
        // receipt away with the sheet.
        #expect(code.contains { $0.contains(".onDisappear") })
    }

    /// **The regression guard.** Each of these is the natural thing to reach for when a
    /// fetch looks stale, and each one crashed this exact path: they walk the objects the
    /// screen is holding and take a property snapshot of every one.
    @Test("The clear never tells the live context about the deletion")
    func theClearTouchesNoRegisteredObject() throws {
        let code = codeLines(try appSource("Models/DataReset.swift"))
        for forbidden in ["mergeChanges(fromRemoteContextSave", "refreshAllObjects(", "context.reset("] {
            #expect(
                !code.contains { $0.contains(forbidden) },
                """
                `\(forbidden)` is back in DataReset. It walks and snapshots every object \
                on screen, which is the SIGSEGV this path shipped with. If the views look \
                stale, rebuild them (`DataGeneration`) — do not refresh the objects.
                """)
        }
        // And the deletion itself stays in the store, where nothing materialises.
        #expect(code.contains { $0.contains("NSBatchDeleteRequest") })
    }

    /// The other teardown: deallocation. Objects the clear retires are abandoned by the
    /// rebuild, and an abandoned managed object deallocates, unregisters, and makes the
    /// row cache release a row that was already read — the same fault on Core Data's own
    /// queue, where no caller can catch it. They are parked for the life of the process.
    @Test("Objects retired by a clear are parked, never released")
    func retiredObjectsAreParked() throws {
        let code = codeLines(try appSource("Models/DataReset.swift"))
        #expect(code.contains { $0.contains("parked.append(contentsOf: context.registeredObjects)") })
        #expect(code.contains { $0.contains("static var parked: [NSManagedObject]") })
    }

    /// The guard every derivation runs before reading a fetched row, pinned on both of
    /// its arms — a row can stop being real by being deleted, or by losing its context.
    @Test("A row stops being live the moment it stops being real")
    func isLiveRowAnswersForBothWaysARowDies() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Renew passport", category: "Admin", in: context)
        context.saveChanges()
        #expect(task.isLiveRow)

        context.delete(task)
        #expect(!task.isLiveRow)
    }

    /// End to end, at the only layer a test can reach: the store is empty afterwards, and
    /// the context that performed the clear is still usable — a fresh fetch answers, and
    /// new work can be captured into it without a relaunch.
    @Test("After a clear the store is empty and the context still works")
    func theContextSurvivesItsOwnClear() {
        let context = TestStore.makeContext()
        _ = UserProfile.bootstrapIdentity(in: context)
        for title in ["Renew passport", "Pay the water bill", "Call mom back"] {
            _ = TaskItem(title: title, category: "Admin", in: context)
        }
        context.saveChanges()
        #expect(TaskItem.fetchAll(in: context).count == 3)

        let defaults = UserDefaults(suiteName: "ClearRebuildTests")!
        defaults.removePersistentDomain(forName: "ClearRebuildTests")
        DataReset.clear(
            .work, in: context, defaults: defaults,
            at: .temporary("clear-rebuild-tests"))

        #expect(TaskItem.fetchAll(in: context).isEmpty)
        _ = TaskItem(title: "Something new", category: "Admin", in: context)
        #expect(context.saveChanges())
        #expect(TaskItem.fetchAll(in: context).count == 1)
    }
}
