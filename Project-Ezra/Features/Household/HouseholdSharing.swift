//
//  HouseholdSharing.swift
//  Project-Ezra
//
//  The second-caretaker invite: one link, install, land in a household that already has
//  content. This is the surface `HouseholdSync` was substrate for, built the day the gate
//  flipped (2026-09-12).
//
//  **Mechanism.** The household is a CloudKit share (`CKShare`) whose root is the
//  `Household` record; `NSPersistentCloudKitContainer.share(_:to:)` moves the household and
//  everything reachable from it — members, invitations, and since model v4 the tasks and
//  the trail — into a shared zone of the OWNER's private database. The link is the share's
//  own URL with `publicPermission = .readWrite`: anyone holding it may join, which is the
//  "one link, no account lookup" the plan asks for and the reason the link is never posted
//  anywhere but a message from one caretaker to the other. On the second phone, iOS hands
//  the tapped link to `SceneDelegate` as `CKShare.Metadata`; `accept` imports it into the
//  SHARED store, and when the household arrives (`eventChangedNotification`, an import)
//  `linkIdentity` points this phone's private `UserProfile` at the member the owner
//  already created for them — so the tasks the owner assigned "Maya" are Maya's on arrival.
//
//  **Who am I?** A share URL is one URL for the whole household, so it cannot carry which
//  member the holder is. `Invitation.memberID` (v4) carries that on the owner's side: when
//  exactly ONE invitation is pending, the arriving phone links to its member with no
//  question asked; otherwise `pendingLink` presents the roster and the person picks
//  themself, with "someone else" minting a new member. Never guessed from a name.
//
//  **What is instrumented** (the plan: "every step from invite sent to first action"):
//  `TelemetryInviteStage` — link created / link failed / accepted / accept failed /
//  identity linked. Which household, which person, which name: never (`Telemetry`).
//
//  **The simulator cannot prove this.** No iCloud account, no share. Every method degrades
//  to a `HouseholdSharingError` the UI can print, the pure halves (`linkCandidates`,
//  `autoLinkTarget`) are tested against fixtures, and the live path is a device sitting
//  with two phones — named in `docs/cohort0-checklist.md` §4.
//

import CloudKit
import CoreData
import Foundation
import Observation

enum HouseholdSharingError: LocalizedError {
    case unavailable
    case linkNotReady
    case noSharedStore
    case accountRequired

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Sharing isn't available on this build."
        case .linkNotReady: return "The link isn't ready yet — give it a moment and try again."
        case .noSharedStore: return "This device can't join a household right now."
        case .accountRequired: return "Sign in to iCloud on this device to share your household."
        }
    }
}

/// What the arriving phone shows when it cannot tell which member the person is.
struct PendingIdentityLink: Identifiable {
    let id = UUID()
    let household: Household
    /// Members the person could be — adults who are not the owner and not yet claimed.
    let candidates: [FamilyMember]
    let invitations: [Invitation]
}

@MainActor
@Observable
final class HouseholdSharing {

    static let shared = HouseholdSharing()

    /// Non-nil only when the app runs a CloudKit container (`PersistenceStack.usesCloudKit`).
    private(set) var container: NSPersistentCloudKitContainer?
    private var context: NSManagedObjectContext?
    private var importObserver: NSObjectProtocol?

    /// Set while an accepted share's household has not yet been imported; the import
    /// observer and every foreground retry the link until it lands.
    private(set) var awaitingSharedHousehold = false
    /// Drives the "which one are you?" sheet.
    var pendingLink: PendingIdentityLink?
    /// The last failure, for the UI to print in the person's words.
    var lastError: String?

    private init() {}

