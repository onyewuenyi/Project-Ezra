//
//  SyncGateTests.swift
//  Project-EzraTests
//
//  What actually happens the day `HouseholdSync.isLive` flips.
//
//  The Phase 5 promise is "a surface to build, not a migration to survive" — the data
//  model has been carrying multiplayer as substrate all along, so sync should be an
//  addition rather than a rewrite. That promise is only worth anything if the substrate
//  has been RUN in the live configuration, and until now most of it could not be:
//  `OwnerProposer` took `syncIsLive:` as a parameter and is proven at `true` by a dozen
//  tests, but the Brief's ownership filter and the assignment publish boundary both read
//  the compile-time constant directly. Flipping it would have shipped their first ever
//  execution to real users on the same day sync did.
//
//  These tests exercise the `true` side. They do not make sync work — nothing here
//  provisions a CloudKit container, and flipping the constant is a one-way door that
//  also closes the clean-break schema escape hatch (see `Project_EzraApp`). They make
//  the flip a tested change instead of a hopeful one.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Sync gate (what happens when HouseholdSync.isLive flips)")
struct SyncGateTests {

    private func context() -> NSManagedObjectContext { PersistenceStack.scratch }

    /// A member who is not the current user.
    private func otherMember(_ name: String, in context: NSManagedObjectContext) -> FamilyMember {
        let member = FamilyMember(name: name, in: context)
        member.household = Household.current(in: context)
        return member
    }

    // MARK: - The Brief's ownership filter

    /// The two owners the filter has to tell apart, plus their tasks.
    private func ownedPair(
        in context: NSManagedObjectContext
    )
        -> (me: UUID?, mine: TaskItem, theirs: TaskItem)
    {
        let me = UserProfile.bootstrapIdentity(in: context)
        let other = otherMember("Maya", in: context)
        let mine = TaskItem(title: "Renew my passport", in: context)
        mine.ownerID = me.uuid
        let theirs = TaskItem(title: "Sort the insurance", in: context)
        theirs.ownerID = other.uuid
        context.saveChanges()
        return (me.uuid, mine, theirs)
    }

    @Test("Before sync, the Brief keeps every task regardless of nominal owner")
    func beforeSyncNothingIsFilteredOut() {
        let context = context()
        let (me, mine, theirs) = ownedPair(in: context)

        // The pre-sync guarantee: work owned by someone with no device in the graph must
        // NOT leave your briefing, or it lands nowhere anyone can act on it.
        let candidates = BriefSequenceModel.candidates(
            from: [mine, theirs], currentUserID: me, syncIsLive: false, now: Date())
        #expect(Set(candidates.compactMap(\.uuid)) == Set([mine, theirs].compactMap(\.uuid)))
    }

    @Test("Once sync is live, the Brief composes only MY day")
    func afterSyncOthersWorkLeavesTheBriefing() {
        let context = context()
        let (me, mine, theirs) = ownedPair(in: context)

        // The Brief is *my* execution; coordination is a different surface. This is the
        // behaviour that has been waiting behind the gate, running for the first time.
        let candidates = BriefSequenceModel.candidates(
            from: [mine, theirs], currentUserID: me, syncIsLive: true, now: Date())
        #expect(candidates.compactMap(\.uuid) == [mine].compactMap(\.uuid))
    }

    // MARK: - The publish boundary

    @Test("Before sync, nothing is ever published — even a task owned by someone else")
    func beforeSyncNothingPublishes() {
        let context = context()
        _ = UserProfile.bootstrapIdentity(in: context)
        let other = otherMember("Maya", in: context)
        let handed = TaskItem(title: "Ask Maya to sort the insurance", in: context)
        handed.ownerID = other.uuid
        context.saveChanges()

        let brain = AppBrain()
        #expect(brain.handedOffAssignments([handed], in: context, syncIsLive: false).isEmpty)
    }

    @Test("Once sync is live, exactly the tasks owned by someone ELSE are published")
    func afterSyncOnlyHandOffsPublish() {
        let context = context()
        let me = UserProfile.bootstrapIdentity(in: context)
        let other = otherMember("Maya", in: context)

        let handed = TaskItem(title: "Ask Maya to sort the insurance", in: context)
        handed.ownerID = other.uuid
        let mine = TaskItem(title: "Renew my passport", in: context)
        mine.ownerID = me.uuid
        // "Unowned" is a human hand-back and exactly `ownerID == nil`. It is nobody's to
        // be notified about, so it must not publish — and it is the case most likely to
        // slip through a naive `ownerID != me` check.
        let unowned = TaskItem(title: "Someone should book the plumber", in: context)
        unowned.ownerID = nil
        context.saveChanges()

        let brain = AppBrain()
        let published = brain.handedOffAssignments(
            [handed, mine, unowned], in: context, syncIsLive: true)

        // Publishing the wrong SET is a message sent to the wrong person — a worse
        // failure than a notification bug, and the reason this half is tested before
        // delivery exists at all.
        #expect(published.map(\.uuid) == [handed.uuid])
    }

    // MARK: - The gate itself

    @Test("The gate is still closed, and closing it is a deliberate act")
    func gateRemainsClosed() {
        // Flipping this is a one-way door: it turns on the inferred ownership rungs, the
        // Brief's ownership filter and the publish boundary together, AND it closes the
        // wipe-on-mismatch schema escape hatch, because a deployed CloudKit schema is
        // additive-only with no server-side reset. It ships with the iCloud entitlement
        // and `PersistenceStack.cloudKitContainerID`, never on its own.
        #expect(HouseholdSync.isLive == false)
        #expect(PersistenceStack.cloudKitContainerID == nil)
    }
}
