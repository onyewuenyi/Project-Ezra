//
//  HouseholdTests.swift
//  Project-EzraTests
//
//  The household identity layer's pure/persistence contracts: the two singletons are
//  genuinely single, the greeting name resolves, and removing a family member is a
//  soft-delete that preserves historical task attribution.
//

import Foundation
import CoreData
import Testing

@testable import Project_Ezra

@Suite("Household identity")
@MainActor
struct HouseholdTests {

    private func makeContext() throws -> NSManagedObjectContext {
        return TestStore.makeContext()
    }

    // MARK: - Singletons

    @Test("UserProfile.current creates one and is idempotent")
    func profileSingleton() throws {
        let context = try makeContext()
        let first = UserProfile.current(in: context)
        first.displayName = "Charles Onyewuenyi"
        let second = UserProfile.current(in: context)

        #expect(second.displayName == "Charles Onyewuenyi")
        #expect(try context.fetch(NSFetchRequest<UserProfile>(entityName: "UserProfile")).count == 1)
    }

    @Test("Household.current creates one and is idempotent")
    func householdSingleton() throws {
        let context = try makeContext()
        let first = Household.current(in: context)
        first.name = "The Onyewuenyis"
        let second = Household.current(in: context)

        #expect(second.name == "The Onyewuenyis")
        #expect(try context.fetch(NSFetchRequest<Household>(entityName: "Household")).count == 1)
    }


    @Test("firstName is nil when there's no name yet")
    func firstNameAbsent() {
        let ctx = TestStore.makeContext()
        #expect(UserProfile(in: ctx).firstName == nil)
        #expect(UserProfile(displayName: "   ", in: ctx).firstName == nil)
    }



    // MARK: - Soft delete

    @Test("Removing a member is a soft-delete that preserves task attribution")
    func softDeletePreservesAttribution() throws {
        let context = try makeContext()
        let household = Household.current(in: context)
        let maya = FamilyMember(name: "Maya", relationship: .partner)
        maya.household = household
        context.insert(maya)

        let task = TaskItem(
            title: "Book venue", category: "Work", status: .todo, confidence: 0.9,
            reasoning: "", ownerID: maya.uuid)
        context.insert(task)

        maya.deletedAt = Date()

        // Gone from the roster the user sees...
        #expect(maya.isRemoved)
        #expect(household.activeMembers.isEmpty)
        // ...but the record survives, so the old task still resolves its owner.
        #expect(try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember")).count == 1)
        let members = try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))
        #expect(task.ownerDisplayName(among: members) == "Maya")
    }

    @Test("A member defaults to a sane relationship and role")
    func memberDefaults() {
        let member = FamilyMember(name: "Nehemiah")
        #expect(member.relationship == .other)
        #expect(member.role == .adult)
        #expect(!member.isRemoved)
    }
}
