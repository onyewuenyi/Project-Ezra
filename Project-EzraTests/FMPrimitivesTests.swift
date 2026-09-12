import Foundation
import Testing

@testable import Project_Ezra

/// Campaign 5's SCORER, bracketed in CI.
///
/// The harness itself is device-only — it needs a model that answers — but its scoring is
/// pure, and pure scoring is exactly where this codebase keeps finding its bugs: seven of
/// the nine failures in the confidence-gate week were in measurement code, one of them a
/// ground truth that asked the wrong question and would have justified a never-firing
/// gate. So the 2×2, the cohort filters and the table's own formatting are pinned here,
/// where they run on every build rather than on the two device sittings a campaign gets.
@Suite("fm primitives scorer")
@MainActor
struct FMPrimitivesTests {

    // MARK: - The 2×2

    @Test("the quadrant names the one cell that can hurt a person")
    func falseAcceptIsTheDangerousCell() {
        // Accepted by the validator, count still wrong: a merged errand revealed as final.
        #expect(
            FMPrimitives.verdict(accepted: true, hadArtifact: true, fragments: 2, expected: 4)
                == .falseAccept)
        #expect(
            FMPrimitives.verdict(accepted: true, hadArtifact: true, fragments: 4, expected: 4)
                == .trueAccept)
        // Refused a cut that was right: one cloud call spent needlessly. An efficiency
        // error, which is the side of the asymmetry we are happy to be on.
        #expect(
            FMPrimitives.verdict(accepted: false, hadArtifact: true, fragments: 4, expected: 4)
                == .falseReject)
        #expect(
            FMPrimitives.verdict(accepted: false, hadArtifact: true, fragments: 2, expected: 4)
                == .trueReject)
    }

    @Test("no artifact is not a verdict about the model's judgment")
    func noArtifactIsItsOwnCell() {
        // A model that never answered has not been scored — folding it into `trueReject`
        // would let an unreachable model print as a cautious one.
        #expect(
            FMPrimitives.verdict(accepted: false, hadArtifact: false, fragments: 0, expected: 4)
                == .noArtifact)
    }

    @Test("the scorer's own bracket holds — clean scores clean, reckless is caught")
    func scorerBracketHolds() {
        // The check the harness runs before it will print anything (Instrument rule 1).
        let clean =
            FMPrimitives.verdict(accepted: true, hadArtifact: true, fragments: 3, expected: 3)
                == .falseAccept ? 1 : 0
        let reckless =
            FMPrimitives.verdict(accepted: true, hadArtifact: true, fragments: 1, expected: 4)
                == .falseAccept ? 1 : 0
        #expect(Instrument.bracketHolds(cleanFlags: clean, recklessFlags: reckless))
    }

    // MARK: - The cohorts

    private func cohort(
        expected: Int, local: Int, reason: CaptureEscalationReason?
    )
        -> FMPrimitives.CohortCase
    {
        FMPrimitives.CohortCase(
            utterance: "x", expected: expected, localCount: local, reason: reason)
    }

    @Test("the reachable cohort is exactly what production hands the arm")
    func reachableIsTheProductionPopulation() {
        let rows = [
            cohort(expected: 3, local: 1, reason: .underSegmented),
            cohort(expected: 3, local: 1, reason: .bigDump),
            cohort(expected: 2, local: 1, reason: nil),
            cohort(expected: 1, local: 0, reason: .emptyRead),
        ]
        // Scoring the arm on rows it never sees is the flattering version of the wrong
        // question — one reason in, and it is the boundary one.
        #expect(FMPrimitives.reachable(rows).count == 1)
    }

    @Test("the potential cohort excludes rows no segmenter could fix")
    func potentialIsBoundaryProblemsOnly() {
        let rows = [
            cohort(expected: 3, local: 1, reason: .underSegmented),  // a boundary failure
            cohort(expected: 0, local: 1, reason: nil),  // anti-invention: not segmentation
            cohort(expected: 1, local: 2, reason: nil),  // over-split: not segmentation either
            cohort(expected: 2, local: 2, reason: nil),  // already right
        ]
        let potential = FMPrimitives.potential(rows)
        #expect(potential.count == 1)
        #expect(potential.first?.expected == 3)
    }

    @Test("the posture cohort is the arm's OTHER live call site, and is its own population")
    func postureCohortIsItsOwnPopulation() {
        // The posture arm fires on the deterministic multi-intent detector, not on the
        // escalation reason, so it reaches rows the open posture's arm never sees. A live
        // call site no cohort covers is the "documented and untrue" shape.
        let several = "book the flights and then renew the passport and also call the vet tomorrow"
        let one = "call the dentist tomorrow about the crown"
        let rows = [
            FMPrimitives.CohortCase(utterance: several, expected: 3, localCount: 1, reason: nil),
            FMPrimitives.CohortCase(utterance: one, expected: 1, localCount: 1, reason: nil),
        ]
        let posture = FMPrimitives.posture(rows)
        #expect(posture.count == 1)
        #expect(posture.first?.utterance == several)
        // …and it is reachable where the open posture's cohort is empty: this row does not
        // escalate, so REACHABLE would not see it at all.
        #expect(FMPrimitives.reachable(rows).isEmpty)
    }

    @Test("a validator refusal reports the CUT's count, not the read it tried to improve")
    func validatorRefusalCarriesTheCutCount() {
        // Substituting the deterministic count here would score the wrong artifact and make
        // the false-reject cell unreadable — a cut that came apart and a cut that was nearly
        // right would print identically.
        let refusal = OnDeviceSegmenter.Refusal.validator(.underSegmented, fragments: 4)
        guard case .validator(let reason, let fragments) = refusal else {
            Issue.record("the refusal lost its payload")
            return
        }
        #expect(reason == .underSegmented)
        #expect(fragments == 4)
        // The label stays the same shape for the table.
        #expect(refusal.label == "validator(underSegmented)")
    }

    // MARK: - The table

    @Test("columns are padded by hand, because %@ ignores a width specifier here")
    func columnsAlign() {
        // The first run of this harness printed every column run together; the fix is a
        // function rather than a format string, so it can be tested.
        #expect(FMPrimitives.pad("abc", 6) == "abc   ")
        #expect(FMPrimitives.pad("abcdef", 4) == "abc ")
        #expect(FMPrimitives.pad("", 3) == "   ")
    }

    @Test("a refusal label stays on one line whatever the model threw")
    func refusalLabelsAreClamped() {
        // An unclamped `LanguageModelError` description is eight lines of nested NSError,
        // and one of them destroys the table it lands in.
        let sprawling = "Error Domain=X\nCode=-1\n" + String(repeating: "detail ", count: 60)
        let label = Instrument.oneLine(OnDeviceSegmenter.Refusal.failed(sprawling).label)
        #expect(!label.contains("\n"))
        #expect(label.count <= 140)
    }
}
