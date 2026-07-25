//
//  OwnerProposerTests.swift
//  Project-EzraTests
//
//  The owner ladder. Replaces `AppBrainOwnershipGateTests`, which guarded the
//  abstention this feature deletes: the old gate flagged a confident household draft
//  `ownerPending` and made the confirm card ask "who does this belong to?".
//
//  Three of these tests exist because the rule they guard is invisible in the output
//  and would rot silently:
//
//  - load can never ORIGINATE a proposal (only adjust one),
//  - the affinity denominator counts HUMAN-established ownership only, or rung 3 is
//    unreachable by construction,
//  - the inferred rungs stay off until sync exists, or a task can be handed to
//    somebody with no device in the graph.
//

import Foundation
import Testing

@testable import Project_Ezra

struct OwnerProposerTests {

    private let maya = UUID()
    private let alex = UUID()

    private func draft(
        _ title: String = "x", category: String = "Home", ownerName: String? = nil
    ) -> TaskDraft {
        TaskDraft(
            title: title, category: category, confidence: 0.9, autonomy: .silent,
            isJudgmentCall: false, reasoning: "", ownerName: ownerName)
    }

    private func candidate(
        _ id: UUID, _ name: String, active: Int = 0, overloaded: Bool = false
    )
        -> OwnerCandidate
    {
        OwnerCandidate(memberID: id, name: name, activeCount: active, isOverloaded: overloaded)
    }

    private func history(
        _ category: String, _ name: String, human: Bool = true, count: Int = 1
    )
        -> [OwnerHistoryEntry]
    {
        Array(
            repeating: OwnerHistoryEntry(
                category: category, ownerName: name, isHumanEstablished: human), count: count)
    }

    // MARK: - Rung 1: spoken

    @Test("A spoken name always wins, and is never sync-gated")
    func spokenWins() {
        let proposal = OwnerProposer.propose(
            draft: draft(ownerName: "Maya"), roster: [], syncIsLive: false)
        #expect(proposal.memberName == "Maya")
        #expect(proposal.basis == .spoken)
        // No reason line: they said it, so nothing is owed an explanation.
        #expect(proposal.reason == nil)
    }

    @Test("A spoken name is never overridden by a graph neighbour or an affinity")
    func spokenBeatsEverything() {
        let proposal = OwnerProposer.propose(
            draft: draft(ownerName: "Maya"), roster: [candidate(alex, "Alex")],
            adjacentOwners: ["Alex"], history: history("Home", "Alex", count: 5), syncIsLive: true)
        #expect(proposal.basis == .spoken)
        #expect(proposal.memberName == "Maya")
    }

    // MARK: - Rung 2: adjacency

    @Test("A graph neighbour's owner is proposed, with a reason")
    func adjacencyProposes() {
        let proposal = OwnerProposer.propose(
            draft: draft(), roster: [candidate(maya, "Maya")], adjacentOwners: ["Maya"],
            syncIsLive: true)
        #expect(proposal.basis == .adjacency)
        #expect(proposal.memberName == "Maya")
        #expect(proposal.reason != nil)
    }

    @Test("An adjacent name that isn't on the roster proposes nobody")
    func adjacencyNeedsARosterMatch() {
        let proposal = OwnerProposer.propose(
            draft: draft(), roster: [candidate(maya, "Maya")], adjacentOwners: ["Priya"],
            syncIsLive: true)
        #expect(proposal.basis == .defaultSelf)
    }

    // MARK: - Rung 3: affinity, and why its denominator matters

    @Test("Category ownership proposes once it clears both bars")
    func affinityProposes() {
        let proposal = OwnerProposer.propose(
            draft: draft(category: "Health"), roster: [candidate(maya, "Maya")],
            history: history("Health", "Maya", count: 4), syncIsLive: true)
        #expect(proposal.basis == .affinity)
        #expect(proposal.memberName == "Maya")
    }

    @Test("Two prior tasks is a coincidence, not a pattern")
    func affinityNeedsSamples() {
        let proposal = OwnerProposer.propose(
            draft: draft(category: "Health"), roster: [candidate(maya, "Maya")],
            history: history("Health", "Maya", count: 2), syncIsLive: true)
        #expect(proposal.basis == .defaultSelf)
    }

