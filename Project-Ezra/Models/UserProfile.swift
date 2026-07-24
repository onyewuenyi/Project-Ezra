//
//  UserProfile.swift
//  Project-Ezra
//
//  The current user's identity — "you". Deliberately separate from `Household`: it
//  lives in the *private* CloudKit database (yours alone), while the household and its
//  members live in the *shared* one. Keeping them apart avoids a cross-database
//  relationship that CloudKit can't express — instead `linkedMemberID` points at the
//  shared "you" `FamilyMember` by uuid.
//
//  `displayName` (not `userName`) is the evolvable name field; nil reads as "You".
//  CloudKit-ready: UUID key, no unique constraint, optional/defaulted properties.
//

import CoreData

@objc(UserProfile)
final class UserProfile: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var displayName: String?
    @NSManaged var photoData: Data?
    @NSManaged var photoUpdatedAt: Date?
    @NSManaged var createdAt: Date
    /// The `FamilyMember.uuid` that represents "you" in the shared household graph.
    /// The current user is a real roster member so others can see your name/avatar/load;
    /// this private profile links to it. `nil` until `bootstrapIdentity` runs. This is
    /// the id `TaskItem.isMine(currentUserID:)` compares against and that `commit`/`claim`
    /// stamp on your tasks — replacing the retired `ownerID == nil` "me" sentinel.
    @NSManaged var linkedMemberID: UUID?

    convenience init(
        displayName: String? = nil, photoData: Data? = nil,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "UserProfile", in: context)!, insertInto: context)
        self.id = UUID()
        self.displayName = displayName
        self.photoData = photoData
        self.photoUpdatedAt = photoData == nil ? nil : Date()
        self.createdAt = Date()
    }

    /// First token of the display name, for the greeting ("Charles Onyewuenyi" → "Charles").
    var firstName: String? {
        displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
    }

    /// The single profile for this install (fetch-first-or-create).
    static func current(in context: NSManagedObjectContext) -> UserProfile {
        let request = NSFetchRequest<UserProfile>(entityName: "UserProfile")
        request.fetchLimit = 1
        if let existing = try? context.fetch(request).first { return existing }
        return UserProfile(in: context)
    }

    /// Ensures the current user is represented by a real `FamilyMember` (`role = .owner`)
    /// in the household — the "you" identity the rest of a shared household can see — and
    /// links this private profile to it via `linkedMemberID`. Idempotent: reuses the link
    /// when it still points at a live member, so it's safe to call on every launch.
    @discardableResult
    static func bootstrapIdentity(in context: NSManagedObjectContext) -> FamilyMember {
        let household = Household.current(in: context)
        let profile = current(in: context)

        if let id = profile.linkedMemberID,
            let existing = household.activeMembers.first(where: { $0.uuid == id })
        {
            return existing
        }

        let me = FamilyMember(name: profile.displayName ?? "You", role: .owner, in: context)
        me.household = household
        profile.linkedMemberID = me.uuid
        try? context.save()
        return me
    }

    /// The current user's `FamilyMember.uuid` — the owner id stamped on "my" tasks and the
    /// identity `isMine(currentUserID:)` compares against. Bootstraps if needed.
    static func currentMemberID(in context: NSManagedObjectContext) -> UUID {
        bootstrapIdentity(in: context).uuid
    }

    /// Mirror this private profile's name/photo onto the shared you-member so the rest of
    /// the household sees current values. Call after editing your name/photo.
    func syncIdentity(to member: FamilyMember) {
        if let displayName, !displayName.isEmpty { member.name = displayName }
        if photoData != member.photoData {
            member.photoData = photoData
            member.photoUpdatedAt = photoData == nil ? nil : Date()
        }
    }
}
