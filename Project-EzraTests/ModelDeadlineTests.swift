//
//  ModelDeadlineTests.swift
//  Project-EzraTests
//
//  The deadline primitive and the result vocabulary that every model call now shares.
//
//  These are the only part of the seam that CAN be tested here: the services themselves
//  short-circuit to `.unavailable` under XCTest by design (there is no on-device model in
//  the simulator), so their model paths are device-verified. What is testable — and worth
//  pinning, because the UI's whole failure story rests on it — is that a timeout, a
//  cancellation, and the operation's own error stay three distinguishable outcomes.
//

import Foundation
import Testing

@testable import Project_Ezra

/// Records whether the losing operation actually observed cancellation.
private actor CancellationFlag {
    private(set) var cancelled = false
    func mark() { cancelled = true }
}

private struct OperationFailure: Error, Equatable {}

@MainActor
struct ModelDeadlineTests {

    // MARK: - The race

    @Test("An operation that finishes in time returns its value")
    func fastOperationWins() async throws {
        let value = try await ModelDeadline.race(timeout: 5) { 42 }
        #expect(value == 42)
    }

    @Test("An operation that outruns the deadline throws Exceeded")
    func deadlineWins() async {
        await #expect(throws: ModelDeadline.Exceeded.self) {
            try await ModelDeadline.race(timeout: 0.05) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
    }

    @Test("An operation that IGNORES cancellation still loses at the deadline")
    func uncancellableOperationStillTimesOut() async {
        // The 2026-09-17 shape: the GA model wedged inside `respond`, which does not
        // honour cancellation, and the old task-group race waited on it forever. The
        // deadline must return on the clock, whatever the operation does.
        let started = ContinuousClock.now
        await #expect(throws: ModelDeadline.Exceeded.self) {
            try await ModelDeadline.race(timeout: 0.1) {
                let end = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < end { /* uncancellable */  }
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("The operation's OWN error surfaces — never disguised as a timeout")
    func operationErrorIsNotATimeout() async {
        // The distinction is load-bearing: a guardrail refusal and a hung model need
        // different fixes, and `ModelRun` labels them differently for the diagnostics.
        await #expect(throws: OperationFailure.self) {
            try await ModelDeadline.race(timeout: 5) { throw OperationFailure() }
        }
    }

    @Test("The losing operation is cancelled, not left running")
    func loserIsCancelled() async throws {
        let flag = CancellationFlag()
        await #expect(throws: ModelDeadline.Exceeded.self) {
            try await ModelDeadline.race(timeout: 0.05) {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    await flag.mark()
                    throw error
                }
                return 1
            }
        }
        // Cancellation propagates asynchronously, so give it a bounded moment rather than
        // asserting on a single instant.
        for _ in 0..<50 where await !flag.cancelled {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await flag.cancelled)
    }

    // MARK: - The result vocabulary

    @Test("Only outcomes a retry could fix are retryable")
    func retryability() {
        // The two that must NEVER offer a retry: there is nothing to retry without a
        // model, and re-offering after the user walked away is nagging.
        #expect(!ModelResult<Int>.unavailable.isRetryable)
        #expect(!ModelResult<Int>.cancelled.isRetryable)
        #expect(!ModelResult<Int>.success(1).isRetryable)
        #expect(ModelResult<Int>.timedOut.isRetryable)
        #expect(ModelResult<Int>.failed("guardrailViolation").isRetryable)
    }

    @Test("map transforms the payload and preserves every other case exactly")
    func mapPreservesNonSuccess() {
        #expect(ModelResult.success(2).map { $0 * 2 }.value == 4)

        // A service that sanitizes its output must not accidentally launder a timeout
        // into a success (or lose the error label on the way through).
        if case .timedOut = ModelResult<Int>.timedOut.map({ "\($0)" }) {
        } else {
            Issue.record("timedOut did not survive map")
        }
        if case .unavailable = ModelResult<Int>.unavailable.map({ "\($0)" }) {
        } else {
            Issue.record("unavailable did not survive map")
        }
        if case .cancelled = ModelResult<Int>.cancelled.map({ "\($0)" }) {
        } else {
            Issue.record("cancelled did not survive map")
        }
        if case .failed(let label) = ModelResult<Int>.failed("refusal").map({ "\($0)" }) {
            #expect(label == "refusal")
        } else {
            Issue.record("failed did not survive map")
        }
    }

    @Test("Under tests the seam reports unavailable without touching a model")
    func runIsInertUnderTests() async {
        // `onDeviceModelAvailable()` is false under XCTest, so `perform` must return
        // before constructing a session — this is what keeps the whole suite off the
        // beta simulator's intelligence daemon.
        let outcome = await ModelRun.perform(.taskAdvisor, deadline: 5) {
            Issue.record("the operation must not run when no model is available")
            return 0
        }
        if case .unavailable = outcome {} else { Issue.record("expected .unavailable") }
    }
}
