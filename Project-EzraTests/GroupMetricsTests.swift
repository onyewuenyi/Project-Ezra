//
//  GroupMetricsTests.swift
//  Project-EzraTests
//
//  The group metrics as pure derivations (`GroupMetrics`): the unit is one household of 1
//  or N; participation and load have no meaning for a group of one and read nil; stale is
//  the product's own flag; the weekly snapshot fires once per window and leaves as buckets.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Group metrics — a household of 1 or N")
struct GroupMetricsTests {

    private let context = PersistenceStack.scratch
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func task(by creator: UUID, owner: UUID? = nil, confirmed: Date, touched: Date? = nil) -> TaskItem
    {
        let task = TaskItem(title: "Something \(UUID().uuidString.prefix(4))", in: context)
        task.creatorID = creator
        task.ownerID = owner
        task.confirmedAt = confirmed
        task.lastHumanTouchAt = touched ?? confirmed
        return task
    }

    private func completion(by actor: UUID, at: Date) -> ChangeLogEntry {
        ChangeLogEntry(
            summary: "Completed", action: "completed", initiatedBy: .human, actorID: actor, timestamp: at,
            in: context)
    }

    @Test("A group of one is measured, and participation and load read nil rather than 100%")
    func soloGroup() {
        let me = UUID()
        let reading = GroupMetrics.measure(
            adults: [me], tasks: [task(by: me, confirmed: now.addingTimeInterval(-day))],
            entries: [completion(by: me, at: now.addingTimeInterval(-3600))], now: now)
        #expect(reading.adults == 1)
        #expect(reading.activeMembers == 1)
        #expect(reading.openCount == 1)
        #expect(reading.participation == nil)
        #expect(reading.loadShare == nil)
    }

    @Test("Load share is the busiest adult's share of the week's completions")
    func loadShare() {
        let me = UUID(), partner = UUID()
        let entries =
            (0..<9).map { completion(by: me, at: now.addingTimeInterval(-Double($0 + 1) * 3600)) }
            + [completion(by: partner, at: now.addingTimeInterval(-60))]
        let reading = GroupMetrics.measure(adults: [me, partner], tasks: [], entries: entries, now: now)
        #expect(reading.loadShare == 0.9)
        #expect(reading.participation == 1.0)
        #expect(ShareBucket(reading.loadShare!) == .ninetyPlus)
    }

    @Test("A partner who never acts halves participation; last week's acts do not count")
    func participationUsesTheWindow() {
        let me = UUID(), partner = UUID()
        let reading = GroupMetrics.measure(
            adults: [me, partner], tasks: [task(by: partner, confirmed: now.addingTimeInterval(-9 * day))],
            entries: [completion(by: me, at: now.addingTimeInterval(-day))], now: now)
        #expect(reading.activeMembers == 1)
        #expect(reading.participation == 0.5)
        #expect(reading.loadShare == 1.0)
    }

    @Test("Hand-off counts this week's tasks owned by someone other than their creator")
    func handOff() {
        let me = UUID(), partner = UUID()
        let tasks = [
            task(by: me, owner: partner, confirmed: now.addingTimeInterval(-day)),
            task(by: me, owner: me, confirmed: now.addingTimeInterval(-day)),
            task(by: me, owner: me, confirmed: now.addingTimeInterval(-2 * day)),
            task(by: me, owner: partner, confirmed: now.addingTimeInterval(-20 * day)),
        ]
        let reading = GroupMetrics.measure(adults: [me, partner], tasks: tasks, entries: [], now: now)
        #expect(reading.handOffShare == 1.0 / 3.0)
    }

    @Test("Stale share uses the product's own stale flag over live tasks only")
    func staleShare() {
        let me = UUID()
        let fresh = task(by: me, confirmed: now.addingTimeInterval(-day))
        let stale = task(by: me, confirmed: now.addingTimeInterval(-30 * day))
        let done = task(by: me, confirmed: now.addingTimeInterval(-30 * day))
        done.complete(now: now.addingTimeInterval(-20 * day))
        let reading = GroupMetrics.measure(adults: [me], tasks: [fresh, stale, done], entries: [], now: now)
        #expect(reading.openCount == 2)
        #expect(reading.staleShare == 0.5)
    }

    @Test("The snapshot leaves as buckets, once per week")
    func weeklySnapshot() {
        let defaults = UserDefaults(suiteName: "GroupMetricsTests.\(UUID())")!
        let sink = RecordingTelemetrySink()
        let previous = Telemetry.sink
        Telemetry.sink = sink
        defer { Telemetry.sink = previous }

        let me = UUID()
        let reading = GroupMetrics.measure(
            adults: [me], tasks: [task(by: me, confirmed: now.addingTimeInterval(-day))], entries: [],
            now: now)
        GroupMetrics.recordWeeklySnapshotIfDue(reading, now: now, defaults: defaults)
        GroupMetrics.recordWeeklySnapshotIfDue(
            reading, now: now.addingTimeInterval(3 * day), defaults: defaults)
        #expect(sink.events.count == 1)
        #expect(sink.events.first?.name == "group_snapshot")
        #expect(sink.events.first?.metadata == ["open": "one", "stale": "0"])

        GroupMetrics.recordWeeklySnapshotIfDue(
            reading, now: now.addingTimeInterval(8 * day), defaults: defaults)
        #expect(sink.events.count == 2)
    }
}
