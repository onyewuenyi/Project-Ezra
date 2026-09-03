//
//  QuickCaptureDiagnosticsTests.swift
//  Project-EzraTests
//
//  Campaign 3's pure parts. As with the previous seams, what gets pinned is the
//  MEASUREMENT SEMANTICS — a wrong detector metric or a leaky case population would
//  corrupt the campaign's conclusion while producing a plausible report. Everything
//  session/stream-shaped is device-verified.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct QuickCaptureDiagnosticsTests {

    // MARK: - Detector metrics

    @Test("Detector score: the positive class is MULTI, and every cell lands where named")
    func detectorCells() {
        var score = QuickCaptureDiagnostics.DetectorScore()
        score.record(predictedMulti: true, actuallyMulti: true)  // TP
        score.record(predictedMulti: true, actuallyMulti: false)  // FP — nags a single thought
        score.record(predictedMulti: false, actuallyMulti: false)  // TN
        score.record(predictedMulti: false, actuallyMulti: true)  // FN — silently under-captures
        #expect(score.truePositives == 1 && score.falsePositives == 1)
        #expect(score.trueNegatives == 1 && score.falseNegatives == 1)
        #expect(score.precision == 0.5)
        #expect(score.recall == 0.5)
        #expect(score.accuracy == 0.5)
    }

    @Test("Empty denominators render as nil, never as a rate")
    func detectorEmptyDenominators() {
        let score = QuickCaptureDiagnostics.DetectorScore()
        // Zero predictions is "not measured", not "perfectly precise" — the absence
        // rule, applied to rates.
        #expect(score.precision == nil)
        #expect(score.recall == nil)
        #expect(score.accuracy == nil)
        #expect(score.line.contains("—"))
    }

    // MARK: - The Q1 population

    @Test("The atomic population is exactly: corpus atomics + compound-is-one adversarials")
    func atomicPopulation() {
        let atomic = QuickCaptureDiagnostics.atomicCases(
            corpus: RambleEval.evalSet, adversarial: RambleEval.gateAdversarialSet)
        // Every case is single-intent by label — a multi case leaking in would score
        // the single-object schema on work the feature deliberately refuses.
        #expect(atomic.allSatisfy { $0.expected.count == 1 || $0.isAtomic })
        #expect(!atomic.isEmpty)
        // The adversarial compound-is-one half (4 cases) is included: the traps a
        // single-capture feature must survive.
        let adversarialSingles = RambleEval.gateAdversarialSet.filter {
            $0.expected.count == 1
        }
        #expect(adversarialSingles.count == 4)
        #expect(atomic.count >= RambleEval.evalSet.filter(\.isAtomic).count + 4)
        // And no multi-intent case from the corpus leaks in.
        #expect(atomic.filter { !$0.isAtomic }.isEmpty)
    }

    // MARK: - The deterministic detector baseline

    @Test("The deterministic detector fires on signal-rich notes and stays quiet on plain ones")
    func deterministicDetector() {
        // Two clear boundary signals → several things.
        #expect(
            QuickCaptureDiagnostics.deterministicSeveralThings(
                "call the dentist tomorrow and buy diapers on friday"))
        // One plain thought, no signals → one thing.
        #expect(!QuickCaptureDiagnostics.deterministicSeveralThings("renew my passport"))
        // The compound-is-one trap: a single connective must not read as several.
        #expect(
            !QuickCaptureDiagnostics.deterministicSeveralThings(
                "email the landlord about the boiler and the leak"))
    }

    // MARK: - Quarantine

    @Test("Campaign-3 measurement artifacts are referenced nowhere outside their seam")
    func measurementArtifactsQuarantined() throws {
        // Same rule as measurementOnlyInstructions: schemas and instruction text that
        // exist to PRICE a design must not leak into production by reference.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("QuickCaptureDiagnostics.swift") }
        for file in files {
            let content =
                (try? String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8))
                ?? ""
            #expect(
                !content.contains("quickCaptureInstructions")
                    && !content.contains("MultiIntentCheck"),
                "campaign-3 measurement artifact leaked into \(file)")
        }
    }
}
