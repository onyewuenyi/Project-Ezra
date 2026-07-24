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
    static func candidates(
        matching text: String,
        category: String? = nil,
        among tasks: [OpenTaskSnapshot],
        now: Date = Date()
    ) -> [RetrievalCandidate] {
        let queryWords = CorrectionProfile.significantWords(text)

        // Vectors come from the `EmbeddingStore` read-through (memo → model), with a
        // bounded fresh-embed budget per call. The query vector is computed outside
        // the budget (it's one embed, and nothing works without it).
        var freshBudget = maxFreshEmbeds
        func vector(for candidateTitle: String) -> [Double]? {
            if let cached = EmbeddingStore.cachedVector(for: candidateTitle) { return cached }
            guard freshBudget > 0, let fresh = EmbeddingStore.computeVector(for: candidateTitle)
            else { return nil }
            freshBudget -= 1
            return fresh
        }
        let queryVector =
            EmbeddingStore.cachedVector(for: text) ?? EmbeddingStore.computeVector(for: text)

        let scored: [RetrievalCandidate] = tasks.compactMap { snap in
            let lexical = jaccard(queryWords, CorrectionProfile.significantWords(snap.title))
            let categoryScore = (category != nil && category == snap.category) ? 1.0 : 0.0
            let recency = recencyScore(snap.updatedAt, now: now)

            let score: Double
            if let queryVector, let candidateVector = vector(for: snap.title) {
                let similarity = EmbeddingStore.similarity(queryVector, candidateVector)
                score =
                    embeddingWeight * similarity + lexicalWeight * lexical
                    + categoryWeight * categoryScore + recencyWeight * recency
            } else {
                // Embedding unavailable (no model, or over the fresh-embed budget) →
                // its weight shifts onto lexical overlap.
                score =
                    (embeddingWeight + lexicalWeight) * lexical
                    + categoryWeight * categoryScore + recencyWeight * recency
            }
            guard score >= relevanceFloor else { return nil }
            return RetrievalCandidate(
                id: snap.id, title: snap.title, facts: factLine(snap, now: now), score: score)
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

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    /// Newer tasks read as more relevant context — a gentle decay so a month-old task
    /// still scores something, but today's work wins ties.
    private static func recencyScore(_ updatedAt: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(updatedAt) / 86_400)
        return 1.0 / (1.0 + days / 30.0)
    }

    /// The compact fact line shown to the model alongside the candidate id.
    private static func factLine(_ snap: OpenTaskSnapshot, now: Date) -> String {
        var parts = [snap.category]
        if let due = snap.dueDate {
            let days =
                Calendar.current.dateComponents(
                    [.day], from: Calendar.current.startOfDay(for: now),
                    to: Calendar.current.startOfDay(for: due)
                ).day ?? 0
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
