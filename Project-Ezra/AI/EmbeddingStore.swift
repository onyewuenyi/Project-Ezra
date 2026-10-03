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
    nonisolated static let revision: Int = NLEmbedding.currentRevision(for: .english)

    /// The sentence-embedding model. **A retrying accessor, not a `static let` — and the
    /// difference was weeks of silently-degraded retrieval on the dogfooding phone.**
    ///
    /// `NLEmbedding.sentenceEmbedding(for: .english)` returns nil on the FIRST call in a
    /// process and succeeds on a later one — measured on an iPhone 15 Pro Max, iOS 27.0,
    /// 2026-09-12 (`-EmbeddingDiag`: a direct call at the top of the seam → NIL; the same
    /// call seconds later → present, dim 512, `vector(for:)` OK; the assets were there
    /// throughout). The old `static let` was touched at launch by `AppBrain.prewarm`, so it
    /// captured that first nil and served it for the life of the process: retrieval fell
    /// to lexical scoring, `DuplicateSweep` skipped every pair for want of a vector, and
    /// the device store held **0 `EmbeddingCache` rows against 70 tasks**. The header
    /// used to say nil meant "the simulator". It meant every launch.
    ///
    /// Now: a successful load is cached forever; a nil is retried on the next access. The
    /// lookup is a catalog check, not a model load, so re-asking is cheap, and a process
    /// that never gets one still degrades exactly as before — the change is that it now
    /// RECOVERS. `nonisolated(unsafe)` because NLEmbedding is not marked Sendable and not
    /// documented thread-safe — which is exactly why `lock` is held across every
    /// `vector(for:)` call, and why this accessor takes it too.
    nonisolated static var sentenceEmbedding: NLEmbedding? {
        lock.withLock {
            if let loaded = loadedSentenceEmbedding { return loaded }
            let attempt = NLEmbedding.sentenceEmbedding(for: .english)
            loadedSentenceEmbedding = attempt
            sentenceEmbeddingAttempts += 1
            return attempt
        }
    }
    nonisolated(unsafe) private static var loadedSentenceEmbedding: NLEmbedding?
    /// How many times the lookup has been asked — the meter's way of saying "nil and
    /// never retried" from "nil so far".
    nonisolated(unsafe) private(set) static var sentenceEmbeddingAttempts = 0

    /// Ask until the lookup answers, or give up after `attempts`. The first lookup in a
    /// process can be nil; the second is usually not. `AppBrain.prewarm` retries once
    /// after a pause, and tests that compare two retrievals call this first so both see
    /// the same world. Returns whether an embedding is available afterwards.
    @discardableResult
    nonisolated static func settle(attempts: Int = 3) -> Bool {
        // At most `attempts` lookups. The old loop asked once more in its `return`, so a phone or
        // fresh simulator with no embedding asset made 4 lookups against a budget of 3.
        for _ in 0..<attempts where sentenceEmbedding != nil { return true }
        return false
    }

    /// The DEBUG diagnostics line. The degrade this store performs is graceful by design,
    /// and a graceful degrade with no meter is how it stayed off for weeks.
    static func statusLine() -> String {
        let available = sentenceEmbedding != nil
        let cached = lock.withLock { memo.count }
        return
            "sentence embedding: \(available ? "available" : "UNAVAILABLE") · "
            + "\(cached) cached vector\(cached == 1 ? "" : "s") · \(sentenceEmbeddingAttempts) lookup\(sentenceEmbeddingAttempts == 1 ? "" : "s")"
    }

    /// One lock for every touch of the mutable statics AND the shared NLEmbedding
    /// instance. The compute surface went `nonisolated` so retrieval can run off the
    /// main actor (`AppBrain.triage` detaches it), which makes overlapping calls
    /// possible — the debounce cancels stale *tasks*, not in-flight computations.
    nonisolated private static let lock = NSLock()

    /// In-process memo: sourceHash → vector. The read-through layer that keeps
    /// `ContextRetrieval` synchronous. Bounded (reset at the cap) so a long session
    /// can't grow it without limit. Guarded by `lock`.
    nonisolated(unsafe) private static var memo: [String: [Double]] = [:]
    nonisolated private static let memoCap = 2048
    /// Hashes already persisted as rows, so `persistFresh` never re-fetches to check.
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var persistedHashes: Set<String> = []
    nonisolated(unsafe) private static var warmedUp = false

    /// The hash of what we'd embed for this text — normalization shared with the
    /// suppression store keeps "what was embedded" stable across punctuation noise.
    /// FNV-1a, NOT `Hasher`: `Hasher` is randomly seeded per process, and this hash
    /// is persisted — it must match across launches or every row reads as stale.
    nonisolated static func sourceHash(_ text: String) -> String {
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
    nonisolated static func cachedVector(for text: String) -> [Double]? {
        lock.withLock { memo[sourceHash(text)] }
    }

    /// Compute (and memoize) the vector for `text`. Nil when the model is unavailable
    /// or declines the string. The lock is deliberately held ACROSS the inference —
    /// serializing the not-documented-thread-safe NLEmbedding instance is the whole
    /// point; a main-thread `cachedVector` waits at most one `vector(for:)`.
    nonisolated static func computeVector(for text: String) -> [Double]? {
        guard let embedding = sentenceEmbedding else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let vector = embedding.vector(for: text) else { return nil }
        if memo.count >= memoCap { wipeMemoLocked() }
        memo[sourceHash(text)] = vector
        return vector
    }

    /// The cap-overflow wipe. It must also re-arm warm-up, or the wipe becomes
    /// permanent: the memo's only bulk refill is `warmUp`, which is one-shot — with
    /// `warmedUp` left true after a wipe, persisted vectors never reloaded and every
    /// later capture re-ran its full fresh-embed budget for the life of the process.
    /// `persistedHashes` deliberately survives — the rows still exist on disk;
    /// forgetting them would make `persistFresh` insert duplicates. Caller holds `lock`.
    nonisolated private static func wipeMemoLocked() {
        memo.removeAll(keepingCapacity: true)
        warmedUp = false
    }

    /// Test seam: force the cap-overflow wipe. `computeVector`'s trigger needs the
    /// real NLEmbedding (absent under XCTest), so the overflow CONTRACT — wipe, then
    /// reload from persisted rows — is pinned through this instead.
    static func overflowMemoForTesting() {
        lock.withLock { wipeMemoLocked() }
    }

    /// Similarity in [0, 1], reproducing the pre-cache scoring EXACTLY. Despite its
    /// `.cosine` name, `NLEmbedding.distance(between:and:)` returns the EUCLIDEAN
    /// distance of the normalized vectors, √(2 − 2·cos) — verified against the host
    /// model during implementation (max Δ < 1e-4; plain cosine differed by up to
    /// 0.5 and would have silently pushed unrelated pairs over the relevance floor
    /// while every test stayed green). Do NOT "fix" this to plain cosine without
    /// re-tuning the retrieval blend weights and `relevanceFloor` together.
    nonisolated static func similarity(_ a: [Double], _ b: [Double]) -> Double {
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
        guard !lock.withLock({ warmedUp }) else { return }
        // The change-invalidated snapshot cache, not a fresh fetchAll — this runs
        // during the sheet-presentation animation, and the composer's first parse is
        // about to read the same snapshot anyway.
        let open = OpenTaskSnapshotCache.shared.snapshots(in: context)
        warmUp(openTaskIDs: Set(open.map(\.id)), in: context)
    }

    static func warmUp(openTaskIDs: Set<UUID>, in context: NSManagedObjectContext) {
        guard
            lock.withLock({
                if warmedUp { return false }; warmedUp = true; return true
            })
        else { return }
        let request = NSFetchRequest<EmbeddingCache>(entityName: "EmbeddingCache")
        let rows = (try? context.fetch(request)) ?? []
        // Decode outside the lock, publish in ONE acquisition — the old shape took
        // the lock per row, on the main thread, during sheet presentation.
        var loaded: [(hash: String, vector: [Double])] = []
        loaded.reserveCapacity(rows.count)
        for row in rows {
            let alive = row.taskID.map(openTaskIDs.contains) ?? false
            guard alive, row.revision == Int32(revision), let data = row.vector else {
                context.delete(row)
                continue
            }
            loaded.append((row.sourceHash, decode(data)))
        }
        lock.withLock {
            for entry in loaded {
                memo[entry.hash] = entry.vector
                persistedHashes.insert(entry.hash)
            }
        }
    }

    /// Persist any freshly-computed vectors for the open set (memo entries with no
    /// row yet). Called after the debounced triage resolves — a handful of tiny rows
    /// on the app's write context, never per keystroke. The QUERY text is deliberately
    /// not persisted (it belongs to no task). Callers own `save()`.
    static func persistFresh(openTasks: [OpenTaskSnapshot], in context: NSManagedObjectContext) {
        for snap in openTasks {
            let hash = sourceHash(snap.title)
            let fresh: [Double]? = lock.withLock {
                guard let vector = memo[hash], !persistedHashes.contains(hash) else { return nil }
                persistedHashes.insert(hash)
                return vector
            }
            guard let fresh else { continue }
            context.insert(
                EmbeddingCache(
                    taskID: snap.id, vector: fresh, sourceHash: hash, revision: revision,
                    in: context))
        }
    }

    // MARK: - Float32 codec (vectors stored compactly, computed as Double)

    nonisolated static func encode(_ vector: [Double]) -> Data {
        vector.map(Float.init).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func decode(_ data: Data) -> [Double] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Float.self).map(Double.init)
        }
    }

    /// Test seam: drop all in-process state (memo + warm-up flag).
    static func resetForTesting() {
        lock.withLock {
            loadedSentenceEmbedding = nil
            sentenceEmbeddingAttempts = 0
            memo.removeAll()
            persistedHashes.removeAll()
            warmedUp = false
        }
    }
}
