//
//  TodayQueries.swift
//  Project-Ezra
//
//  The DAY as a scope — the pure queries the Brief was built on, harvested when the
//  Brief was cut (2026-09-02) because the user problem outlived the surface: "what
//  deserves me today?" is still asked, it is just answered as a question inside Ask
//  rather than as a once-a-day cinematic. Everything here is deterministic and takes
//  an injected `now`; membership and order come from these queries and `TaskRanking`,
//  never from a model.
//
//  Two things live here that used to live in `Features/Brief/`:
//  - the day's queries (`docket`, `recap`) and the ownership-filtered CANDIDATE set,
//    which is where `HouseholdSync.isLive` decides whose day this is (pinned by
//    `SyncGateTests` — the gate's live side must have RUN before it ships);
//  - `Capacity`, kept only because the frozen `CapacityLog` entity stores its raw
//    value. Nothing writes it any more.
//

import Foundation

/// The retired one-tap capacity pivot. The `CapacityLog` entity persists its raw value
/// and the schema is frozen, so the vocabulary stays; nothing reads or writes it.
enum Capacity: String, CaseIterable, Codable, Sendable {
    case full
    case steady
    case light
}

/// The recently-completed set — a pure query, never a stored surface.
struct TodayRecap {
    let completedSince: Date
    /// Completed tasks in the window, newest resolution first.
    let completedTasks: [TaskItem]

    var count: Int { completedTasks.count }
    var isEmpty: Bool { completedTasks.isEmpty }
}

/// Everything that legitimately wants attention today: due today, overdue, or carrying
/// an open decision. `items` is the deduped union in `TaskRanking` stack order.
struct TodayDocket {
    let dueToday: [TaskItem]
    let overdue: [TaskItem]
    let needsDecision: [TaskItem]
    let items: [TaskItem]

    var isEmpty: Bool { items.isEmpty }
}

enum TodayQueries {

    /// The day's candidate set, in rank order — the open working set, filtered to MINE
    /// once sync is live. Before sync, everything stays (a task handed to someone with
    /// no device would otherwise leave every list and land nowhere). Harvested from the
    /// Brief's `BriefSequenceModel.candidates`; the day answer (F-11) reads it.
    static func candidates(
        from tasks: [TaskItem], currentUserID: UUID?, syncIsLive: Bool = HouseholdSync.isLive,
        now: Date = Date()
    ) -> [TaskItem] {
        let open = tasks.filter {
            ($0.status.isLive || ($0.needsDecision && !$0.status.isResolved))
                && (!syncIsLive || $0.isMine(currentUserID: currentUserID))
        }
        return TaskRanking.sorted(open, among: tasks, now: now)
    }

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
        var seen: Set<UUID> = []
        var union: [TaskItem] = []
        for task in dueToday + overdue + needsDecision {
            guard let id = task.uuid, seen.insert(id).inserted else { continue }
            union.append(task)
        }
        let items = TaskRanking.sorted(union, among: tasks, now: now)
        return TodayDocket(dueToday: dueToday, overdue: overdue, needsDecision: needsDecision, items: items)
    }
}
