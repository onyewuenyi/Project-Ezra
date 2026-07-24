//
//  CapacityBaselineTests.swift
//  Project-EzraTests
//
//  The baseline is what makes personalization deterministic: code decides what a
//  user's "Light" day is, from a rolling window of CapacityLog history — the model
//  never does. Cold-start honesty (no claim before data), the 14-day window, the
//  rounded average, and the divergence signal are all invariants.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Capacity baseline")
struct CapacityBaselineTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A CapacityLog fixture in the scratch context (pure baseline math never saves).
    private func log(_ capacity: Capacity, completed: Int, dayOffset: Int) -> CapacityLog {
        CapacityLog(
            date: epoch.addingTimeInterval(Double(dayOffset) * 24 * 3600),
            capacity: capacity, planCount: completed + 1, completedCount: completed,
            skippedCount: 1)
    }

    @Test("Cold start: below the sample threshold, the baseline is the static default")
    func coldStart() {
        let logs = (0..<3).map { log(.light, completed: 5, dayOffset: $0) }
        let baseline = CapacityBaseline.baseline(for: .light, logs: logs)
        #expect(baseline.sampleSize == 3)
        #expect(baseline.typicalCompletedCount == Capacity.light.defaultCount)  // 2
        #expect(!baseline.isPersonalized)
        #expect(!baseline.isDivergent)
    }

    @Test("At the threshold, the baseline is the rounded average of completions")
    func rollingAverage() {
        // completedCount 1,2,3,4,5 → average 3.
        let logs = (1...5).map { log(.steady, completed: $0, dayOffset: $0) }
        let baseline = CapacityBaseline.baseline(for: .steady, logs: logs)
        #expect(baseline.sampleSize == 5)
        #expect(baseline.typicalCompletedCount == 3)
        #expect(baseline.isPersonalized)
    }

    @Test("Only the most recent 14 that-capacity days inform the baseline")
    func fourteenDayWindow() {
        // 14 recent days completing 6, plus 6 older days completing 0.
        let recent = (0..<14).map { log(.full, completed: 6, dayOffset: 100 + $0) }
        let older = (0..<6).map { log(.full, completed: 0, dayOffset: $0) }
        let baseline = CapacityBaseline.baseline(for: .full, logs: older + recent)
        #expect(baseline.sampleSize == 14)
        #expect(baseline.typicalCompletedCount == 6)  // the older zeros are outside the window
    }

    @Test("Only same-capacity logs count toward a capacity's baseline")
    func capacityFiltering() {
        let steady = (0..<5).map { log(.steady, completed: 4, dayOffset: $0) }
        let light = (0..<10).map { log(.light, completed: 1, dayOffset: 100 + $0) }
        let baseline = CapacityBaseline.baseline(for: .steady, logs: steady + light)
        #expect(baseline.sampleSize == 5)
        #expect(baseline.typicalCompletedCount == 4)
    }

    @Test("Divergence: enough samples and typical differs from default by ≥ 2")
    func divergence() {
        // full defaults to 6; a user who completes ~3 on full days is divergent.
        let low = (0..<6).map { log(.full, completed: 3, dayOffset: $0) }
        #expect(CapacityBaseline.baseline(for: .full, logs: low).isDivergent)

        // A user tracking the default is not divergent.
        let onTrack = (0..<6).map { log(.full, completed: 6, dayOffset: $0) }
        #expect(!CapacityBaseline.baseline(for: .full, logs: onTrack).isDivergent)

        // Not enough samples → never divergent, whatever the numbers say.
        let sparse = (0..<3).map { log(.full, completed: 1, dayOffset: $0) }
        #expect(!CapacityBaseline.baseline(for: .full, logs: sparse).isDivergent)
    }
}
