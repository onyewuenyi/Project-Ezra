//
//  Invitation.swift
//  Project-Ezra
//
//  Reserved. Modeled now — before household sharing exists — precisely so turning on
//  real invitations later needs no schema migration (painful once CloudKit is live).
//  A pending/accepted/expired record tied to the household. No V1 UI.
//

import CoreData

enum InvitationStatus: String, CaseIterable, Identifiable, Codable {
    case pending, accepted, expired
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@objc(Invitation)
final class Invitation: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var email: String?
    @NSManaged private var statusRaw: String
    @NSManaged var createdAt: Date
    @NSManaged var household: Household?
    /// Reserved seams for real cross-account sharing (Phase 3): a stable share token and
    /// the CloudKit `CKShare` URL. Modeled now so the accept-link needs no migration once
    /// CloudKit is live.
    @NSManaged var token: UUID?
    @NSManaged var shareURL: String?
    /// Which roster member this link is FOR — model v4. The owner invites "Maya", a
    /// `FamilyMember` that already exists; when the link is accepted on Maya's phone, her
    /// private `UserProfile` links to THIS member (`linkedMemberID`), so the tasks the
    /// owner already assigned her are hers on arrival and no "which one are you?" screen
    /// is needed.
    @NSManaged var memberID: UUID?
    /// When the link was accepted — the anchor `HouseholdActivation` measures from. Nil
    /// while pending.
    @NSManaged var acceptedAt: Date?

    convenience init(
        email: String? = nil, status: InvitationStatus = .pending,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "Invitation", in: context)!, insertInto: context)
        self.id = UUID()
        self.email = email
        self.statusRaw = status.rawValue
        self.createdAt = Date()
    }

    var status: InvitationStatus {
        get { InvitationStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// Marks the invitation accepted and stamps when. Called on the ACCEPTING device
    /// (`HouseholdSharing.accept`), and since the record rides the household's share the
    /// owner's roster sees the state flip without a message being sent.
    func accept(now: Date = Date()) {
        status = .accepted
        acceptedAt = now
    }
}
