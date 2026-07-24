//
//  FamilyMember.swift
//  Project-Ezra
//
//  A person in the household. This now includes the current user themself — the
//  "you" member the rest of a shared household sees (see `UserProfile.linkedMemberID`) —
//  as well as everyone you delegate to. A stable identity so two mentions of "Maya"
//  are provably the same person, not two strings that happen to match. `photoData`
//  feeds the avatar pipeline; nil → initials.
//
//  `relationship` and `role` are captured now (mostly for the AI later — "Ezra is a
//  child", "Maya can approve purchases") even though V1 surfaces only relationship.
//  Deletion is a soft-delete (`deletedAt`) so a completed task delegated to someone
//  keeps its attribution after they leave the roster. CloudKit-ready throughout.
//

import CoreData

/// How this person relates to the user — warm, human, and a strong AI signal.
enum FamilyRelationship: String, CaseIterable, Identifiable, Codable {
    case partner, child, parent, pet, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .partner: return "Partner"
        case .child: return "Child"
        case .parent: return "Parent"
        case .pet: return "Pet"
        case .other: return "Other"
        }
    }
}

/// Household authority. Reserved for later (permissions, purchase approval); every
/// member defaults to `.adult` and the field is not surfaced in V1.
enum HouseholdRole: String, CaseIterable, Identifiable, Codable {
    case owner, adult, child, guest
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@objc(FamilyMember)
final class FamilyMember: NSManagedObject {
    @NSManaged var uuid: UUID
    @NSManaged var name: String
    @NSManaged var photoData: Data?
    @NSManaged var photoUpdatedAt: Date?
    @NSManaged private var relationshipRaw: String
    @NSManaged private var roleRaw: String
    /// Soft-delete tombstone. Non-nil = removed from the active roster, but the record
    /// stays so historical task attribution survives. See `Household.activeMembers`.
    @NSManaged var deletedAt: Date?
    @NSManaged var createdAt: Date
    /// Back-reference to the owning household (inverse declared on `Household.members`).
    @NSManaged var household: Household?

    convenience init(
        name: String,
        photoData: Data? = nil,
        relationship: FamilyRelationship = .other,
        role: HouseholdRole = .adult,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "FamilyMember", in: context)!, insertInto: context)
        self.uuid = UUID()
        self.name = name
        self.photoData = photoData
        self.photoUpdatedAt = photoData == nil ? nil : Date()
        self.relationshipRaw = relationship.rawValue
        self.roleRaw = role.rawValue
        self.createdAt = Date()
    }

    var relationship: FamilyRelationship {
        get { FamilyRelationship(rawValue: relationshipRaw) ?? .other }
        set { relationshipRaw = newValue.rawValue }
    }

    var role: HouseholdRole {
        get { HouseholdRole(rawValue: roleRaw) ?? .adult }
        set { roleRaw = newValue.rawValue }
    }

    /// Soft-deleted from the roster (named `isRemoved`, not `isDeleted`, since the latter
    /// is `NSManagedObject`'s own "pending context deletion" flag).
    var isRemoved: Bool { deletedAt != nil }
}
