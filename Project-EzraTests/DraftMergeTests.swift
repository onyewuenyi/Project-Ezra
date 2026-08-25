//
//  DraftMergeTests.swift
//  Project-EzraTests
//
//  The merge is where a re-parse (or a streaming partial) meets cards the user may
//  already have touched, and its two prior failure modes were exactly the ones the
//  product cannot afford: a human edit silently discarded, and a deleted card
//  resurrected by the next keystroke. These pin the replacement's contract:
//  identity survives the stream, edits survive the re-read, removals stick, and
//  `aiOriginal` always adopts the LATEST AI reading (the Correction diff and the
//  suppression key both depend on that).
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct DraftMergeTests {

    private func draft(
        _ title: String, aiTitle: String? = nil, category: String = "Admin",
        dueDate: Date? = nil, edgeProposals: [EdgeProposal] = []
    ) -> TaskDraft {
        var d = TaskDraft(
            title: title, category: category, confidence: 0.9, autonomy: .silent,
            isJudgmentCall: false, reasoning: "")
        d.dueDate = dueDate
        d.edgeProposals = edgeProposals
        d.aiOriginal = AIFieldSnapshot(
            title: aiTitle ?? title, category: category, dueDate: dueDate, isUrgent: false,
            ownerName: nil, effortMinutes: nil, edgeProposals: edgeProposals)
        return d
    }

    private var none: RemovedDraftSet { RemovedDraftSet() }

    // MARK: - Identity

    @Test("A streaming partial whose title is still growing keeps the card's identity")
    func streamingGrowthKeepsIdentity() {
        let current = draft("renew pass")
        let fresh = draft("renew passport before the trip")

        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)

        #expect(merged.count == 1)
        #expect(merged[0].id == current.id)
        #expect(merged[0].title == "renew passport before the trip")
    }

    @Test("An exact-title re-parse keeps identity, user edits, and the LATEST aiOriginal")
    func exactMatchKeepsIdAndEdits() {
        var current = draft("call the vet")
        current.category = "Health"
        current.markEdited(.category)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        let fresh = draft("call the vet", dueDate: tomorrow)

        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)

        #expect(merged[0].id == current.id)
        // The user's edit survives; the AI's new reading lands on untouched fields.
        #expect(merged[0].category == "Health")
        #expect(merged[0].dueDate == tomorrow)
        // aiOriginal is the FRESH snapshot — commit diffs and suppression keys read
        // the AI's current proposal, not a stale one.
        #expect(merged[0].aiOriginal == fresh.aiOriginal)
        #expect(merged[0].userEdited(.category))
        #expect(!merged[0].userEdited(.dueDate))
    }

    @Test("A related re-title keeps the card — including a user-edited title")
    func relatedRetitleKeepsEditedTitle() {
        var current = draft("book flights to lagos")
        current.title = "Book the Lagos flights (aisle seats!)"
        current.markEdited(.title)
        let fresh = draft("book flights to lagos for december")

        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)

        #expect(merged[0].id == current.id)
        #expect(merged[0].title == "Book the Lagos flights (aisle seats!)")
    }

    @Test("An unrelated fresh candidate never absorbs another card's edits")
    func unrelatedCandidateIsANewCard() {
        var current = draft("buy milk")
        current.markEdited(.isUrgent)
        let fresh = draft("call the dentist")

        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)

        #expect(merged.count == 1)
        #expect(merged[0].id != current.id)
        #expect(merged[0].editedFields == nil)
    }

    @Test("Re-segmentation 3 → 2: survivors match, the vanished line's card drops")
    func resegmentationDropsTheVanishedLine() {
        let a = draft("renew passport")
        let b = draft("book dentist appointment")
        let c = draft("water the plants")
        let freshA = draft("renew passport")
        let freshB = draft("book the dentist appointment for tuesday")

        let merged = DraftMerge.merge(fresh: [freshA, freshB], into: [a, b, c], removed: none)

        #expect(merged.count == 2)
        #expect(merged[0].id == a.id)
        #expect(merged[1].id == b.id)
    }

    @Test("Two identical lines pair positionally — no duplicate ids, both survive")
    func identicalLinesPairPositionally() {
        let first = draft("buy milk")
        let second = draft("buy milk")
        let merged = DraftMerge.merge(
            fresh: [draft("buy milk"), draft("buy milk")], into: [first, second], removed: none)

        #expect(merged.map(\.id) == [first.id, second.id])
        #expect(Set(merged.map(\.id)).count == 2)
    }

    // MARK: - The provisional upgrade (instant card → model card)

    private func provisional(_ title: String, source: String) -> TaskDraft {
        var d = draft(title)
        d.provisionalSource = source
        return d
    }

    @Test("A model retitle claims the provisional card it came from — id, edits, and all")
    func modelRetitleClaimsProvisionalCard() {
        // The motivating case: word overlap between the two TITLES is 0.25, under the
        // 0.3 retitle floor, so Passes A and B both miss. Only source-clause lineage
        // recognises them as one thought.
        let source = "I should probably get around to booking the flights"
        var current = provisional("Get around to booking the flights", source: source)
        current.category = "Travel"
        current.markEdited(.category)

        let fresh = draft("Book flights")
        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)

        #expect(merged.count == 1)
        #expect(merged[0].id == current.id)  // no swap, no view teardown
        #expect(merged[0].title == "Book flights")  // the model's better reading wins
        #expect(merged[0].category == "Travel")  // the user's edit survived
        #expect(merged[0].aiOriginal == fresh.aiOriginal)  // correction diff stays honest
        #expect(!merged[0].isProvisional)  // cleared by construction, not by a flag reset
    }

    @Test("Claiming requires shared SUBJECT words — a shared verb alone is not lineage")
    func sharedVerbAloneNeverClaims() {
        // "Call mom" and "call the dentist" share exactly "call". Letting that claim
        // would hand one line's edits to another line's card.
        #expect(!DraftMerge.claims(modelTitle: "Call mom", source: "call the dentist"))
        #expect(!DraftMerge.claims(modelTitle: "Buy milk", source: "call mom back"))
        // Real compressions do claim, including across inflection (booking → book).
        #expect(
            DraftMerge.claims(
                modelTitle: "Book flights",
                source: "I should probably get around to booking the flights"))
        #expect(DraftMerge.claims(modelTitle: "Renew passport", source: "renew my passport"))
    }

    @Test("The provisional claim never fires model-over-model")
    func claimNeverFiresModelOverModel() {
        // Neither card is provisional (no source clause), so Pass C cannot engage —
        // structurally, not by a parameter someone could forget to pass.
        let current = draft("Get around to booking the flights")
        let fresh = draft("Book flights")
        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)
        #expect(merged.count == 1)
        #expect(merged[0].id != current.id)  // dropped and replaced, today's behavior
    }

    // MARK: - Removal survives a retitle

    @Test("A removed provisional card stays removed when the model re-proposes it retitled")
    func removedProvisionalStaysRemovedAcrossRetitle() {
        let source = "I should probably get around to booking the flights"
        var removed = RemovedDraftSet()
        removed.record(provisional("Get around to booking the flights", source: source))

        // The model's re-proposal carries a title the removal key can't recognise.
        let merged = DraftMerge.merge(
            fresh: [draft("Book flights"), draft("Call mom")], into: [], removed: removed)

        #expect(merged.map(\.title) == ["Call mom"])
    }

    // MARK: - Removal stickiness

    @Test("A removed card stays removed when the re-parse proposes it again")
    func removedCardStaysRemoved() {
        let doomed = draft("buy milk")
        var removed = RemovedDraftSet()
        removed.record(doomed)

        let merged = DraftMerge.merge(
            fresh: [draft("buy milk"), draft("call mom")], into: [], removed: removed)

        #expect(merged.map(\.title) == ["call mom"])
    }

    @Test("Removing one of two identical lines keeps exactly one")
    func removalIsCounted() {
        let kept = draft("buy milk")
        var removed = RemovedDraftSet()
        removed.record(draft("buy milk"))

        let merged = DraftMerge.merge(
            fresh: [draft("buy milk"), draft("buy milk")], into: [kept], removed: removed)

        #expect(merged.count == 1)
        #expect(merged[0].id == kept.id)
    }

    // MARK: - Proposal decisions

    @Test("A user's proposal decision carries across a re-parse that re-proposes it")
    func proposalDecisionCarries() {
        let target = UUID()
        let proposed = EdgeProposal(
            kind: .duplicateOf, targetID: target, targetTitle: "Renew passport",
            confidence: 0.9, decision: .accepted)
        var current = draft("renew my passport", edgeProposals: [proposed])
        // The user said "keep both" — decision diverges from the frozen original.
        current.edgeProposals[0].decision = .rejected

        let fresh = draft("renew my passport", edgeProposals: [proposed])
        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)

        #expect(merged[0].id == current.id)
        #expect(merged[0].edgeProposals[0].decision == .rejected)
    }

    @Test("An untouched proposal takes the AI's fresh decision")
    func untouchedProposalTakesFreshDecision() {
        let target = UUID()
        let undecided = EdgeProposal(
            kind: .duplicateOf, targetID: target, targetTitle: "Renew passport",
            confidence: 0.6, decision: .undecided)
        let current = draft("renew my passport", edgeProposals: [undecided])

        var accepted = undecided
        accepted.decision = .accepted
        var fresh = draft("renew my passport", edgeProposals: [accepted])
        fresh.aiOriginal?.edgeProposals = [accepted]

        let merged = DraftMerge.merge(fresh: [fresh], into: [current], removed: none)

        #expect(merged[0].edgeProposals[0].decision == .accepted)
    }


    // MARK: - Pass C is reachable — do not delete it

    @Test("A local reveal, then more prose, then the authority: cards keep identity and edits")
    func passCSurvivesTheResubmitPath() {
        // Pass C was assumed dead after routing collapsed to local/cloud, on the grounds
        // that the two arms are exclusive: a local capture never sees a model result.
        // That is true for ONE submit and false for the flow this test describes.
        //
        //   type a list        → explicit structure → LOCAL reveal (provisional cards)
        //   tap Back           → `reopen()` deliberately KEEPS those drafts
        //   add a sentence     → now unstructured  → CLOUD
        //   the model answers  → merges into cards that carry `provisionalSource`
        //
        // Which is exactly Pass C's gate. Deleting it would not have failed a build or a
        // test; it would have silently dropped the user's edits and swapped their cards
        // for new ones with fresh ids, in a flow nobody would think to check.
        var typed = provisional("Renew passport", source: "renew passport")
        typed.category = "Health"
        typed.markEdited(.category)

        // The model rewrites the title, so Passes A and B structurally cannot match:
        // word overlap between "Renew passport" and "Sort out the passport renewal" is
        // below `retitleSimilarityFloor`.
        let fromAuthority = draft("Sort out the passport renewal")

        let merged = DraftMerge.merge(
            fresh: [fromAuthority], into: [typed], removed: none)

        #expect(merged.count == 1)
        #expect(merged[0].id == typed.id, "the card lost its identity across the re-submit")
        #expect(merged[0].category == "Health", "the user's edit was discarded")
    }
}
