//
//  SettingsView.swift
//  Project-Ezra
//
//  The Settings sheet reached from the "My Tasks" title bar's "…" menu. Deliberately
//  spare (the best settings screens are almost empty): your profile (name + photo),
//  the AI engine's live availability, and the quiet beta diagnostics that used to live
//  in the AI trail footer — acceptance / rot / opens, plus the dev-only Today-plan
//  tier readout.
//

import CoreData
import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppBrain.self) private var brain

    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)])
    private var changesResults: FetchedResults<ChangeLogEntry>
    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>

    @State private var photoItem: PhotosPickerItem?

    private var profile: UserProfile? { profilesResults.first }
    private var tasks: [TaskItem] { Array(tasksResults) }
    /// AI-only entries — the acceptance metric must count the AI's own actions only.
    private var aiEntries: [ChangeLogEntry] { changesResults.filter { $0.initiatedBy == .ai } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    profileCard
                    engineCard
                    diagnosticsCard
                }
                .padding(Spacing.lg)
            }
            .background(Palette.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { try? context.save() }
            .task { UserProfile.bootstrapIdentity(in: context) }
        }
    }

    // MARK: - Profile (name + photo — the roster's youRow idiom)

    private var profileCard: some View {
        VStack(spacing: Spacing.md) {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                AvatarView(profile: profile, size: 88)
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel("Your photo")
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let raw = try? await newItem.loadTransferable(type: Data.self),
                        let small = AvatarPhoto.downscaled(raw), let profile
                    {
                        profile.photoData = small
                        profile.photoUpdatedAt = Date()
                        syncYou()
                    }
                    photoItem = nil
                }
            }

            if let profile {
                TextField("Your name", text: bindingName(profile))
                    .font(.screenTitle)
                    .foregroundStyle(Palette.primaryText)
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { syncYou() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.lg)
        .background(
            Palette.primarySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
    }

    private func bindingName(_ profile: UserProfile) -> Binding<String> {
        Binding(
            get: { profile.displayName ?? "" },
            set: { profile.displayName = $0.isEmpty ? nil : $0 }
        )
    }

    /// Mirror the private profile's name/photo onto the shared "you" member.
    private func syncYou() {
        guard let profile else { return }
        let members = Array(membersResults)
        if let me = members.first(where: { $0.uuid == profile.linkedMemberID }) {
            profile.syncIdentity(to: me)
        }
        try? context.save()
    }

    // MARK: - AI engine status

    private var engineCard: some View {
        settingsCard(title: "AI Engine") {
            HStack(spacing: Spacing.sm) {
                Image(systemName: brain.status.isOnDevice ? "sparkles" : "gearshape.2")
                    .font(.system(size: IconSize.body))
                    .foregroundStyle(brain.status.isOnDevice ? Palette.accentFlat : Palette.secondaryText)
                Text(brain.status.description)
                    .font(.supporting)
                    .foregroundStyle(Palette.primaryText)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Diagnostics (lifted from the old AI-trail footer)

    private var diagnosticsCard: some View {
        settingsCard(title: "Diagnostics") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(diagnosticsLine)
                    .metadataStyle()
                #if DEBUG
                Text(planDiagnosticsLine)
                    .metadataStyle()
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnosticsLine: String {
        var parts: [String] = []
        parts.append("Kept \(percent(Metrics.acceptanceRate(entries: aiEntries)))")
        parts.append("rot \(percent(Metrics.rotRate(tasks: tasks)))")
        parts.append("opens \(brain.metrics.selfInitiatedOpens)")
        if let payoff = brain.metrics.timeToFirstPayoff {
            parts.append("first payoff \(Int(payoff))s")
        }
        return parts.joined(separator: " · ")
    }

    #if DEBUG
    private var planDiagnosticsLine: String {
        let m = brain.planMetrics
        var parts = [
            "plan: on-device \(m.onDeviceCount) · pcc \(m.pccCount) · rules \(m.deterministicCount)"
        ]
        if m.lastLatencyMs >= 0 { parts.append("last \(m.lastLatencyMs)ms") }
        if m.lastPromptTokens >= 0 || m.lastOutputTokens >= 0 {
            parts.append("tok \(max(m.lastPromptTokens, 0))/\(max(m.lastOutputTokens, 0))")
        }
        if let tier = m.lastTier { parts.append("via \(tier)") }
        if let err = m.lastError { parts.append("err \(err)") }
        if let avail = m.lastAvailability { parts.append("ai \(avail)") }
        return parts.joined(separator: " · ")
    }
    #endif

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    // MARK: - Shared card chrome

    private func settingsCard<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .metadataStyle()
                .textCase(.uppercase)
                .tracking(0.6)
            content()
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Palette.primarySurface,
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