    /// Wire to the loaded container. Called once from `Project_EzraApp` after
    /// `loadPersistentStores`; a plain container (tests, no CloudKit) leaves this inert.
    func configure(container: NSPersistentContainer, context: NSManagedObjectContext) {
        self.context = context
        guard let cloud = container as? NSPersistentCloudKitContainer else { return }
        self.container = cloud
        importObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: cloud, queue: .main
        ) { [weak self] notification in
            guard
                let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                event.type == .import, event.endDate != nil, event.succeeded
            else { return }
            MainActor.assumeIsolated { self?.retryPendingLink() }
        }
    }

    // MARK: - Owner: the link

    /// Create (or reuse) the household's share and return its URL, recording an
    /// `Invitation` for `member` so the arriving phone knows who it is.
    func inviteLink(for member: FamilyMember, household: Household) async throws -> URL {
        guard let container, let context, let privateStore = PersistenceStack.privateStore(in: container)
        else { throw HouseholdSharingError.unavailable }

        let share: CKShare
        do {
            if let existing = try container.fetchShares(matching: [household.objectID])[household.objectID] {
                share = existing
            } else {
                let (_, created, _) = try await container.share([household], to: nil)
                share = created
            }
            share[CKShare.SystemFieldKey.title] = (household.name ?? "Our household") as CKRecordValue
            share.publicPermission = .readWrite
            let persisted = try await container.persistUpdatedShare(share, in: privateStore)
            guard let url = persisted.url else { throw HouseholdSharingError.linkNotReady }

            // The record the arriving phone reads. Reused when this member was already
            // invited, so re-sending a link does not stack pending rows.
            let invitation =
                household.pendingInvitation(for: member.uuid)
                ?? {
                    let fresh = Invitation(in: context)
                    fresh.household = household
                    fresh.memberID = member.uuid
                    fresh.token = UUID()
                    return fresh
                }()
            invitation.shareURL = url.absoluteString
            // The link itself was already minted and is returned below regardless — a
            // dropped save here only risks the invitation record it rides on, which the
            // next successful save on this context carries. Still worth a word: the
            // person is about to send a link that names them in a message.
            if !context.saveChanges() {
                lastError = "The link works, but saving the invite locally didn't — try reopening this sheet."
            }
            Telemetry.log(.invite(stage: .linkCreated))
            // The household is about to be shared: the one moment the digest asks.
            await WeeklyDigestScheduler.shared.requestPermissionIfNeeded()
            return url
        } catch {
            Telemetry.log(.invite(stage: .linkFailed))
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    // MARK: - Invitee: accept and link

    /// Accept a tapped share link. The household's records arrive asynchronously; the
    /// identity link runs when they do.
    func accept(_ metadata: CKShare.Metadata) async {
        guard let container, let sharedStore = PersistenceStack.sharedStore(in: container) else {
            lastError = HouseholdSharingError.noSharedStore.errorDescription
            Telemetry.log(.invite(stage: .acceptFailed))
            return
        }
        do {
            _ = try await container.acceptShareInvitations(from: [metadata], into: sharedStore)
            awaitingSharedHousehold = true
            Telemetry.log(.invite(stage: .accepted))
            retryPendingLink()
        } catch {
            lastError = error.localizedDescription
            Telemetry.log(.invite(stage: .acceptFailed))
        }
    }

    /// Try to resolve who this phone is inside the shared household. Safe to call often:
    /// it does nothing until a shared household exists, and nothing once linked.
    func retryPendingLink() {
        guard awaitingSharedHousehold, let container, let context,
            let sharedStore = PersistenceStack.sharedStore(in: container),
            let household = Self.sharedHousehold(in: context, store: sharedStore)
        else { return }
        let profile = UserProfile.current(in: context)
        let invitations = household.pendingInvitations
        let candidates = Self.linkCandidates(in: household)
        if let target = Self.autoLinkTarget(candidates: candidates, invitations: invitations) {
            linkIdentity(profile: profile, to: target.member, invitation: target.invitation)
        } else {
            pendingLink = PendingIdentityLink(
                household: household, candidates: candidates, invitations: invitations)
        }
    }

    /// The person chose a member (or asked for a new one). Called by the chooser sheet.
    func resolvePendingLink(as member: FamilyMember?, named name: String?) {
        guard let pending = pendingLink, let context else { return }
        let profile = UserProfile.current(in: context)
        let target: FamilyMember
        if let member {
            target = member
        } else {
            let fresh = FamilyMember(name: name ?? profile.displayName ?? "Me", in: context)
            fresh.household = pending.household
            target = fresh
        }
        let invitation = pending.invitations.first { $0.memberID == target.uuid }
        linkIdentity(profile: profile, to: target, invitation: invitation)
    }

    private func linkIdentity(profile: UserProfile, to member: FamilyMember, invitation: Invitation?) {
        guard let context else { return }
        profile.linkedMemberID = member.uuid
        // The person's own name and photo win over what the owner typed for them — but
        // only where the person HAS one; an empty profile keeps the owner's "Maya".
        profile.syncIdentity(to: member)
        invitation?.accept()
        if !context.saveChanges() {
            lastError = "You're linked, but saving it locally didn't land — reopen the app to confirm."
        }
        awaitingSharedHousehold = false
        pendingLink = nil
        Telemetry.log(.invite(stage: .identityLinked))
        // Joined a shared household: the one moment the digest asks on this side.
        Task { await WeeklyDigestScheduler.shared.requestPermissionIfNeeded() }
    }

    // MARK: - Pure halves

    /// The household that lives in the shared store, if one has been imported.
    static func sharedHousehold(in context: NSManagedObjectContext, store: NSPersistentStore) -> Household? {
        let request = NSFetchRequest<Household>(entityName: "Household")
        request.affectedStores = [store]
        return (try? context.fetch(request))?.min { $0.createdAt < $1.createdAt }
    }

    /// Who the arriving person could be: live adult members who are not the owner.
    static func linkCandidates(in household: Household) -> [FamilyMember] {
        household.activeMembers
            .filter { $0.role != .owner && $0.relationship != .child && $0.relationship != .pet }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Link without asking ONLY when exactly one invitation is pending and it names a
    /// candidate. Two pending invitations is two possible people, and a guess there
    /// would hand one caretaker the other's tasks.
    static func autoLinkTarget(
        candidates: [FamilyMember], invitations: [Invitation]
    ) -> (member: FamilyMember, invitation: Invitation)? {
        guard invitations.count == 1, let invitation = invitations.first,
            let member = candidates.first(where: { $0.uuid == invitation.memberID })
        else { return nil }
        return (member, invitation)
    }
}

extension Household {
    var invitationsArray: [Invitation] { (invitations as? Set<Invitation>).map(Array.init) ?? [] }

    var pendingInvitations: [Invitation] {
        invitationsArray.filter { $0.status == .pending }.sorted { $0.createdAt < $1.createdAt }
    }

    func pendingInvitation(for memberID: UUID) -> Invitation? {
        pendingInvitations.first { $0.memberID == memberID }
    }

    /// The invitation state of one member, for the roster row's caption.
    func invitationState(for memberID: UUID) -> InvitationStatus? {
        invitationsArray.filter { $0.memberID == memberID }
            .sorted { $0.createdAt > $1.createdAt }.first?.status
    }
}
