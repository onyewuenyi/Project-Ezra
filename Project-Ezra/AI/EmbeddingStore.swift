//
//  EmbeddingStore.swift
//  Project-Ezra
//
//  The embedding cache behind `ContextRetrieval` — an implementation detail of
//  retrieval, NOT a public vector index (keep it private to this seam until a
//  second consumer genuinely needs raw vectors; that's the Knowledge-Engine
//  expansion's problem, not today's).
//
//  Why it exists: retrieval used to re-embed the query AND every open-task title on
//  every debounced triage tick, so capture latency scaled with store size. Now
//  vectors are computed once (`NLEmbedding.vector(for:)` + manual cosine), memoized
//  in-memory for the process, and persisted in their own `EmbeddingCache` entity —
//  deliberately its own entity so vectors never ride a task-list fetch.
//
//  Staleness needs no edit hooks: a row is valid iff its `sourceHash` matches the
//  hash of what we WOULD embed now, and its `revision` matches the current
//  `NLEmbedding` revision. Cross-revision cosine is MEANINGLESS (not merely
//  imprecise) — a mismatched row is deleted, never compared, not even once.
//
//  Concurrency (a deliberate deviation from "background context"): this codebase
//  runs ONE coordinator/context by design — multi-coordinator variants corrupt
//  Core Data class binding and have a real crash history here (see
//  `PersistenceStack.scratch`). So persistence stays on the app's write context at
//  the debounced triage seam (a handful of tiny rows, post-debounce, never per
//  keystroke), and the expensive part — vector computation — is memoized in-memory.
//  `ContextRetrieval` stays a sync pure function over these lookups.
//
//  Eviction: rows whose task is no longer in the open set are pruned at warm-up
//  (retrieval runs over the open set only). A REOPENED task therefore re-embeds on
//  its next capture — an accepted cost of evict-on-completion, not a cache bug.
//

import CoreData
import Foundation
import NaturalLanguage

// MARK: - Core Data row

@objc(EmbeddingCache)
final class EmbeddingCache: NSManagedObject {
    @NSManaged var taskID: UUID?
    @NSManaged var vector: Data?
    @NSManaged var sourceHash: String
    @NSManaged var revision: Int32
    @NSManaged var computedAt: Date?

    convenience init(
        taskID: UUID, vector: [Double], sourceHash: String, revision: Int,
        in context: NSManagedObjectContext
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "EmbeddingCache", in: context)!,
            insertInto: context)
        self.taskID = taskID
        self.vector = EmbeddingStore.encode(vector)
        self.sourceHash = sourceHash
        self.revision = Int32(revision)
        self.computedAt = Date()
    }
}

// MARK: - Store

enum EmbeddingStore {
    /// The current `NLEmbedding` model revision — rows from any other revision are stale.
    static let revision: Int = NLEmbedding.currentRevision(for: .english)

