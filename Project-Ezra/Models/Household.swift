//
//  Household.swift
//  Project-Ezra
//
//  The root aggregate — the collaboration boundary a family shares. Not a profile
//  screen's backing store: this is the object future features (shared tasks, AI
//  memory, calendars, automations, invitations) hang off of. V1 uses only `name`
//  and `photoData`; the relationships below are the reserved seams for that growth.
//
//  CloudKit-ready by construction: a UUID key, no unique constraint, every attribute
//  optional or defaulted, and every relationship optional with an inverse — so the
//  Phase 3 CKShare zone sharing hangs off this root with no schema change.
//

import CoreData

@objc(Household)
final class Household: NSManagedObject {
    @NSManaged var id: UUID
    /// Optional family/group name, e.g. "The Onyewuenyis". Nil is a valid, quiet state.
    @NSManaged var name: String?
    /// The family photo shown in the household header. Nil falls back to family initials.
    @NSManaged var photoData: Data?
    @NSManaged var photoUpdatedAt: Date?
    @NSManaged var createdAt: Date

    // The aggregate's contents. All optional for CloudKit; cascade so tearing down a
    // household takes its owned records with it. Only `members` has V1 UI.
    @NSManaged var members: NSSet?
    @NSManaged var settings: HouseholdSettings?
    @NSManaged var aiContext: HouseholdAIContext?
    @NSManaged var memories: NSSet?
    @NSManaged var invitations: NSSet?

    convenience init(
        name: String? = nil, photoData: Data? = nil,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "Household", in: context)!, insertInto: context)
        self.id = UUID()
        self.name = name
        self.photoData = photoData
        self.photoUpdatedAt = photoData == nil ? nil : Date()
        self.createdAt = Date()
    }

    /// The members relationship as a typed array (Core Data stores it as an untyped `NSSet`).
    var membersArray: [FamilyMember] { (members as? Set<FamilyMember>).map(Array.init) ?? [] }

    /// Live, non-deleted members — the roster the UI shows and counts. Since the current
    /// user is now a real member too (see `UserProfile.linkedMemberID`), this includes
    /// "you"; use `otherMembers(excluding:)` for the people you delegate to.
    var activeMembers: [FamilyMember] {
        membersArray.filter { !$0.isRemoved }
    }

    /// Live members excluding the current user's linked member — the delegatable roster.
    /// Pass `UserProfile.linkedMemberID`. Every place that iterates members for "other
    /// people" (roster list, `.you` vs `.member` load buckets, owner chips) uses this so
    /// "you" is never double-counted or shown as someone to delegate to.
    func otherMembers(excluding currentUserID: UUID?) -> [FamilyMember] {
        activeMembers.filter { $0.uuid != currentUserID }
    }

    /// The single household for this install (fetch-first-or-create). One household
    /// per device today; when CloudKit sharing lands this becomes the shared record.
    static func current(in context: NSManagedObjectContext) -> Household {
        let request = NSFetchRequest<Household>(entityName: "Household")
        request.fetchLimit = 1
        if let existing = try? context.fetch(request).first { return existing }
        return Household(in: context)
    }
}
