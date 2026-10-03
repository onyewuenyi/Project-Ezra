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

    // MARK: - The participant's phone (2026-09-30)

    @Test("A household someone shared with this phone wins over a larger one of its own")
    func sharedHouseholdWinsOutright() throws {
        let mine = household(members: 4, createdAt: Date(timeIntervalSince1970: 1))
        let joined = household(members: 2)
        let chosen = try #require(Household.preferred(among: [mine, joined], isShared: { $0 == joined }))
        #expect(chosen == joined, "joining IS choosing — the roster count must not undo it")
    }

    @Test("With nothing shared, the larger roster still wins, then the older")
    func largestRosterWithoutAShare() throws {
        let small = household(members: 1, createdAt: Date(timeIntervalSince1970: 1))
        let large = household(members: 3)
        let older = household(members: 3, createdAt: Date(timeIntervalSince1970: 2))
        let chosen = try #require(
            Household.preferred(among: [small, large, older], isShared: { _ in false }))
        #expect(chosen == older)
    }

    @Test("Only the shared mirror's file counts as shared, and an unsaved object is never shared")
    func sharedIsReadFromTheStoreFile() throws {
        #expect(!PersistenceStack.isShared(nil))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistenceStack.model)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let privateStore = try coordinator.addPersistentStore(
            type: .inMemory, at: dir.appendingPathComponent(PersistenceStack.storeFileName))
        let sharedStore = try coordinator.addPersistentStore(
            type: .inMemory, at: dir.appendingPathComponent(PersistenceStack.sharedStoreFileName))
        #expect(!PersistenceStack.isShared(privateStore))
        #expect(PersistenceStack.isShared(sharedStore))

        // The clear's scope: everything but the mirror — and "all of them" when there is
        // no mirror to protect, so a phone that never joined anything is unchanged.
        #expect(DataReset.clearableStores([privateStore, sharedStore]) == [privateStore])
        #expect(DataReset.clearableStores([privateStore]) == nil)
    }

    @Test("A link is honoured in ANY household — launch never mints a second 'you' over it")
    func bootstrapKeepsACrossHouseholdLink() throws {
        let profile = UserProfile.current(in: context)
        let original = profile.linkedMemberID
        defer { profile.linkedMemberID = original }

        // A one-member household that is NOT the working one: before the fix, launch
        // looked only in the working household, missed this member and overwrote the link.
        let elsewhere = household(members: 2)
        let me = try #require(HouseholdSharing.linkCandidates(in: elsewhere).first)
        profile.linkedMemberID = me.uuid
        let resolved = UserProfile.bootstrapIdentity(in: context)
        #expect(resolved == me)
        #expect(profile.linkedMemberID == me.uuid)
    }

    @Test("Awaiting a link is derived from the stores, so a kill between accept and import loses nothing")
    func needsLinkIsDerived() throws {
        let joined = household(members: 2)
        let member = try #require(HouseholdSharing.linkCandidates(in: joined).first)
        let stranger = household(members: 1).activeMembers[0]
        #expect(HouseholdSharing.needsLink(linkedMemberID: nil, in: joined))
        #expect(HouseholdSharing.needsLink(linkedMemberID: stranger.uuid, in: joined))
        #expect(!HouseholdSharing.needsLink(linkedMemberID: member.uuid, in: joined))
    }

    @Test("Ezra asks 'which one are you?' only when there is someone to choose")
    func noCandidatesNoQuestion() {
        #expect(!HouseholdSharing.shouldAsk(candidates: []))
        let home = household(members: 2)
        #expect(HouseholdSharing.shouldAsk(candidates: HouseholdSharing.linkCandidates(in: home)))
    }

    @Test("A household outside the shared mirror can hand out links")
    func ownersPhoneCanShare() {
        // The scratch store is not the shared mirror, so every fixture here is the
        // owner's case; the participant's is `sharedIsReadFromTheStoreFile`'s file rule.
        #expect(HouseholdSharing.canShare(household(members: 2)))
    }

    @Test("Every profile read uses one order, so the model and every screen name the same 'you'")
    func profileOrderIsOneOrder() throws {
        let order = UserProfile.chosenOrder
        #expect(order.first?.key == "createdAt")
        #expect(order.first?.ascending == true)
        let request = NSFetchRequest<UserProfile>(entityName: "UserProfile")
        request.sortDescriptors = order
        let all = try context.fetch(request)
        let current = UserProfile.current(in: context)
        #expect(all.first == current)
    }

    @Test("No view reads 'you' from an unsorted profile fetch")
    func everyProfileFetchIsOrdered() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        let files =
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // One declaration per line even when swift-format wraps it after the colon
            // (`…profilesResults:` / `FetchedResults<UserProfile>`, 2026-10-03).
            let text = raw.replacing(/:\n\s+/, with: ": ")
            for line in text.split(separator: "\n")
            where line.contains("FetchedResults<UserProfile>") && !line.contains("UserProfile.chosenOrder") {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
