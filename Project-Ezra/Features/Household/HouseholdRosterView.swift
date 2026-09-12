//
//  HouseholdRosterView.swift
//  Project-Ezra
//
//  The identity/roster editor — the "Manage" screen behind the Household surface's
//  mission control. This is where the household is a *place*: a family photo, an
//  optional family name, and the people in it. Everything here is identity; the
//  reserved models behind it (settings, AI context, memory, invitations)
//  deliberately have no UI yet, because the best settings screens are almost empty.
//
//  Removing someone is a soft-delete, so a task they once owned keeps its
//  attribution. Reached from the Tasks "…" menu; carries no NavigationStack of
//  its own (the presenting sheet owns navigation).
//

import PhotosUI
import CoreData
import SwiftUI

struct HouseholdRosterView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: []) private var householdsResults: FetchedResults<Household>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    private var households: [Household] { Array(householdsResults) }
    private var profiles: [UserProfile] { Array(profilesResults) }

    var body: some View {
        // Both singletons are created on open, so the editor always has something to
        // bind to (a fresh install has neither until now).
        Group {
            if let household = households.first, let profile = profiles.first {
                HouseholdRosterContent(household: household, profile: profile)
            } else {
                Color.clear
            }
        }
        .task {
            // Ensures Household + UserProfile + the linked "you" household member all
            // exist, so the editor always has the full identity to bind to.
            UserProfile.bootstrapIdentity(in: context)
            context.saveChanges()
        }
    }
}

