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
}
