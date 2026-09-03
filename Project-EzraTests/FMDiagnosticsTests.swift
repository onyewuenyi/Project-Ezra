//
//  FMDiagnosticsTests.swift
//  Project-EzraTests
//
//  The FM-diagnosis seam's pure parts. Everything session/stream/tokenCount-shaped
//  is device-verified, not tested; what CAN be pinned off-device is the measurement
//  semantics — the verdict axes staying independent, the contract population's
//  minimum-n rule, nil never rendering as zero, and the row format pull-scripts
//  grep. These protect the EXPERIMENT: a wrong verdict rule corrupts the campaign's
//  conclusion while producing a perfectly plausible report.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct FMDiagnosticsTests {

    // MARK: - Contract axis

    @Test("The contract verdict needs n ≥ 8 valid observations — else inconclusive")
    func contractNeedsMinimumSample() {
        // Seven fast samples are not a pass; they are not enough evidence for a
        // verdict at all. Timeouts eating the sample must surface as inconclusive,
        // never as a pass built on survivors.
        let fast = Array(repeating: 100, count: 7)
        #expect(FMDiagnostics.contractVerdict(validWarmMs: fast) == .inconclusive)
        #expect(
            FMDiagnostics.contractVerdict(validWarmMs: fast + [100]) == .pass)
    }

    @Test("Gate boundaries: p50 and p95 bind; p99 binds only with n ≥ 20")
    func gateBoundaries() {
        // Ten samples all at exactly the p50 gate: pass (gates are ceilings, > fails).
        let atGate = Array(repeating: 500, count: 10)
        #expect(FMDiagnostics.contractVerdict(validWarmMs: atGate) == .pass)
        #expect(
            FMDiagnostics.contractVerdict(validWarmMs: Array(repeating: 501, count: 10)) == .fail)
        // p95 breach with a passing p50: nine fast + one slow of ten → p95 = slow.
        let p95Breach = Array(repeating: 100, count: 9) + [1600]
        #expect(FMDiagnostics.contractVerdict(validWarmMs: p95Breach) == .fail)
        // p99 breach at n=10 is INFORMATIONAL — it must not fail the contract...
        let p99OnlyBreachSmall = Array(repeating: 100, count: 9) + [1400]
        #expect(FMDiagnostics.contractVerdict(validWarmMs: p99OnlyBreachSmall) == .pass)
        // ...but at n ≥ 20 the p99 gate binds: 19 fast + one 3100ms tail.
        let p99BreachLarge = Array(repeating: 100, count: 19) + [3100]
        // p95 of this list is 100 (index round(19*0.95)=18) so only p99 catches it.
        #expect(FMDiagnostics.contractVerdict(validWarmMs: p99BreachLarge) == .fail)
    }

    // MARK: - Diagnosis axis (independent of contract by design)

    @Test("Dominance names the interval; nothing over 60% is mixed")
    func diagnosisBranches() {
        #expect(
            FMDiagnostics.diagnosis(
                sessionShare: 0.7, preFirstTokenShare: 0.2, postFirstTokenShare: 0.1)
                == .sessionDominated)
        #expect(
            FMDiagnostics.diagnosis(
                sessionShare: 0.0, preFirstTokenShare: 0.65, postFirstTokenShare: 0.35)
                == .preFirstTokenDominated)
        #expect(
            FMDiagnostics.diagnosis(
                sessionShare: 0.0, preFirstTokenShare: 0.35, postFirstTokenShare: 0.65)
                == .postFirstTokenDominated)
        #expect(
            FMDiagnostics.diagnosis(
                sessionShare: 0.2, preFirstTokenShare: 0.4, postFirstTokenShare: 0.4) == .mixed)
    }

    @Test("FAIL + dominated is a legal combination — dominance is never a viability verdict")
    func axesAreIndependent() {
        // A run can FAIL the contract while being preFirstToken-dominated: the
        // diagnosis then names the next experiment, and only the contract axis says
        // whether FM is viable. Conflating them was the failure mode this split exists
        // to prevent.
        let slow = Array(repeating: 20_000, count: 10)
        #expect(FMDiagnostics.contractVerdict(validWarmMs: slow) == .fail)
        let diag = FMDiagnostics.diagnosis(
            sessionShare: 0.0, preFirstTokenShare: 0.62, postFirstTokenShare: 0.38)
        #expect(diag == .preFirstTokenDominated)
        #expect(
            FMDiagnostics.nextExperiment(contract: .fail, diagnosis: diag) == .promptCache)
        // And a PASS outranks any dominance: the next step is the routing conversation.
        #expect(
            FMDiagnostics.nextExperiment(contract: .pass, diagnosis: diag)
                == .routingConversation)
    }

    // MARK: - Attribution math

    @Test("Attribution: post = total − pre, session uses acquisition only, shares ≈ 1")
    func attributionShares() {
        let row = FMDiagnostics.Row(
            caseNumber: 1, caseCount: 1, rep: 2, repCount: 3, sessionLabel: "poolHit",
            acquisitionMs: 100, preparedAheadMs: 5000,  // prepared-ahead must NOT count
            preFirstTokenMs: 400, totalMs: 900, failure: nil, promptTok: nil, outTok: nil)
        #expect(row.postFirstTokenMs == 500)
        let shares = FMDiagnostics.attributionShares(rows: [row])
        #expect(abs(shares.session + shares.pre + shares.post - 1.0) < 0.001)
        // acquisition 100 / (900 + 100) = 10% — if prepared-ahead leaked in, this
        // would read 51% and the diagnosis would blame the session wrongly.
        #expect(abs(shares.session - 0.1) < 0.001)
    }

    @Test("A failed row never contributes a synthetic latency")
    func failedRowsStayOut() {
        let timedOut = FMDiagnostics.Row(
            caseNumber: 1, caseCount: 1, rep: 2, repCount: 3, sessionLabel: "poolHit",
            acquisitionMs: 3, preparedAheadMs: 40, preFirstTokenMs: nil, totalMs: nil,
            failure: "TIMEOUT 60s", promptTok: nil, outTok: nil)
        #expect(!timedOut.isValid)
        #expect(timedOut.postFirstTokenMs == nil)
        let shares = FMDiagnostics.attributionShares(rows: [timedOut])
        #expect(shares == (0, 0, 0))  // nothing measurable, not "everything is fast"
        #expect(FMDiagnostics.contractVerdict(validWarmMs: []) == .inconclusive)
    }

    // MARK: - The row format (pull scripts grep this; drift = silent breakage)

    @Test("The row format is pinned, and nil renders as — never 0")
    func rowFormatPinned() {
        let row = FMDiagnostics.Row(
            caseNumber: 2, caseCount: 5, rep: 2, repCount: 3, sessionLabel: "poolHit",
            acquisitionMs: 3, preparedAheadMs: 41, preFirstTokenMs: 9214, totalMs: 20844,
            failure: nil, promptTok: 180, outTok: 210)
        let line = FMDiagnostics.formatRow(row)
        #expect(
            line.contains(
                "fm case 2/5 rep 2/3 poolHit(acquisition 3ms · prepared-ahead 41ms)"))
        #expect(line.contains("preFirstToken 9214ms"))
        #expect(line.contains("postFirstToken 11630ms"))
        #expect(line.contains("total 20844ms"))
        #expect(line.contains("outTok ~210"))

        let failed = FMDiagnostics.Row(
            caseNumber: 3, caseCount: 5, rep: 1, repCount: 3,
            sessionLabel: "post-reboot first invocation ", acquisitionMs: nil,
            preparedAheadMs: nil, preFirstTokenMs: nil, totalMs: nil,
            failure: "TIMEOUT 60s", promptTok: nil, outTok: nil)
        let failedLine = FMDiagnostics.formatRow(failed)
        #expect(failedLine.contains("preFirstToken —"))
        #expect(failedLine.contains("total —"))
        #expect(failedLine.contains("FAILED(TIMEOUT 60s)"))
        #expect(!failedLine.contains("total 0ms"))
    }

    // MARK: - Case selection

    @Test("Representative cases: deterministic, in-bounds, tier-covering, run-on included")
    func representativeSelection() {
        let picks = FMDiagnostics.representativeCases(from: RambleEval.evalSet, count: 5)
        #expect(!picks.isEmpty && picks.count <= 5)
        // Deterministic: same call, same answer.
        let again = FMDiagnostics.representativeCases(from: RambleEval.evalSet, count: 5)
        #expect(picks.map(\.index) == again.map(\.index))
        // In-bounds and unique.
        #expect(Set(picks.map(\.index)).count == picks.count)
        #expect(picks.allSatisfy { RambleEval.evalSet.indices.contains($0.index) })
        // The ≥8-outcome run-on (case 50's shape) is in the slice.
        #expect(picks.contains { $0.evalCase.expected.count >= 8 })
        // Both simple and multi tiers appear.
        let tiers = Set(
            picks.map { CapturePerformanceContract.Tier.tier(for: $0.evalCase.utterance) })
        #expect(tiers.contains(.simple) && tiers.contains(.multi))
    }

    // MARK: - Campaign-2 verdict (GREEN/YELLOW/RED)

    @Test("The campaign verdict: RED needs the floor to survive every attack; GREEN needs all three conditions")
    func campaignVerdictBranches() {
        typealias V = FMDiagnostics.CampaignVerdict
        // RED: best arm still >= 3s — the floor survived minimal schema, minimal
        // instructions, AND unguided.
        #expect(
            FMDiagnostics.campaignVerdict(bestPreMs: 3400, candidateTotalMs: 9000, accuracyHeld: true)
                == .red)
        // GREEN: sub-1s floor + candidate total near contract + accuracy held.
        #expect(
            FMDiagnostics.campaignVerdict(bestPreMs: 800, candidateTotalMs: 1800, accuracyHeld: true)
                == .green)
        // YELLOW in each direction GREEN can fail while the floor moved:
        #expect(  // floor moved but >= 1s (the 3.5→1.3s case — engineerable, gap remains)
            FMDiagnostics.campaignVerdict(bestPreMs: 1300, candidateTotalMs: 1800, accuracyHeld: true)
                == .yellow)
        #expect(  // sub-1s floor but candidate total too slow
            FMDiagnostics.campaignVerdict(bestPreMs: 800, candidateTotalMs: 5000, accuracyHeld: true)
                == .yellow)
        #expect(  // sub-1s floor but accuracy dropped — speed may not buy wrong answers
            FMDiagnostics.campaignVerdict(bestPreMs: 800, candidateTotalMs: 1800, accuracyHeld: false)
                == .yellow)
        #expect(  // accuracy unmeasurable blocks GREEN, never fakes it
            FMDiagnostics.campaignVerdict(bestPreMs: 800, candidateTotalMs: 1800, accuracyHeld: nil)
                == .yellow)
        #expect(
            FMDiagnostics.campaignVerdict(bestPreMs: nil, candidateTotalMs: nil, accuracyHeld: nil)
                == .inconclusive)
    }

    // MARK: - Minimal schema mapping + accuracy scorer

    @Test("Minimal-schema output maps into the pipeline's own vocabulary, trust fields intact")
    func minimalMappingKeepsTrustFields() {
        let minimal = FMDiagnostics.MinimalCapture(tasks: [
            FMDiagnostics.MinimalTask(
                title: "Walk the dog", sourceQuote: "walk my dog monday and tuesday",
                dateExpression: "monday and tuesday", isJudgmentCall: false, blockerPhrase: nil)
        ])
        let intents = FMDiagnostics.intents(fromMinimal: minimal)
        #expect(intents.count == 1)
        #expect(intents[0].sourceQuote == "walk my dog monday and tuesday")  // grounding contract
        #expect(intents[0].dateExpression == "monday and tuesday")  // raw-expression rule
        // And the SAME resolver expansion runs: two named occasions → two drafts.
        let drafts = IntentResolver.resolve(intents)
        #expect(drafts.count == 2)
    }

    @Test("The accuracy scorer matches the eval's comparisons and skips fields on a seg miss")
    func accuracyScorer() {
        var tally = FMDiagnostics.AccuracyTally()
        let expected = [
            RambleEval.ExpectedTask(titleContains: ["passport"], expectDue: false)
        ]
        let hit = [
            TaskDraft(
                title: "Renew passport", category: "Admin", confidence: 0.9,
                autonomy: .silent, isJudgmentCall: false, reasoning: "")
        ]
        FMDiagnostics.score(drafts: hit, against: expected, into: &tally)
        #expect(tally.segHits == 1 && tally.titleHits == 1 && tally.dueHits == 1)
        // A count mismatch is a seg miss and scores NO field rows — misaligned pairs
        // would corrupt the field numbers (the eval's own rule).
        FMDiagnostics.score(drafts: [], against: expected, into: &tally)
        #expect(tally.segTotal == 2 && tally.segHits == 1)
        #expect(tally.titleTotal == 1)
        #expect(tally.line.contains("seg 1/2"))
    }

    // MARK: - Launch guards

    @Test("The seam refuses to share a launch with -RambleEval")
    func refusesEvalCoLaunch() {
        #expect(
            FMDiagnostics.refusesLaunch(arguments: ["-FMDiagnostics", "-RambleEval"]))
        #expect(!FMDiagnostics.refusesLaunch(arguments: ["-FMDiagnostics"]))
        #expect(!FMDiagnostics.refusesLaunch(arguments: ["-RambleEval"]))
    }

    @Test("Dials: malformed values fall back to defaults")
    func dialParsing() {
        #expect(FMDiagnostics.dial("-FMDiagCases", in: ["-FMDiagCases", "3"], default: 5) == 3)
        #expect(FMDiagnostics.dial("-FMDiagCases", in: ["-FMDiagCases"], default: 5) == 5)
        #expect(FMDiagnostics.dial("-FMDiagCases", in: ["-FMDiagCases", "x"], default: 5) == 5)
        #expect(FMDiagnostics.dial("-FMDiagCases", in: ["-FMDiagCases", "0"], default: 5) == 5)
        #expect(FMDiagnostics.dial("-FMDiagCases", in: [], default: 5) == 5)
    }

    @Test("measurementOnlyInstructions is referenced nowhere outside the seam")
    func minimalInstructionsStayQuarantined() throws {
        // The production instruction block must stay byte-identical across arms; the
        // minimal set exists to price instruction size, never to parse captures anyone
        // keeps. Grep the app source: the symbol may appear only in FMDiagnostics.swift
        // (and this test).
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Project-EzraTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Project-Ezra")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("FMDiagnostics.swift") }
        for file in files {
            let content =
                (try? String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8))
                ?? ""
            #expect(
                !content.contains("measurementOnlyInstructions"),
                "measurementOnlyInstructions leaked into \(file)")
        }
    }
}
