//
//  RambleEvalTests.swift
//  Project-EzraTests
//
//  The CI arm of the eval instrument. The fixtures, the scoring body AND THE FLOORS
//  live in the APP target (`AI/RambleEvalSet.swift`, DEBUG-only) so this test and the
//  `-RambleEval` device seam score IDENTICALLY — the same labeled set, the same field
//  pairing, the same named misses, the same numbers to clear.
//
//  This file now owns exactly one thing: the ENGINE CHOICE. That is the honest
//  division, and it is a correction. The floors used to be `#expect` literals here,
//  which meant they could only ever be failed by CI — and CI runs the heuristic
//  pipeline, because the Foundation Models path only exists on real hardware. The
//  floors were therefore held by the fallback while the front door went unmeasured,
//  and an unstructured spoken blob failed to segment on device with every number in
//  this file still reading green.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Ramble eval (heuristic pipeline)")
struct RambleEvalTests {

    @Test("The heuristic arm holds the shared regression floors")
    func evalAccuracy() async throws {
        let report = try await RambleEval.score { utterance in
            let intents = try await HeuristicEngine().triage(rawText: utterance)
            return IntentResolver.resolve(intents)
        }
        print(report.table(against: .standard, arm: "heuristic"))

        // ONE assertion over `failures`, deliberately — not eight `#expect`s. An
        // enumerated list is a place for an arm to check a subset of the fields without
        // anyone noticing, which is a smaller version of the same failure that let the
        // on-device arm go unmeasured. `failures` iterates every field there is.
        let broken = report.failures(against: .standard)
        #expect(broken.isEmpty, "floors broken: \(broken.joined(separator: " · "))")
    }

    @Test("Every scored field has a floor — no field may be measured and left unheld")
    func everyFieldIsHeld() {
        // The structural guard behind the test above. A new scored field added to
        // `Report` without a matching entry in `fields(against:)` would be reported in
        // the table and checked by nothing — measured, printed, and unenforced. Pinning
        // the count makes that omission a failing test rather than a quiet gap.
        #expect(RambleEval.Report().fields().count == 8)
    }

    @Test("Latency is held too — a timing row reported and unchecked is the same rot")
    func settledLatencyIsHeld() {
        // `fields()` covers accuracy; latency fails by being too BIG, so it cannot live
        // in that list and is checked separately inside `failures`. This pins that it
        // really is checked — the whole point of `everyFieldIsHeld` applied to the one
        // number that doesn't fit its shape.
        var report = RambleEval.Report()
        report.settledMs = [Int(RambleEval.Floors.standard.settledRevealP90Ms) + 500]
        #expect(report.failures().contains { $0.contains("settled p90") })

        // And "not measured" must never read as "fast": no samples, no verdict.
        #expect(RambleEval.Report().failures().isEmpty)
    }

    // The gate scorer's tests lived here until 2026-08-22, deleted with the gate. They
    // were worth having: they caught three bugs in the instrument before it was ever
    // pointed at a model, and then the instrument reported honestly that the thing it
    // measured could not be made to work.

}
