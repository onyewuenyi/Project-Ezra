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
    case offline
    case storageFull

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Sharing isn't available on this build."
        case .linkNotReady: return "The link isn't ready yet — give it a moment and try again."
        case .noSharedStore: return "This device can't join a household right now."
        case .accountRequired: return "Sign in to iCloud on this device to share your household."
        case .offline: return "No connection — the link needs the network for a moment. Try again."
        case .storageFull: return "There's no iCloud storage left to share the household with."
        }
    }

    /// The sharing failure in the PRODUCT's words, or nil when this is not one we can
    /// name (2026-09-18). Every sharing path rethrew the raw framework error, so the
    /// likeliest real failure — nobody is signed into iCloud — reached the invite sheet
    /// as "This operation couldn't be completed. (CKErrorDomain error 9.)": unactionable,
    /// and a vendor string on a customer screen. `.accountRequired` had the right
    /// sentence and nothing ever threw it. Unknown codes still surface as they were, so
    /// a failure we have not met is never disguised as one we have.
    static func naming(_ error: Error) -> HouseholdSharingError? {
        guard let ck = error as? CKError else { return nil }
        switch ck.code {
        case .notAuthenticated, .managedAccountRestricted, .permissionFailure: return .accountRequired
        case .networkUnavailable, .networkFailure, .serviceUnavailable: return .offline
        case .quotaExceeded: return .storageFull
        default: return nil
        }
    }
}

/// What the arriving phone shows when it cannot tell which member the person is.
struct PendingIdentityLink: Identifiable {
    var id = UUID()
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

    // "Awaiting a link" is DERIVED, never held (2026-09-30): a shared household exists on
    // this phone and the profile's member is not in it. A flag set at accept lived in
    // memory only, so a phone killed between the accept and the household's arrival —
    // a large household takes a while — never linked at all, and the person sat in the
    // household as nobody. The stores remember what the flag forgot.
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
            context.saveChanges()
            lastError = nil
            Telemetry.log(.invite(stage: .linkCreated))
            // The household is about to be shared: the one moment the digest asks.
            await WeeklyDigestScheduler.shared.requestPermissionIfNeeded()
            return url
        } catch {
            Telemetry.log(.invite(stage: .linkFailed))
            // Named in the product's words where we can name it; the raw error only
            // where we genuinely have not met the failure before.
            let named = HouseholdSharingError.naming(error) ?? error
            lastError = (named as? LocalizedError)?.errorDescription ?? named.localizedDescription
            throw named
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
            lastError = nil
            Telemetry.log(.invite(stage: .accepted))
            retryPendingLink()
        } catch {
            // The ARRIVING phone's half of the same rule: the person who just tapped a
            // link is the likeliest of all to have no iCloud account on this device.
            let named = HouseholdSharingError.naming(error) ?? error
            lastError = (named as? LocalizedError)?.errorDescription ?? named.localizedDescription
            Telemetry.log(.invite(stage: .acceptFailed))
        }
    }

    /// Try to resolve who this phone is inside the shared household. Safe to call often:
    /// it does nothing until a shared household exists, and nothing once linked.
    func retryPendingLink() {
        guard let container, let context,
            let sharedStore = PersistenceStack.sharedStore(in: container),
            let household = Self.sharedHousehold(in: context, store: sharedStore)
        else { return }
        let profile = UserProfile.current(in: context)
        guard Self.needsLink(linkedMemberID: profile.linkedMemberID, in: household) else {
            pendingLink = nil
            return
        }
        let invitations = household.pendingInvitations
        let candidates = Self.linkCandidates(in: household)
        if let target = Self.autoLinkTarget(candidates: candidates, invitations: invitations) {
            linkIdentity(profile: profile, to: target.member, invitation: target.invitation)
        } else if Self.shouldAsk(candidates: candidates) {
            // Kept, not rebuilt: a fresh id on every import re-presented the sheet under
            // the person's thumb. Same id, the latest roster.
            pendingLink = PendingIdentityLink(
                id: pendingLink?.id ?? UUID(),
                household: household, candidates: candidates, invitations: invitations)
        }
        // No candidates yet: the household's record can land before its members and its
        // invitation do. Asking now would offer only "someone else" and mint a duplicate
        // of the member the owner already made — so wait for the next import.
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
        context.saveChanges()
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

    /// Whether this phone still has to say who it is in `household`: true until the
    /// profile's member is one of that household's live members.
    static func needsLink(linkedMemberID: UUID?, in household: Household) -> Bool {
        guard let id = linkedMemberID else { return true }
        return !household.activeMembers.contains { $0.uuid == id }
    }

    /// Ask "which one are you?" only when there is someone to choose.
    static func shouldAsk(candidates: [FamilyMember]) -> Bool { !candidates.isEmpty }

    /// Whether this phone may hand out links to `household`. Only the owner's phone can:
    /// the household lives in its PRIVATE store. A participant holds it in the shared
    /// mirror, where the share's permissions are not theirs to change — the attempt
    /// failed with a raw CloudKit error.
    static func canShare(_ household: Household) -> Bool {
        !PersistenceStack.isShared(household.objectID.persistentStore)
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