    @Test("INFERRED ownership is excluded from the denominator — or rung 3 never fires")
    func affinityCountsHumanIntentOnly() {
        // The shape this guards: rung 4 makes the capturer the owner of everything the
        // earlier rungs miss, so counting ALL tasks would flood every category's
        // denominator with the proposer's own output and Maya could never cross 60%.
        let flooded =
            history("Health", "Maya", human: true, count: 4)
            + history("Health", "You", human: false, count: 20)
        let proposal = OwnerProposer.propose(
            draft: draft(category: "Health"), roster: [candidate(maya, "Maya")],
            history: flooded, syncIsLive: true)
        #expect(proposal.basis == .affinity)
        #expect(proposal.memberName == "Maya")
    }

    // MARK: - Load: a modifier, never a selector

    @Test("Load alone NEVER yields a non-self owner")
    func loadNeverOriginates() {
        // An idle roster member with no fit signal at all. If load could select, this
        // would hand her the task purely because her number is lower.
        let proposal = OwnerProposer.propose(
            draft: draft(), roster: [candidate(maya, "Maya", active: 0)], syncIsLive: true)
        #expect(proposal.basis == .defaultSelf)
        #expect(proposal.memberName == nil)
    }

    @Test("An overloaded candidate yields to the next one sharing the basis")
    func overloadDemotes() {
        let proposal = OwnerProposer.propose(
            draft: draft(),
            roster: [
                candidate(maya, "Maya", active: 9, overloaded: true),
                candidate(alex, "Alex", active: 2),
            ],
            adjacentOwners: ["Maya", "Alex"], syncIsLive: true)
        #expect(proposal.memberName == "Alex")
        #expect(proposal.basis == .adjacency)
    }

    @Test("An all-overloaded field still proposes — the lightest plate, not nobody")
    func allOverloadedFallsToLightest() {
        let proposal = OwnerProposer.propose(
            draft: draft(),
            roster: [
                candidate(maya, "Maya", active: 9, overloaded: true),
                candidate(alex, "Alex", active: 5, overloaded: true),
            ],
            adjacentOwners: ["Maya", "Alex"], syncIsLive: true)
        #expect(proposal.memberName == "Alex")
    }

    // MARK: - The sync gate

    @Test("Inferred rungs are off until sync — nothing is handed to an unreachable member")
    func inferredRungsAreSyncGated() {
        let adjacency = OwnerProposer.propose(
            draft: draft(), roster: [candidate(maya, "Maya")], adjacentOwners: ["Maya"],
            syncIsLive: false)
        #expect(adjacency.basis == .defaultSelf)

        let affinity = OwnerProposer.propose(
            draft: draft(category: "Health"), roster: [candidate(maya, "Maya")],
            history: history("Health", "Maya", count: 5), syncIsLive: false)
        #expect(affinity.basis == .defaultSelf)
    }

    // MARK: - The ladder is total

    @Test("A solo install always terminates at the capturer, with nothing to explain")
    func soloTerminates() {
        let proposal = OwnerProposer.propose(draft: draft(), roster: [], syncIsLive: true)
        #expect(proposal.basis == .defaultSelf)
        #expect(proposal.memberName == nil)
        // The ✦ keys off this: defaulting to you is not an inference, and claiming it
        // was is worse for trust than the abstention this replaced.
        #expect(proposal.reason == nil)
    }

    @Test("Every path returns an owner — there is no abstention case")
    func ladderIsTotal() {
        let cases: [(TaskDraft, [OwnerCandidate], [String], Bool)] = [
            (draft(ownerName: "Maya"), [], [], false),
            (draft(), [candidate(maya, "Maya")], ["Maya"], true),
            (draft(), [candidate(maya, "Maya")], [], true),
            (draft(), [], [], false),
        ]
        for (d, roster, adjacent, sync) in cases {
            let proposal = OwnerProposer.propose(
                draft: d, roster: roster, adjacentOwners: adjacent, syncIsLive: sync)
            // Non-optional by type; the point is that no input path traps or abstains.
            #expect(OwnerProposal.Basis.allBases.contains(proposal.basis))
        }
    }
}

extension OwnerProposal.Basis {
    fileprivate static let allBases: [OwnerProposal.Basis] = [
        .spoken, .adjacency, .affinity, .defaultSelf,
    ]
}
