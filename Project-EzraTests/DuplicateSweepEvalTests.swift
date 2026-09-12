import Foundation
import Testing

@testable import Project_Ezra

/// The destructive gate's SCORER and its corpus, pinned in CI.
///
/// The judge itself is device-only, but everything that decides what its answers MEAN is
/// pure — and pure scoring is where this codebase keeps finding its bugs. A blind scorer on
/// a report about merging the user's tasks is the worst place to have one.
@Suite("duplicate sweep eval")
@MainActor
struct DuplicateSweepEvalTests {

    // MARK: - The 2×2

    @Test("false merge is the cell that destroys something, and it is named as its own")
    func falseMergeIsTheDangerousCell() {
        #expect(
            DuplicateSweepEval.verdict(merged: true, hadArtifact: true, isDuplicate: false)
                == .falseMerge)
        #expect(
            DuplicateSweepEval.verdict(merged: true, hadArtifact: true, isDuplicate: true) == .trueMerge)
        // Leaving a real duplicate alone is clutter, not damage — and the two must not
        // share a cell, or a conservative judge and a reckless one score the same.
        #expect(
            DuplicateSweepEval.verdict(merged: false, hadArtifact: true, isDuplicate: true)
                == .missedDuplicate)
        #expect(
            DuplicateSweepEval.verdict(merged: false, hadArtifact: true, isDuplicate: false)
                == .correctlyLeft)
        #expect(
            DuplicateSweepEval.verdict(merged: false, hadArtifact: false, isDuplicate: true)
                == .noArtifact)
    }

    @Test("the scorer's bracket holds — a correct merge scores clean, a wrong one is caught")
    func scorerBracketHolds() {
        let clean =
            DuplicateSweepEval.verdict(merged: true, hadArtifact: true, isDuplicate: true)
                == .falseMerge ? 1 : 0
        let reckless =
            DuplicateSweepEval.verdict(merged: true, hadArtifact: true, isDuplicate: false)
                == .falseMerge ? 1 : 0
        #expect(Instrument.bracketHolds(cleanFlags: clean, recklessFlags: reckless))
    }

    // MARK: - The corpus

    @Test("the corpus is PAIRED, so a yes-to-everything judge cannot score well")
    func corpusIsBalanced() {
        let duplicates = DuplicateSweepEval.corpus.filter(\.isDuplicate).count
        let nearMisses = DuplicateSweepEval.corpus.count - duplicates
        #expect(duplicates == nearMisses, "the corpus stopped being matched")
        #expect(duplicates >= 10, "too small to distinguish a judge from a coin")
        // A judge that answers "duplicate" to everything scores exactly half; so does one
        // that answers "not". That is the property the pairing buys.
        #expect(Double(duplicates) / Double(DuplicateSweepEval.corpus.count) == 0.5)
    }

    @Test("no pair is labeled twice, and none is labeled both ways")
    func corpusHasNoContradictions() {
        // One utterance carrying two labels across corpora was a real bug in the ramble
        // eval; a pair carrying two labels here would be the same bug on a destructive gate.
        var seen: [String: Bool] = [:]
        for pair in DuplicateSweepEval.corpus {
            let key = [pair.a.lowercased(), pair.b.lowercased()].sorted().joined(separator: " ↔ ")
            if let existing = seen[key] {
                #expect(existing == pair.isDuplicate, "\(key) is labeled both ways")
                Issue.record("\(key) appears twice")
            }
            seen[key] = pair.isDuplicate
        }
    }

    @Test("the near-misses are built from their partner's words, not from unrelated tasks")
    func nearMissesAreAdversarial() {
        // A corpus whose negatives are obviously unrelated ("renew passport" / "walk the
        // dog") measures nothing twice over: word overlap alone would ace it, AND the
        // production prefilter's lexical floor would drop the pair before the judge ever
        // saw it — so it would be scoring a population the judge is never handed. This
        // test caught exactly that in the first draft of the corpus.
        for pair in DuplicateSweepEval.corpus where !pair.isDuplicate {
            let a = Set(pair.a.lowercased().split(separator: " ").map(String.init))
            let b = Set(pair.b.lowercased().split(separator: " ").map(String.init))
            #expect(
                !a.intersection(b).isEmpty,
                "\(pair.a) / \(pair.b) shares no words — it is not a near-miss")
        }
    }

    // MARK: - The gate itself

    @Test("acceptance takes BOTH the boolean and the threshold")
    func acceptanceNeedsBoth() {
        // The eval sweeps this rather than asserting 0.85, but the shape of the gate is
        // the thing the sweep depends on being true.
        let confidentYes = DuplicateJudgment(isDuplicate: true, confidence: 0.9, reason: "")
        let hesitantYes = DuplicateJudgment(isDuplicate: true, confidence: 0.5, reason: "")
        let confidentNo = DuplicateJudgment(isDuplicate: false, confidence: 0.99, reason: "")
        #expect(DuplicateSweep.accepts(confidentYes))
        #expect(!DuplicateSweep.accepts(hesitantYes))
        // A model certain they are NOT duplicates must never merge, however certain it is.
        #expect(!DuplicateSweep.accepts(confidentNo))
        // And the threshold is a parameter, which is what makes the sweep possible.
        #expect(DuplicateSweep.accepts(hesitantYes, threshold: 0.4))
    }

    @Test("the destructive tier is the same one capture-time merges use")
    func thresholdIsShared() {
        // Two thresholds for one destructive act would be two places to get it wrong.
        #expect(DuplicateSweep.acceptThreshold == IntentResolver.acceptThreshold)
    }
}
