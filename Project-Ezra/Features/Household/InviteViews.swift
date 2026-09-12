//
//  InviteViews.swift
//  Project-Ezra
//
//  The two sheets of the second-caretaker invite (`HouseholdSharing`).
//
//  `InviteLinkSheet` — the owner's side. One link, shared through the system sheet or
//  copied, and one sentence saying what the link does in the person's terms (whoever opens
//  it joins this household and sees everything in it). No account field, no email lookup,
//  no "pending invitations" management surface: the roster row's caption carries the
//  state, and re-sending is tapping the same menu item again.
//
//  `IdentityLinkSheet` — the arriving side, shown only when the phone cannot tell which
//  member the person is (`HouseholdSharing.autoLinkTarget` returned nil: two or more
//  invitations pending, or none). The roster the owner built, and "someone else". It is a
//  sheet the shell mounts once (`RootTabView`), like the other three.
//

import CoreData
import SwiftUI

struct InviteLinkSheet: View {
    let member: FamilyMember
    let household: Household
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Invite \(member.name)")
                        .screenTitleStyle()
                    Text(
                        "Send \(member.name) this link. When they open it, they join "
                            + "\(household.name ?? "your household") and see the same tasks you do — "
                            + "including the ones already assigned to them."
                    )
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let url {
                    VStack(spacing: Spacing.sm) {
                        ShareLink(
                            item: url, subject: Text("Join \(household.name ?? "our household") in Ezra"),
                            message: Text("Open this on your phone to see our shared plan.")
                        ) {
                            Text("Send link")
                                .font(.ctaLabel)
                                .foregroundStyle(Palette.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Palette.accentGradient, in: Capsule())
                        }
                        .buttonStyle(.pressableProminent)

                        Button {
                            UIPasteboard.general.url = url
                            copied = true
                        } label: {
                            Text(copied ? "Copied" : "Copy link")
                                .font(.ctaCompact.weight(.regular))
                                .foregroundStyle(Palette.secondaryText)
                        }
                        .buttonStyle(.pressableLink)
                    }
                } else if let error {
                    Text(error)
                        .font(.supporting)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { Task { await makeLink() } }
                        .font(.supporting.weight(.medium))
                        .foregroundStyle(Palette.accentFlat)
                        .buttonStyle(.pressableLink)
                } else {
                    // A wait the person asked for — the sanctioned `ThinkingLine` placement
                    // shape — but it is a NETWORK wait, not a model one, so the line says so.
                    HStack(spacing: Spacing.sm) {
                        ProgressView().tint(Palette.mutedText)
                        Text("Preparing the link…").metadataStyle()
                    }
                }
                Spacer()
            }
            .padding(Spacing.lg)
            .background(Palette.background)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await makeLink() }
        }
        .presentationDetents([.medium])
    }

    private func makeLink() async {
        error = nil
        do {
            url = try await HouseholdSharing.shared.inviteLink(for: member, household: household)
        } catch let failure {
            error = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        }
    }
}

struct IdentityLinkSheet: View {
    let pending: PendingIdentityLink
    @State private var name = ""
    @State private var namingSomeoneElse = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Which one is you?")
                        .screenTitleStyle()
                    Text(
                        "You've joined \(pending.household.name ?? "a household"). "
                            + "Pick your name so the tasks meant for you are yours."
                    )
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(pending.candidates) { member in
                        Button {
                            HouseholdSharing.shared.resolvePendingLink(as: member, named: nil)
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                AvatarView(member: member, size: 44)
                                Text(member.name)
                                    .font(.supporting.weight(.medium))
                                    .foregroundStyle(Palette.primaryText)
                                Spacer(minLength: 0)
                                if pending.invitations.contains(where: { $0.memberID == member.uuid }) {
                                    Text("Invited").metadataStyle()
                                }
                            }
                            .padding(Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        Rectangle().fill(Palette.border).frame(height: 0.5).padding(.leading, Spacing.md)
                    }

                    if namingSomeoneElse {
                        HStack(spacing: Spacing.sm) {
                            TextField("Your name", text: $name)
                                .font(.bodyInput)
                                .foregroundStyle(Palette.primaryText)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit(finishNaming)
                            Button("Join") { finishNaming() }
                                .font(.supporting.weight(.medium))
                                .foregroundStyle(Palette.accentFlat)
                                .buttonStyle(.pressableLink)
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(Spacing.md)
                    } else {
                        Button {
                            namingSomeoneElse = true
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "plus")
                                    .font(.glyphBody(.semibold))
                                    .foregroundStyle(Palette.accentFlat)
                                    .frame(width: 44, height: 44)
                                Text("Someone else")
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
                }
                .background(
                    Palette.primarySurface,
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                }
                Spacer()
            }
            .padding(Spacing.lg)
            .background(Palette.background)
        }
        .interactiveDismissDisabled()
    }

    private func finishNaming() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        HouseholdSharing.shared.resolvePendingLink(as: nil, named: trimmed)
    }
}
