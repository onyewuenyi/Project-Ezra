//
//  TaskRanking.swift
//  Project-Ezra
//
//  The Policy layer of the attention architecture (Facts → Reasoning → Policy). The
//  stack comparator enforces the product's hard bands as lexicographic sort-key
//  components; the attention component only ever breaks ties WITHIN a band, so
//  "the AI never decides the band" holds by construction. Resolved precedence, in order:
//
//    1. Needs Decision → forced crisp top, unconditionally (overrides Blocked).
//    2. Blocked → sinks toward the back.
//    3. Effective attention (desc) → the primary sort among the rest: the persisted
//       slow score PLUS the live `currentRelevance` layer (below).
//    4. Blocking → modest boost within equal score (downstream value).
//    5. Overdue → visible marker elsewhere; here, a boost similar to Blocking.
//
//  Pinned is retired: a manual float-to-top override competed with the very score it
//  was meant to complement. Urgent is the only user Signal, and it acts through the
//  score rather than as a band of its own.
//
//  **`currentRelevance` — the decay fix, computed live, never persisted.** Importance
//  stays slow (the persisted score); relevance is the fast half: staleness and
//  repeated deferral pull a task down, a just-cleared blocker / a new dependent / a
//  related deadline approaching pull it up (the dormant-passport case: intrinsic
//  importance stays high, relevance is deeply negative while nothing happens, then
//  spikes the moment flights get booked). It is a deliberate ADDITIVE layer *within*
//  precedence component 3 only — clamped ±`relevanceClamp`, evaluated ONCE per
//  snapshot into the `RankKey` (never inside the comparator: the graph terms and the
//  `now`-relative windows would make per-comparison evaluation O(n²) with graph
//  traversal, and a clock read mid-sort would break the strict weak ordering). The
//  hard bands stay lexicographic and fact-fed; the AI still never decides the band.
//  Staleness reads the HUMAN clock (`humanTouchedAt`), never `updatedAt` — a system
//  edge-write must not reset a dormant task's decay.
//
//  Every band term is a lexicographic sort-key component — that keeps `stackOrder` a
//  strict weak ordering, which `sorted(by:)` requires. The fast-moving facts
//  (needsDecision/blocked/blocking/overdue) are read live here, so the persisted
//  score never has to encode them (the persist-slow/compute-fast split).
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
    /// The persisted attention score (0…100) PLUS the live `currentRelevance`
    /// adjustment (±25), sorted DESCENDING — the primary sort among unblocked,
    /// non-decision tasks. Precomputed here so the comparator compares one Double.
    var effectiveAttention: Double
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

    // MARK: - currentRelevance weights (the live layer; all named, clamped ±relevanceClamp)

    /// Staleness pull-down per day since the last HUMAN touch.
    static let stalenessPerDay = -0.6
    /// Pull-down per time the task was planned and left untouched (`deferralCount`).
    /// `carriedOverCount` (worked-but-unfinished) is deliberately unread for now.
    static let deferralPenalty = -1.5
    /// Boost while a cleared blocker is fresh (`lastUnblockedAt` within the window).
    static let recentUnblockBoost = 12.0
    /// Boost while a newly-gained dependent is fresh (a reverse `.blocks` edge's age).
    static let recentDependentBoost = 8.0
    /// Max boost from a related task's approaching due date (linear decay to 0).
    static let dueProximityMax = 15.0
    /// The freshness window for the two event boosts.
    static let recentWindow: TimeInterval = 48 * 3600
    /// The live layer can shift the effective attention by at most this much either way.
    static let relevanceClamp = 25.0

    /// Compute every task's rank key in one pass over the graph. `tasks` should be
    /// the full working set — blocked/blocking/relevance are relative to it.
    static func rankKeys(for tasks: [TaskItem], now: Date = Date()) -> [UUID: RankKey] {
        let open = tasks.filter { !$0.status.isResolved }
        let openIDs = Set(open.compactMap(\.uuid))
        let dueByID = Dictionary(
            uniqueKeysWithValues: open.compactMap { task in task.uuid.map { ($0, task.dueDate) } })

        // One pass over the open graph: reverse blocking edges, freshly-gained
        // dependents (edge age within the window), and the symmetric neighbor sets
        // (parent/children/blocking/blocked) that feed due-date proximity.
        var blockingIDs: Set<UUID> = []
        var recentlyGainedDependent: Set<UUID> = []
        var neighborIDs: [UUID: Set<UUID>] = [:]
        for task in open {
            guard let id = task.uuid else { continue }
            for rel in task.relationships {
                guard let target = rel.targetID, openIDs.contains(target) else { continue }
                switch rel.kind {
                case .blocks:
                    blockingIDs.insert(target)
                    if now.timeIntervalSince(rel.createdAt) <= recentWindow,
                        rel.createdAt <= now
                    {
                        recentlyGainedDependent.insert(target)
                    }
                    neighborIDs[id, default: []].insert(target)
                    neighborIDs[target, default: []].insert(id)
                case .parent:
                    neighborIDs[id, default: []].insert(target)
                    neighborIDs[target, default: []].insert(id)
                case .related:
                    continue
                }
            }
        }

        var keys: [UUID: RankKey] = [:]
        for task in tasks {
            guard let id = task.uuid else { continue }
            let neighborDueDates = (neighborIDs[id] ?? []).compactMap { dueByID[$0] ?? nil }
            let relevance = currentRelevance(
                for: task, now: now,
                recentlyGainedDependent: recentlyGainedDependent.contains(id),
                neighborDueDates: neighborDueDates)
            keys[id] = RankKey(
                needsDecision: task.needsDecision && !task.status.isResolved,
                isBlocked: task.hasActiveBlockers(among: tasks),
                effectiveAttention: task.attention.score + relevance,
                isBlocking: blockingIDs.contains(id) && !task.status.isResolved,
                isOverdue: task.isOverdue(now: now),
                dueDate: task.dueDate,
                createdAt: task.createdAt,
                id: id
            )
        }
        return keys
    }

    /// The live relevance adjustment for one task — see the header. Pure over its
    /// inputs (the graph terms arrive precomputed), evaluated once per snapshot.
    static func currentRelevance(
        for task: TaskItem, now: Date,
        recentlyGainedDependent: Bool, neighborDueDates: [Date]
    ) -> Double {
        var relevance = 0.0
        let staleDays = max(0, now.timeIntervalSince(task.humanTouchedAt) / 86_400)
        relevance += staleDays * stalenessPerDay
        relevance += Double(task.deferralCount) * deferralPenalty
        if let unblockedAt = task.lastUnblockedAt, unblockedAt <= now,
            now.timeIntervalSince(unblockedAt) <= recentWindow
        {
            relevance += recentUnblockBoost
        }
        if recentlyGainedDependent { relevance += recentDependentBoost }
        relevance += dueProximity(neighborDueDates, now: now)
        return min(max(relevance, -relevanceClamp), relevanceClamp)
    }

    /// 0…`dueProximityMax` from the NEAREST related due date: a neighbor due today
    /// (or overdue) scores the max, decaying linearly by a point per day out.
    static func dueProximity(_ dueDates: [Date], now: Date) -> Double {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let daysOut = dueDates.compactMap { due in
            cal.dateComponents([.day], from: today, to: cal.startOfDay(for: due)).day
        }
        guard let nearest = daysOut.min() else { return 0 }
        return max(0, dueProximityMax - Double(max(0, nearest)))
    }

    /// The stack comparator — the resolved precedence, term by term. Strict weak
    /// ordering: every branch compares one component and recurses to the next only
    /// on equality, so transitivity holds by construction. (All inputs live in the
    /// precomputed `RankKey` — the comparator never reads the clock or the graph.)
    static func stackOrder(_ a: RankKey, _ b: RankKey) -> Bool {
        // 1. Needs Decision: forced crisp top, full stop — overrides everything below.
        if a.needsDecision != b.needsDecision { return a.needsDecision }
        // 2. Blocked sinks, regardless of score.
        if a.isBlocked != b.isBlocked { return b.isBlocked }
        // 3. Effective attention (persisted score + live relevance) — higher first.
        if a.effectiveAttention != b.effectiveAttention {
            return a.effectiveAttention > b.effectiveAttention
        }
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