private struct HouseholdRosterContent: View {
    @ObservedObject var household: Household
    @ObservedObject var profile: UserProfile

    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: []) private var allMembersResults: FetchedResults<FamilyMember>
    private var allMembers: [FamilyMember] { Array(allMembersResults) }
    @State private var showAddPerson = false
    @State private var newPersonName = ""
    /// The member an invite link is being made for (drives `InviteLinkSheet`).
    @State private var inviting: FamilyMember?

    /// Live roster only, excluding the current user's own linked member (shown as its
    /// own `youRow`) — soft-deleted people stay in the store for attribution.
    private var members: [FamilyMember] {
        allMembers
            .filter { !$0.isRemoved && $0.uuid != profile.linkedMemberID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The current user's linked household member — the shared identity others see.
    private var youMember: FamilyMember? {
        allMembers.first { $0.uuid == profile.linkedMemberID }
    }

    /// Mirror your private profile's name/photo onto your shared "you" member so the
    /// rest of the household sees current values.
    private func syncYou() {
        guard let me = youMember else { return }
        profile.syncIdentity(to: me)
        context.saveChanges()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                header
                peopleCard
            }
            .padding(Spacing.lg)
        }
        .background(Palette.background)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Manage household")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { context.saveChanges() }
        .alert("Add someone", isPresented: $showAddPerson) {
            TextField("Name", text: $newPersonName)
            Button("Add") { addPerson() }
            Button("Cancel", role: .cancel) { newPersonName = "" }
        } message: {
            Text("Who else is in your household?")
        }
        .sheet(item: $inviting) { member in
            InviteLinkSheet(member: member, household: household)
        }
    }

    /// Whether this member can be handed a phone: an adult who is not the owner. Children
    /// and pets are planned FOR, not invited. Only once sync is live — before that a link
    /// would promise another person will see something nothing can deliver.
    private func canInvite(_ member: FamilyMember) -> Bool {
        HouseholdSync.isLive && member.role != .owner && member.relationship != .child
            && member.relationship != .pet
    }

    /// The roster row's one word about the invite: nothing until a link was made, then
    /// the state the invitation record carries (it rides the share, so "Joined" appears
    /// on the owner's phone when the other phone links its identity).
    private func invitationCaption(_ member: FamilyMember) -> String? {
        switch household.invitationState(for: member.uuid) {
        case .pending: return "Invited · waiting"
        case .accepted: return "Joined"
        case .expired, .none: return nil
        }
    }

    // MARK: - Header — the household as a place, not a form

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            PhotoPickerButton { data in
                household.photoData = data
                household.photoUpdatedAt = Date()
                context.saveChanges()
            } label: {
                AvatarView(household: household, size: 88)
            }
            .accessibilityLabel("Family photo")

            TextField("Family name (optional)", text: $household.name.orEmpty)
                .font(.screenTitle)
                .foregroundStyle(Palette.primaryText)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)

            Text("\(members.count + 1) member\(members.count == 0 ? "" : "s")")
                .metadataStyle()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - People

    private var peopleCard: some View {
        VStack(spacing: 0) {
            youRow
            ForEach(members) { member in
                divider
                memberRow(member)
            }
            divider
            addPersonRow
        }
        .background(
            Palette.primarySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
    }

    private var youRow: some View {
        HStack(spacing: Spacing.sm) {
            PhotoPickerButton { data in
                profile.photoData = data
                profile.photoUpdatedAt = Date()
                syncYou()
            } label: {
                AvatarView(profile: profile, size: 44)
            }
            .accessibilityLabel("Your photo")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Your name", text: $profile.displayName.orEmpty)
                    .font(.supporting.weight(.medium))
                    .foregroundStyle(Palette.primaryText)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onChange(of: profile.displayName) { _, _ in syncYou() }
                Text("You")
                    .metadataStyle()
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
    }

    private func memberRow(_ member: FamilyMember) -> some View {
        HStack(spacing: Spacing.sm) {
            PhotoPickerButton { data in
                member.photoData = data
                member.photoUpdatedAt = Date()
                context.saveChanges()
            } label: {
                AvatarView(member: member, size: 44)
            }
            .accessibilityLabel("\(member.name)'s photo")

            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    "Name", text: Binding(get: { member.name }, set: { member.name = $0 })
                )
                .font(.supporting.weight(.medium))
                .foregroundStyle(Palette.primaryText)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                // Relationship is warm and human — and the single strongest hint the AI
                // gets about a person. Role stays defaulted and unsurfaced in V1.
                Menu {
                    ForEach(FamilyRelationship.allCases) { relation in
                        Button(relation.label) {
                            member.relationship = relation
                            context.saveChanges()
                        }
                    }
                } label: {
                    Text(member.relationship.label)
                        .metadataStyle()
                }
                .accessibilityLabel("\(member.name)'s relationship, \(member.relationship.label)")
                if let caption = invitationCaption(member) {
                    Text(caption)
                        .metadataStyle()
                        .foregroundStyle(caption == "Joined" ? Palette.accentFlat : Palette.mutedText)
                }
            }
            Spacer(minLength: 0)

            Menu {
                if canInvite(member) {
                    Button(
                        household.invitationState(for: member.uuid) == .pending ? "Send the link again" : "Invite to share this household",
                        systemImage: "person.badge.plus"
                    ) { inviting = member }
                }
                Button("Remove from household", role: .destructive) { remove(member) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.glyphCaption(.semibold))
                    .foregroundStyle(Palette.mutedText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(member.name)")
        }
        .padding(Spacing.md)
    }

    private var addPersonRow: some View {
        Button {
            showAddPerson = true
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "plus")
                    .font(.glyphBody(.semibold))
                    .foregroundStyle(Palette.accentFlat)
                    .frame(width: 44, height: 44)
                Text("Add someone")
                    .font(.supporting.weight(.medium))
                    .foregroundStyle(Palette.accentFlat)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 0.5)
            .padding(.leading, Spacing.md)
    }

    // MARK: - Actions

    private func addPerson() {
        let trimmed = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPersonName = ""
        guard !trimmed.isEmpty else { return }
        let member = FamilyMember(name: trimmed, in: context)
        member.household = household
        context.saveChanges()
    }

    /// Soft-delete: the record stays so a task they once owned keeps its attribution.
    private func remove(_ member: FamilyMember) {
        Motion.withMotion(Motion.decide) { member.deletedAt = Date() }
        context.saveChanges()
    }
}

// MARK: - Photo picking

/// A tappable label that opens the photo library and hands back avatar-sized bytes.
/// Owns its own selection state so each row can have one without a shared binding.
private struct PhotoPickerButton<Label: View>: View {
    let onPick: (Data) -> Void
    @ViewBuilder let label: Label
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
            label
        }
        .buttonStyle(.pressableIcon)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let raw = try? await newItem.loadTransferable(type: Data.self),
                    let small = AvatarPhoto.downscaled(raw)
                {
                    onPick(small)
                }
                item = nil
            }
        }
    }
}

// MARK: - Optional string binding

extension Binding where Value == String? {
    /// Bridges an optional model string to a TextField: empty text reads back as nil, so
    /// "no family name" stays genuinely absent rather than an empty string.
    var orEmpty: Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? "" },
            set: { wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

#Preview {
    NavigationStack {
        HouseholdRosterView()
    }
    .environment(\.managedObjectContext, PersistenceStack.scratch)
}
