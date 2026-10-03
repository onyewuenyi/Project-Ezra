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

    @Test("The gate is OPEN (2026-09-12), and it opened as one act: gate + container + entitlement")
    func gateIsOpenAsOneAct() throws {
        // Flipping this was the one-way door: it turned on the inferred ownership rungs,
        // the day answer's ownership filter and the publish boundary together, AND it
        // closed the wipe-on-mismatch schema escape hatch (`SchemaFreezeTests`). The
        // three halves must agree — a live gate over a nil container would send tasks
        // to people with no device in the graph, and a container the entitlement does
        // not name fails at the first sync with nothing wrong in the code.
        #expect(HouseholdSync.isLive == true)
        let container = try #require(PersistenceStack.cloudKitContainerID)
        let entitlements = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra/Project_Ezra.entitlements")
        let plist = try String(contentsOf: entitlements, encoding: .utf8)
        #expect(plist.contains("<string>\(container)</string>"), "the entitlement does not name \(container)")
        #expect(plist.contains("<string>CloudKit</string>"))
    }
}
