//
//  CaptureDuplicates.swift
//  Project-Ezra
//
//  **"You already have that" — at capture, on the device.** (2026-10-04)
//
//  Capture-time duplicate offers ("Merge with 'Renew passport'?") used to come out of the
//  model's whole-capture parse, which cited a candidate id from retrieval. That parse ran
//  on the cloud rung, and when capture moved to the device only the offers went with it:
//  a person could add "pay the water bill" beside the "Pay the water bill" already on the
//  list and nothing said so.
//
//  This brings them back from two parts that are already measured:
//  - **Candidates** are the duplicate sweep's own lexical floor (`DuplicateSweep`): the
//    significant words of a new card against each open task's, one best candidate per
//    card, the person's past "keep both" respected.
//  - **The verdict** is the duplicate sweep's own judge (`DuplicateSweep.judge`, the same
//    instructions and prompt), measured on the phone at FALSE MERGE 0/20 on iOS 27 GA.
//    It is tiered exactly as capture-time proposals always were (`IntentResolver.tier`:
//    0.85 and up arrives pre-selected, 0.5–0.85 asks), and the card's Merge / Keep both
//    is the human boundary. A "not the same" or no answer proposes nothing.
//
//  Only cards that HAVE a lexical candidate cost a call, and at most `maxChecks` of them,
//  all at once — on most captures the store holds nothing close and this is free.
//

import Foundation

enum CaptureDuplicates {

    /// The most cards judged per capture.
    static let maxChecks = 3
    /// The whole check. A card without a verdict by then simply carries no offer.
    nonisolated static let budgetSeconds: Double = 4

    struct Candidate: Equatable {
        var draftIndex: Int
        var target: OpenTaskSnapshot
        var score: Double
    }

    /// The best open task per card that clears the sweep's lexical floor, strongest
    /// first, capped. Pure. Skips a card that already carries a duplicate proposal and
    /// any pairing the person already declined.
    static func candidates(
        for drafts: [TaskDraft], among open: [OpenTaskSnapshot], suppressions: [RelationshipSuppression]
    ) -> [Candidate] {
        let openWords = open.map { ($0, CorrectionProfile.significantWords($0.title)) }.filter {
            !$0.1.isEmpty
        }
        var found: [Candidate] = []
        for (index, draft) in drafts.enumerated() {
            guard !draft.edgeProposals.contains(where: { $0.kind == .duplicateOf }) else { continue }
            let words = CorrectionProfile.significantWords(draft.title)
            guard !words.isEmpty else { continue }
            let normalized = RelationshipSuppression.normalizeTitle(draft.title)
            var best: Candidate?
            for (snapshot, targetWords) in openWords {
                let union = Double(words.union(targetWords).count)
                let score = union > 0 ? Double(words.intersection(targetWords).count) / union : 0
                guard score >= DuplicateSweep.lexicalFloor, score > (best?.score ?? 0) else { continue }
                guard
                    !suppressions.contains(where: {
                        $0.suppresses(
                            kind: .duplicateMerge, targetID: snapshot.id, normalizedTitle: normalized)
                    })
                else { continue }
                best = Candidate(draftIndex: index, target: snapshot, score: score)
            }
            if let best { found.append(best) }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(maxChecks))
    }

    /// The proposal a verdict earns, or nil: the judge must call them the same task, and
    /// the confidence must clear capture's suggest floor (`IntentResolver.tier`).
    static func proposal(
        for judgment: DuplicateJudgment, target: OpenTaskSnapshot
    ) -> EdgeProposal? {
        guard judgment.isDuplicate,
            let decision = IntentResolver.tier(.duplicateOf, judgment.confidence)
        else { return nil }
        return EdgeProposal(
            kind: .duplicateOf, targetID: target.id, targetTitle: target.title,
            confidence: judgment.confidence, decision: decision)
    }

    /// Judge each candidate and attach the proposals it earns. The frozen AI snapshot
    /// gets the same proposal, so a "keep both" at Confirm is recorded as the person's
    /// answer to it. `judge` is injected so the pass runs under test with no model.
    static func proposing(
        _ drafts: [TaskDraft], among open: [OpenTaskSnapshot], suppressions: [RelationshipSuppression],
        budget: Double = budgetSeconds,
        judge: @escaping @Sendable (DuplicateSweep.CandidatePair) async -> DuplicateJudgment?
    ) async -> [TaskDraft] {
        let found = candidates(for: drafts, among: open, suppressions: suppressions)
        guard !found.isEmpty else { return drafts }
        let pairs = found.map { candidate in
            (
                candidate,
                DuplicateSweep.CandidatePair(
                    a: OpenTaskSnapshot(
                        id: drafts[candidate.draftIndex].id, title: drafts[candidate.draftIndex].title,
                        category: drafts[candidate.draftIndex].category),
                    b: candidate.target, score: candidate.score)
            )
        }
        let verdicts: [Int: DuplicateJudgment] =
            (try? await ModelDeadline.race(timeout: budget) {
                await withTaskGroup(of: (Int, DuplicateJudgment?).self) { group in
                    for (candidate, pair) in pairs {
                        group.addTask { (candidate.draftIndex, await judge(pair)) }
                    }
                    var answers: [Int: DuplicateJudgment] = [:]
                    for await (index, judgment) in group { if let judgment { answers[index] = judgment } }
                    return answers
                }
            }) ?? [:]
        var result = drafts
        for candidate in found {
            guard let judgment = verdicts[candidate.draftIndex],
                let proposal = proposal(for: judgment, target: candidate.target)
            else { continue }
            result[candidate.draftIndex].edgeProposals.append(proposal)
            result[candidate.draftIndex].aiOriginal?.edgeProposals.append(proposal)
        }
        return result
    }

    /// The product's judge: the duplicate sweep's, on the device.
    static func modelJudge(_ pair: DuplicateSweep.CandidatePair) async -> DuplicateJudgment? {
        if case .success(let judgment) = await DuplicateSweep.judge(pair) { return judgment }
        return nil
    }
}
