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

    @Test("Household.current creates one and is idempotent")
    func householdSingleton() throws {
        let context = try makeContext()
        let first = Household.current(in: context)
        first.name = "The Onyewuenyis"
        let second = Household.current(in: context)

        #expect(second.name == "The Onyewuenyis")
        #expect(try context.fetch(NSFetchRequest<Household>(entityName: "Household")).count == 1)
    }

    @Test("UserProfile.current creates one and is idempotent")
    func profileSingleton() throws {
        let context = try makeContext()
        let first = UserProfile.current(in: context)
        first.displayName = "Charles Onyewuenyi"
        let second = UserProfile.current(in: context)

        #expect(second.displayName == "Charles Onyewuenyi")
        #expect(try context.fetch(NSFetchRequest<UserProfile>(entityName: "UserProfile")).count == 1)
    }

    // MARK: - Greeting name

    @Test("firstName takes the leading token of the display name")
    func firstNameToken() {
        let ctx = TestStore.makeContext()
        #expect(UserProfile(displayName: "Charles Onyewuenyi", in: ctx).firstName == "Charles")
        #expect(UserProfile(displayName: "Maya", in: ctx).firstName == "Maya")
        #expect(UserProfile(displayName: "  Ezra  Onyewuenyi ", in: ctx).firstName == "Ezra")
    }

    @Test("firstName is nil when there's no name yet")
    func firstNameAbsent() {
        let ctx = TestStore.makeContext()
        #expect(UserProfile(in: ctx).firstName == nil)
        #expect(UserProfile(displayName: "   ", in: ctx).firstName == nil)
    }

    @Test("Greeting personalizes only when a name exists")
    func greetingPersonalization() {
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 9))!
        #expect(Greeting.make(firstName: "Charles", date: morning).primary == "Good morning, Charles")
        #expect(Greeting.make(firstName: nil, date: morning).primary == "Good morning")
        #expect(Greeting.make(firstName: "  ", date: morning).primary == "Good morning")
        // The context lines are the reserved seam — empty until the household fills them.
        #expect(Greeting.make(firstName: "Charles", date: morning).lines.isEmpty)
    }

    @Test("Greeting follows the time of day")
    func greetingTimeOfDay() {
        func at(_ hour: Int) -> String {
            let date = Calendar.current.date(
                from: DateComponents(year: 2026, month: 7, day: 17, hour: hour))!
            return Greeting.make(firstName: nil, date: date).primary
        }
        #expect(at(9) == "Good morning")
        #expect(at(14) == "Good afternoon")
        #expect(at(21) == "Good evening")
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
            title: "Book venue", category: "Work", status: .active, confidence: 0.9,
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
