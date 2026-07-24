//
//  CapacityLog.swift
//  Project-Ezra
//
//  One row per day: the capacity the user chose, how big that day's plan was, and
//  how it actually resolved (completed vs. skipped). Written at the next-day Recap
//  moment (reconciliation reuses that beat — no new surface), never mid-day.
//
//  This is BOTH the personalization substrate (see `CapacityBaseline`, which reads
//  a rolling window of these) AND instrumentation (spec §7) — the rows are the
//  ground truth for "what does this user's 'Light' day actually look like?". They
//  never touch a task: capacity is user/session data on its own axis, so the
//  three-dimensions-never-fused invariant holds.
//
//  CloudKit-compatible per the house conventions: optional identity, defaulted
//  scalars. Same convenience-init idiom as `Correction`.
//

import CoreData

@objc(CapacityLog)
final class CapacityLog: NSManagedObject {
    /// Stable identity, mirroring the other models' UUID idiom.
    @NSManaged var uuid: UUID?
    /// The calendar day this row summarizes (start-of-day). One row per day.
    @NSManaged var date: Date?
    @NSManaged private var capacityRaw: String
    /// How many actions that day's plan contained.
    @NSManaged var planCount: Int64
    /// How many of the planned actions were resolved `.done` by day's end.
    @NSManaged var completedCount: Int64
    /// How many of the planned actions were still open at day's end.
    @NSManaged var skippedCount: Int64

    var capacity: Capacity {
        get { Capacity(rawValue: capacityRaw) ?? .steady }
        set { capacityRaw = newValue.rawValue }
    }

    convenience init(
        date: Date,
        capacity: Capacity,
        planCount: Int,
        completedCount: Int,
        skippedCount: Int,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "CapacityLog", in: context)!,
            insertInto: context)
        self.uuid = UUID()
        self.date = date
        self.capacityRaw = capacity.rawValue
        self.planCount = Int64(planCount)
        self.completedCount = Int64(completedCount)
        self.skippedCount = Int64(skippedCount)
    }
}
