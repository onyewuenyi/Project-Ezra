//
//  InstrumentTests.swift
//  Project-EzraTests
//
//  The bracket, bracketed. An instrument that cannot be shown to catch a bad arm is a
//  blind scorer — so the shared pieces are held to §11's own three rules.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Instrument — the measurement bracket")
struct InstrumentTests {

    private func stats(
        successes: Int = 0, salvaged: Int = 0, timeouts: Int = 0, failures: Int = 0, error: String? = nil
    )
        -> ModelMetrics.Stats
    {
        var s = ModelMetrics.Stats()
        s.successes = successes
        s.salvaged = salvaged
        s.timeouts = timeouts
        s.failures = failures
        s.lastError = error
        return s
    }

    @Test("A served ratio is a delta, and salvage counts as served")
    func delta() {
        let before = stats(successes: 10, salvaged: 1, timeouts: 2, failures: 1)
        let after = stats(successes: 50, salvaged: 5, timeouts: 4, failures: 2, error: "timedOut")
        let d = Instrument.ArmDelta.between(before, after)
        #expect(d.served == 44)
        #expect(d.attempted == 47)
        #expect(d.isCredible)
        #expect(Instrument.degradedBanner(d, arm: "on-device") == nil)
    }

    @Test("The rule-2 bracket: an arm serving 2 of 52 is DEGRADED, and the banner names the error")
    func degraded() {
        let d = Instrument.ArmDelta.between(
            stats(), stats(successes: 2, timeouts: 0, failures: 50, error: "LanguageModelError -1"))
        #expect(!d.isCredible)
        let banner = Instrument.degradedBanner(d, arm: "on-device")
        #expect(banner?.hasPrefix("DEGRADED") == true)
        #expect(banner?.contains("3%") == true)
        #expect(banner?.contains("LanguageModelError -1") == true)
    }

    @Test("An arm that attempted nothing is DEGRADED too — zero served must never read as a pass")
    func nothingAttempted() {
        let d = Instrument.ArmDelta.between(stats(), stats())
        #expect(!d.isCredible)
        #expect(Instrument.degradedBanner(d, arm: "cloud")?.contains("attempted no calls") == true)
    }

    @Test("Rule 3: a provider call on a zero-cloud run invalidates the run")
    func zeroCloud() {
        #expect(Instrument.zeroCloudViolation(providerCallsBefore: 3, providerCallsAfter: 3) == nil)
        #expect(
            Instrument.zeroCloudViolation(providerCallsBefore: 3, providerCallsAfter: 4)?
                .hasPrefix("RUN INVALID") == true)
    }

    @Test("Rule 1: a scorer that passes both a clean and a reckless input is blind")
    func bracket() {
        #expect(Instrument.bracketHolds(cleanFlags: 0, recklessFlags: 2))
        #expect(!Instrument.bracketHolds(cleanFlags: 0, recklessFlags: 0))
        #expect(!Instrument.bracketHolds(cleanFlags: 1, recklessFlags: 2))
    }

    @Test("Percentiles and the arm line are stable")
    func armLine() {
        let latencies: [Double] = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
        #expect(Instrument.percentile(latencies, 0.5) == 600)
        #expect(Instrument.percentile(latencies, 0.9) == 1000)
        #expect(Instrument.percentile([], 0.5) == 0)
        let d = Instrument.ArmDelta(served: 9, attempted: 10, lastError: nil)
        let line = Instrument.armLine("model", delta: d, latenciesMs: latencies, suffix: "grounding flags 0")
        #expect(line == "model arm: served 9/10 · p50 600ms · p90 1000ms · grounding flags 0")
    }
}
