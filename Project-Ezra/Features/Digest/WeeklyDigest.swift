//
//  WeeklyDigest.swift
//  Project-Ezra
//
//  The Sunday-evening household digest — the ONE notification this product sends, and a
//  NEW carve-out from the "zero notifications" rule, argued from scratch in
//  `prev-docs/product-guardrails.md` on 2026-09-12. Read that argument before touching
//  the rhythm, the content or the default; the invariants are restated here.
//
//  **What it is.** Family planning has a weekly rhythm — the school email arrives Friday,
//  the week is planned Sunday night — and this is a household artifact that matches it:
//  once a week, on Sunday evening, what the coming week holds for the household. It is
//  the shared plan's weekly edition, not a reminder to open an app.
//
//  **What keeps it on the right side of the guardrail** (each is code, not policy):
//    · ONE per week, one identifier (`identifier`) — scheduling replaces, never stacks.
//    · It is SILENT when there is nothing to say — `compose` returns nil for a week with
//      nothing due, nothing overdue and no decision waiting, and nil schedules NOTHING.
//      A notification that fires to say "nothing" is the engagement shape the rule
//      refuses; this one is skipped and the skip is a counted decision (`digestSkipped`).
//    · It is a HOUSEHOLD artifact: enabled by default only once the household has two
//      caretakers (the plan's "both caretakers can see and trust"), off for a household
//      of one, and one switch in Settings turns it off for good (`enabledKey`).
//    · No badge, no count, no escalation, no second type. A tap opens Tasks — the record
//      — never a special landing surface.
//    · It never inflates the one honest pull metric: an open from the digest is excluded
//      from `Metrics.selfInitiatedOpens` (`WeeklyDigestScheduler.consumeNotificationOpen`).
//    · It is remotely killable (`TelemetryGate.killWeeklyDigest`) — a kill switch, never
//      a way to change what it says.
//
//  **Composition is deterministic** (`TaskRanking`'s bands, no model): due-in-the-week,
//  overdue, decisions waiting. The body names at most two titles, because a notification
//  is a glance, and titles are local — the content never leaves the device.
//

import Foundation

struct WeeklyDigest: Equatable {
    let title: String
    let body: String

    /// The week's edition, or nil when the week is empty — and nil means no notification.
    static func compose(tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> WeeklyDigest? {
        let live = tasks.filter { $0.status.isLive }
        let weekEnd = now.addingTimeInterval(7 * 24 * 3600)
        let dueThisWeek =
            live.filter { task in
                guard let due = task.dueDate else { return false }
                return due >= calendar.startOfDay(for: now) && due <= weekEnd
            }
            .sorted { ($0.dueDate ?? now) < ($1.dueDate ?? now) }
        let overdue = live.filter { $0.isOverdue(now: now) }
        let decisions = live.filter(\.needsDecision)

        guard !dueThisWeek.isEmpty || !overdue.isEmpty || !decisions.isEmpty else { return nil }

        var lines: [String] = []
        if !dueThisWeek.isEmpty {
            let named = dueThisWeek.prefix(2).map { task -> String in
                if let due = task.dueDate {
                    return "\(task.title) (\(weekdayName(due, calendar: calendar)))"
                }
                return task.title
            }
            let rest = dueThisWeek.count - named.count
            lines.append(
                "Coming up: " + named.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "") + ".")
        }
        if !overdue.isEmpty {
            lines.append(overdue.count == 1 ? "1 thing is overdue." : "\(overdue.count) things are overdue.")
        }
        if !decisions.isEmpty {
            lines.append(
                decisions.count == 1
                    ? "1 decision is waiting on you." : "\(decisions.count) decisions are waiting on you.")
        }
        return WeeklyDigest(title: "Your week ahead", body: lines.joined(separator: " "))
    }

    private static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale.current
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    // MARK: - The rhythm

    /// Sunday, 18:00 local.
    static let weekday = 1
    static let hour = 18

    /// The next Sunday 18:00 strictly after `now`.
    static func nextFireDate(after now: Date, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now
    }

    /// Whether the digest is on for this install: the persisted choice when there is one,
    /// otherwise the household rule — on for two or more caretakers, off for one.
    static func isEnabled(caretakerCount: Int, defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: enabledKey) != nil { return defaults.bool(forKey: enabledKey) }
        return caretakerCount >= 2
    }

    static let enabledKey = "digest.enabled"
    static let identifier = "weeklyDigest"
}
