//
//  ContextRetrieval.swift
//  Project-Ezra
//
//  "Retrieve the relevant slice of the graph." A deterministic, pre-model ranking that
//  answers "which existing tasks is THIS text about?" — the substrate behind Capture
//  Graph Awareness (every capture discovers edges, not just tasks). Named
//  ContextRetrieval, not CaptureRetrieval, because it's a SHARED capability: capture is
//  the first client, but the Today advisor's candidate set, decision-framing context,
//  and future reflection are all downstream clients of the same "relevant slice" idea.
//
//  Pure and value-typed (operates on `[OpenTaskSnapshot]`), so it runs off-context and
//  is fully testable. The blend is deterministic with a stable uuid tiebreak: no
//  candidate order is a generation artifact.
//

import Foundation

/// One retrieved neighbour: the task's identity plus a compact fact line for the model
/// prompt, and the blended relevance score that ranked it.
struct RetrievalCandidate: Sendable, Hashable {
    var id: UUID
    var title: String
    var facts: String
    var score: Double
}

enum ContextRetrieval {
    /// The cap on how many neighbours reach the model — the context budget is small, and
    /// a near-duplicate is either in the top handful or it isn't.
    static let maxCandidates = 12

    // Blend weights (named, not magic): semantic similarity dominates, lexical overlap
    // backs it up, category and recency are light tie-shapers. When the embedding model
    // is unavailable, its weight shifts onto the lexical term (nil-safe degrade).
    static let embeddingWeight = 0.5
    static let lexicalWeight = 0.3
    static let categoryWeight = 0.1
    static let recencyWeight = 0.1

    /// The relevance floor — below this a neighbour isn't worth showing the model at all.
    static let relevanceFloor = 0.12

    /// The cap on FRESH embeddings per retrieval call (cache misses that actually run
    /// the model). Everything cached is free; misses beyond the budget fall back to
    /// lexical-only scoring for that candidate, so capture latency stays flat
    /// regardless of store size (they'll embed on a later capture).
    static let maxFreshEmbeds = 20

    /// Rank the open set by relevance to `text`. Deterministic: ties break by uuid,
    /// capped at `maxCandidates`. Rejected pairings are NOT filtered here — retrieval
    /// stays a pure relevance ranking; suppression is the resolver's job
    /// (`IntentResolver.edgeProposals` + `SuppressionStore`), keyed per-proposal.
    /// `nonisolated` so the whole ranking — including up to 21 sentence-embedding
    /// inferences — can run off the main actor (`AppBrain.triage` detaches it). The
    /// function is pure over value snapshots; the only shared state it touches is
    /// `EmbeddingStore`'s memo, which is lock-guarded for exactly this reason.
    nonisolated static func candidates(
        matching text: String,
        category: String? = nil,
        among tasks: [OpenTaskSnapshot],
        now: Date = Date()
    ) -> [RetrievalCandidate] {
        let queryWords = CorrectionProfile.significantWords(text)
        let queryVector =
            EmbeddingStore.cachedVector(for: text) ?? EmbeddingStore.computeVector(for: text)

        // Score the CHEAP components for every candidate first — lexical overlap, category,
        // recency — plus the embedding-free "provisional" score. This decides WHERE the
        // bounded fresh-embed budget is spent: on the most-provisionally-relevant cache
        // misses, not whatever happens to be first in array order. A paraphrased duplicate
        // (low lexical, high semantic) must not be starved of its one embed by a run of
        // unrelated tasks ahead of it — otherwise it scores ≤ the floor and never reaches
        // the model, and a silent duplicate gets created.
        struct Prescored {
            let snap: OpenTaskSnapshot
            let lexical: Double
            let categoryScore: Double
            let recency: Double
            let provisional: Double
            let cachedVector: [Double]?
        }
        let prescored: [Prescored] = tasks.map { snap in
            let lexical = jaccard(queryWords, CorrectionProfile.significantWords(snap.title))
            let categoryScore = (category != nil && category == snap.category) ? 1.0 : 0.0
            let recency = recencyScore(snap.updatedAt, now: now)
            let provisional =
                (embeddingWeight + lexicalWeight) * lexical
                + categoryWeight * categoryScore + recencyWeight * recency
            return Prescored(
                snap: snap, lexical: lexical, categoryScore: categoryScore, recency: recency,
                provisional: provisional,
                cachedVector: EmbeddingStore.cachedVector(for: snap.title))
        }

        // Grant the fresh-embed budget to the highest-provisional cache misses first
        // (uuid tiebreak keeps the grant deterministic). Cached vectors are free and always
        // used. The query vector gates everything — no query embed, no fresh embeds at all.
        var freshVectors: [UUID: [Double]] = [:]
        if queryVector != nil {
            var budget = maxFreshEmbeds
            let misses = prescored.filter { $0.cachedVector == nil }
                .sorted {
                    if $0.provisional != $1.provisional { return $0.provisional > $1.provisional }
                    return $0.snap.id.uuidString < $1.snap.id.uuidString
                }
            for item in misses {
                guard budget > 0 else { break }
                if let fresh = EmbeddingStore.computeVector(for: item.snap.title) {
                    freshVectors[item.snap.id] = fresh
                    budget -= 1
                }
            }
        }

        let scored: [RetrievalCandidate] = prescored.compactMap { item in
            let vector = item.cachedVector ?? freshVectors[item.snap.id]
            let score: Double
            if let queryVector, let vector {
                let similarity = EmbeddingStore.similarity(queryVector, vector)
                score =
                    embeddingWeight * similarity + lexicalWeight * item.lexical
                    + categoryWeight * item.categoryScore + recencyWeight * item.recency
            } else {
                // Embedding unavailable (no model, or a miss the budget didn't reach) →
                // the embedding weight shifts onto lexical overlap (the provisional score).
                score = item.provisional
            }
            guard score >= relevanceFloor else { return nil }
            return RetrievalCandidate(
                id: item.snap.id, title: item.snap.title, facts: factLine(item.snap, now: now),
                score: score)
        }

        return
            scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.id.uuidString < $1.id.uuidString  // stable tiebreak
            }
            .prefix(maxCandidates)
            .map { $0 }
    }

    // MARK: - Components

    nonisolated private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    /// Newer tasks read as more relevant context — a gentle decay so a month-old task
    /// still scores something, but today's work wins ties.
    nonisolated private static func recencyScore(_ updatedAt: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(updatedAt) / 86_400)
        return 1.0 / (1.0 + days / 30.0)
    }

    /// The compact fact line shown to the model alongside the candidate id.
    nonisolated private static func factLine(_ snap: OpenTaskSnapshot, now: Date) -> String {
        var parts = [snap.category]
        if let due = snap.dueDate {
            let days = TaskItem.daysUntil(due, now: now) ?? 0
            if days < 0 {
                parts.append("overdue")
            } else if days == 0 {
                parts.append("due today")
            } else {
                parts.append("due in \(days)d")
            }
        }
        if snap.isBlocked { parts.append("blocked") }
        if let parent = snap.parentTitle { parts.append("step of “\(parent)”") }
        return parts.joined(separator: " · ")
    }
}
