//
//  SegmentationTests.swift
//  Project-EzraTests
//
//  The connective-aware splitter's contract, pinned at the unit level (RambleEval
//  scores the whole pipeline; these isolate the splitter). The guard cases are the
//  important half: every split rule has a phrase it must NOT split, and the old
//  splitter's 120-char comma cliff must stay dead.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct SegmentationTests {

    // MARK: - Run-ons split

    @Test("A dictated run-on splits at breath-connectives, lead-ins stripped")
    func runOnSplits() {
        let items = Segmentation.items(
            from:
                "i need to renew my passport and then i need to book flights and also call mom about thanksgiving"
        )
        #expect(items == ["renew my passport", "book flights", "call mom about thanksgiving"])
    }

    @Test("A verb+object left clause splits at bare 'and'")
    func verbObjectLeftSplits() {
        let items = Segmentation.items(from: "pay rent and figure out if we should switch insurance")
        #expect(items == ["pay rent", "figure out if we should switch insurance"])
    }

    @Test("Sentences split; trailing periods drop")
    func sentencesSplit() {
        let items = Segmentation.items(from: "Renew the passport. Book the dentist.")
        #expect(items == ["Renew the passport", "Book the dentist"])
    }

    @Test("A rejected boundary doesn't stop the scan — later boundaries still split")
    func scanContinuesPastRejectedBoundary() {
        let items = Segmentation.items(
            from: "call mom and dad about the reunion and then book the campsite")
        #expect(items == ["call mom and dad about the reunion", "book the campsite"])
    }

    // MARK: - Guards: what must NOT split

    @Test("Compound objects stay together")
    func compoundObjectsHold() {
        #expect(Segmentation.items(from: "call mom and dad about the reunion").count == 1)
        #expect(Segmentation.items(from: "buy milk and eggs").count == 1)
    }

    @Test("Compound verbs sharing one object stay together")
    func compoundVerbsHold() {
        #expect(Segmentation.items(from: "wash and fold the laundry").count == 1)
        #expect(Segmentation.items(from: "pick up and drop off the kids").count == 1)
    }

    @Test("A blocker phrase is not a boundary")
    func blockerPhraseHolds() {
        #expect(
            Segmentation.items(from: "book flights after passport is done").count == 1)
    }

    @Test("'after that' splits as a connective; 'after <noun>' stays a blocker — both directions")
    func afterThatVersusBlockerAfter() {
        // The connective form: the split's second item carries no phantom blocker.
        let items = Segmentation.items(
            from: "renew my passport and after that book flights for the trip")
        #expect(items == ["renew my passport", "book flights for the trip"])
        let second = HeuristicEngine.intent(from: items[1])
        #expect(second.blockerPhrase == nil)

        // The blocker form: no "after that" phrase present, so no split — and the
        // dependency survives intact through the engine.
        let blocked = Segmentation.items(from: "book flights after passport is done")
        #expect(blocked.count == 1)
        #expect(HeuristicEngine.intent(from: blocked[0]).blockerPhrase != nil)
    }

    @Test("'then i need to' splits with the lead-in consumed by the boundary")
    func thenINeedToSplits() {
        let items = Segmentation.items(
            from: "call the dentist then i need to return the amazon package")
        #expect(items == ["call the dentist", "return the amazon package"])
    }

    @Test("Ordinal openers strip only when the remainder verifies as an item")
    func ordinalOpenersStripSafely() {
        let items = Segmentation.items(from: "first call mom, second pay the rent")
        #expect(items == ["call mom", "pay the rent"])
        // "first aid kit" is a noun phrase — the ordinal must not eat its words.
        #expect(Segmentation.items(from: "first aid kit for the car") == ["first aid kit for the car"])
    }

    @Test("A trailing rationale clause stays attached to its judgment item")
    func rationaleStaysAttached() {
        let items = Segmentation.items(
            from: "figure out whether we keep the storage unit because it's expensive and we never go there"
        )
        #expect(items.count == 1)
    }

    // MARK: - Comma lists

    @Test("A comma list past the old 120-char cliff still splits per part")
    func longCommaListSplits() {
        let long =
            "renew my passport before the trip, book the dentist appointment for both kids, pay the water bill before the late fee, return the amazon package to the ups store"
        #expect(long.count > 120)
        #expect(Segmentation.items(from: long).count == 4)
    }

    @Test("Digit,digit commas never split")
    func numericCommasHold() {
        let items = Segmentation.items(from: "pay the 1,200 deposit for the venue")
        #expect(items == ["pay the 1,200 deposit for the venue"])
    }

    @Test("A comma clause that isn't a list stays whole")
    func nonListCommaHolds() {
        let items = Segmentation.items(
            from:
                "when the contractor finally calls back, which could honestly take another whole week or more"
        )
        #expect(items.count == 1)
    }

    // MARK: - Preambles

    @Test("A dash preamble strips when what follows is a verified item")
    func dashPreambleStrips() {
        let items = Segmentation.items(from: "ok brain dump time — renew my passport before the trip")
        #expect(items == ["renew my passport before the trip"])
    }

    @Test("Filler openers strip when the remainder verifies as an item")
    func fillerOpenersStrip() {
        let items = Segmentation.items(from: "okay so um call the dentist about the kids")
        #expect(items == ["call the dentist about the kids"])
    }

    @Test("An all-filler sentence is kept, never silently dropped")
    func allFillerSentenceKept() {
        // It becomes a card the user can delete — dimmed by the heuristic's
        // low-confidence read — because invisible-and-gone is worse than
        // visible-and-fixable (always-confirm).
        let items = Segmentation.items(from: "okay so this week is a lot")
        #expect(items.count == 1)
    }

    @Test("A real noun-phrase task never loses words to preamble stripping")
    func nounPhraseTaskKeepsItsWords() {
        let items = Segmentation.items(from: "daycare enrollment forms are due friday")
        #expect(items == ["daycare enrollment forms are due friday"])
    }

    @Test("A one-significant-word fragment folds into its left neighbour")
    func thinFragmentFolds() {
        // "and stuff" carries one significant word — junk as a standalone card.
        let items = Segmentation.items(from: "clean out the garage, and stuff")
        #expect(items == ["clean out the garage, and stuff"])
    }

    @Test("An anaphoric second item rides as its own card — honest over merged")
    func anaphoricFragmentSplits() {
        // "dad too" means a second call; a slightly-odd title the user can fix
        // beats silently folding a real task away (always-confirm philosophy).
        let items = Segmentation.items(from: "call mom, dad too")
        #expect(items == ["call mom", "dad too"])
    }

    // MARK: - The trust predicate (what may be revealed without the model)

    /// `structure(of:)` answers ONE question: did the user draw these boundaries, or did
    /// we infer them? Only boundaries the user drew may be presented as the answer.
    ///
    /// It used to be a three-state `confidence`, and the middle state (`.singleThought`)
    /// was a word ceiling plus a verb lexicon deciding that an unpunctuated sentence
    /// probably described one task. That is a semantic judgment about task boundaries —
    /// the judgment the semantic authority exists to make — so it was deleted along with
    /// `readsAsOneThought`, `maxSingleThoughtWords`, and the on-device gate that was
    /// built to make the call properly and measured too slow to be worth it.

    @Test("Structure the user typed is explicit — lines, bullets, and a comma list")
    func typedStructureIsExplicit() {
        #expect(Segmentation.structure(of: "Renew passport\nCall mom\nBuy diapers").isExplicit)
        #expect(Segmentation.structure(of: "- Renew passport\n- Call mom").isExplicit)
        #expect(Segmentation.structure(of: "Buy milk, call mom, book flights").isExplicit)
    }

    @Test("A lone sentence is UNSTRUCTURED however obviously single it reads")
    func oneItemIsNeverExplicit() {
        // The deliberate consequence of the collapse, and the case most likely to be
        // "fixed" by someone who thinks it is a bug: "renew my passport" is obviously one
        // task, and saying so is semantic work this function is not allowed to do. It
        // goes to the authority.
        #expect(Segmentation.structure(of: "renew my passport") == .unstructured)
        #expect(
            Segmentation.structure(of: "figure out whether we should book the hotel")
                == .unstructured)
        #expect(Segmentation.structure(of: "") == .unstructured)
    }

    @Test("Connective prose is UNSTRUCTURED — that split is our inference, not their input")
    func connectiveProseIsUnstructured() {
        #expect(Segmentation.structure(of: "renew my passport and call mom") == .unstructured)
        #expect(
            Segmentation.structure(
                of: "i need to renew my passport and then book flights and also call mom")
                == .unstructured)
    }

    @Test("explicitItems reads punctuation only — it never splits a connective")
    func explicitItemsIgnoreConnectives() {
        #expect(Segmentation.explicitItems(from: "renew my passport and call mom").count == 1)
        #expect(Segmentation.explicitItems(from: "Renew passport\nCall mom").count == 2)
        #expect(Segmentation.explicitItems(from: "Buy milk, call mom").count == 2)
    }

    // MARK: - One item is not evidence of one thought (the 2026-08-11 regression)

    /// The old gate returned "certain" for ANY one-item read, which is exactly backwards:
    /// one item out of a long dictation means every boundary test failed, not that the
    /// user said one thing. Shipped consequence — a four-errand ramble became a single
    /// task titled with the raw transcript, silently dropped the other three, and rewrote
    /// its own title twenty seconds later when the model disagreed.
    ///
    /// The two-state model makes that regression unrepresentable rather than merely
    /// detected: an unpunctuated run has no user-drawn boundaries, so it cannot be local
    /// no matter how it reads.

    @Test("The dictated four-errand run-on from the 08-11 recording never reveals locally")
    func dictatedRunOnIsNotExplicit() {
        let ramble =
            "Cook dinner at 3PM make odd duck reservation tonight take my wife to dinner "
            + "next week book reservation at tiki tomorrow at 1pm"
        // The splitter genuinely cannot cut this — no connectives, just juxtaposition.
        #expect(Segmentation.items(from: ramble).count == 1)
        // Which is precisely why it must NOT be revealed as the answer.
        #expect(Segmentation.structure(of: ramble) == .unstructured)
        #expect(CaptureRoute.route(for: ramble) == .cloud)
    }

    /// Deleted with `readsAsOneThought` (2026-08-22): `interiorVerbsMeanSeveralItems`,
    /// `subordinateVerbsAreNotItemStarts`, `realSingleThoughtsStayCertain`,
    /// `lengthAloneCanDisqualify`, `confidenceDistinguishesProvenance`.
    ///
    /// They were good tests of a function that should not have existed. Every one of
    /// them pinned some corner of a lexical rule inferring task boundaries — a modal
    /// before a verb, a determiner making a verb a noun, a 25-word ceiling — and the
    /// whole point of the collapse is that inferring boundaries is not deterministic
    /// code's job. Keeping them would have preserved the interpretation in the test
    /// suite after removing it from the product.
    ///
    /// The behaviour they protected did not go unmeasured: `RambleEval`'s segmentation
    /// floor scores exactly this, end to end, against labeled ground truth, on whichever
    /// arm actually runs.

}
