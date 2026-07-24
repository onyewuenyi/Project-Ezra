//
//  FamilyMemberTests.swift
//  Project-EzraTests
//
//  The family roster replaces a bare `ownerName` string with a real reference, so
//  two mentions of "Sarah" resolve to one person rather than two unrelated strings.
//  `ownerDisplayName(among:)` is pure; owner resolution at commit time (match or
//  auto-create) needs a NSManagedObjectContext, mirroring `CommitBlockerResolutionTests`.
//

import Foundation
import CoreData
import Testing

@testable import Project_Ezra

@Suite("TaskItem owner display")
struct FamilyMemberDisplayTests {

    private let me = UUID()

    @Test("ownerDisplayName resolves a set ownerID against the roster")
    func resolvesKnownOwner() {
        let sarah = FamilyMember(name: "Sarah")
        let task = TaskItem(title: "Book venue", status: .active, confidence: 0.9, ownerID: sarah.uuid)
        #expect(task.ownerDisplayName(among: [sarah]) == "Sarah")
        #expect(!task.isMine(currentUserID: me))
    }

    @Test("A nil ownerID is shared/unassigned — not mine; an owner matching me is mine")
    func nilOwnerIsSharedOwnedByMeIsMine() {
        let shared = TaskItem(title: "Pick up dry cleaning", status: .active, confidence: 0.9)
        #expect(shared.ownerDisplayName(among: [FamilyMember(name: "Sarah")]) == nil)
        #expect(!shared.isMine(currentUserID: me))  // nil now means shared, never "you"

        let mine = TaskItem(title: "My errand", status: .active, confidence: 0.9, ownerID: me)
        #expect(mine.isMine(currentUserID: me))
    }

    @Test("An ownerID with no matching roster entry resolves to nil, not a crash")
    func deletedOwnerResolvesNil() {
        let task = TaskItem(title: "Orphaned", status: .active, confidence: 0.9, ownerID: UUID())
        #expect(task.ownerDisplayName(among: []) == nil)
        #expect(!task.isMine(currentUserID: me))  // a stranger's id is not mine
    }
}

@Suite("Commit owner resolution")
@MainActor
struct CommitOwnerResolutionTests {

    private func makeContext() throws -> NSManagedObjectContext {
        return TestStore.makeContext()
    }

    private func draft(_ title: String, ownerName: String? = nil) -> TaskDraft {
        TaskDraft(
            title: title, category: "Work", proposedStatus: .active, confidence: 0.9, autonomy: .silent,
            isJudgmentCall: false, reasoning: "", dueDate: nil, ownerName: ownerName)
    }

    @Test("A new owner name auto-creates a FamilyMember and assigns it")
    func autoCreatesNewPerson() throws {
        let context = try makeContext()
        let brain = AppBrain()
        let created = brain.commit(
            [draft("Book venue for the offsite", ownerName: "Sarah")], rawCapture: "", into: context)

        // A real capture also bootstraps the current user's own creator identity (the
        // "Created" tab keys off it), so assert on the delegate we care about here.
        let members = try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))
        let sarah = try #require(members.first { $0.name == "Sarah" })
        #expect(created[0].ownerID == sarah.uuid)
    }

    @Test("A second mention of the same name (different case) reuses the existing person")
    func reusesExistingPersonCaseInsensitively() throws {
        let context = try makeContext()
        let brain = AppBrain()
        _ = brain.commit([draft("Book venue", ownerName: "Sarah")], rawCapture: "", into: context)
        let created2 = brain.commit(
            [draft("Confirm caterer", ownerName: "sarah")], rawCapture: "", into: context)

        let members = try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))
        let sarahs = members.filter { $0.name.caseInsensitiveCompare("Sarah") == .orderedSame }
        #expect(sarahs.count == 1)  // no duplicate "sarah" person across the two commits
        #expect(created2[0].ownerID == sarahs.first?.uuid)
    }

    @Test("No owner name in the draft → the task is explicitly the current user's own")
    func noOwnerNameBecomesMine() throws {
        let context = try makeContext()
        let brain = AppBrain()
        let created = brain.commit([draft("Pick up dry cleaning")], rawCapture: "", into: context)

        // Commit now stamps unowned, non-pending work with the current user's linked
        // member id (the `nil == you` sentinel is retired), bootstrapping that identity.
        let me = UserProfile.currentMemberID(in: context)
        #expect(created[0].ownerID == me)
        #expect(created[0].isMine(currentUserID: me))
        // The only member created is the current user's own "you" member.
        let members = try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))
        #expect(members.count == 1)
        #expect(members[0].uuid == me)
    }
}
