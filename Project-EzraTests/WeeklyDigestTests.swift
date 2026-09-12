//
//  WeeklyDigestTests.swift
//  Project-EzraTests
//
//  The Sunday digest's deterministic half (`WeeklyDigest`): what it says, when it says
//  nothing, when it fires, and who it is on for by default. The notification-centre half
//  (`WeeklyDigestScheduler`) is a thin wrapper over these and over `UNUserNotificationCenter`,
//  which a unit test cannot exercise.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Weekly digest — the one notification")
struct WeeklyDigestTests {

    private let context = PersistenceStack.scratch
    /// A Wednesday, 10:00 local.
    private var wednesday: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 16
        components.hour = 10
        return Calendar.current.date(from: components)!
    }

    private func task(_ title: String, due: Date? = nil, decision: Bool = false) -> TaskItem {
        let item = TaskItem(title: title, in: context)
        item.dueDate = due
        item.needsDecision = decision
        return item
    }

    @Test("An empty week composes NOTHING — and nothing is what gets scheduled")
    func silentWhenEmpty() {
        #expect(WeeklyDigest.compose(tasks: [], now: wednesday) == nil)
        let undated = task("Someday")
        #expect(WeeklyDigest.compose(tasks: [undated], now: wednesday) == nil)
        let farOff = task("Next month", due: wednesday.addingTimeInterval(30 * 24 * 3600))
        #expect(WeeklyDigest.compose(tasks: [farOff], now: wednesday) == nil)
    }

    @Test("Due this week, overdue and decisions each earn a sentence; resolved tasks never do")
    func composesTheWeek() throws {
        let soon = task("Daycare forms", due: wednesday.addingTimeInterval(2 * 24 * 3600))
        let later = task("Water bill", due: wednesday.addingTimeInterval(5 * 24 * 3600))
        let third = task("Oil change", due: wednesday.addingTimeInterval(6 * 24 * 3600))
        let late = task("Passport", due: wednesday.addingTimeInterval(-3 * 24 * 3600))
        let choice = task("Keep the gym?", decision: true)
        let done = task("Done thing", due: wednesday.addingTimeInterval(24 * 3600))
        done.complete(now: wednesday)

        let digest = try #require(
            WeeklyDigest.compose(tasks: [later, soon, third, late, choice, done], now: wednesday))
        #expect(digest.title == "Your week ahead")
        #expect(digest.body.hasPrefix("Coming up: Daycare forms ("), "earliest due first")
        #expect(digest.body.contains("Water bill ("))
        #expect(digest.body.contains("and 1 more"), "at most two titles are named")
        #expect(!digest.body.contains("Oil change"))
        #expect(digest.body.contains("1 thing is overdue."))
        #expect(digest.body.contains("1 decision is waiting on you."))
        #expect(!digest.body.contains("Done thing"))
    }

    @Test("It fires the next Sunday at 18:00 — this Sunday if we're before it, next if we're past")
    func nextSunday() {
        let calendar = Calendar.current
        let fromWednesday = WeeklyDigest.nextFireDate(after: wednesday, calendar: calendar)
        var parts = calendar.dateComponents([.weekday, .hour, .minute], from: fromWednesday)
        #expect(parts.weekday == 1 && parts.hour == 18 && parts.minute == 0)
        #expect(fromWednesday.timeIntervalSince(wednesday) < 7 * 24 * 3600)

        let sundayEvening = calendar.date(byAdding: .hour, value: 1, to: fromWednesday)!
        let following = WeeklyDigest.nextFireDate(after: sundayEvening, calendar: calendar)
        parts = calendar.dateComponents([.weekday, .hour], from: following)
        #expect(parts.weekday == 1 && parts.hour == 18)
        #expect(following.timeIntervalSince(fromWednesday) > 6 * 24 * 3600)
    }

    @Test("On by default for two caretakers, off for one, and the person's choice wins either way")
    func defaultFollowsTheHousehold() {
        let defaults = UserDefaults(suiteName: "WeeklyDigestTests.\(UUID())")!
        #expect(!WeeklyDigest.isEnabled(caretakerCount: 1, defaults: defaults))
        #expect(WeeklyDigest.isEnabled(caretakerCount: 2, defaults: defaults))
        defaults.set(false, forKey: WeeklyDigest.enabledKey)
        #expect(!WeeklyDigest.isEnabled(caretakerCount: 2, defaults: defaults))
        defaults.set(true, forKey: WeeklyDigest.enabledKey)
        #expect(WeeklyDigest.isEnabled(caretakerCount: 1, defaults: defaults))
    }

    @Test("One identifier, so scheduling replaces and never stacks")
    func oneIdentifier() {
        #expect(WeeklyDigest.identifier == "weeklyDigest")
    }
}
