//
//  TaskTimeline.swift
//  Project-Ezra
//
//  Turns a task's state history into one quiet, factual line. This is a ledger
//  read-out ("Active for 2d"), never a score, a streak, or a nudge — time here is
//  an honesty signal about where a task actually sat, in the same spirit as
//  `Metrics.rotRate`.
//
//  Pure and testable: no view touches the timeline math directly, and every path
//  returns nil rather than inventing a number when there's nothing real to say.
//

import Foundation

enum TaskTimeline {

    /// Sub-minute durations read as noise ("Active for 0m"), so they're treated as
    /// "nothing to report yet" rather than rounded into a fake number.
    static func compactDuration(_ seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        return "\(hours / 24)d"
    }

    /// The detail sheet's timeline line. Nil when the task has no recorded history
    /// or hasn't sat anywhere long enough to be worth stating.
    static func summary(for task: TaskItem, now: Date = Date()) -> String? {
        guard !task.stateTimeline.isEmpty else { return nil }
        return task.status.isResolved ? resolvedSummary(task) : dwellSummary(task, now: now)
    }

    /// Resolved: lead with how long it took end-to-end.
    private static func resolvedSummary(_ task: TaskItem) -> String? {
        guard let total = task.timeToResolution, let took = compactDuration(total) else { return nil }
        return "\(task.status == .canceled ? "Canceled" : "Done") · took \(took)"
    }

    /// Unresolved: how long it has been sitting in the state it's in now.
    private static func dwellSummary(_ task: TaskItem, now: Date) -> String? {
        guard let dwell = compactDuration(task.secondsIn(task.status, now: now)) else { return nil }
        return "\(phrase(for: task.status)) \(dwell)"
    }

    /// The detail page's one lifecycle caption under the title — where the task IS in
    /// its life, said the way a person would: "Started 2 hours ago" · "Done yesterday" ·
    /// "Canceled 3 days ago". Nil for a plain to-do, which has nothing to report beyond
    /// existing (its capture time is a receipt, and lives under Details).
    ///
    /// Reads the CURRENT visit (`currentStateEnteredAt`), never the summed dwell: a task
    /// picked up, dropped and picked up again is "started" when it was last started.
    /// "took 3d" stays in `summary` — the total is a receipt, the caption is the fact.
    static func caption(
        for task: TaskItem, now: Date = Date(), locale: Locale = .current
    ) -> String? {
        guard task.status != .todo, let at = task.currentStateEnteredAt else { return nil }
        let verb: String
        switch task.status {
        case .doing: verb = "Started"
        case .done: verb = "Done"
        case .canceled: verb = "Canceled"
        case .todo: return nil
        }
        return "\(verb) \(relative(at, now: now, locale: locale))"
    }

    /// "just now" under a minute, otherwise the named relative form ("2 hours ago",
    /// "yesterday"). Sub-minute is special-cased because "in 0 seconds" is what the
    /// formatter says about the tap that just happened.
    static func relative(_ date: Date, now: Date, locale: Locale = .current) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func phrase(for state: TaskStatus) -> String {
        switch state {
        case .todo: return "Queued for"
        case .doing: return "In progress for"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }
}
