//
//  AutonomyPolicyTests.swift
//  Project-EzraTests
//
//  Locks down the autonomy tier, the AI's proposed entry status, the stored
//  Needs Decision rule, and the derived assessment — especially the
//  judgment-category rule, which is a product invariant, not a tunable heuristic.
//

import Testing

@testable import Project_Ezra

@Suite("AutonomyPolicy & assessment")
struct AutonomyPolicyTests {

    // MARK: - Tier from confidence

    @Test("High confidence + reversible → silent")
    func highConfidenceIsSilent() {
        #expect(AutonomyPolicy.tier(confidence: 0.9, isJudgmentCall: false) == .silent)
        #expect(AutonomyPolicy.tier(confidence: 0.8, isJudgmentCall: false) == .silent)
    }

    @Test("Medium confidence → suggest")
    func mediumConfidenceIsSuggest() {
        #expect(AutonomyPolicy.tier(confidence: 0.65, isJudgmentCall: false) == .suggest)
        #expect(AutonomyPolicy.tier(confidence: 0.5, isJudgmentCall: false) == .suggest)
    }

    @Test("Low confidence → ask")
    func lowConfidenceIsAsk() {
        #expect(AutonomyPolicy.tier(confidence: 0.49, isJudgmentCall: false) == .ask)
        #expect(AutonomyPolicy.tier(confidence: 0.0, isJudgmentCall: false) == .ask)
    }

    // MARK: - Judgment-category rule (the invariant)

    @Test("A judgment call is ALWAYS ask, even at max confidence")
    func judgmentCallIsAlwaysAsk() {
        #expect(AutonomyPolicy.tier(confidence: 1.0, isJudgmentCall: true) == .ask)
        #expect(AutonomyPolicy.tier(confidence: 0.95, isJudgmentCall: true) == .ask)
    }

    // MARK: - Entry status (always-confirm: every creation lands in the Inbox)

    @Test("The resolver stamps every creation into the Inbox, at any confidence")
    func alwaysInbox() {
        for (confidence, judgment) in [(0.9, false), (0.5, false), (0.3, false), (1.0, true)] {
            let draft = IntentResolver.resolve(
                TaskIntent(
                    title: "x", category: "Home", confidence: confidence,
                    isJudgmentCall: judgment, reasoning: ""))
            #expect(draft.proposedStatus == .inbox)
        }
    }

    // MARK: - The stored Needs Decision rule (set at triage, on the draft)

    @Test("needsDecision: judgment call OR confidence < 0.5, regardless of each other")
    func draftNeedsDecisionRule() {
        func draft(_ confidence: Double, judgment: Bool) -> TaskDraft {
            IntentResolver.resolve(
                TaskIntent(
                    title: "x", category: "Home", confidence: confidence,
                    isJudgmentCall: judgment, reasoning: ""))
        }
        #expect(draft(1.0, judgment: true).needsDecision)  // judgment at any confidence
        #expect(draft(0.3, judgment: false).needsDecision)  // low confidence
        #expect(!draft(0.65, judgment: false).needsDecision)  // suggest tier: confirmable, not a decision
        #expect(!draft(0.9, judgment: false).needsDecision)  // silent tier
    }

    // MARK: - Assessment (the observation axis over the stored flag)

    @Test("A judgment call reads as Needs Decision (human judgment) while flagged")
    func judgmentAssessment() {
        let t = TaskItem(
            title: "should I quit the gym", status: .inbox, confidence: 1.0, isJudgmentCall: true,
            needsDecision: true)
        #expect(t.assessment(isBlocked: false).needsDecision == .humanJudgment)
    }

    @Test("Low confidence reads as Needs Decision (low confidence)")
    func lowConfidenceAssessment() {
        let t = TaskItem(title: "vague thing", status: .inbox, confidence: 0.3, needsDecision: true)
        #expect(t.assessment(isBlocked: false).needsDecision == .lowConfidence)
    }

    @Test("Confirm clears a low-confidence flag but NOT a judgment call's")
    func confirmClearsOnlyLowConfidence() {
        // Low confidence: the confirm glance validated the fields — flag settled.
        let vague = TaskItem(title: "vague thing", status: .inbox, confidence: 0.3, needsDecision: true)
        vague.confirm()
        #expect(vague.assessment(isBlocked: false).needsDecision == nil)

        // Judgment call: confirming the task exists is not making the call. The
        // flag survives (forced-top in the stack) until an explicit resolution —
        // the permanent judgment-category carve-out.
        let judgment = TaskItem(
            title: "should I quit the gym", status: .inbox, confidence: 1.0, isJudgmentCall: true,
            needsDecision: true)
        judgment.confirm()
        #expect(judgment.status == .active)
        #expect(judgment.assessment(isBlocked: false).needsDecision == .humanJudgment)
        // Only the human explicitly deciding clears it; provenance stays honest.
        judgment.resolveDecision()
        #expect(judgment.assessment(isBlocked: false).needsDecision == nil)
        #expect(judgment.isJudgmentCall)
    }

    @Test("Blocked and unowned are orthogonal observations, not statuses")
    func blockedUnownedAreObservations() {
        let t = TaskItem(title: "x", status: .active, confidence: 0.9, ownerPending: true)
        let a = t.assessment(isBlocked: true)
        #expect(a.isBlocked)
        #expect(a.isUnowned)
        // The observations didn't move the status.
        #expect(t.status == .active)
    }

    // MARK: - User override (review)

    @Test("userOverride accepts a proposal to Active at the silent tier, judgment flag intact")
    func userOverrideAccepts() {
        var draft = TaskDraft(
            title: "should I quit the gym",
            category: "Health",
            proposedStatus: .inbox,
            confidence: 1.0,
            autonomy: .ask,
            isJudgmentCall: true,
            reasoning: "Your call to make.",
            dueDate: nil
        )
        draft.userOverride(status: .active)
        #expect(draft.proposedStatus == .active)
        #expect(draft.autonomy == .silent)
        // A human resolving the call satisfies the rule; the provenance stays honest.
        #expect(draft.isJudgmentCall)
        #expect(draft.reasoning == "Your call to make.")
    }
}
