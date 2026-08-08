//
//  DuplicateSweepTests.swift
//  Project-EzraTests
//
//  The sweep's sim-verifiable halves: the deterministic prefilter (floors,
//  missing-vector skip, suppression skip, cap, ordering), the kill-don't-delete
//  merge with its reversible entry, the full undo round-trip (loser reopened with
//  identity intact, winner's note stripped, pair suppressed so the prefilter
//  drops it forever), and the off-device gate (under XCTest the model is absent —
//  the whole sweep must be a no-op).
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct DuplicateSweepTests {

    private func snap(_ id: UUID, _ title: String) -> OpenTaskSnapshot {
        OpenTaskSnapshot(id: id, title: title)
    }

    /// A tiny injected vector table — unit vectors so similarity is exact.
    private func vectors(_ table: [String: [Double]]) -> (String) -> [Double]? {
        { table[$0] }
    }

    // MARK: - Prefilter

    @Test("Both floors must clear: near vectors alone or shared words alone are not a pair")
    func bothFloorsRequired() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // cos 0.99 maps to similarity ≈0.86 under the distance formula — above the
        // 0.82 floor. (cos 0.98 maps to 0.80, BELOW it — the floor is tight.)
        let table = [
            "renew my passport": [1.0, 0.0],
            "passport renewal": [0.99, 0.141],  // near vector + shared word → pair
            "book flights for the trip": [0.99, 0.141],  // near vector, NO shared words → lexical floor drops it
        ]
        let pairs = DuplicateSweep.candidatePairs(
            among: [
                snap(a, "renew my passport"), snap(b, "passport renewal"),
                snap(c, "book flights for the trip"),
            ],
            suppressions: [], vector: vectors(table))
        #expect(pairs.count == 1)
        #expect(Set([pairs[0].a.id, pairs[0].b.id]) == Set([a, b]))
    }

    @Test("A pair missing a vector is skipped — the sweep only reasons over evidence it has")
    func missingVectorSkips() {
        let pairs = DuplicateSweep.candidatePairs(
            among: [snap(UUID(), "renew my passport"), snap(UUID(), "passport renewal")],
            suppressions: [],
            vector: vectors(["renew my passport": [1.0, 0.0]]))  // second title unembedded
        #expect(pairs.isEmpty)
    }

    @Test("A suppressed pair never surfaces again")
    func suppressedPairDrops() {
        let a = UUID()
        let b = UUID()
        let table = [
            "renew my passport": [1.0, 0.0],
            "passport renewal": [0.98, 0.199],
        ]
        let suppression = RelationshipSuppression(
            kind: .duplicateMerge, pairKey: RelationshipSuppression.symmetricKey(a, b),
            targetID: nil, normalizedTitle: nil, createdAt: Date())
        let pairs = DuplicateSweep.candidatePairs(
            among: [snap(a, "renew my passport"), snap(b, "passport renewal")],
            suppressions: [suppression], vector: vectors(table))
        #expect(pairs.isEmpty)
    }

    @Test("Output is capped and best-first")
    func cappedAndOrdered() {
        // 30 identical-title clones → C(30,2) qualifying pairs; the cap holds.
        let clones = (0..<30).map { snap(UUID(), "renew passport \($0 % 2 == 0 ? "now" : "soon")") }
        var table: [String: [Double]] = [:]
        for clone in clones { table[clone.title] = [1.0, 0.0] }
        let pairs = DuplicateSweep.candidatePairs(
            among: clones, suppressions: [], vector: vectors(table))
        #expect(pairs.count == DuplicateSweep.maxPairsPerRun)
        #expect(pairs.map(\.score) == pairs.map(\.score).sorted(by: >))
    }

    // MARK: - Merge + undo round-trip

    @Test("Merge kills the newer task reversibly; undo reopens it, strips the note, and suppresses the pair")
    func mergeUndoRoundTrip() throws {
        let context = TestStore.makeContext()
        let older = TaskItem(
            title: "Renew my passport", status: .todo,
            createdAt: Date(timeIntervalSinceNow: -86_400), in: context)
        let newer = TaskItem(title: "Passport renewal", status: .todo, in: context)
        context.insert(older)
        context.insert(newer)
        try context.save()

        let pair = DuplicateSweep.CandidatePair(
            a: OpenTaskSnapshot(id: older.uuid!, title: older.title),
            b: OpenTaskSnapshot(id: newer.uuid!, title: newer.title), score: 0.95)
        #expect(DuplicateSweep.mergeJudgedPair(pair, in: context))

        // The older task won; the newer folded in, killed but never deleted.
        #expect(older.status == .todo)
        #expect(older.notes?.contains("Also captured: Passport renewal") == true)
        #expect(newer.status == .canceled)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let entry = try #require(entries.first { $0.action == "mergedPair" })
        #expect(entry.initiatedBy == .ai)
        #expect(entry.isReversible)
        #expect(entry.taskUUID == older.uuid)

        // Undo: the loser reopens with its identity (same row, same uuid), the
        // winner's absorbed note comes off, and the pair is suppressed.
        ChangeLogUndo.revert(entry, in: context)
        #expect(newer.status == .todo)
        #expect(newer.uuid != nil)
        #expect(older.notes?.contains("Also captured") != true)
        let suppressions = SuppressionStore.load(
            in: context, existingTaskIDs: [older.uuid!, newer.uuid!])
        #expect(
            suppressions.contains {
                $0.suppressesPair(kind: .duplicateMerge, older.uuid!, newer.uuid!)
            })

        // And the prefilter now drops the pair forever.
        let pairs = DuplicateSweep.candidatePairs(
            among: [pair.a, pair.b], suppressions: suppressions,
            vector: { _ in [1.0, 0.0] })
        #expect(pairs.isEmpty)
    }

    @Test("A judgment call is never the loser — the pair is skipped whole")
    func judgmentLoserSkips() throws {
        let context = TestStore.makeContext()
        let older = TaskItem(
            title: "Decide about the gym", status: .todo,
            createdAt: Date(timeIntervalSinceNow: -86_400), in: context)
        let newer = TaskItem(
            title: "Gym decision", status: .todo, isJudgmentCall: true, in: context)
        context.insert(older)
        context.insert(newer)
        try context.save()

        let pair = DuplicateSweep.CandidatePair(
            a: OpenTaskSnapshot(id: older.uuid!, title: older.title),
            b: OpenTaskSnapshot(id: newer.uuid!, title: newer.title), score: 0.95)
        #expect(!DuplicateSweep.mergeJudgedPair(pair, in: context))
        #expect(newer.status == .todo)  // untouched
    }

    // MARK: - The off-device gate

    @Test("With no model (XCTest), the whole sweep is a no-op")
    func offDeviceGate() async throws {
        let context = TestStore.makeContext()
        let a = TaskItem(title: "Renew my passport", status: .todo, in: context)
        let b = TaskItem(title: "Passport renewal", status: .todo, in: context)
        context.insert(a)
        context.insert(b)
        try context.save()

        let merges = await DuplicateSweep.run(in: context)
        #expect(merges == 0)
        #expect(a.status == .todo)
        #expect(b.status == .todo)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(entries.isEmpty)
    }
}
