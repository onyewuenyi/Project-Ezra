//
//  CaptureHedgeTests.swift
//  Project-EzraTests
//
//  The hedged capture race — the concurrency that decides how long the user waits when
//  the paid arm is slow, and therefore the one piece of the Ramble pipeline whose bugs
//  are invisible in every screenshot and every green field-scoring table.
//
//  The regression these exist for is `totalBudgetIsSpentOnce`. The chain used to be
//  serial: the cloud arm got the whole capture deadline, and only once it came back
//  empty did the on-device arm start — with a FRESH full deadline. The docs said the
//  deadline "measures the user's patience", which was true per rung and false per
//  capture, and nothing in the suite could tell the difference because nothing measured
//  the wall clock across both arms.
//
//  Timings are deliberately tiny (hundreds of ms) so the suite stays fast, and every
//  assertion is an INEQUALITY with slack rather than an equality — a scheduling-sensitive
//  test that pins exact durations is a test that fails on a loaded CI box and teaches
//  people to re-run until green.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Capture hedge")
@MainActor
struct CaptureHedgeTests {

    private func intents(_ titles: String...) -> [TaskIntent] {
        titles.map {
            TaskIntent(
                title: $0, category: "Home", confidence: 0.9, isJudgmentCall: false, reasoning: "")
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private struct Boom: Error {}

    /// Wall-clock around an async body, in seconds.
    private func elapsed(_ body: () async -> Void) async -> Double {
        let started = Date()
        await body()
        return Date().timeIntervalSince(started)
    }

    // MARK: - The normal path: the paid arm wins and the free one never runs

    @Test("A healthy primary wins outright and the hedge never starts")
    func primaryWinsWithoutHedging() async {
        var result: CaptureTriageRace.HedgedResult?
        let seconds = await elapsed {
            result = await CaptureTriageRace.hedged(
                budget: 2.0, hedgeAfter: 0.4, onPartial: nil,
                primary: { _ in self.intents("Cloud read") },
                hedge: { _ in
                    Issue.record("the hedge must not run when the primary answers in time")
                    return self.intents("Local read")
                })
        }
        #expect(result?.arm == .primary)
        #expect(result?.hedgeStarted == false)
        if case .finished(let value) = result?.outcome {
            #expect(value.map { $0.title } == ["Cloud read"])
        } else {
            Issue.record("expected .finished, got \(String(describing: result?.outcome))")
        }
        // It returned on the primary's schedule, not the hedge delay's.
        #expect(seconds < 0.4)
    }

    // MARK: - The tail: the free arm covers a slow or dead primary

    @Test("A stalled primary is covered by the hedge, which starts while it stalls")
    func hedgeCoversAStalledPrimary() async {
        let result = await CaptureTriageRace.hedged(
            budget: 3.0, hedgeAfter: 0.2, onPartial: nil,
            primary: { _ in
                try await self.sleep(10)  // never answers within the budget
                return self.intents("Cloud read")
            },
            hedge: { _ in
                try await self.sleep(0.1)
                return self.intents("Local read")
            })
        #expect(result.arm == .hedge)
        #expect(result.hedgeStarted)
        if case .finished(let value) = result.outcome {
            #expect(value.map(\.title) == ["Local read"])
        } else {
            Issue.record("expected .finished, got \(result.outcome)")
        }
    }

    @Test("A primary that throws hands off to the hedge rather than failing the capture")
    func hedgeCoversAThrowingPrimary() async {
        let result = await CaptureTriageRace.hedged(
            budget: 2.0, hedgeAfter: 0.2, onPartial: nil,
            primary: { _ in throw Boom() },
            hedge: { _ in self.intents("Local read") })
        #expect(result.arm == .hedge)
        if case .finished(let value) = result.outcome {
            #expect(value.map(\.title) == ["Local read"])
        } else {
            Issue.record("expected .finished, got \(result.outcome)")
        }
    }

    @Test("A primary that fails early releases the hedge early — no waiting out the delay")
    func earlyFailureReleasesTheHedgeImmediately() async {
        // The dead-network case. Holding the fallback behind a timer that exists to
        // protect a call which has ALREADY failed is pure dead time, on the surface where
        // the product claims to be instant.
        let hedgeAfter = 1.5
        var result: CaptureTriageRace.HedgedResult?
        let seconds = await elapsed {
            result = await CaptureTriageRace.hedged(
                budget: 5.0, hedgeAfter: hedgeAfter, onPartial: nil,
                primary: { _ in throw Boom() },
                hedge: { _ in self.intents("Local read") })
        }
        #expect(result?.arm == .hedge)
        // The whole point: it did NOT sit out the hedge delay first.
        #expect(seconds < hedgeAfter)
    }

    @Test("A primary that returns nothing also releases the hedge early")
    func emptyPrimaryReleasesTheHedgeImmediately() async {
        // An empty answer is not a failure the engine reports as one — it is the shape a
        // degraded parse actually takes, so it must trigger the same early release.
        let hedgeAfter = 1.5
        var result: CaptureTriageRace.HedgedResult?
        let seconds = await elapsed {
            result = await CaptureTriageRace.hedged(
                budget: 5.0, hedgeAfter: hedgeAfter, onPartial: nil,
                primary: { _ in [] },
                hedge: { _ in self.intents("Local read") })
        }
        #expect(result?.arm == .hedge)
        #expect(seconds < hedgeAfter)
    }

    // MARK: - The regression: patience is spent once

    @Test("The budget bounds the WHOLE capture, not each arm in turn")
    func totalBudgetIsSpentOnce() async {
        // Both arms hang. The old serial chain would have spent the full deadline on the
        // primary and then a fresh full deadline on the fallback; this must come back
        // inside one budget.
        let budget = 0.6
        var result: CaptureTriageRace.HedgedResult?
        let seconds = await elapsed {
            result = await CaptureTriageRace.hedged(
                budget: budget, hedgeAfter: 0.1, onPartial: nil,
                primary: { _ in
                    try await self.sleep(30)
                    return self.intents("Cloud read")
                },
                hedge: { _ in
                    try await self.sleep(30)
                    return self.intents("Local read")
                })
        }
        #expect(seconds < budget * 2)
        // And close to the budget itself, not merely under twice it.
        #expect(seconds < budget + 0.5)
        if case .timedOutEmpty = result?.outcome {
        } else {
            Issue.record("expected .timedOutEmpty, got \(String(describing: result?.outcome))")
        }
    }

    // MARK: - Salvage

    @Test("A deadline hit salvages the primary's streamed partials")
    func salvagesPrimaryPartials() async {
        let result = await CaptureTriageRace.hedged(
            budget: 0.5, hedgeAfter: 5.0, onPartial: nil,
            primary: { tee in
                tee(self.intents("Streamed one"))
                try await self.sleep(30)
                return self.intents("Never arrives")
            },
            hedge: { _ in
                try await self.sleep(30)
                return []
            })
        #expect(result.arm == .primary)
        if case .salvaged(let value) = result.outcome {
            #expect(value.map(\.title) == ["Streamed one"])
        } else {
            Issue.record("expected .salvaged, got \(result.outcome)")
        }
    }

    @Test("With only the hedge streaming, its partials are salvaged rather than nothing")
    func salvagesHedgePartials() async {
        let result = await CaptureTriageRace.hedged(
            budget: 0.6, hedgeAfter: 0.1, onPartial: nil,
            primary: { _ in
                try await self.sleep(30)
                return []
            },
            hedge: { tee in
                tee(self.intents("Local partial"))
                try await self.sleep(30)
                return []
            })
        #expect(result.arm == .hedge)
        if case .salvaged(let value) = result.outcome {
            #expect(value.map(\.title) == ["Local partial"])
        } else {
            Issue.record("expected .salvaged, got \(result.outcome)")
        }
    }

    @Test("Only the primary tees to onPartial — the two arms never interleave")
    func hedgePartialsStayOutOfTheUIStream() async {
        // `firstPartialMs` and the composer's stream must keep meaning ONE thing. Two
        // arms feeding one handler would report a metric about neither.
        var seen: [String] = []
        _ = await CaptureTriageRace.hedged(
            budget: 2.0, hedgeAfter: 0.1,
            onPartial: { intents in seen.append(contentsOf: intents.map(\.title)) },
            primary: { tee in
                tee(self.intents("From primary"))
                try await self.sleep(0.6)
                return self.intents("Primary final")
            },
            hedge: { tee in
                tee(self.intents("From hedge"))
                try await self.sleep(30)
                return []
            })
        #expect(seen.contains("From primary"))
        #expect(!seen.contains("From hedge"))
    }

    // MARK: - Degenerate shapes

    @Test("With no hedge arm it behaves as a plain bounded race")
    func noHedgeArmStillTerminates() async {
        let result = await CaptureTriageRace.hedged(
            budget: 0.4, hedgeAfter: 0.1, onPartial: nil,
            primary: { _ in
                try await self.sleep(30)
                return []
            },
            hedge: nil)
        #expect(result.hedgeStarted == false)
        if case .timedOutEmpty = result.outcome {
        } else {
            Issue.record("expected .timedOutEmpty, got \(result.outcome)")
        }
    }

    @Test("Both arms barren reports the failure, carrying the error itself")
    func bothBarrenSurfacesTheError() async {
        let result = await CaptureTriageRace.hedged(
            budget: 2.0, hedgeAfter: 0.05, onPartial: nil,
            primary: { _ in throw Boom() },
            hedge: { _ in throw Boom() })
        #expect(result.arm == nil)
        guard case .failed(let error) = result.outcome else {
            Issue.record("expected .failed, got \(result.outcome)")
            return
        }
        // The error travels, it isn't merely detected — `AppBrain.errorLabel` reads it to
        // name the failure in telemetry, so a `.failed` carrying nothing useful would
        // report every broken capture identically.
        #expect(error is Boom)
    }

    // MARK: - Ported from the retired single-arm `run`
    //
    // `run` was deleted with the serial chain it belonged to. Four of its six semantics
    // were already covered by the hedged tests above; these are the four that were not,
    // and the first one found a real bug — see `cancellationIsNeverATimeout`.

    @Test("Salvage takes the LAST streamed partial set, not the first")
    func salvageTakesTheLatestPartial() async {
        // A stream grows: an early snapshot is a worse answer than a later one, and the
        // box must keep overwriting. Salvaging the first would hand the user the least
        // complete reading the parse ever produced.
        let result = await CaptureTriageRace.hedged(
            budget: 0.4, hedgeAfter: 5.0, onPartial: nil,
            primary: { tee in
                tee(self.intents("renew pass"))
                tee(self.intents("renew passport", "book dentist"))
                try await self.sleep(30)
                return self.intents("never arrives")
            })
        guard case .salvaged(let value) = result.outcome else {
            Issue.record("expected .salvaged, got \(result.outcome)")
            return
        }
        #expect(value.map(\.title) == ["renew passport", "book dentist"])
    }

    @Test("Every primary partial reaches onPartial, in order")
    func partialsForwardInOrder() async {
        // `hedgePartialsStayOutOfTheUIStream` proves the hedge's partials are excluded;
        // this proves the primary's are all included and sequenced, which is what
        // `firstPartialMs` and any future streaming consumer actually depend on.
        var received: [[String]] = []
        _ = await CaptureTriageRace.hedged(
            budget: 2.0, hedgeAfter: 5.0,
            onPartial: { received.append($0.map(\.title)) },
            primary: { tee in
                tee(self.intents("one"))
                tee(self.intents("one", "two"))
                return self.intents("one", "two")
            })
        #expect(received == [["one"], ["one", "two"]])
    }

    @Test("Cancelling the enclosing task reads as .cancelled, never a timeout")
    func cancellationIsNeverATimeout() async {
        // THE bug this port found. The deadline arm slept with `try?`, which swallows
        // cancellation and returned `.deadline` immediately — racing the primary's honest
        // `.cancelled`. So dismissing the composer mid-parse landed as `.timedOutEmpty`
        // or `.cancelled` depending on scheduling, and `.cancelled` exists precisely to
        // stay OUT of the timeout metrics that `captureSeconds` is tuned on.
        //
        // Run it repeatedly: a scheduling race that reproduces one time in three is still
        // a bug, and a single-shot assertion would have passed on the old code.
        for _ in 0..<8 {
            let task = Task { @MainActor in
                await CaptureTriageRace.hedged(
                    budget: 60, hedgeAfter: 0.05, onPartial: nil,
                    primary: { _ in
                        try await self.sleep(120)
                        return []
                    },
                    hedge: { _ in
                        try await self.sleep(120)
                        return []
                    })
            }
            try? await Task.sleep(for: .milliseconds(20))
            task.cancel()
            let result = await task.value
            guard case .cancelled = result.outcome else {
                Issue.record("a cancelled capture reported \(result.outcome)")
                return
            }
        }
    }

    @Test("A cancelled capture salvages nothing — the user left, there is no one to serve")
    func cancellationBeatsSalvage() async {
        // Distinct from the above: partials EXIST here, so a naive implementation could
        // return `.salvaged` and the composer would propose an interpretation into a
        // dismissed sheet.
        let task = Task { @MainActor in
            await CaptureTriageRace.hedged(
                budget: 60, hedgeAfter: 5.0, onPartial: nil,
                primary: { tee in
                    tee(self.intents("streamed something"))
                    try await self.sleep(120)
                    return []
                })
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        guard case .cancelled = result.outcome else {
            Issue.record("expected .cancelled, got \(result.outcome)")
            return
        }
    }
}
