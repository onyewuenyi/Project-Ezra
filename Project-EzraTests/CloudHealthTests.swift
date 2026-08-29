//
//  CloudHealthTests.swift
//  Project-EzraTests
//
//  The cloud rung's circuit breaker. These pin the two properties the capture path's
//  latency now rests on, and one that looks like a bug and isn't.
//
//  What made this necessary: `CloudModelProvider.isAvailable` is configuration presence
//  (`FirebaseApp.app() != nil`), so an exhausted quota reported a healthy provider
//  forever. Every capture re-issued a doomed call and then waited `captureHedgeSeconds`
//  behind it. The breaker is the memory that was missing.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CloudHealthTests {

    /// A fresh breaker per test — `CloudHealth.shared` is a process singleton and these
    /// assertions are about state transitions, so they must not inherit each other's.
    private func fresh() -> CloudHealth {
        let health = CloudHealth.shared
        health.reset()
        return health
    }

    /// Errors shaped like the real vocabulary, by the only channel classification
    /// actually reads: `AppBrain.errorLabel`'s string. A struct with a custom
    /// description is the honest fixture here — the Firebase quota error this exists for
    /// is a private type that lands in `errorLabel`'s unmapped arm exactly like this.
    private struct LabeledError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Classification

    @Test("A refusal, a transport failure and a content failure are three different facts")
    func classification() {
        // The service said "not now" — however it phrases it.
        #expect(CloudHealth.kind(ofLabel: "rateLimited") == .refused)
        #expect(CloudHealth.kind(ofLabel: "GenerativeError: quota exceeded") == .refused)
        // Every separator form of the same concept. The underscore spelling is the gRPC
        // status code, which is how a Firebase quota error actually arrives — and it is
        // the one the first version of the classifier missed, so the breaker sat
        // classifying real 429s as transient and needing two of them.
        #expect(CloudHealth.kind(ofLabel: "BackendError: RESOURCE_EXHAUSTED (429)") == .refused)
        #expect(CloudHealth.kind(ofLabel: "resource exhausted") == .refused)
        #expect(CloudHealth.kind(ofLabel: "rate-limited") == .refused)
        #expect(CloudHealth.kind(ofLabel: "HTTPError: 429 Too Many Requests") == .refused)

        // The service ANSWERED and the answer was unusable. Bytes made the round trip,
        // so this is evidence of health — see `contentFailuresCountAsHealth`.
        #expect(CloudHealth.kind(ofLabel: "guardrailViolation") == .contentual)
        #expect(CloudHealth.kind(ofLabel: "decodingFailure") == .contentual)
        #expect(CloudHealth.kind(ofLabel: "unsupportedCapability") == .contentual)
        #expect(CloudHealth.kind(ofLabel: "exceededContextWindowSize") == .contentual)

        // Anything else is a request that may simply not have arrived.
        #expect(CloudHealth.kind(ofLabel: "URLError: notConnectedToInternet") == .transient)
        #expect(CloudHealth.kind(ofLabel: "timedOut") == .transient)
    }

    // MARK: - Opening

    @Test("One refusal is enough to open the breaker")
    func refusalOpensImmediately() {
        let health = fresh()
        #expect(health.isClosed(now: Date()))

        // A 429 is not a coin flip. Re-asking immediately is the one thing the response
        // explicitly says not to do, and the whole latency win is not paying for it.
        health.recordFailure(LabeledError(description: "RESOURCE_EXHAUSTED"), now: Date())
        #expect(!health.isClosed(now: Date()))
    }

    @Test("A single transient failure does NOT open it; the second one does")
    func transientNeedsCorroboration() {
        let health = fresh()
        let blip = LabeledError(description: "notConnectedToInternet")

        // The cloud arm is the better parser. One blip must not cost a minute of it.
        health.recordFailure(blip, now: Date())
        #expect(health.isClosed(now: Date()))

        health.recordFailure(blip, now: Date())
        #expect(!health.isClosed(now: Date()))
    }

    @Test("A success between transient failures resets the count")
    func successResetsTheRunningCount() {
        let health = fresh()
        let blip = LabeledError(description: "notConnectedToInternet")

        health.recordFailure(blip, now: Date())
        health.recordSuccess()
        health.recordFailure(blip, now: Date())
        // Two failures have happened, but never two in a ROW — the breaker tracks a run,
        // not a lifetime tally, or a healthy provider would eventually trip on noise.
        #expect(health.isClosed(now: Date()))
    }

    @Test("A content failure counts as HEALTH, not against it")
    func contentFailuresCountAsHealth() {
        let health = fresh()
        let blip = LabeledError(description: "notConnectedToInternet")
        health.recordFailure(blip, now: Date())

        // The looks-like-a-bug case, and the reason the three-way split exists. A
        // guardrail refusal means the service answered: the round trip works and the
        // problem is the prompt. Tripping here would disable the better parser over a
        // wording problem the next capture would not have hit — so it resets like a
        // success, and the transient run above is cleared with it.
        health.recordFailure(LabeledError(description: "guardrailViolation"), now: Date())
        health.recordFailure(blip, now: Date())
        #expect(health.isClosed(now: Date()))
    }

    // MARK: - Recovery

    @Test("The breaker reopens for a probe once its cooldown elapses")
    func cooldownYieldsAProbe() {
        let health = fresh()
        let start = Date()
        health.recordFailure(LabeledError(description: "429"), now: start)

        let inside = start.addingTimeInterval(CloudHealth.baseCooldownSeconds - 1)
        #expect(!health.isClosed(now: inside))
        #expect(!health.isProbing(now: inside))

        // Past the cooldown the call really is attempted — half-open is deliberately
        // indistinguishable from closed to the caller, so no consumer grows a second
        // policy. What differs is the COST, which `isProbing` is what makes cheap.
        let after = start.addingTimeInterval(CloudHealth.baseCooldownSeconds + 1)
        #expect(health.isClosed(now: after))
        #expect(health.isProbing(now: after))
    }

    @Test("A successful probe closes the breaker completely")
    func successfulProbeClosesIt() {
        let health = fresh()
        let start = Date()
        health.recordFailure(LabeledError(description: "429"), now: start)
        health.recordSuccess()

        #expect(health.isClosed(now: start))
        #expect(!health.isProbing(now: start))
        // And the backoff is forgotten, so the next outage starts at the base cooldown
        // rather than inheriting an exponent from an outage that has since healed.
        #expect(health.consecutiveOpenings == 0)
    }

    @Test("Repeated failures back off, so a daily quota isn't probed every minute")
    func cooldownBacksOff() {
        let health = fresh()
        var now = Date()
        let refusal = LabeledError(description: "429")

        health.recordFailure(refusal, now: now)
        let first = try! #require(health.openUntil).timeIntervalSince(now)

        // Fail the probe: the next window must be longer, or a day-long quota would make
        // one capture per minute pay the full failure for hours.
        now = now.addingTimeInterval(first + 1)
        health.recordFailure(refusal, now: now)
        let second = try! #require(health.openUntil).timeIntervalSince(now)
        #expect(second > first)

        // …and bounded, so a long outage can't push recovery past the session.
        for _ in 0..<10 {
            now = now.addingTimeInterval(CloudHealth.maxCooldownSeconds + 1)
            health.recordFailure(refusal, now: now)
        }
        let settled = try! #require(health.openUntil).timeIntervalSince(now)
        #expect(settled <= CloudHealth.maxCooldownSeconds)
    }

    // MARK: - The seam the routing decisions read

    @Test("Reachability is availability AND health; the privacy answer is availability alone")
    func reachabilityIsTheRoutingQuestion() {
        let health = fresh()
        // Under XCTest Firebase is deliberately never configured, so `isAvailable` is
        // false and `isReachable` must be too — a suite may never make live billable
        // calls while pretending to test routing.
        #expect(CloudModel.isAvailable == false)
        #expect(CloudModel.isReachable == false)

        // The split that matters: an OPEN breaker must never be able to make
        // `isAvailable` report that this build is unconfigured. `DataBoundary`'s
        // transmission sentence is written against configuration, and an outage must not
        // quietly retract a privacy disclosure that is still true.
        health.recordFailure(LabeledError(description: "429"), now: Date())
        #expect(CloudModel.isAvailable == false)
        health.reset()
    }
}
