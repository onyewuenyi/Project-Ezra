//
//  RevealBoundaryTests.swift
//  Project-EzraTests
//
//  The product's central AI-trust invariant, pinned:
//
//  > The system can think as much as it wants before showing you the answer. Once it shows
//  > you the answer, it owns that interpretation until you change it.
//
//  Three earlier attempts held this as a rule and all three leaked, each time reaching the
//  user as the same defect: a card changing after they had started reading it. These tests
//  exist because the rule is now a TYPE — and a type's promise is worth exactly as much as
//  the tests that hold it to the promise.
//
//  Post-reveal mutation is ZERO TOLERANCE, not a metric to keep low: a failure here is a
//  launch blocker.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct RevealBoundaryTests {

    private func draft(_ title: String) -> TaskDraft {
        TaskDraft(
            title: title, category: "Admin", confidence: 0.9, autonomy: .silent,
            isJudgmentCall: false, reasoning: "")
    }

    // MARK: - The boundary

    @Test("Before the reveal the system may propose freely")
    func proposalsAcceptedWhilePending() {
        var interpretation = Interpretation()
        let first = interpretation.propose([draft("Pick up food")])
        let second = interpretation.propose([draft("Pick up food"), draft("Call mom")])
        #expect(first)
        #expect(second)
        #expect(interpretation.drafts.count == 2)
        #expect(interpretation.state == .pending)
    }

    @Test("After the reveal an AI proposal is REFUSED — the printer-paper case")
    func proposalsRefusedAfterReveal() {
        var interpretation = Interpretation()
        _ = interpretation.propose([draft("Pick up food from the store")])
        interpretation.reveal()

        // Exactly what happened in the field: the model comes back seconds later with an
        // extra task the user never said.
        let refused = interpretation.propose([
            draft("Pick up food from the store"), draft("Buy new printer paper"),
        ])

        #expect(!refused)
        #expect(interpretation.drafts.count == 1)
        #expect(interpretation.drafts[0].title == "Pick up food from the store")
        #expect(!interpretation.hasUnexplainedMutation)
    }

    @Test("A better answer is refused too — improvement is not an exemption")
    func evenBetterProposalsAreRefused() {
        // The invariant is not "don't make it worse". A card the user has read must not
        // change, and a strictly better rewrite landing late is exactly the defect that
        // was reported first: a title rewriting itself twenty seconds after the reveal.
        var interpretation = Interpretation()
        _ = interpretation.propose([draft("Buy groceries")])
        interpretation.reveal()

        let refused = interpretation.propose([draft("Pick up food from the store later today")])
        #expect(!refused)
        #expect(interpretation.drafts[0].title == "Buy groceries")
    }

    // MARK: - The user is never constrained

    @Test("The user may edit a revealed interpretation, and that is not a mutation")
    func userEditsAlwaysAllowed() {
        var interpretation = Interpretation()
        _ = interpretation.propose([draft("Pick up food")])
        interpretation.reveal()

        interpretation.editableDrafts[0].title = "Pick up food for dinner"
        #expect(interpretation.drafts[0].title == "Pick up food for dinner")
        // Re-baselined: the user changing their own card is the sanctioned path, so the
        // zero-tolerance detector must stay quiet.
        #expect(!interpretation.hasUnexplainedMutation)

        interpretation.editableDrafts.removeAll()
        #expect(interpretation.drafts.isEmpty)
        #expect(!interpretation.hasUnexplainedMutation)
    }

    // MARK: - Reopening

    @Test("Going back to say more reopens the boundary and keeps the words")
    func reopenAcceptsProposalsAgain() {
        var interpretation = Interpretation()
        _ = interpretation.propose([draft("Pick up food")])
        interpretation.reveal()
        interpretation.reopen()

        #expect(interpretation.state == .pending)
        #expect(interpretation.drafts.count == 1)  // their cards survive the trip
        let accepted = interpretation.propose([draft("Pick up food"), draft("Call mom")])
        #expect(accepted)
        #expect(interpretation.drafts.count == 2)
    }

    // A routing test lived here and was deleted (2026-08-22). A reveal-boundary suite
    // should never have owned one: this file is about `Interpretation` refusing a late
    // proposal, which is true regardless of who produced it. That coupling is the only
    // reason a routing change ever touched this file. Routing is pinned in
    // `CaptureRouteTests`, where it belongs.
}
