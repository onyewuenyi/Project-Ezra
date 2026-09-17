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

    @Test("The lexical floor gates; the embedding only ranks")
    func lexicalGatesEmbeddingRanks() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        // Real device vectors (2026-09-17) put "renew my passport / passport renewal" at
        // similarity 0.17 — far below the old 0.82 embedding floor — while the judge
        // scored the pair 1.00. The gate admits the paraphrase on its shared word; a
        // near vector with NO shared words is still not a pair.
        let table = [
            "renew my passport": [1.0, 0.0],
            "passport renewal": [0.0, 1.0],  // orthogonal vector + shared word → pair
            "book flights for the trip": [0.99, 0.141],  // near vector, NO shared words → dropped
            "passport photos": [0.99, 0.141],  // near vector + shared word → pair, ranked first
        ]
        let pairs = DuplicateSweep.candidatePairs(
            among: [
                snap(a, "renew my passport"), snap(b, "passport renewal"),
                snap(c, "book flights for the trip"), snap(d, "passport photos"),
            ],
            suppressions: [], vector: vectors(table))
        let keys = Set(pairs.map { Set([$0.a.id, $0.b.id]) })
        #expect(keys.contains(Set([a, b])))
        #expect(keys.contains(Set([a, d])))
        #expect(!keys.contains(where: { $0.contains(c) }))
        // Ranking: same overlap, the nearer vector sorts first.
        #expect(Set([pairs[0].a.id, pairs[0].b.id]) == Set([a, d]))
    }

    @Test("Any faster candidatePairs must return exactly what the naive one does")
    func fastPathMatchesTheNaiveOne() {
        // THE ORACLE for `candidatePairs` (88ms for 206 tasks before 2026-09-12, 23ms
        // after). The rewrite is a pure reordering of an AND plus hoisting per-snapshot
        // work out of the pair loop, so its output must be identical to the original
        // loop — which is kept here verbatim, run over a seeded pseudo-random store where
        // a meaningful share of pairs clears one floor but not the other. A sweep that
        // merges the user's tasks must not change which pairs it finds as a side effect
        // of getting faster.
        func naive(
            _ snapshots: [OpenTaskSnapshot], vector: (String) -> [Double]?
        ) -> [(UUID, UUID, Double)] {
            var out: [(UUID, UUID, Double)] = []
            for i in snapshots.indices {
                let va = vector(snapshots[i].title)
                let wa = CorrectionProfile.significantWords(snapshots[i].title)
                guard !wa.isEmpty else { continue }
                for j in snapshots.indices where j > i {
                    let vb = vector(snapshots[j].title)
                    let wb = CorrectionProfile.significantWords(snapshots[j].title)
                    guard !wb.isEmpty else { continue }
                    let overlap = Double(wa.intersection(wb).count)
                    let union = Double(wa.union(wb).count)
                    let lexical = union > 0 ? overlap / union : 0
                    guard lexical >= DuplicateSweep.lexicalFloor else { continue }
                    let sim = (va != nil && vb != nil) ? EmbeddingStore.similarity(va!, vb!) : 0
                    out.append((snapshots[i].id, snapshots[j].id, lexical + sim))
                }
            }
            return out
        }

        // Deterministic LCG so the fixture is the same on every run.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let words = ["renew", "passport", "book", "flights", "call", "dentist", "pay", "bill", "fix", "tap"]
        var table: [String: [Double]] = [:]
        var snapshots: [OpenTaskSnapshot] = []
        for _ in 0..<80 {
            let count = 1 + Int(next() * 3)
            let title = (0..<count).map { _ in words[Int(next() * Double(words.count))] }.joined(
                separator: " ")
            // Two clusters of vectors so some pairs are near and most are not.
            let angle = next() < 0.5 ? next() * 0.2 : 1.0 + next() * 0.2
            table[title] = [cos(angle), sin(angle)]
            snapshots.append(OpenTaskSnapshot(id: UUID(), title: title))
        }
        let vector: (String) -> [Double]? = { table[$0] }

        // The production function sorts best-first (uuid tiebreak) and caps at
        // `maxPairsPerRun`; the oracle must too, or it compares 20 pairs against every
        // pair and fails against the ORIGINAL loop — which is exactly how the first
        // shape of this test misreported a correct rewrite as a broken one.
        let expected = Array(
            naive(snapshots, vector: vector)
                .sorted {
                    if $0.2 != $1.2 { return $0.2 > $1.2 }
                    return $0.0.uuidString < $1.0.uuidString
                }
                .prefix(DuplicateSweep.maxPairsPerRun))
        let actual = DuplicateSweep.candidatePairs(among: snapshots, suppressions: [], vector: vector)
        // Compare as sets keyed on the pair, with the score — the sort is the same in both.
        let expectedKeys = Set(expected.map { "\($0.0)|\($0.1)|\($0.2)" })
        let actualKeys = Set(actual.map { "\($0.a.id)|\($0.b.id)|\($0.score)" })
        #expect(actualKeys == expectedKeys)
        // And the fixture actually exercised both floors, or the parity proves nothing.
        #expect(!expected.isEmpty, "the fixture produced no pairs — widen the clusters")
        #expect(expected.count < 80 * 79 / 2, "every pair passed — the gate was not exercised")
    }

    @Test("A pair missing a vector is still a pair — it ranks on overlap alone")
    func missingVectorStillGates() {
        // The embedding is a tiebreak, not evidence the gate needs: a cold cache or the
        // accessor's first-call nil must not drop a pair the words admitted.
        let a = UUID()
        let b = UUID()
        let pairs = DuplicateSweep.candidatePairs(
            among: [snap(a, "renew my passport"), snap(b, "passport renewal")],
            suppressions: [],
            vector: vectors(["renew my passport": [1.0, 0.0]]))  // second title unembedded
        #expect(pairs.count == 1)
        #expect(abs(pairs[0].score - 1.0 / 3.0) < 0.001)
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
