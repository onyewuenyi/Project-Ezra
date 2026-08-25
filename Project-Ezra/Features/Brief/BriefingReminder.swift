//
//  BriefingReminder.swift
//  Project-Ezra
//
//  One local notification a day: "your briefing is ready."
//
//  **A deliberate, narrow carve-out.** `prev-docs/product-guardrails.md` lists
//  "notification-driven re-engagement" under Things We Refuse to Build, and that rule
//  stands. What ships here is the opposite of a re-engagement loop, and stays that way
//  only if every one of these holds:
//
//    · ONE notification type. A second one is the signal this was abused.
//    · Off by default, at a time the user picks — an alarm they set, not a hook we cast.
//    · No badges, no counts, no "5 tasks overdue", no escalation, no streaks.
//    · It never fires on a day the briefing already played (see `BriefingSchedule`).
//
//  The rationale: the Today sequence is a once-a-day cinematic moment. A moment that
//  only happens if you remember it isn't a moment, it's a chore — and the guardrail
//  exists to prevent optimizing for sessions, which a single self-scheduled alarm does
//  not do.
//

import Foundation
import UserNotifications

// MARK: - The pure part

/// Scheduling math, with no dependency on the notification centre so it can be tested
/// directly. Time is injected; nothing here reads the clock.
enum BriefingSchedule {

    /// How many days ahead to keep scheduled. A rolling horizon rather than a repeating
    /// trigger: `UNCalendarNotificationTrigger(repeats: true)` cannot skip a day you
    /// already showed up for, and skipping is the whole point. Three days means a long
    /// weekend away still gets nudged, without pretending to schedule forever.
    static let horizon = 3

    /// The next `horizon` firing dates.
    ///
    /// - Today is included only if its time is still ahead AND the briefing has not
    ///   already played today.
    /// - **DST is the calendar's problem, and it handles it.** On a spring-forward day
    ///   whose gap swallows the chosen time, `date(bySettingHour:...)` does not fail —
    ///   it snaps to the first valid instant (verified: 02:30 on 2026-03-08 in New York
    ///   becomes 03:00 EDT). So the day is neither skipped nor duplicated, and the
    ///   sequence stays strictly increasing at one per day. The `continue` below is
    ///   defensive only.
    static func occurrences(
        after now: Date,
        hour: Int,
        minute: Int,
        briefingPlayedToday: Bool,
        calendar: Calendar = .current,
        horizon: Int = horizon
    ) -> [Date] {
        var results: [Date] = []
        // Look one day past the horizon: if today is skipped we still want `horizon`
        // future days, not `horizon - 1`.
        for offset in 0...horizon {
            guard
                let day = calendar.date(byAdding: .day, value: offset, to: now),
                let fire = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if fire <= now { continue }
            if offset == 0 && briefingPlayedToday { continue }
            results.append(fire)
            if results.count == horizon { break }
        }
        return results
    }
}

// MARK: - The notification-centre part

/// Owns authorization, scheduling and the "this open came from a notification" flag.
@Observable
final class BriefingReminder: NSObject, UNUserNotificationCenterDelegate {

    /// Every request this app posts carries this prefix, so a tap can be attributed and
    /// a reschedule only ever cancels its own work.
    static let identifierPrefix = "briefing."

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter

    /// True when the current foreground began with the user tapping the briefing
    /// notification. Consumed once — see `consumeCameFromNotification()`.
    private var cameFromNotification = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
        }
    }

    var hour: Int {
        didSet {
            guard hour != oldValue else { return }
            defaults.set(hour, forKey: Key.hour)
        }
    }

    var minute: Int {
        didSet {
            guard minute != oldValue else { return }
            defaults.set(minute, forKey: Key.minute)
        }
    }

    /// Set when the system says notifications are refused, so the Settings card can say
    /// so instead of silently doing nothing.
    private(set) var isDenied = false

    init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
        self.defaults = defaults
        self.center = center
        self.isEnabled = defaults.bool(forKey: Key.enabled)
        // 8:00am unless chosen otherwise. `object(forKey:)` distinguishes "never set"
        // from a deliberate midnight.
        self.hour = (defaults.object(forKey: Key.hour) as? Int) ?? 8
        self.minute = (defaults.object(forKey: Key.minute) as? Int) ?? 0
        super.init()
        center.delegate = self
    }

    // MARK: Authorization

    /// Ask for permission — only ever called from the Settings toggle, never at launch.
    /// Returns whether the reminder is now usable.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            isDenied = !granted
            return granted
        } catch {
            isDenied = true
            return false
        }
    }

    /// Refresh `isDenied` from the system (the user can revoke in Settings at any time).
    func refreshAuthorizationState() async {
        let settings = await center.notificationSettings()
        isDenied = settings.authorizationStatus == .denied
    }

    // MARK: Scheduling

    /// Cancel everything this app scheduled and lay down the next few days.
    ///
    /// Call on every background transition: that is when we know whether today's
    /// briefing played, and it keeps the horizon rolling without a background task.
    func reschedule(briefingPlayedToday: Bool, now: Date = Date()) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier)
                .filter { $0.hasPrefix(Self.identifierPrefix) })

        guard isEnabled else { return }
        await refreshAuthorizationState()
        guard !isDenied else { return }

        let dates = BriefingSchedule.occurrences(
            after: now, hour: hour, minute: minute, briefingPlayedToday: briefingPlayedToday)

        for date in dates {
            let content = UNMutableNotificationContent()
            content.title = "Your briefing is ready"
            content.body = "A minute to see what today asks of you."
            content.sound = .default
            // No badge, on purpose: a number on the icon is a count, and counts nag.

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(
                identifier: Self.identifierPrefix + ISO8601DateFormatter().string(from: date),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
        }
    }

    /// Drop every scheduled nudge (the toggle going off).
    func cancelAll() async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier)
                .filter { $0.hasPrefix(Self.identifierPrefix) })
    }

    // MARK: Open attribution

    /// Whether this foreground came from tapping the nudge — read once, then cleared.
    ///
    /// This exists to protect `Metrics.selfInitiatedOpens`, which counts every `.active`
    /// transition. An open the app *asked for* is not self-initiated, and letting it
    /// inflate that number would quietly turn the one honest engagement metric into
    /// exactly the vanity number the guardrails refuse to optimize for.
    ///
    /// **Known limitation:** the ordering of `didReceive` against the first `.active`
    /// scene phase is not guaranteed on a COLD launch, so a cold launch from the nudge
    /// can still be counted once. Warm foregrounds — the common case — are exact. Not
    /// worked around, because the alternatives (retracting a counted open, or reaching
    /// into `UIApplication` launch options from the SwiftUI lifecycle) cost more
    /// coupling than a diagnostic counter is worth.
    func consumeCameFromNotification() -> Bool {
        defer { cameFromNotification = false }
        return cameFromNotification
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier.hasPrefix(Self.identifierPrefix) else {
            return
        }
        await MainActor.run {
            self.cameFromNotification = true
            self.pendingOpenBriefing = true
        }
    }

    /// Set when a tap should route the UI to Today. `RootTabView` observes and clears it.
    var pendingOpenBriefing = false

    // Deliberately no `willPresent`: if the app is already open the briefing is a tap
    // away, and a banner over it would be noise.

    private enum Key {
        static let enabled = "briefing.enabled"
        static let hour = "briefing.hour"
        static let minute = "briefing.minute"
    }
}
