//
//  CapacityBaseline.swift
//  Project-Ezra
//
//  The personalized answer to "how much does THIS user actually get done on a
//  '<capacity>' day?" — computed deterministically from `CapacityLog` history, not
//  by the model (spec §5.3). Deterministic code decides what "Light" means; the
//  model only narrates against the number.
//
//  Cold-start: until there are at least `minSamples` days at a given capacity, the
//  baseline IS the capacity's static `defaultCount`, and `isPersonalized` is false
//  so no personalization claim is made before the data exists (spec §5.6).
//
//  Pure and clock-free — reads a snapshot of logs, returns a value. No model, no
//  side effects.
//

import Foundation

/// The rolling, per-capacity completion baseline. A value type: recomputed fresh
/// from live logs before every plan (so a shifting average needs no session
/// teardown), never stored on a task.
struct CapacityBaseline: Sendable, Equatable {
    let capacity: Capacity
    /// How many that-capacity days informed this baseline (capped at `window`).
    let sampleSize: Int
    /// The personalized "this capacity typically completes N" figure. Equals
    /// `capacity.defaultCount` until `sampleSize >= minSamples`.
    let typicalCompletedCount: Int

    /// The rolling window and the cold-start threshold (spec §5.3).
    static let window = 14
    static let minSamples = 5

    /// True once enough samples exist to make a personalization claim. Before this,
    /// `typicalCompletedCount` is the deterministic default, and the dynamic
    /// instructions omit the baseline sentence entirely (spec §5.6).
    var isPersonalized: Bool { sampleSize >= Self.minSamples }

    /// The §5.5 escalation signal: the observed typical diverges from the static
    /// default by ≥ 2, with enough samples to trust it. Used once to escalate to
    /// the stronger tier so the first personalized plan reads right.
    var isDivergent: Bool {
        isPersonalized && abs(typicalCompletedCount - capacity.defaultCount) >= 2
    }

    /// Roll up the most recent `window` logs at `capacity` into a baseline. Below
    /// `minSamples`, cold-starts to the capacity's default; at or above, the rounded
    /// average of `completedCount` (floored at 1 — a plan is never empty).
    static func baseline(for capacity: Capacity, logs: [CapacityLog]) -> CapacityBaseline {
        let matching =
            logs
            .filter { $0.capacity == capacity }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(window)
        let sampleSize = matching.count
        guard sampleSize >= minSamples else {
            return CapacityBaseline(
                capacity: capacity, sampleSize: sampleSize,
                typicalCompletedCount: capacity.defaultCount)
        }
        let total = matching.reduce(0) { $0 + Int($1.completedCount) }
        let average = Int((Double(total) / Double(sampleSize)).rounded())
        return CapacityBaseline(
            capacity: capacity, sampleSize: sampleSize, typicalCompletedCount: max(1, average))
    }
}
