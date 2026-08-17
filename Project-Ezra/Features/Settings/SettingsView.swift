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

    @Environment(BriefingReminder.self) private var briefing

    @State private var photoItem: PhotosPickerItem?
    @State private var pendingReset: StoreResetRecord?
    @State private var exportURL: URL?
    @State private var backupArchiveURL: URL?
    /// The clear awaiting confirmation. Nil is the resting state; what HAPPENED is read
    /// from `StoreResetLog` into `pendingReset`, not tracked separately here.
    @State private var pendingScope: DataReset.Scope?

    private var profile: UserProfile? { profilesResults.first }
    private var tasks: [TaskItem] { Array(tasksResults) }
    /// AI-only entries — the acceptance metric must count the AI's own actions only.
    private var aiEntries: [ChangeLogEntry] { changesResults.filter { $0.initiatedBy == .ai } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // The reset notice leads when present: it is the one thing here the
                    // user did not choose and needs to know about.
                    if let reset = pendingReset { resetCard(reset) }
                    profileCard
                    briefingCard
                    engineCard
                    dataCard
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
            .onDisappear { context.saveChanges() }
            .task {
                UserProfile.bootstrapIdentity(in: context)
                pendingReset = StoreResetLog.pending()
                if let name = pendingReset?.backupName {
                    backupArchiveURL = PersistenceStack.zippedBackup(named: name)
                }
                // Built once per open, so what you share is what you have. Small enough
                // (a personal store, no photo blobs) that this is imperceptible.
                exportURL = try? DataExport.writeTemporaryFile(in: context)
                await briefing.refreshAuthorizationState()
            }
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
        context.saveChanges()
    }

    // MARK: - AI engine status

    private var engineCard: some View {
        settingsCard(title: "AI Engine") {
            HStack(spacing: Spacing.sm) {
                Image(systemName: brain.status.isOnDevice ? "sparkles" : "gearshape.2")
                    .font(.glyphBody())
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
                // Per-capability model outcomes — the evidence behind the deadlines.
                // Local only; nothing here is ever transmitted.
                ForEach(ModelMetrics.shared.footerLines(), id: \.self) { line in
                    Text(line)
                        .metadataStyle()
                }
                // Per-move Advisor outcomes (acted/offered, plus the silence count),
                // and the north-star derivation: % of advised tasks that later moved,
                // with the re-intervention rate.
                if let advisor = AdvisorMetrics.shared.footerLine {
                    Text(advisor)
                        .metadataStyle()
                }
                if let progression = AdvisorMetrics.shared.progressionLine(among: tasks) {
                    Text(progression)
                        .metadataStyle()
                }
                // What share of the real list the Advisor speaks on, and why it is silent
                // on the rest. Free to render here: this view already fetches every task.
                // A DIAGNOSTIC, never a target — see `AdvisorCoverage`.
                Text(AdvisorCoverage.measure(tasks).line)
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
        if m.lastTurn > 0 { parts.append("turn \(m.lastTurn) · tools \(m.lastToolCalls)") }
        if let err = m.lastError { parts.append("err \(err)") }
        if let avail = m.lastAvailability { parts.append("ai \(avail)") }
        return parts.joined(separator: " · ")
    }
    #endif

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    // MARK: - Reset notice (a wipe must never be silent)

    /// ONE card for every wipe, voluntary or not — because what the user needs afterwards
    /// (when, what went, where the copy is) is identical either way, and two cards would
    /// drift. Only the tone branches: a warning triangle for a reset that happened TO you,
    /// a checkmark for one you asked for. `Palette.warning` is correct in the first case —
    /// this is a literal warning about data, not one of the split attention hues the
    /// design system reserves (`overdue`/`statusInProgress`/`householdAttention`).
    ///
    /// Shown until dismissed, which is the whole point of reading it from `StoreResetLog`
    /// rather than from view state: the backup stays reachable after the sheet closes, and
    /// after the app is relaunched.
    private func resetCard(_ reset: StoreResetRecord) -> some View {
        let voluntary = reset.reason.isVoluntary
        return settingsCard(title: voluntary ? "Data cleared" : "Data was reset") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: voluntary ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .font(.glyphCaption())
                        .foregroundStyle(voluntary ? Palette.secondaryText : Palette.warning)
                    Text(
                        "Your saved data was cleared on \(reset.date.formatted(date: .abbreviated, time: .shortened)) because \(reset.reason.explanation)."
                    )
                    .font(.supporting)
                    .foregroundStyle(Palette.primaryText)
                }
                if case .userRequested(let clearedIdentity) = reset.reason, clearedIdentity {
                    // The first-run cover is armed at launch and deliberately not
                    // re-presented mid-session (raising it from the shell while this sheet
                    // is open is a presentation conflict), so say when setup returns.
                    Text("Setup runs again the next time you open the app.")
                        .metadataStyle()
                }
                if let detail = reset.reason.detail {
                    Text(detail)
                        .metadataStyle()
                }
                if reset.backupName != nil {
                    Text("A copy of what was there was saved first.")
                        .font(.supporting)
                        .foregroundStyle(Palette.secondaryText)
                    if let archive = backupArchiveURL {
                        ShareLink(item: archive) {
                            Label("Share the backup", systemImage: "square.and.arrow.up")
                                .font(.controlLabel)
                                .foregroundStyle(Palette.accentFlat)
                        }
                        .frame(minHeight: LayoutMetrics.hitTarget, alignment: .leading)
                    }
                } else {
                    // The worst case, stated plainly rather than left to be discovered.
                    Text("The safety copy could not be written, so this data is gone.")
                        .font(.supporting)
                        .foregroundStyle(Palette.warning)
                }
                Button("Dismiss") {
                    StoreResetLog.clear()
                    pendingReset = nil
                }
                .font(.controlLabel)
                .foregroundStyle(Palette.secondaryText)
                .frame(minHeight: LayoutMetrics.hitTarget, alignment: .leading)
            }
        }
    }

    // MARK: - Briefing nudge

    /// The ONE notification this app sends. See `BriefingReminder` for why this is a
    /// carve-out from the "no notification-driven re-engagement" guardrail, and what
    /// keeps it honest.
    private var briefingCard: some View {
        @Bindable var briefing = briefing
        return settingsCard(title: "Daily briefing") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Toggle(isOn: $briefing.isEnabled) {
                    Text("Remind me")
                        .font(.supporting)
                        .foregroundStyle(Palette.primaryText)
                }
                .tint(Palette.accentFlat)
                .onChange(of: briefing.isEnabled) { _, enabled in
                    Task {
                        if enabled {
                            // Permission is asked for here and nowhere else — never at
                            // launch, where it would be a demand before any value.
                            guard await briefing.requestAuthorization() else {
                                briefing.isEnabled = false
                                return
                            }
                            await briefing.reschedule(
                                briefingPlayedToday: TodayPlanStore.sequencePlayedToday())
                        } else {
                            await briefing.cancelAll()
                        }
                    }
                }

                if briefing.isEnabled && !briefing.isDenied {
                    DatePicker(
                        "Time", selection: briefingTime, displayedComponents: .hourAndMinute
                    )
                    .font(.supporting)
                    .foregroundStyle(Palette.primaryText)
                }

                if briefing.isDenied {
                    Text("Notifications are turned off for Ezra in iOS Settings.")
                        .metadataStyle()
                }

                Text("One a day, at a time you pick. Nothing if you've already looked.")
                    .metadataStyle()
            }
        }
    }

    /// Bridges the reminder's hour/minute to a `DatePicker`, rescheduling on change.
    private var briefingTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: briefing.hour, minute: briefing.minute, second: 0,
                    of: Date()) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                briefing.hour = parts.hour ?? briefing.hour
                briefing.minute = parts.minute ?? briefing.minute
                Task {
                    await briefing.reschedule(
                        briefingPlayedToday: TodayPlanStore.sequencePlayedToday())
                }
            }
        )
    }

    // MARK: - Data (export, and the two clears)

    /// Export sits ABOVE the clears on purpose: the JSON snapshot is the honest safety net
    /// (the automatic copy taken by `DataReset` is of a store that is currently open), so
    /// the escape hatch is in view before the destructive button is.
    private var dataCard: some View {
        settingsCard(title: "Data") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export everything", systemImage: "square.and.arrow.up")
                            .font(.controlLabel)
                            .foregroundStyle(Palette.accentFlat)
                    }
                    .frame(minHeight: LayoutMetrics.hitTarget, alignment: .leading)
                }
                Text(
                    "A readable copy of your tasks, captures and history. Everything stays on this device."
                )
                .metadataStyle()

                Divider().overlay(Palette.border)

                // A clear that just happened is reported by `resetCard` at the top of the
                // sheet — the same card every other wipe uses — so the controls simply
                // stand down rather than growing a second, parallel receipt here.
                if pendingReset?.reason.isVoluntary == true {
                    Text("Cleared. The receipt is at the top of this screen.")
                        .metadataStyle()
                } else {
                    clearControls
                }
            }
        }
    }

    /// Two clears, weighted differently on purpose. Clearing your work is the one people
    /// actually want (a bad import, a test drive, a fresh start on the same phone), so it
    /// reads as a normal destructive action. The factory reset takes your name, your
    /// household and your settings with it — it is the rarer, heavier thing, so it sits
    /// below in supporting type rather than as a second red button competing with the first.
    private var clearControls: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(role: .destructive) {
                pendingScope = .work
            } label: {
                Label("Clear all tasks", systemImage: "trash")
                    .font(.controlLabel)
                    .foregroundStyle(Palette.error)
            }
            .frame(minHeight: LayoutMetrics.hitTarget, alignment: .leading)

            Text("Deletes every task, capture and activity entry. Your profile and household stay.")
                .metadataStyle()

            Button {
                pendingScope = .everything
            } label: {
                Text("Reset everything")
                    .font(.supporting)
                    .foregroundStyle(Palette.secondaryText)
            }
            .frame(minHeight: LayoutMetrics.hitTarget, alignment: .leading)
        }
        // One dialog for both, driven by the scope — the copy is what differs, and putting
        // the two apart invites them to drift into saying different things about the same act.
        .confirmationDialog(
            clearTitle, isPresented: clearDialogPresented, titleVisibility: .visible,
            presenting: pendingScope
        ) { scope in
            Button(clearVerb(scope), role: .destructive) { performClear(scope) }
            Button("Cancel", role: .cancel) {}
        } message: { scope in
            Text(clearMessage(scope))
        }
    }

    private var clearTitle: String {
        pendingScope == .everything ? "Reset everything?" : "Clear all tasks?"
    }

    private func clearVerb(_ scope: DataReset.Scope) -> String {
        scope == .everything ? "Reset everything" : "Clear all tasks"
    }

    private func clearMessage(_ scope: DataReset.Scope) -> String {
        switch scope {
        case .work:
            return
                "Every task, capture and activity entry is deleted. This can't be undone from inside the app — a copy of your data is saved first."
        case .everything:
            return
                "Everything goes: tasks, captures, history, your profile, your household and your settings. Setup runs again the next time you open the app. A copy of your data is saved first."
        }
    }

    /// Binding rather than a second `@State` flag: the pending scope IS the presentation
    /// state, and two sources of truth for one dialog is how a cancel leaves a stale scope
    /// armed for the next tap.
    private var clearDialogPresented: Binding<Bool> {
        Binding(get: { pendingScope != nil }, set: { if !$0 { pendingScope = nil } })
    }

    /// `DataReset` writes the receipt to `StoreResetLog`; this just adopts it into view
    /// state, so the card at the top of the sheet renders from the same record a relaunch
    /// would read. One reporting path, two readers.
    private func performClear(_ scope: DataReset.Scope) {
        let record = DataReset.clear(
            scope, in: context, metrics: brain.metrics, planMetrics: brain.planMetrics)
        pendingScope = nil
        pendingReset = record
        backupArchiveURL = record.backupName.flatMap { PersistenceStack.zippedBackup(named: $0) }
        // The offered export was built at open, from data that no longer exists — sharing
        // it after a clear would hand back the very thing the user just deleted.
        exportURL = try? DataExport.writeTemporaryFile(in: context)
        if scope == .everything {
            // The one preference with a side effect outside the store: a scheduled nudge
            // for a briefing that no longer has anything to brief about.
            briefing.isEnabled = false
            Task { await briefing.cancelAll() }
        }
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
        .environment(BriefingReminder())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
