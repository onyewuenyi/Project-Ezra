//
//  TodayModels.swift
//  Project-Ezra
//
//  The pure foundations of the Today sequence (Recap → Docket → Capacity → Plan).
//  Everything here is deterministic: membership and order come from pure queries
//  and `TaskRanking`, never the model. The model only narrates over what these
//  types decide — a boundary enforced mechanically downstream in
//  `GeneratedPlan.sanitized(against:)`.
//
//  All time-dependent logic takes an injected `now` so the whole surface is
//  testable with a fixed clock; there are no `Date()` singletons in this file.
//

import Foundation

// MARK: - Capacity (the one-tap pivot)

/// How much the user has to give today — the single human input in the sequence.
/// Deliberately coarse (three states, no slider): the point is a one-tap read of
/// today, not a planning ritual. Copy is Full / Steady / Light (spec §5.3).
enum Capacity: String, CaseIterable, Codable, Sendable {
    case full
    case steady
    case light

    var label: String {
        switch self {
        case .full: return "Full"
        case .steady: return "Steady"
        case .light: return "Light"
        }
    }

    /// The deterministic cold-start plan size for this capacity, used until
    /// `CapacityLog` has enough samples to personalize (spec §5.3). Personalization
    /// (see `CapacityBaseline`) only ever *replaces* this number with an observed
    /// one — the model never decides what "Light" means.
    var defaultCount: Int {
        switch self {
        case .full: return 6
        case .steady: return 4
        case .light: return 2
        }
    }
}

// MARK: - Recap (the exhale)

/// The recently-completed set that opens the sequence — a pure query, never a
/// stored surface. `completedSince` is the window's start (the store decides it);
/// an empty recap means the beat is skipped entirely (never an empty celebration).
struct TodayRecap {
    let completedSince: Date
    /// Completed tasks in the window, newest resolution first.
    let completedTasks: [TaskItem]

    var count: Int { completedTasks.count }
    var isEmpty: Bool { completedTasks.isEmpty }
}

// MARK: - Docket (what today is actually asking)

/// The union of everything that legitimately wants attention today: due today,
/// overdue, or carrying an open decision. A pure query over the working set —
/// `items` is the deduped union in `TaskRanking` stack order, so the beat renders
/// the same precedence the Tasks stack does.
struct TodayDocket {
    let dueToday: [TaskItem]
    let overdue: [TaskItem]
    let needsDecision: [TaskItem]
    /// The deduped union of the three buckets, stack-sorted among the full working
    /// set (so Blocked/Blocking stay graph-accurate).
    let items: [TaskItem]

    var isEmpty: Bool { items.isEmpty }
}

// MARK: - Pure queries

/// The deterministic membership logic behind the sequence. Everything takes an
/// injected `now`; day boundaries use `Calendar.current` exactly as `TaskItem`'s
/// own `isOverdue` / `TaskRanking.layer` do, so behavior stays consistent.
enum TodayQueries {

    /// The tasks resolved-as-done in `[since, now]`, newest first. Killed tasks are
    /// not a celebration; only `.done` counts.
    static func recap(tasks: [TaskItem], since: Date, now: Date) -> TodayRecap {
        let completed =
            tasks
            .filter { task in
                task.status == .done
                    && (task.completedAt.map { $0 >= since && $0 <= now } ?? false)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return TodayRecap(completedSince: since, completedTasks: completed)
    }

    /// The docket buckets and their stack-ordered union.
    static func docket(tasks: [TaskItem], now: Date) -> TodayDocket {
        let cal = Calendar.current
        let dueToday = tasks.filter { task in
            !task.status.isResolved
                && (task.dueDate.map { cal.isDate($0, inSameDayAs: now) } ?? false)
        }
        let overdue = tasks.filter { $0.isOverdue(now: now) }
        let needsDecision = tasks.filter { $0.needsDecision && !$0.status.isResolved }

        // Deduped union in bucket-priority order, then re-sorted by stack precedence
        // among the full population so Blocked/Blocking are graph-accurate.
        var seen: Set<UUID> = []
        var union: [TaskItem] = []
        for task in dueToday + overdue + needsDecision {
            guard let id = task.uuid, seen.insert(id).inserted else { continue }
            union.append(task)
        }
        let items = TaskRanking.sorted(union, among: tasks, now: now)
        return TodayDocket(dueToday: dueToday, overdue: overdue, needsDecision: needsDecision, items: items)
    }

    /// Whether any open task is BOTH blocked and blocking — a dependency chain of
    /// depth ≥ 2. A pure signal into `PlanRouting`: chains are where a smarter tier
    /// earns its keep, so their presence tilts routing toward the stronger model.
    static func hasBlockedBlockingChain(_ tasks: [TaskItem]) -> Bool {
        tasks.contains { task in
            !task.status.isResolved
                && task.hasActiveBlockers(among: tasks)
                && task.isBlocking(among: tasks)
        }
    }
}
