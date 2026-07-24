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

    /// Marks the invitation accepted. Inert today (only flips status); the real CloudKit
    /// share-acceptance + identity linking lands in Phase 3 (`HouseholdSyncService`).
    func accept() {
        status = .accepted
    }
}
