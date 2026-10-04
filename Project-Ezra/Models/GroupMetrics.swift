//
//  GroupMetrics.swift
//  Project-Ezra
//
//  The launch plan's group metrics, as pure derivations (2026-10-04).
//
//  **The unit is the group: one household of 1 or N.** The plan measures Ezra the way
//  Linear measures a team — throughput, lead time, cycle time, triage time, issue age — and
//  a family's version of "team" is the household, whatever its size. A solo parent is a
//  group of one, counted like any other; that is the reversal of `HouseholdActivation`'s
//  "a household of one has no load to split", which stays as a participation reading but
//  is no longer the activation metric.
//
//  **Normalization lives on the dashboard; the shapes live here.** Volumes are per event
//  already (`task_completed`, `capture_committed`, each carrying the install's group id),
//  so throughput per active member is a division the console does. What only the device
//  can see is the SHAPE of the group's work, and that is this file: how much of the open
//  work has gone stale, how much was handed to someone other than its creator, how many
//  of the adults took part, and how much of the doing fell on one of them. Participation
//  and load are nil for a group of one, where they would always read 100% and say nothing.
//
//  Same charter as `HouseholdActivation` and `RequiredAttention`: derived over the store
//  the app already holds, never shown to the person as a score, and what leaves is buckets
//  only — one `groupSnapshot` a week per install. Every phone in a shared household sends
//  its own, from the same synced data, so the console keeps one per group per week.
//

import Foundation

struct GroupMetrics: Equatable {

    /// The trailing window every reading looks at, and the snapshot's cadence.
    static let window: TimeInterval = 7 * 24 * 3600

    /// Adults on the roster — the people who plan, not the people planned for.
    let adults: Int
    /// Adults who captured or completed something inside the window.
    let activeMembers: Int
    /// Live tasks (to do or in progress).
    let openCount: Int
    /// Live tasks the product itself calls stale (`TaskItem.isStale`), as a share of live.
    let staleShare: Double?
    /// Tasks confirmed inside the window whose owner is not their creator, as a share of
    /// those with both set.
    let handOffShare: Double?
    /// Active adults ÷ adults. Nil for a group of one.
    let participation: Double?
    /// The busiest adult's share of the window's human completions. Nil for a group of
    /// one, or a week with nothing completed.
    let loadShare: Double?

    static func measure(
        adults: [UUID], tasks: [TaskItem], entries: [ChangeLogEntry], now: Date
    ) -> GroupMetrics {
        let ids = Set(adults)
        let since = now.addingTimeInterval(-window)
        let inWindow = { (date: Date) in date > since && date <= now }

        let acts = HouseholdActivation.acts(by: ids, tasks: tasks, entries: entries)
        let active = Set(acts.filter { inWindow($0.at) }.map(\.actor))

        let open = tasks.filter { $0.status.isLive }
        let stale = open.filter { $0.isStale(now: now) }

        let handed = tasks.filter { task in
            guard let confirmed = task.confirmedAt, inWindow(confirmed) else { return false }
            return task.creatorID != nil && task.ownerID != nil
        }
        let handedOff = handed.filter { $0.ownerID != $0.creatorID }

        var completions: [UUID: Int] = [:]
        for entry in entries
        where entry.action == "completed" && entry.initiatedBy == .human && !entry.undone
            && inWindow(entry.timestamp)
        {
            if let actor = entry.actorID, ids.contains(actor) { completions[actor, default: 0] += 1 }
        }
        let total = completions.values.reduce(0, +)
        let isGroup = ids.count >= 2

        return GroupMetrics(
            adults: ids.count,
            activeMembers: active.count,
            openCount: open.count,
            staleShare: open.isEmpty ? nil : Double(stale.count) / Double(open.count),
            handOffShare: handed.isEmpty ? nil : Double(handedOff.count) / Double(handed.count),
            participation: isGroup ? Double(active.count) / Double(ids.count) : nil,
            loadShare: isGroup && total > 0 ? Double(completions.values.max() ?? 0) / Double(total) : nil)
    }

    /// The store-backed form: the adults from the household itself.
    static func measure(
        household: Household, tasks: [TaskItem], entries: [ChangeLogEntry], now: Date = Date()
    ) -> GroupMetrics {
        measure(
            adults: HouseholdActivation.caretakerIDs(in: household), tasks: tasks, entries: entries, now: now)
    }

    /// The group this install reports as. A household that has no adults on the roster yet
    /// (a first launch mid-onboarding) is still a group of one: the person holding the phone.
    static func group(for household: Household) -> TelemetryGroup {
        TelemetryGroup(
            householdID: household.id, adults: max(1, HouseholdActivation.caretakerIDs(in: household).count))
    }

    /// The reading as the wire carries it: buckets, nil where the share has no meaning.
    var snapshotEvent: TelemetryEvent {
        .groupSnapshot(
            open: CountBucket(openCount), stale: staleShare.map(ShareBucket.init),
            handOff: handOffShare.map(ShareBucket.init), participation: participation.map(ShareBucket.init),
            load: loadShare.map(ShareBucket.init))
    }

    // MARK: - The weekly snapshot

    static let snapshotKey = "groupMetrics.lastSnapshotAt"

    /// Send `groupSnapshot` at most once per window on this install. Called from the hourly
    /// foreground sweep, where the working set is already fetched.
    static func recordWeeklySnapshotIfDue(
        _ reading: GroupMetrics, now: Date, defaults: UserDefaults = .standard
    ) {
        if let last = defaults.object(forKey: snapshotKey) as? Date, now.timeIntervalSince(last) < window {
            return
        }
        defaults.set(now, forKey: snapshotKey)
        Telemetry.log(reading.snapshotEvent, defaults: defaults)
    }
}
