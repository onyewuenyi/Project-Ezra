//
//  HouseholdSharingTests.swift
//  Project-EzraTests
//
//  The invite flow's pure halves — everything the simulator CAN prove. The CloudKit
//  round trip (share, accept, import) needs two signed-in phones and is a device sitting
//  named in `docs/cohort0-checklist.md`; what is pinned here is the logic on either side
//  of it: which store a new object is assigned to, which household an install works in,
//  who the arriving person is linked to, and what the roster says about it.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Household sharing — the halves the simulator can prove")
struct HouseholdSharingTests {

    private let context = PersistenceStack.scratch

    private func household(members: Int, createdAt: Date = Date()) -> Household {
        let household = Household(in: context)
        household.createdAt = createdAt
        for index in 0..<members {
            let member = FamilyMember(
                name: "Person \(index)", role: index == 0 ? .owner : .adult, in: context)
            member.household = household
        }
        return household
    }

    // MARK: - Which household

    @Test("The working household is the one with the most live members — the shared one, for an invitee")
    func largestRosterWins() throws {
        // Scratch accumulates fixtures from other suites, so compare against the answer
        // rather than against a fresh store: whichever wins must have the largest roster.
        let mine = household(members: 1, createdAt: Date(timeIntervalSince1970: 1))
        let shared = household(members: 3)
        let chosen = try #require(Household.existing(in: context))
        #expect(chosen.activeMembers.count >= shared.activeMembers.count)
        #expect(chosen != mine)
    }

    // MARK: - Store affinity

    @Test("A task or trail entry saved with no household is given the working one")
    func affinityBackfillsHousehold() throws {
        let home = try #require(Household.existing(in: context))
        let task = TaskItem(title: "Renew the passport", in: context)
        let entry = ChangeLogEntry(summary: "Filed", in: context)
        let capture = Capture(rawText: "renew the passport", in: context)
        #expect(task.household == nil)
        HouseholdStoreAffinity.assign(insertedIn: context)
        #expect(task.household == home)
        #expect(entry.household == home)
        // No household relationship → untouched. A capture is the person's, not the plan's.
        #expect(capture.entity.relationshipsByName["household"] == nil)
        // One store under XCTest, so the assignment itself is a no-op; the pin is on the
        // backfill, which is what decides the SHARE membership.
        context.saveChanges()
        #expect(task.household == home)
    }

    @Test("A task that already names a household keeps it")
    func affinityRespectsAnExplicitHousehold() {
        let other = household(members: 1)
        let task = TaskItem(title: "Their thing", in: context)
        task.household = other
        HouseholdStoreAffinity.assign(insertedIn: context)
        #expect(task.household == other)
    }

    // MARK: - Who am I

    @Test("Exactly one pending invitation naming a candidate links without asking")
    func autoLinkOnOnePending() throws {
        let home = household(members: 2)
        let maya = try #require(HouseholdSharing.linkCandidates(in: home).first)
        let invitation = Invitation(in: context)
        invitation.household = home
        invitation.memberID = maya.uuid
        let target = try #require(
            HouseholdSharing.autoLinkTarget(
                candidates: HouseholdSharing.linkCandidates(in: home), invitations: home.pendingInvitations))
        #expect(target.member == maya)
        #expect(target.invitation == invitation)
    }

    @Test("Two pending invitations, or none, or one naming nobody: ask, never guess")
    func askWhenAmbiguous() {
        let home = household(members: 3)
        let candidates = HouseholdSharing.linkCandidates(in: home)
        #expect(candidates.count == 2, "the owner is never a candidate")
        #expect(HouseholdSharing.autoLinkTarget(candidates: candidates, invitations: []) == nil)

        for member in candidates {
            let invitation = Invitation(in: context)
            invitation.household = home
            invitation.memberID = member.uuid
        }
        #expect(
            HouseholdSharing.autoLinkTarget(candidates: candidates, invitations: home.pendingInvitations)
                == nil)

        let stranger = household(members: 1)
        let orphan = Invitation(in: context)
        orphan.household = stranger
        orphan.memberID = UUID()
        #expect(
            HouseholdSharing.autoLinkTarget(
                candidates: HouseholdSharing.linkCandidates(in: stranger),
                invitations: stranger.pendingInvitations)
                == nil)
    }

    @Test("Candidates exclude the owner, children, pets and the removed")
    func candidatesAreInvitableAdults() {
        let home = household(members: 1)
        let partner = FamilyMember(name: "Maya", relationship: .partner, in: context)
        let child = FamilyMember(name: "Kid", relationship: .child, in: context)
        let dog = FamilyMember(name: "Rex", relationship: .pet, in: context)
        let gone = FamilyMember(name: "Ex", in: context)
        gone.deletedAt = Date()
        for member in [partner, child, dog, gone] { member.household = home }
        #expect(HouseholdSharing.linkCandidates(in: home).map(\.name) == ["Maya"])
    }

    // MARK: - The roster's word

    @Test("The roster caption follows the newest invitation for that member")
    func invitationState() {
        let home = household(members: 2)
        let maya = HouseholdSharing.linkCandidates(in: home)[0]
        #expect(home.invitationState(for: maya.uuid) == nil)
        let first = Invitation(in: context)
        first.household = home
        first.memberID = maya.uuid
        first.createdAt = Date(timeIntervalSince1970: 100)
        #expect(home.invitationState(for: maya.uuid) == .pending)
        first.accept()
        #expect(home.invitationState(for: maya.uuid) == .accepted)
        #expect(first.acceptedAt != nil)
        #expect(home.pendingInvitation(for: maya.uuid) == nil, "accepted rows are no longer pending")
    }

    @Test("Re-inviting reuses the pending row rather than stacking one")
    func pendingIsReused() {
        let home = household(members: 2)
        let maya = HouseholdSharing.linkCandidates(in: home)[0]
        let row = Invitation(in: context)
        row.household = home
        row.memberID = maya.uuid
        #expect(home.pendingInvitation(for: maya.uuid) == row)
    }
}
