//
//  AttentionEngine.swift
//  Project-Ezra
//
//  The Reasoning layer of the three-layer attention architecture (Facts →
//  Reasoning → Policy). Where the old model let the AI set a user-facing Priority,
//  attention is now a computed system score: a task's `AttentionMetadata` (0…100 +
//  the contributors that explain it) derived from SLOW-MOVING inputs only —
//  the urgent signal, the AI's importance estimate, effort shape, and graph
//  centrality. It is persisted (`TaskItem.attentionData`) because those inputs
//  rarely change; recompute runs at the existing save seams, never on a background
//  observer.
//
//  **Persist-slow / compute-fast split (constitutional):** the score NEVER reads a
//  fast-moving fact — overdue, blocked, blocking, and needsDecision are computed
//  live by the `TaskRanking` comparator instead. That is what keeps the hard bands
//  absolute and lets "the AI never decides the band" hold by construction: the
//  persisted score only ever moves a task WITHIN a band (additive contributor
//  scoring), never across one.
//

import Foundation

/// One explained input to a task's attention score. The `points` it added are kept
/// so a later recompute can carry a contributor forward (e.g. AI importance) when the
/// fresh input isn't supplied.
struct AttentionContributor: Codable, Hashable {
    enum Kind: String, Codable {
        case urgentSignal, aiImportance, effortShape, graphCentrality
        case deferralPattern  // reserved (V1 unused)
    }
    var kind: Kind
    var points: Double
    var detail: String?
}

/// A task's persisted attention: the system score plus the contributors that
/// explain it. `neutral` is the honest default for a task that has never been
/// scored (mid-list, no signal).
struct AttentionMetadata: Codable, Hashable {
    var score: Double  // 0…100
    var contributors: [AttentionContributor]
    var computedAt: Date

    static let neutral = AttentionMetadata(
        score: AttentionEngine.baseScore, contributors: [], computedAt: .distantPast)

    /// The importance implied by a prior compute, recovered from the carried
    /// `aiImportance` contributor (`points = importance × 20`). Nil when none was set.
    var carriedImportance: Double? {
        contributors.first { $0.kind == .aiImportance }.map { $0.points / 20 }
    }
}

enum AttentionEngine {
    /// The base every task starts from before any signal applies — a mid-list score.
    static let baseScore = 35.0

    /// Compute a task's attention from its slow-moving inputs. `aiImportance` (0…1) is
    /// the model's importance estimate when known; when nil the prior contributor is
    /// carried forward, so a plain recompute (urgent toggle, blocker change) never
    /// silently drops the AI's earlier read. `among` supplies the graph for centrality.
    static func metadata(
        for task: TaskItem, among all: [TaskItem], aiImportance: Double?, now: Date = Date()
    ) -> AttentionMetadata {
        var contributors: [AttentionContributor] = []
        var score = baseScore

        // Urgent signal — the user's own "this matters now" flag.
        if task.isUrgent {
            contributors.append(.init(kind: .urgentSignal, points: 30, detail: "Marked urgent"))
            score += 30
        }

        // AI importance — carried forward when a fresh estimate isn't supplied.
        if let importance = (aiImportance ?? task.attention.carriedImportance),
            importance > 0
        {
            let points = (min(max(importance, 0), 1) * 20).rounded()
            contributors.append(.init(kind: .aiImportance, points: points, detail: nil))
            score += points
        }

        // Effort shape — a genuine quick win earns a nudge; a modest task a smaller one.
        if let effort = task.effortMinutes, effort > 0 {
            if effort <= 15 {
                contributors.append(.init(kind: .effortShape, points: 5, detail: "Quick win"))
                score += 5
            } else if effort <= 60 {
                contributors.append(.init(kind: .effortShape, points: 2, detail: nil))
                score += 2
            }
        }

        // Graph centrality — unblocking this frees others; +6 per open direct dependent,
        // capped at +18 so a hub task can't run away with the score.
        let dependents = min(openDirectDependents(of: task, among: all), 3)
        if dependents > 0 {
            let points = Double(dependents) * 6
            contributors.append(
                .init(
                    kind: .graphCentrality, points: points,
                    detail: dependents == 1 ? "1 task waits on this" : "\(dependents) tasks wait on this"))
            score += points
        }

        return AttentionMetadata(
            score: min(100, max(0, score)), contributors: contributors, computedAt: now)
    }

    /// Recompute and stamp `attention` on every touched task in place, carrying each
    /// task's prior AI importance forward. Callers own `save()` — this runs at the
    /// existing mutation seams, never on an observer.
    static func recompute(_ touched: [TaskItem], among all: [TaskItem], now: Date = Date()) {
        for task in touched {
            task.attention = metadata(for: task, among: all, aiImportance: nil, now: now)
        }
    }

    /// Count of open tasks directly blocked BY `task` — the reverse-edge fan-out.
    private static func openDirectDependents(of task: TaskItem, among all: [TaskItem]) -> Int {
        guard let id = task.uuid, !task.status.isResolved else { return 0 }
        return all.filter { other in
            other.uuid != id && !other.status.isResolved && other.taskBlockerIDs.contains(id)
        }.count
    }
}
