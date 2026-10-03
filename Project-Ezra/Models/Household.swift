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
    /// Model v4 (2026-09-12): the tasks and the trail, so the whole plan travels with the
    /// share. Inverses of `TaskItem.household` / `ChangeLogEntry.household`; nothing reads
    /// them as collections (the lists still fetch), they exist so the graph is CONNECTED.
    @NSManaged var tasks: NSSet?
    @NSManaged var changes: NSSet?

    convenience init(
        name: String? = nil, photoData: Data? = nil,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "Household", in: context)!, insertInto: context)
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

    /// The household this install works in (fetch-first-or-create).
    ///
    /// **Since sharing went live there can be TWO** (2026-09-12): the one this device
    /// minted at first launch (private store) and one someone else owns and this person
    /// accepted an invitation into (shared store). `existing(in:)` picks the one with the
    /// most live members, oldest first on a tie — the shared household always has at least
    /// the owner and this person, the private leftover has exactly one, so the invited
    /// caretaker lands in the household they were invited to without a "which one?" step,
    /// and the owner (who only ever has one) is unaffected. A person who is BOTH an owner
    /// with a partner AND an invitee elsewhere is not a household shape this product
    /// models; the larger roster wins and is stated here rather than left to fetch order.
    static func current(in context: NSManagedObjectContext) -> Household {
        existing(in: context) ?? Household(in: context)
    }

    /// The working household, or nil when this install has none yet. Never creates —
    /// `HouseholdStoreAffinity` reads it from inside a save, where inserting is not allowed.
    ///
    /// **A household someone shared with this phone wins outright (2026-09-30).** A
    /// participant's install bootstrapped a household of its own on first launch, and the
    /// largest-roster rule alone let that one beat the household they were invited into —
    /// two members each was enough — after which every new task landed in the private
    /// store and the person never saw the shared plan. Joining IS choosing.
    static func existing(in context: NSManagedObjectContext) -> Household? {
        let request = NSFetchRequest<Household>(entityName: "Household")
        guard let all = try? context.fetch(request) else { return nil }
        return preferred(among: all) { PersistenceStack.isShared($0.objectID.persistentStore) }
    }

    /// This install's OWN household — the working one, never one someone shared with it.
    /// Where a fresh identity is minted: a participant who has not yet said which member
    /// they are must not appear in another person's household as a stranger called "You".
    static func own(in context: NSManagedObjectContext) -> Household {
        let request = NSFetchRequest<Household>(entityName: "Household")
        let mine = ((try? context.fetch(request)) ?? [])
            .filter { !PersistenceStack.isShared($0.objectID.persistentStore) }
        return preferred(among: mine, isShared: { _ in false }) ?? Household(in: context)
    }

    /// The choice, as a pure function: a shared household first, then the larger roster,
    /// then the older.
    static func preferred(among all: [Household], isShared: (Household) -> Bool) -> Household? {
        let shared = all.filter(isShared)
        let pool = shared.isEmpty ? all : shared
        return pool.min { lhs, rhs in
            let l = lhs.activeMembers.count, r = rhs.activeMembers.count
            if l != r { return l > r }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
