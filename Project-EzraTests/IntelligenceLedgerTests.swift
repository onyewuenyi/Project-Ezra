//
//  IntelligenceLedgerTests.swift
//  Project-EzraTests
//
//  The meter that has to be trustworthy before anything is capped on it. Challenge 4's
//  sequence is meter → cap → govern, and every step after the first reads
//  `cloudCallsToday` — so the day boundary and the "only the producing tier counts"
//  rule are pinned here rather than discovered when a cap misfires.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Intelligence ledger (per-rung counters)")
struct IntelligenceLedgerTests {

    /// A ledger over a throwaway defaults suite — the shared singleton is real user
    /// state, and a test that incremented it would corrupt the numbers a spend decision
    /// gets made on.
    private func ledger(now: Date = Date()) -> IntelligenceLedger {
        let suite = UserDefaults(suiteName: "ledger.test.\(UUID().uuidString)")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return IntelligenceLedger(defaults: suite, calendar: utc, now: now)
    }

    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    @Test("Counts are per workload AND per rung — an aggregate would hide the question")
    func countsAreTwoDimensional() {
        let ledger = ledger()
        ledger.record(.facts, for: .advisor)
        ledger.record(.facts, for: .advisor)
        ledger.record(.memory, for: .advisor)
        ledger.record(.onDevice, for: .ramble)

        #expect(ledger.counts[.advisor]?[.facts] == 2)
        #expect(ledger.counts[.advisor]?[.memory] == 1)
        #expect(ledger.counts[.advisor]?[.onDevice] == 0)
        #expect(ledger.counts[.ramble]?[.onDevice] == 1)
        // Untouched workloads stay at zero rather than absent — the grid is total, so a
        // reader can tell "never happened" from "never instrumented".
        #expect(ledger.counts[.sweeps]?[.cloud] == 0)
    }

    @Test("Only cloud records touch the daily number")
    func onlyCloudCounts() {
        let ledger = ledger()
        for rung in [IntelligenceRung.facts, .memory, .onDevice] {
            ledger.record(rung, for: .brief)
        }
        #expect(ledger.cloudCallsToday() == 0)
        ledger.record(.cloud, for: .brief)
        #expect(ledger.cloudCallsToday() == 1)
    }

    @Test("The daily cloud count rolls over at the day boundary, on write")
    func dailyCountRollsOver() {
        let monday = day("2026-08-17 09:00")
        let ledger = ledger(now: monday)
        ledger.record(.cloud, for: .advisor, now: monday)
        ledger.record(.cloud, for: .advisor, now: day("2026-08-17 23:59"))
        #expect(ledger.cloudCallsToday(now: monday) == 2)

        // A new day starts the count over — the cap is DAILY, so a count carried across
        // midnight would silently halve the next day's budget.
        let tuesday = day("2026-08-18 08:00")
        ledger.record(.cloud, for: .advisor, now: tuesday)
        #expect(ledger.cloudCallsToday(now: tuesday) == 1)
        // Lifetime tallies are unaffected — the rollover is the daily number's alone.
        #expect(ledger.counts[.advisor]?[.cloud] == 3)
    }

    @Test("Reading after midnight reports zero WITHOUT discarding the stored count")
    func readingIsPure() {
        let monday = day("2026-08-17 09:00")
        let ledger = ledger(now: monday)
        ledger.record(.cloud, for: .brief, now: monday)

        let tuesday = day("2026-08-18 08:00")
        // The read must answer honestly for `tuesday`…
        #expect(ledger.cloudCallsToday(now: tuesday) == 0)
        // …and must not be what throws Monday away: a footer nobody looked at should not
        // be the difference between a correct and an incorrect count.
        #expect(ledger.cloudCallsToday(now: monday) == 1)
    }

    @Test("Counters survive a relaunch — they are evidence, not session state")
    func countersPersist() {
        let suite = UserDefaults(suiteName: "ledger.test.\(UUID().uuidString)")!
        let first = IntelligenceLedger(defaults: suite)
        first.record(.cloud, for: .ramble)
        first.record(.facts, for: .ramble)

        let reopened = IntelligenceLedger(defaults: suite)
        #expect(reopened.counts[.ramble]?[.cloud] == 1)
        #expect(reopened.counts[.ramble]?[.facts] == 1)
        #expect(reopened.cloudCallsToday() == 1)
    }

    @Test("Reset clears both the tallies and the daily number, in memory and on disk")
    func resetClearsEverything() {
        let suite = UserDefaults(suiteName: "ledger.test.\(UUID().uuidString)")!
        let ledger = IntelligenceLedger(defaults: suite)
        ledger.record(.cloud, for: .brief)
        ledger.record(.onDevice, for: .advisor)
        ledger.reset()

        #expect(ledger.cloudCallsToday() == 0)
        #expect(ledger.counts[.brief]?[.cloud] == 0)
        #expect(ledger.counts[.advisor]?[.onDevice] == 0)
        // Cached-at-init state is the trap `PlanMetrics.reset` documents: clearing the
        // keys alone leaves yesterday's numbers on the footer until the next launch.
        #expect(IntelligenceLedger(defaults: suite).cloudCallsToday() == 0)
    }

    @Test("A workload with no activity prints no line; the daily cloud line always does")
    func footerOmitsSilentWorkloads() {
        let ledger = ledger()
        #expect(ledger.footerLines().isEmpty)

        ledger.record(.facts, for: .advisor)
        let lines = ledger.footerLines()
        #expect(lines.contains { $0.hasPrefix("rungs advisor:") })
        #expect(!lines.contains { $0.hasPrefix("rungs ramble:") })
        // Zero paid calls is an ANSWER, so it prints — a missing line would read as
        // missing instrumentation.
        #expect(lines.contains("cloud today: 0"))
    }

    @Test("Every plan tier maps to a rung, and only the cloud tier maps to the paid one")
    func planTierRungMapping() {
        #expect(PlanTier.onDevice.rung == .onDevice)
        #expect(PlanTier.cloud.rung == .cloud)
        // The deterministic tail is Rung 0, not a fourth thing: it is fact-fed template
        // content, free and offline.
        #expect(PlanTier.deterministic.rung == .facts)
        // Exactly ONE paid tier. A second would mean two privacy stories and two
        // failure modes behind one slot — the thing `CloudModelProvider` is singular to
        // prevent — so a new tier mapping to `.cloud` should fail here first.
        #expect(PlanTier.allCases.filter { $0.rung == .cloud }.count == 1)
    }

    @Test("The cloud slot is unavailable until its provider is configured, and never traps")
    func cloudSlotIsClosedByDefault() {
        // This asks the question every launch asks, and the fact that asking it neither
        // crashes nor goes to the network IS the assertion. The protocol requires
        // `isAvailable` to answer from something cheap and local: PCC fatal-errored on
        // construction without its entitlement, and `GeminiProvider` would otherwise
        // turn every routing decision into a round trip. Under a suite Firebase is
        // deliberately never configured (`AppDelegate`), so the slot reads closed.
        #expect(CloudModel.isAvailable == false)
        #expect(CloudModel.label == "cloud(gemini-flash)")
    }

    @Test("Capture's two routes map to distinct rungs, and only one is paid")
    func captureRouteRungMapping() {
        #expect(CaptureRoute.local.rung == .facts)
        #expect(CaptureRoute.cloud.rung == .cloud)
        #expect(CaptureRoute.allCases.filter { $0.rung == .cloud }.count == 1)
    }
}
