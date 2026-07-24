//
//  TaskRanking.swift
//  Project-Ezra
//
//  The Policy layer of the attention architecture (Facts → Reasoning → Policy). The
//  stack comparator enforces the product's hard bands as lexicographic sort-key
//  components; the AI-computed attention SCORE only ever breaks ties WITHIN a band, so
//  "the AI never decides the band" holds by construction. Resolved precedence, in order:
//
//    1. Needs Decision → forced crisp top, unconditionally (overrides Blocked).
//    2. Blocked → sinks toward the back.
//    3. Attention score (desc) → the primary sort among the rest (persisted, slow-moving).
//    4. Blocking → modest boost within equal score (downstream value).
//    5. Overdue → visible marker elsewhere; here, a boost similar to Blocking.
//
//  Pinned is retired: a manual float-to-top override competed with the very score it
//  was meant to complement. Urgent is the only user Signal, and it acts through the
//  score rather than as a band of its own.
//
//  Every term is a lexicographic sort-key component, never an additive score —
//  that keeps `stackOrder` a strict weak ordering, which `sorted(by:)` requires. The
//  fast-moving facts (needsDecision/blocked/blocking/overdue) are read live here, so
//  the persisted score never has to encode them (the persist-slow/compute-fast split).
//
//  Pure and ModelContext-free: callers compute `RankKey`s once per render from
//  the full task list (the blocked/blocking sets need the graph) and sort with
//  the comparator.
//

import Foundation

// MARK: - Rank key (one task's position inputs, precomputed)

/// Everything the stack comparator needs about one task, computed once per render
/// so sorting never re-walks the dependency graph per comparison.
struct RankKey {
    var needsDecision: Bool
    var isBlocked: Bool
    /// The persisted attention score (0…100), sorted DESCENDING — the primary sort
    /// among unblocked, non-decision tasks.
    var attentionScore: Double
    var isBlocking: Bool
    var isOverdue: Bool
    var dueDate: Date?
    /// Stable tiebreakers — a comparator that can call two distinct tasks "equal
    /// both ways" is fine, but deterministic output needs a final total order.
    var createdAt: Date
    var id: UUID
}

// MARK: - Rank bands (internal — never rendered)

/// The three invisible bands that bound the Now surface's attention budget.
/// They influence sectioning and ordering but are never shown to the user. Renamed
/// from the old `AttentionLayer` to avoid colliding with the attention SCORE.
enum RankBand {
    case critical  // immediate action required
    case important  // should be completed today
    case routine  // can wait
}

// MARK: - Ranking

enum TaskRanking {

    /// Compute every task's rank key in one pass over the graph. `tasks` should be
    /// the full working set — blocked/blocking are relative to it.
    static func rankKeys(for tasks: [TaskItem], now: Date = Date()) -> [UUID: RankKey] {
        let open = tasks.filter { !$0.status.isResolved }
        let openIDs = Set(open.compactMap(\.uuid))
        // Reverse edges once: who is blocking whom.
        var blockingIDs: Set<UUID> = []
        for task in open {
            for blockerID in task.taskBlockerIDs where openIDs.contains(blockerID) {
                blockingIDs.insert(blockerID)
            }
        }
        var keys: [UUID: RankKey] = [:]
        for task in tasks {
            guard let id = task.uuid else { continue }
            keys[id] = RankKey(
                needsDecision: task.needsDecision && !task.status.isResolved,
                isBlocked: task.hasActiveBlockers(among: tasks),
                attentionScore: task.attention.score,
                isBlocking: blockingIDs.contains(id) && !task.status.isResolved,
                isOverdue: task.isOverdue(now: now),
                dueDate: task.dueDate,
                createdAt: task.createdAt,
                id: id
            )
        }
        return keys
    }

    /// The stack comparator — the resolved precedence, term by term. Strict weak
    /// ordering: every branch compares one component and recurses to the next only
    /// on equality, so transitivity holds by construction.
    static func stackOrder(_ a: RankKey, _ b: RankKey) -> Bool {
        // 1. Needs Decision: forced crisp top, full stop — overrides everything below.
        if a.needsDecision != b.needsDecision { return a.needsDecision }
        // 2. Blocked sinks, regardless of score.
        if a.isBlocked != b.isBlocked { return b.isBlocked }
        // 3. Attention score is the primary sort among the rest (higher first).
        if a.attentionScore != b.attentionScore { return a.attentionScore > b.attentionScore }
        // 4. Blocking: a modest promotion within equal score.
        if a.isBlocking != b.isBlocking { return a.isBlocking }
        // 5. Overdue: a similar nudge, never a score override.
        if a.isOverdue != b.isOverdue { return a.isOverdue }
        // Then the calendar: soonest due first, undated last.
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        // Stable tiebreak so output is deterministic.
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// Sort a slice of tasks by stack precedence, using keys computed over
    /// `population` (defaults to the slice itself — pass the full working set when
    /// the slice is a filtered view, so blocked/blocking stay graph-accurate).
    static func sorted(
        _ tasks: [TaskItem], among population: [TaskItem]? = nil, now: Date = Date()
    ) -> [TaskItem] {
        let keys = rankKeys(for: population ?? tasks, now: now)
        return tasks.sorted { a, b in
            guard let ka = a.uuid.flatMap({ keys[$0] }), let kb = b.uuid.flatMap({ keys[$0] }) else {
                return a.createdAt < b.createdAt
            }
            return stackOrder(ka, kb)
        }
    }

    /// The internal rank band for one task. Never rendered — it drives the Now
    /// surface's sectioning and attention budget only. Computed from live facts + the
    /// user's Urgent signal (priority is retired).
    static func band(for task: TaskItem, isBlocked: Bool, now: Date = Date()) -> RankBand {
        guard !task.status.isResolved else { return .routine }
        let cal = Calendar.current
        let dueToday = task.dueDate.map { cal.isDate($0, inSameDayAs: now) } ?? false
        // Relative to the injected `now`, not the wall clock — `isDateInTomorrow`
        // would silently pin this to the real calendar and break testability.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let dueTomorrow = task.dueDate.map { cal.isDate($0, inSameDayAs: tomorrow) } ?? false

        if task.needsDecision { return .critical }
        if task.isOverdue(now: now) { return .critical }
        if dueToday && task.isUrgent { return .critical }
        if isBlocked { return .routine }  // sunk work can't demand today's attention
        if dueToday || dueTomorrow { return .important }
        if task.isUrgent { return .important }
        return .routine
    }

    /// The quick-win signal: small, bounded, and actionable right now. Feeds the
    /// occasional Momentum attention item — never a permanent section.
    static func isQuickWin(_ task: TaskItem, isBlocked: Bool) -> Bool {
        guard task.status == .active, !isBlocked, !task.ownerPending, !task.needsDecision,
            let effort = task.effortMinutes
        else { return false }
        return effort <= 15
    }
}