    /// The sentence-embedding model, loaded once per process. Nil when unavailable
    /// (the simulator) → retrieval degrades to lexical scoring.
    static let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)

    /// In-process memo: sourceHash → vector. The read-through layer that keeps
    /// `ContextRetrieval` synchronous. Bounded (reset at the cap) so a long session
    /// can't grow it without limit.
    private static var memo: [String: [Double]] = [:]
    private static let memoCap = 2048
    /// Hashes already persisted as rows, so `persistFresh` never re-fetches to check.
    private static var persistedHashes: Set<String> = []
    private static var warmedUp = false

    /// The hash of what we'd embed for this text — normalization shared with the
    /// suppression store keeps "what was embedded" stable across punctuation noise.
    /// FNV-1a, NOT `Hasher`: `Hasher` is randomly seeded per process, and this hash
    /// is persisted — it must match across launches or every row reads as stale.
    static func sourceHash(_ text: String) -> String {
        let normalized = RelationshipSuppression.normalizeTitle(text)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// Memo-only lookup — never computes. The retrieval budget uses this to tell a
    /// cache hit from a fresh embed.
    static func cachedVector(for text: String) -> [Double]? {
        memo[sourceHash(text)]
    }

    /// Compute (and memoize) the vector for `text`. Nil when the model is unavailable
    /// or declines the string.
    static func computeVector(for text: String) -> [Double]? {
        guard let embedding = sentenceEmbedding, let vector = embedding.vector(for: text) else {
            return nil
        }
        if memo.count >= memoCap { memo.removeAll(keepingCapacity: true) }
        memo[sourceHash(text)] = vector
        return vector
    }

    /// Similarity in [0, 1], reproducing the pre-cache scoring EXACTLY. Despite its
    /// `.cosine` name, `NLEmbedding.distance(between:and:)` returns the EUCLIDEAN
    /// distance of the normalized vectors, √(2 − 2·cos) — verified against the host
    /// model during implementation (max Δ < 1e-4; plain cosine differed by up to
    /// 0.5 and would have silently pushed unrelated pairs over the relevance floor
    /// while every test stayed green). Do NOT "fix" this to plain cosine without
    /// re-tuning the retrieval blend weights and `relevanceFloor` together.
    static func similarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var magA = 0.0
        var magB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        guard magA > 0, magB > 0 else { return 0 }
        let cosine = dot / (magA * magB).squareRoot()
        let distance = max(0, 2 - 2 * cosine).squareRoot()
        return max(0, min(1, 1 - distance))
    }

    // MARK: - Persistence (load at warm-up, write after triage; lazy eviction)

    /// Load persisted vectors for the open set into the memo. Rows with a stale
    /// `revision` are deleted unread (cross-revision cosine is meaningless); rows
    /// whose task has left the open set are evicted here (retrieval never needs
    /// them). Runs once per process — later captures ride the memo. Callers own
    /// `save()` (the triage seam saves at commit).
    /// Convenience for call sites that have a context but no snapshot yet (the
    /// capture prewarm): fetches the open set itself. The `warmedUp` guard makes
    /// repeat calls free, so this and the composer's snapshot-shaped call coexist —
    /// whichever runs first does the work.
    static func warmUp(in context: NSManagedObjectContext) {
        guard !warmedUp else { return }
        let open = TaskItem.fetchAll(in: context).filter { !$0.status.isResolved }
        warmUp(openTaskIDs: Set(open.compactMap(\.uuid)), in: context)
    }

    static func warmUp(openTaskIDs: Set<UUID>, in context: NSManagedObjectContext) {
        guard !warmedUp else { return }
        warmedUp = true
        let request = NSFetchRequest<EmbeddingCache>(entityName: "EmbeddingCache")
        let rows = (try? context.fetch(request)) ?? []
        for row in rows {
            let alive = row.taskID.map(openTaskIDs.contains) ?? false
            guard alive, row.revision == Int32(revision), let data = row.vector else {
                context.delete(row)
                continue
            }
            memo[row.sourceHash] = decode(data)
            persistedHashes.insert(row.sourceHash)
        }
    }

    /// Persist any freshly-computed vectors for the open set (memo entries with no
    /// row yet). Called after the debounced triage resolves — a handful of tiny rows
    /// on the app's write context, never per keystroke. The QUERY text is deliberately
    /// not persisted (it belongs to no task). Callers own `save()`.
    static func persistFresh(openTasks: [OpenTaskSnapshot], in context: NSManagedObjectContext) {
        for snap in openTasks {
            let hash = sourceHash(snap.title)
            guard let vector = memo[hash], !persistedHashes.contains(hash) else { continue }
            context.insert(
                EmbeddingCache(
                    taskID: snap.id, vector: vector, sourceHash: hash, revision: revision,
                    in: context))
            persistedHashes.insert(hash)
        }
    }

    // MARK: - Float32 codec (vectors stored compactly, computed as Double)

    static func encode(_ vector: [Double]) -> Data {
        vector.map(Float.init).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Double] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Float.self).map(Double.init)
        }
    }

    /// Test seam: drop all in-process state (memo + warm-up flag).
    static func resetForTesting() {
        memo.removeAll()
        persistedHashes.removeAll()
        warmedUp = false
    }
}
