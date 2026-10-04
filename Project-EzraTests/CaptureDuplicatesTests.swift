//
//  CaptureDuplicatesTests.swift
//  Project-EzraTests
//
//  "You already have that", at capture (`CaptureDuplicates`): the sweep's lexical floor
//  picks one candidate per card, the sweep's judge decides, capture's tiers apply, and a
//  pairing the person already declined is never offered again. The judge is injected.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Capture duplicates — the sweep's judge, at capture")
struct CaptureDuplicatesTests {

    private let waterBill = OpenTaskSnapshot(id: UUID(), title: "Pay the water bill", category: "Bills")
    private let passport = OpenTaskSnapshot(id: UUID(), title: "Renew passport", category: "Travel")

    private func draft(_ title: String) -> TaskDraft {
        AppBrain.provisionalDrafts(title).first!
    }

    @Test("One candidate per card, only past the sweep's lexical floor")
    func candidatesUseTheLexicalFloor() {
        let drafts = [draft("pay the water bill"), draft("call the dentist about the crown")]
        let found = CaptureDuplicates.candidates(for: drafts, among: [waterBill, passport], suppressions: [])
        #expect(found.count == 1)
        #expect(found.first?.draftIndex == 0)
        #expect(found.first?.target.id == waterBill.id)
    }

    @Test(
        "A same-task verdict is tiered like every capture proposal; a different-task verdict offers nothing")
    func verdictsAreTiered() {
        let sure = DuplicateJudgment(isDuplicate: true, confidence: 0.95, reason: "same errand")
        let maybe = DuplicateJudgment(isDuplicate: true, confidence: 0.6, reason: "probably")
        let faint = DuplicateJudgment(isDuplicate: true, confidence: 0.3, reason: "unsure")
        let different = DuplicateJudgment(isDuplicate: false, confidence: 0.9, reason: "different")
        #expect(CaptureDuplicates.proposal(for: sure, target: waterBill)?.decision == .accepted)
        #expect(CaptureDuplicates.proposal(for: maybe, target: waterBill)?.decision == .undecided)
        #expect(CaptureDuplicates.proposal(for: faint, target: waterBill) == nil)
        #expect(CaptureDuplicates.proposal(for: different, target: waterBill) == nil)
    }

    @Test("The judge's verdict lands on the card and on its frozen AI snapshot")
    func proposalLands() async {
        let drafts = [draft("pay the water bill"), draft("call the dentist about the crown")]
        let result = await CaptureDuplicates.proposing(
            drafts, among: [waterBill, passport], suppressions: []
        ) { _ in
            DuplicateJudgment(isDuplicate: true, confidence: 0.92, reason: "same errand")
        }
        let proposal = result[0].edgeProposals.first { $0.kind == .duplicateOf }
        #expect(proposal?.targetID == waterBill.id)
        #expect(proposal?.decision == .accepted)
        #expect(result[0].aiOriginal?.edgeProposals.contains { $0.kind == .duplicateOf } == true)
        #expect(result[1].edgeProposals.isEmpty, "a card with no candidate is never judged")
    }

    @Test("No answer, or no candidate, leaves the cards exactly as they were")
    func silenceChangesNothing() async {
        let drafts = [draft("pay the water bill")]
        let silent = await CaptureDuplicates.proposing(drafts, among: [waterBill], suppressions: []) { _ in
            nil
        }
        #expect(silent == drafts)
        let nothingClose = await CaptureDuplicates.proposing(drafts, among: [passport], suppressions: []) {
            _ in
            Issue.record("judged a card with no candidate")
            return nil
        }
        #expect(nothingClose == drafts)
    }

    @Test("A pairing the person already declined is never offered again")
    func suppressionsHold() {
        let drafts = [draft("pay the water bill")]
        let declined = RelationshipSuppression(
            kind: .duplicateMerge, pairKey: nil, targetID: waterBill.id,
            normalizedTitle: RelationshipSuppression.normalizeTitle(drafts[0].title), createdAt: Date())
        #expect(
            CaptureDuplicates.candidates(for: drafts, among: [waterBill], suppressions: [declined]).isEmpty)
    }

    @Test("A duplicate candidate sends a capture to the model pass, only with a model")
    func planHonoursCandidates() {
        let text = "pay the water bill"
        let local = AppBrain.provisionalDrafts(text)
        #expect(
            CaptureFlow.plan(
                text: text, localRead: local, fromVoice: false, modelAvailable: true,
                duplicateCandidates: true
            ).arm == .judge)
        #expect(
            CaptureFlow.plan(
                text: text, localRead: local, fromVoice: false, modelAvailable: false,
                duplicateCandidates: true
            ).arm == .revealInstantly)
    }
}
