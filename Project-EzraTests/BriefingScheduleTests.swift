//
//  BriefingScheduleTests.swift
//  Project-EzraTests
//
//  The daily nudge is a deliberate carve-out from the "no notification-driven
//  re-engagement" guardrail, and the thing that keeps it honest is mechanical: it must
//  never fire on a day the briefing already played. That rule lives here, in the pure
//  half, so it can be asserted rather than trusted.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Briefing schedule")
struct BriefingScheduleTests {

    /// A fixed calendar so the assertions don't move with the machine's locale.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test("Today counts when its time is still ahead and the briefing hasn't played")
    func includesTodayWhenStillAhead() {
        let now = date(2026, 7, 26, 6, 0)
        let dates = BriefingSchedule.occurrences(
            after: now, hour: 8, minute: 0, briefingPlayedToday: false, calendar: calendar)

        #expect(dates.first == date(2026, 7, 26, 8, 0))
    }

    @Test("Today is skipped once the briefing has played — the carve-out's core promise")
    func skipsTodayOncePlayed() {
        let now = date(2026, 7, 26, 6, 0)
        let dates = BriefingSchedule.occurrences(
            after: now, hour: 8, minute: 0, briefingPlayedToday: true, calendar: calendar)

        #expect(dates.first == date(2026, 7, 27, 8, 0))
    }

    @Test("A time already past today rolls to tomorrow")
    func skipsTodayWhenTimePassed() {
        let now = date(2026, 7, 26, 9, 30)
        let dates = BriefingSchedule.occurrences(
            after: now, hour: 8, minute: 0, briefingPlayedToday: false, calendar: calendar)

        #expect(dates.first == date(2026, 7, 27, 8, 0))
    }

    @Test("The horizon is filled even when today is skipped")
    func fillsHorizonAfterSkip() {
        let now = date(2026, 7, 26, 9, 30)
        let dates = BriefingSchedule.occurrences(
            after: now, hour: 8, minute: 0, briefingPlayedToday: false, calendar: calendar)

        #expect(dates.count == BriefingSchedule.horizon)
        #expect(
            dates == [
                date(2026, 7, 27, 8, 0), date(2026, 7, 28, 8, 0), date(2026, 7, 29, 8, 0),
            ])
    }

    @Test("Occurrences are strictly increasing and all in the future")
    func strictlyIncreasingAndFuture() {
        let now = date(2026, 7, 26, 6, 0)
        let dates = BriefingSchedule.occurrences(
            after: now, hour: 8, minute: 0, briefingPlayedToday: false, calendar: calendar)

        #expect(dates.allSatisfy { $0 > now })
        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count)
    }

    @Test("A spring-forward day still gets exactly one nudge, at a real instant")
    func handlesDSTGap() {
        // 2026-03-08 in New York: 02:00 → 03:00 never happens. Foundation does not fail
        // on the missing time — it snaps to the first valid instant (03:00 EDT). What
        // matters is that the gap day is neither skipped nor doubled, so the horizon
        // still means "one a day".
        let now = date(2026, 3, 7, 12, 0)
        let dates = BriefingSchedule.occurrences(
            after: now, hour: 2, minute: 30, briefingPlayedToday: false, calendar: calendar)

        #expect(dates.count == BriefingSchedule.horizon)
        #expect(dates == dates.sorted())
        // One per calendar day, gap day included.
        let days = dates.map { calendar.startOfDay(for: $0) }
        #expect(Set(days).count == dates.count)
        // The gap day's nudge lands after the gap, not inside it.
        let gapDay = try? #require(dates.first { calendar.component(.day, from: $0) == 8 })
        if let gapDay {
            #expect(calendar.component(.hour, from: gapDay) == 3)
        }
    }

    @Test("Nothing is scheduled at all when the horizon is zero")
    func respectsHorizon() {
        let now = date(2026, 7, 26, 6, 0)
        let dates = BriefingSchedule.occurrences(
            after: now, hour: 8, minute: 0, briefingPlayedToday: false, calendar: calendar,
            horizon: 1)

        #expect(dates.count == 1)
    }
}
