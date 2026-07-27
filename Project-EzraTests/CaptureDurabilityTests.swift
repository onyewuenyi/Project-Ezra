//
//  CaptureDurabilityTests.swift
//  Project-EzraTests
//
//  The promise: a thought you rambled but never confirmed survives an interruption.
//
//  Before this, drafts lived in composer `@State` on a sheet with interactive
//  dismissal, and the `Capture` row was written only inside `commit` — so a swipe-down
//  destroyed the raw text outright. With `.inbox` gone there is nothing else to catch
//  it, which is why the parked row IS the pre-Confirm representation.
//
//  Two invariants here are load-bearing and easy to regress:
//
//  - a parked capture is NOT a task (no `TaskItem`, nothing in any list),
//  - draft ids survive the encode→decode round trip. `TaskDraft.id` had to become
//    `var`, because synthesized `Codable` silently skips an immutable property with an
//    initial value: it compiles, encodes fine, and mints fresh ids on every restore.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CaptureDurabilityTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func draft(_ title: String) -> TaskDraft {
        TaskDraft(
            title: title, category: "Admin", confidence: 0.9, autonomy: .silent,
            isJudgmentCall: false, reasoning: "")
    }

    private func captures(in context: NSManagedObjectContext) throws -> [Capture] {
        try context.fetch(NSFetchRequest<Capture>(entityName: "Capture"))
    }

    private func tasks(in context: NSManagedObjectContext) throws -> [TaskItem] {
        try context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))
    }

    // MARK: - Parking

    @Test("Parking keeps the raw text and the drafts — and creates NO task")
    func parkCreatesNoTask() throws {
        let context = context()
        let brain = AppBrain()

        let parked = brain.park(
            [draft("call the vet")], rawCapture: "call the vet about the cat",
            source: .text, into: nil, in: context)

        let capture = try #require(parked)
        #expect(capture.rawText == "call the vet about the cat")
        #expect(capture.isParked)
        #expect(capture.parkedDrafts?.count == 1)
        // The whole point: a parked capture has never been through Confirm, so it must
        // not exist as work anywhere.
        #expect(try tasks(in: context).isEmpty)
    }

    @Test("Re-parking the same session updates one row, never a second")
    func reparkingIsIdempotent() throws {
        let context = context()
        let brain = AppBrain()

        let first = brain.park(
            [draft("call vet")], rawCapture: "call vet", source: .text, into: nil, in: context)
        let second = brain.park(
            [draft("call the vet"), draft("buy food")], rawCapture: "call the vet, buy food",
            source: .text, into: first, in: context)

        #expect(try captures(in: context).count == 1)
        #expect(second?.parkedDrafts?.count == 2)
        #expect(second?.rawText == "call the vet, buy food")
    }

    @Test("Two interruptions park two captures — the first is never overwritten")
    func multipleParksCoexist() throws {
        let context = context()
        let brain = AppBrain()

        brain.park([draft("a")], rawCapture: "thought one", source: .text, into: nil, in: context)
        brain.park([draft("b")], rawCapture: "thought two", source: .text, into: nil, in: context)

        // Being interrupted twice is ordinary, and an implementation that forced a
        // discard or silently overwrote would reintroduce the exact loss this prevents.
        let parked = AppBrain.parkedCaptures(in: context)
        #expect(parked.count == 2)
        #expect(Set(parked.map(\.rawText)) == ["thought one", "thought two"])
    }

    @Test("Empty text parks nothing")
    func emptyTextParksNothing() throws {
        let context = context()
        let brain = AppBrain()
        #expect(brain.park([], rawCapture: "   ", source: .text, into: nil, in: context) == nil)
        #expect(try captures(in: context).isEmpty)
    }

    // MARK: - Round-tripping the drafts

    @Test("Draft ids survive encode → decode (the `let id = UUID()` Codable trap)")
    func draftIDsSurviveRoundTrip() throws {
        let context = context()
        let brain = AppBrain()
        let original = [draft("one"), draft("two")]

        let capture = try #require(
            brain.park(original, rawCapture: "one, two", source: .text, into: nil, in: context))
        let restored = try #require(capture.parkedDrafts)

        #expect(restored.map(\.id) == original.map(\.id))
        #expect(restored.map(\.title) == ["one", "two"])
    }

    @Test("Edited fields survive the round trip, not just the AI's originals")
    func editsSurviveRoundTrip() throws {
        let context = context()
        let brain = AppBrain()
        var edited = draft("call vet")
        edited.title = "Call the vet about Maple"
        edited.isUrgent = true
        edited.effortMinutes = 15

        let capture = try #require(
            brain.park([edited], rawCapture: "call vet", source: .text, into: nil, in: context))
        let restored = try #require(capture.parkedDrafts?.first)

        #expect(restored.title == "Call the vet about Maple")
        #expect(restored.isUrgent)
        #expect(restored.effortMinutes == 15)
    }

    @Test("editedFields survives the round trip — the merge's authority must not reset on resume")
    func editedFieldsSurviveRoundTrip() throws {
        let context = context()
        let brain = AppBrain()
        var edited = draft("call vet")
        edited.title = "Call the vet about Maple"
        edited.markEdited(.title)
        edited.markEdited(.isUrgent)

        let capture = try #require(
            brain.park([edited], rawCapture: "call vet", source: .text, into: nil, in: context))
        let restored = try #require(capture.parkedDrafts?.first)

        #expect(restored.editedFields == [.title, .isUrgent])
        #expect(restored.userEdited(.title))
        #expect(!restored.userEdited(.category))
    }

    @Test("An unreadable payload degrades to nil so the caller re-parses from rawText")
    func corruptPayloadDegradesGracefully() throws {
        let context = context()
        let brain = AppBrain()
        let capture = try #require(
            brain.park([draft("x")], rawCapture: "the raw thought", source: .text, into: nil, in: context))

        capture.setValue(Data("not json".utf8), forKey: "draftsData")

        // `rawText` is the irreplaceable part; drafts are derived, so losing them must
        // never mean losing the thought.
        #expect(capture.parkedDrafts == nil)
        #expect(capture.rawText == "the raw thought")
    }

    @Test("A payload from another envelope version is discarded, not misread")
    func versionMismatchIsDiscarded() throws {
        let context = context()
        let brain = AppBrain()
        let capture = try #require(
            brain.park([draft("x")], rawCapture: "raw", source: .text, into: nil, in: context))

        // A decode that SUCCEEDS but means something different is worse than one that
        // throws — that is the whole reason for the version envelope.
        let forged = try JSONEncoder().encode(
            ParkedDrafts(version: ParkedDrafts.currentVersion + 1, drafts: [draft("stale")]))
        capture.setValue(forged, forKey: "draftsData")

        #expect(capture.parkedDrafts == nil)
    }

    // MARK: - Commit and discard

    @Test("Commit adopts the parked row — one Capture per event, never two")
    func commitAdoptsParkedRow() throws {
        let context = context()
        let brain = AppBrain()
        let parked = brain.park(
            [draft("call vet")], rawCapture: "call vet", source: .text, into: nil, in: context)

        let created = brain.commit(
            [draft("call vet")], rawCapture: "call vet", parked: parked, into: context)

        #expect(try captures(in: context).count == 1)
        #expect(created.count == 1)
        #expect(created[0].status == .todo)
        // No longer parked: committed, and its derived drafts are spent.
        let capture = try #require(try captures(in: context).first)
        #expect(!capture.isParked)
        #expect(capture.committedAt != nil)
        #expect(AppBrain.parkedCaptures(in: context).isEmpty)
    }

    @Test("Parking into a committed row is a no-op — spent history is never rewritten")
    func parkIntoCommittedRowIsANoOp() throws {
        let context = context()
        let brain = AppBrain()
        let parked = brain.park(
            [draft("call vet")], rawCapture: "call vet", source: .text, into: nil, in: context)
        brain.commit([draft("call vet")], rawCapture: "call vet", parked: parked, into: context)
        let committed = try #require(parked)

        // The FAB-after-resume bug handed a committed row back to a new session.
        // Parking into it must refuse: no re-park, no rawText rewrite, no second row.
        let result = brain.park(
            [draft("something new")], rawCapture: "something entirely new",
            source: .text, into: committed, in: context)

        #expect(result === committed)
        #expect(committed.rawText == "call vet")
        #expect(!committed.isParked)
        #expect(committed.committedAt != nil)
        #expect(try captures(in: context).count == 1)
    }

    @Test("Parking into a deleted row mints a fresh one — the thought survives")
    func parkIntoDeletedRowMintsAFreshOne() throws {
        let context = context()
        let brain = AppBrain()
        let parked = try #require(
            brain.park([draft("x")], rawCapture: "doomed", source: .text, into: nil, in: context))
        AppBrain.discard(parked, in: context)

        let result = brain.park(
            [draft("y")], rawCapture: "a new thought", source: .text, into: parked, in: context)

        let fresh = try #require(result)
        #expect(fresh !== parked)
        #expect(fresh.rawText == "a new thought")
        #expect(fresh.isParked)
        #expect(try captures(in: context).count == 1)
    }

    @Test("Discard is the only destructive path")
    func discardDeletes() throws {
        let context = context()
        let brain = AppBrain()
        let parked = try #require(
            brain.park([draft("x")], rawCapture: "regrettable", source: .text, into: nil, in: context))

        AppBrain.discard(parked, in: context)

        #expect(try captures(in: context).isEmpty)
        #expect(AppBrain.parkedCaptures(in: context).isEmpty)
    }

    // MARK: - Decay (the surface must not grow forever)

    @Test("A long-parked capture is pruned reversibly, keeping the raw text")
    func stalePruneIsLoggedAndReversible() throws {
        let context = context()
        let brain = AppBrain()
        let now = Date()
        let capture = try #require(
            brain.park(
                [draft("x")], rawCapture: "an old thought", source: .text, into: nil, in: context))
        capture.createdAt = now.addingTimeInterval(-40 * 24 * 3600)

        let result = BrainSweeps.run(in: context, now: now)
        #expect(result.prunedCaptures.count == 1)
        #expect(!capture.isParked)
        // The surface decays; the thought does not.
        #expect(capture.rawText == "an old thought")

        // And a silent prune would reintroduce the very failure this phase prevents, on
        // a longer clock — so it is a normal reversible feed entry.
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let entry = try #require(entries.first { $0.action == "prunedCapture" })
        #expect(entry.isReversible)
        #expect(entry.initiatedBy == .ai)

        ChangeLogUndo.revert(entry, in: context)
        #expect(capture.isParked)
    }

    @Test("A recently parked capture is left alone")
    func freshParkSurvivesTheSweep() throws {
        let context = context()
        let brain = AppBrain()
        let capture = try #require(
            brain.park([draft("x")], rawCapture: "fresh", source: .text, into: nil, in: context))

        let result = BrainSweeps.run(in: context, now: Date())
        #expect(result.prunedCaptures.isEmpty)
        #expect(capture.isParked)
    }
}
