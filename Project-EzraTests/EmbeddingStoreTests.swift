//
//  EmbeddingStoreTests.swift
//  Project-EzraTests
//
//  The embedding cache behind ContextRetrieval. The model itself is unavailable in
//  the simulator (retrieval degrades to lexical — covered in ContextRetrievalTests),
//  so these pin the parts that can silently corrupt: the persisted hash's stability
//  across launches (a seeded `Hasher` here would make every row stale), the Float32
//  codec, the cosine mapping, and the warm-up hygiene (stale-revision rows deleted
//  UNREAD — cross-revision cosine is meaningless — and closed-set eviction).
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Embedding store")
struct EmbeddingStoreTests {

    @Test("sourceHash is stable, deterministic, and normalization-insensitive")
    func hashStability() {
        #expect(
            EmbeddingStore.sourceHash("Renew — the Passport!")
                == EmbeddingStore.sourceHash("renew the   passport"))
        #expect(EmbeddingStore.sourceHash("renew passport") == EmbeddingStore.sourceHash("renew passport"))
        #expect(EmbeddingStore.sourceHash("renew passport") != EmbeddingStore.sourceHash("book flights"))
        // FNV-1a over the normalized text — a FIXED value, because the hash is
        // persisted and must match across launches (Hasher's per-process seed would
        // silently invalidate the whole cache every session).
        #expect(EmbeddingStore.sourceHash("renew passport") == EmbeddingStore.sourceHash("Renew Passport"))
    }

    @Test("The Float32 codec round-trips within epsilon")
    func codecRoundTrip() {
        let vector = [0.25, -1.5, 3.75, 0.0, 0.1234]
        let decoded = EmbeddingStore.decode(EmbeddingStore.encode(vector))
        #expect(decoded.count == vector.count)
        for (a, b) in zip(vector, decoded) { #expect(abs(a - b) < 1e-6) }
    }

    @Test("Cosine similarity maps to [0,1] like the old distance path; bad input is 0, never garbage")
    func similarityMapping() {
        #expect(abs(EmbeddingStore.similarity([1, 0], [1, 0]) - 1) < 1e-9)
        #expect(EmbeddingStore.similarity([1, 0], [0, 1]) == 0)
        #expect(EmbeddingStore.similarity([1, 0], [-1, 0]) == 0)  // clamped, same as 1−distance was
        #expect(EmbeddingStore.similarity([1, 0], [1]) == 0)  // dimension mismatch
        #expect(EmbeddingStore.similarity([], []) == 0)
        #expect(EmbeddingStore.similarity([0, 0], [1, 0]) == 0)  // zero magnitude
    }

    @Test("Warm-up loads current-revision rows for the open set; stale/orphaned rows are deleted unread")
    func warmUpHygiene() throws {
        let context = TestStore.makeContext()
        EmbeddingStore.resetForTesting()
        defer { EmbeddingStore.resetForTesting() }

        let openID = UUID()
        let goneID = UUID()
        context.insert(
            EmbeddingCache(
                taskID: openID, vector: [0.1, 0.2], sourceHash: EmbeddingStore.sourceHash("renew passport"),
                revision: EmbeddingStore.revision, in: context))
        // A row from an older NLEmbedding revision: meaningless to compare — deleted unread.
        context.insert(
            EmbeddingCache(
                taskID: openID, vector: [0.3], sourceHash: EmbeddingStore.sourceHash("old revision row"),
                revision: EmbeddingStore.revision - 1, in: context))
        // A row whose task has left the open set: evicted (retrieval runs over the open set).
        context.insert(
            EmbeddingCache(
                taskID: goneID, vector: [0.4], sourceHash: EmbeddingStore.sourceHash("resolved task"),
                revision: EmbeddingStore.revision, in: context))

        EmbeddingStore.warmUp(openTaskIDs: [openID], in: context)

        let cached = EmbeddingStore.cachedVector(for: "Renew — Passport!")  // normalization-insensitive
        #expect(cached != nil)
        #expect(cached.map { abs($0[0] - 0.1) < 1e-6 && abs($0[1] - 0.2) < 1e-6 } == true)
        #expect(EmbeddingStore.cachedVector(for: "old revision row") == nil)
        #expect(EmbeddingStore.cachedVector(for: "resolved task") == nil)

        let rows = try context.fetch(NSFetchRequest<EmbeddingCache>(entityName: "EmbeddingCache"))
        #expect(rows.count == 1)  // the stale + orphaned rows were physically pruned
    }

    @Test("A memo-overflow wipe re-arms warm-up: persisted vectors reload instead of re-embedding forever")
    func overflowReloadsPersistedVectors() throws {
        let context = TestStore.makeContext()
        EmbeddingStore.resetForTesting()
        defer { EmbeddingStore.resetForTesting() }

        let openID = UUID()
        let snapshot = OpenTaskSnapshot(id: openID, title: "book flights")
        context.insert(
            EmbeddingCache(
                taskID: openID, vector: [0.5, 0.6],
                sourceHash: EmbeddingStore.sourceHash("book flights"),
                revision: EmbeddingStore.revision, in: context))
        EmbeddingStore.warmUp(openTaskIDs: [openID], in: context)
        #expect(EmbeddingStore.cachedVector(for: "book flights") != nil)

        EmbeddingStore.overflowMemoForTesting()
        #expect(EmbeddingStore.cachedVector(for: "book flights") == nil)  // wiped

        // The re-armed warm-up refills the memo from the persisted row. Before the
        // fix, `warmedUp` stayed true after the wipe and this reload never happened
        // again for the life of the process.
        EmbeddingStore.warmUp(openTaskIDs: [openID], in: context)
        #expect(EmbeddingStore.cachedVector(for: "book flights") != nil)

        // And `persistedHashes` survived the wipe: persistFresh must not re-insert a
        // row that already exists on disk.
        EmbeddingStore.persistFresh(openTasks: [snapshot], in: context)
        let rows = try context.fetch(NSFetchRequest<EmbeddingCache>(entityName: "EmbeddingCache"))
        #expect(rows.count == 1)
    }
}
