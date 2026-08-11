//
//  RambleEvalTests.swift
//  Project-EzraTests
//
//  The regression-floor half of the eval instrument. The fixtures and the scoring
//  body live in the APP target (`AI/RambleEvalSet.swift`, DEBUG-only) so this test
//  and the `-RambleEval` device seam score IDENTICALLY — the same 47-case set, the
//  same field pairing, the same named misses. This file owns only what a test can:
//  the engine choice (heuristic + resolver — the deterministic pipeline) and the
//  floors, calibrated just under observed numbers. They catch a change that
//  degrades the pipeline; they are not aspirations.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Ramble eval (heuristic pipeline)")
struct RambleEvalTests {

    @Test("Per-field accuracy holds the regression floors")
    func evalAccuracy() async throws {
        let report = try await RambleEval.score { utterance in
            let intents = try await HeuristicEngine().triage(rawText: utterance)
            return IntentResolver.resolve(intents)
        }
        print(report.table)

        // Regression floors — calibrated just under observed numbers. Re-baselined
        // upward with the connective-aware splitter (Segmentation.swift): observed
        // segmentation/title/judgment/blocked/due all 100% and category 97% across 47
        // cases including the dictated run-on set. Owner keeps its old floor — three
        // samples is no basis for a tighter one.
        #expect(report.segmentation.rate >= 0.95, "segmentation regressed: \(report.segmentation.display)")
        #expect(report.title.rate >= 0.95, "title fidelity regressed: \(report.title.display)")
        #expect(report.category.rate >= 0.90, "category accuracy regressed: \(report.category.display)")
        #expect(report.judgment.rate >= 0.95, "judgment detection regressed: \(report.judgment.display)")
        #expect(report.owner.rate >= 0.60, "owner extraction regressed: \(report.owner.display)")
        #expect(report.blocked.rate >= 0.95, "blocker detection regressed: \(report.blocked.display)")
        #expect(report.due.rate >= 0.95, "due detection regressed: \(report.due.display)")
        // Kind is INTERNAL (no user correction exists since 2026-08-11), so this floor
        // is the field's whole trust story — an AI-owned field earns trust through
        // evaluation, not invisibility. Observed 11/11 on the labeled subset.
        #expect(report.kind.rate >= 0.90, "kind classification regressed: \(report.kind.display)")
    }
}
