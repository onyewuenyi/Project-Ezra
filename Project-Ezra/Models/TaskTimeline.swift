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
        return "\(task.status == .killed ? "Killed" : "Done") · took \(took)"
    }

    /// Unresolved: how long it has been sitting in the state it's in now.
    private static func dwellSummary(_ task: TaskItem, now: Date) -> String? {
        guard let dwell = compactDuration(task.secondsIn(task.status, now: now)) else { return nil }
        return "\(phrase(for: task.status)) \(dwell)"
    }

    private static func phrase(for state: TaskStatus) -> String {
        switch state {
        case .inbox: return "Awaiting your confirm for"
        case .active: return "Active for"
        case .done: return "Done"
        case .killed: return "Killed"
        }
    }
}
