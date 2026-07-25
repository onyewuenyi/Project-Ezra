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
        let task = TaskItem(title: "Book venue", status: .todo, confidence: 0.9, ownerID: sarah.uuid)
        #expect(task.ownerDisplayName(among: [sarah]) == "Sarah")
        #expect(!task.isMine(currentUserID: me))
    }

    @Test("A nil ownerID is shared/unassigned — not mine; an owner matching me is mine")
    func nilOwnerIsSharedOwnedByMeIsMine() {
        let shared = TaskItem(title: "Pick up dry cleaning", status: .todo, confidence: 0.9)
        #expect(shared.ownerDisplayName(among: [FamilyMember(name: "Sarah")]) == nil)
        #expect(!shared.isMine(currentUserID: me))  // nil now means shared, never "you"

        let mine = TaskItem(title: "My errand", status: .todo, confidence: 0.9, ownerID: me)
        #expect(mine.isMine(currentUserID: me))
    }

    @Test("An ownerID with no matching roster entry resolves to nil, not a crash")
    func deletedOwnerResolvesNil() {
        let task = TaskItem(title: "Orphaned", status: .todo, confidence: 0.9, ownerID: UUID())
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
            title: title, category: "Work", confidence: 0.9, autonomy: .silent,
            isJudgmentCall: false, reasoning: "", dueDate: nil, ownerName: ownerName)
    }

    @Test("An UNMATCHED owner name creates no FamilyMember — the task stays shared")
    func unmatchedNameMintsNobody() throws {
        let context = try makeContext()
        let brain = AppBrain()
        let created = brain.commit(
            [draft("Book venue for the offsite", ownerName: "Sarah")], rawCapture: "", into: context)

        // Minting a person from a misheard name used to look like the same mechanical
        // filing philosophy applied to categorization — but a category is a label and a
        // person is not. A phantom becomes an EXISTING member: it accrues category
        // ownership, feeds the affinity denominator, and becomes proposable. So an
        // unresolved name leaves the task shared and "Add person…" stays the human step.
        let members = try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))
        #expect(!members.contains { $0.name == "Sarah" })
        #expect(created[0].ownerID == nil)
    }

    @Test("A name matching an EXISTING person resolves case-insensitively")
    func resolvesExistingPersonCaseInsensitively() throws {
        let context = try makeContext()
        let sarah = FamilyMember(name: "Sarah", in: context)
        context.insert(sarah)
        let brain = AppBrain()
        let created = brain.commit(
            [draft("Confirm caterer", ownerName: "sarah")], rawCapture: "", into: context)

        let members = try context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))
        let sarahs = members.filter { $0.name.caseInsensitiveCompare("Sarah") == .orderedSame }
        #expect(sarahs.count == 1)  // still one person; the commit added nobody
        #expect(created[0].ownerID == sarah.uuid)
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
