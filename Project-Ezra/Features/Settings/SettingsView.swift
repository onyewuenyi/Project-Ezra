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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppBrain.self) private var brain

    @FetchRequest(sortDescriptors: UserProfile.chosenOrder) private var profilesResults:
        FetchedResults<UserProfile>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)])
    private var changesResults: FetchedResults<ChangeLogEntry>
    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>
    /// Backs the capture dimension of the Required Attention scorecard — corrections per
    /// confirmed task. Write-only as a learning signal; read here only to count.
    @FetchRequest(sortDescriptors: []) private var correctionsResults: FetchedResults<Correction>

    @State private var photoItem: PhotosPickerItem?
    /// `Telemetry.enabledKey` — read here so the boundary card re-renders on the flip.
    @AppStorage(Telemetry.enabledKey) private var telemetryEnabled = true
    /// The digest switch — seeded from the household rule in `.task`, written by its setter.
    @State private var digestOn = false
    @State private var pendingReset: StoreResetRecord?
    @State private var exportURL: URL?
    @State private var backupArchiveURL: URL?
    /// The clear awaiting confirmation. Nil is the resting state.
    @State private var pendingScope: DataReset.Scope?
    /// What a clear performed in THIS sheet did — and deliberately NOT read from
    /// `pendingReset`, which is the DURABLE `StoreResetLog` record and stands until
    /// somebody taps Dismiss.
    ///
    /// Gating the controls on that durable record made the first successful clear the
    /// last one: the receipt survives relaunch, so on every later visit both buttons were
    /// replaced by "Cleared. The receipt is at the top of this screen." and the only way
    /// back was noticing Dismiss on a card further up. The stand-down is about the beat
    /// you just performed, so it belongs to the session, not to the store.
    @State private var clearOutcome: ClearOutcome?

    /// The two things that can come back from a clear. `failed` exists because
    /// `DataReset` can now say so (`StoreResetRecord.destroyedData`), and a wipe that
    /// silently left everything standing is the one outcome the user must not have to
    /// discover by relaunching.
    private enum ClearOutcome { case cleared, failed }

    private var profile: UserProfile? { profilesResults.first }

    /// **LIVE rows only — this screen deletes its own fetches (2026-09-18).** The clear
    /// lives here, and it wipes `TaskItem`, `ChangeLogEntry` and `Correction` while this
    /// view holds a `@FetchRequest` for each; the re-render that follows walks them
    /// (`requiredAttention`, `diagnosticsLine`, the activation line) and read a row Core
    /// Data had already torn down — SIGSEGV, every time, the crash "Clear all tasks"
    /// shipped with. A deleted or context-less object is not data any more, so it leaves
    /// the derivation, which is also exactly what the clear means.
    private var tasks: [TaskItem] { tasksResults.filter(\.isLiveRow) }
    private var changes: [ChangeLogEntry] { changesResults.filter(\.isLiveRow) }
    private var corrections: [Correction] { correctionsResults.filter(\.isLiveRow) }
    /// AI-only entries — the acceptance metric must count the AI's own actions only.
    private var aiEntries: [ChangeLogEntry] { changes.filter { $0.initiatedBy == .ai } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // The reset notice leads when present: it is the one thing here the
                    // user did not choose and needs to know about.
                    if let reset = pendingReset { resetCard(reset) }
                    profileCard
                    digestCard
                    dataBoundaryCard
                    dataCard
                    // Developer lines live in DEBUG only. The card's first line — "Kept
                    // 62% · rot 8% · opens 14 · first payoff 42s" — shipped to customers
                    // until 2026-09-18: acceptance and rot rates are the product's own
                    // scorecard, and the guardrails say reporting, never scoring, and no
                    // user-facing score. The whole card is the developer's.
                    #if DEBUG
                    diagnosticsCard
                    #endif
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
            .onDisappear {
                context.saveChanges()
                // The clear emptied the STORE; the screens behind this sheet are still
                // showing what used to be in it, because the one safe way to delete on
                // this runtime tells the live context nothing (`DataGeneration`). Rebuild
                // them now — after the receipt has been read and the sheet is closing, so
                // the rebuild takes nothing away from the person who asked for it.
                if clearOutcome == .cleared { DataGeneration.shared.rebuild() }
            }
            .task {
                UserProfile.bootstrapIdentity(in: context)
                digestOn = WeeklyDigest.isEnabled(caretakerCount: caretakerCount, defaults: .standard)
                pendingReset = StoreResetLog.pending()
                if let name = pendingReset?.backupName {
                    backupArchiveURL = PersistenceStack.zippedBackup(named: name)
                }
                // Built once per open, so what you share is what you have. Small enough
                // (a personal store, no photo blobs) that this is imperceptible.
                exportURL = try? DataExport.writeTemporaryFile(in: context)
                #if DEBUG
                // `-ClearAllTasks` / `-ResetEverything` perform the destructive clear
                // on arrival. They are the two controls here that cannot be reviewed
                // any other way: each sits behind a confirmation dialog, and synthetic
                // taps are blocked on this host. They are also how the SIGSEGV this
                // path shipped with was found and how it is kept honest — a destructive
                // button's "it does not crash" has to be re-measurable. The short sleep
                // lets the screen finish its first render, so the clear lands on a live
                // view exactly as a tap would. Never fires in a normal run.
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-ClearAllTasks") || args.contains("-ResetEverything") {
                    try? await Task.sleep(for: .milliseconds(400))
                    performClear(args.contains("-ResetEverything") ? .everything : .work)
                    // Closes the sheet afterwards so the rebuilt list can be
                    // screenshotted — the half of the clear that has no other witness.
                    // Note when reading the frames: the rebuild re-runs `-OpenSettings`
                    // too, so Settings comes back a second later. The empty list in
                    // between is the measurement.
                    if args.contains("-DismissAfterClear") {
                        try? await Task.sleep(for: .milliseconds(1500))
                        dismiss()
                    }
                }
                #endif
            }
        }
    }

    // MARK: - Profile (name + photo — the roster's youRow idiom)

    /// A row, not a hero (2026-09-25, the importance audit): the person's own name is
    /// the least-changed thing in Settings, and an 88pt photo over a 28pt name made it
    /// the page's largest object, pushing the digest and privacy sections below the
    /// fold. Same editors, row weight.
    ///
    /// At accessibility sizes the photo sits ABOVE the name: beside it, a surname longer
    /// than the remaining width cannot wrap (one word) and was cut to "Charles Onyewuen"
    /// (2026-10-02, the /verify AX5 sheet). Stacked, the name has the card's whole width.
    private var profileCard: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(spacing: Spacing.md))
        return layout {
            PhotosPicker(selection: $photoItem, matching: .images) {
                AvatarView(profile: profile, size: 52)
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
                // Wraps rather than truncates: at the accessibility sizes a two-word
                // name read "Charles Ony…" (2026-09-18), and a name is the one field
                // whose whole value must be readable to be recognised as yours.
                TextField("Your name", text: bindingName(profile), axis: .vertical)
                    .lineLimit(1...2)
                    .font(.sectionHeader)
                    .foregroundStyle(Palette.primaryText)
                    .multilineTextAlignment(.leading)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { syncYou() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
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

    // MARK: - The week's edition

    /// The one notification — see `WeeklyDigest` and the carve-out in the guardrails. The
    /// switch reads the household rule until the person decides (on for two caretakers,
    /// off for one), and a decision here is final for this install.
    private var digestCard: some View {
        settingsCard(title: "Your week") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // The side effect rides the SETTER, never an `onChange` on the state:
                // seeding the state from the household rule echoed through `onChange`
                // as a flip and asked for notification permission on opening Settings
                // (caught on-sim 2026-09-12) — the one moment the digest must not ask.
                Toggle(
                    "Sunday evening digest",
                    isOn: Binding(
                        get: { digestOn },
                        set: { on in
                            digestOn = on
                            digestChanged(to: on)
                        })
                )
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .tint(Palette.accentFlat)
                Text(
                    "Once a week, what the coming week holds for your household — due dates, "
                        + "anything overdue, decisions waiting. Nothing is sent on a week with nothing to say."
                )
                .metadataStyle()
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var caretakerCount: Int {
        Household.existing(in: context).map(HouseholdActivation.caretakerIDs)?.count ?? 1
    }

    /// A flip here is the person's decision, persisted under `WeeklyDigest.enabledKey`.
    private func digestChanged(to on: Bool) {
        UserDefaults.standard.set(on, forKey: WeeklyDigest.enabledKey)
        Task {
            if on { await WeeklyDigestScheduler.shared.requestPermissionIfNeeded() }
            WeeklyDigestScheduler.shared.refresh(tasks: tasks, caretakerCount: caretakerCount)
        }
    }

    // MARK: - What leaves this device

    /// The data boundary — and the only thing this screen says about how Ezra thinks.
    ///
    /// **The customer never hears "AI", and never hears a provider name.** This card used
    /// to be titled "AI Engine" and printed `brain.status.description` — "Apple
    /// Intelligence · on-device" / "Rules engine · Apple Intelligence off" — which broke
    /// that rule twice in one line, and did it with an internal enum description. Worse,
    /// it answered a question no user asked: which vendor is doing the thinking is not
    /// their business or their decision, and showing it invites them to manage something
    /// the product exists to manage for them (principle 10).
    ///
    /// What a person actually wants from this screen is the one thing they cannot check
    /// for themselves: **what leaves.** So that is what it says, in three sentences. The
    /// engine readout still exists — in the DEBUG diagnostics card, where an internal
    /// number belongs.
    private var dataBoundaryCard: some View {
        settingsCard(title: "What leaves this device") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(
                    DataBoundary.current(
                        cloudReachable: CloudModel.isAvailable,
                        telemetry: Telemetry.sink != nil && telemetryEnabled
                    ).sentences, id: \.self
                ) { sentence in
                    Text(sentence)
                        .font(.supporting)
                        .foregroundStyle(Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The opt-out sits under the sentence that describes it, not in a
                // separate privacy screen: the switch and the promise are one thought.
                // Rendered only when a sink exists — a toggle for a transmission this
                // build cannot make would be theatre.
                if Telemetry.sink != nil {
                    Toggle("Share anonymous product signals", isOn: $telemetryEnabled)
                        .font(.supporting)
                        .foregroundStyle(Palette.primaryText)
                        .tint(Palette.accentFlat)
                        .padding(.top, Spacing.xs)
                }
                // The long form of the three sentences above, and the place to go when
                // the app is not working. App Review requires the privacy link to be
                // reachable inside the app, not only in the listing, and this card is
                // where a person is already reading about what leaves. Rendered only
                // when the page exists — a dead link under "Privacy policy" is worse
                // than none, and it is the first thing a reviewer taps (`SupportLinks`).
                if SupportLinks.privacyPolicy != nil || SupportLinks.support != nil {
                    HStack(spacing: Spacing.md) {
                        if let policy = SupportLinks.privacyPolicy {
                            Link("Privacy policy", destination: policy)
                        }
                        if let support = SupportLinks.support {
                            Link("Get help", destination: support)
                        }
                    }
                    .font(.supporting)
                    .tint(Palette.accentFlat)
                    .padding(.top, Spacing.xs)
                }
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
                // Which engine is actually backing this install. It used to sit in a
                // customer-facing card; an internal enum description naming a vendor is a
                // developer's line, and this is where developer lines live.
                Text(brain.status.description)
                    .metadataStyle()
                // Where intelligent moments actually resolved, per workload, plus the
                // one number the cloud rung's economics turn on: paid calls today.
                // Read this before arguing about model spend.
                ForEach(IntelligenceLedger.shared.footerLines(), id: \.self) { line in
                    Text(line)
                        .metadataStyle()
                }
                // The cap's headroom. If this is never approached, the cap is correctly
                // inert and the smart governor stays unbuilt — which is the answer we
                // are hoping for.
                Text(CloudBudget.statusLine())
                // The retrieval substrate's meter (2026-09-12): the phone ran for weeks with
                // this reading UNAVAILABLE and nothing said so.
                Text(EmbeddingStore.statusLine())
                    .metadataStyle()
                // The submission gate that no build failure will ever mention: an app
                // that collects data must link its privacy policy from inside the app,
                // and neither page is written yet. Counted down here for the same reason
                // App Check is — prose in a header is not a reminder (`SupportLinks`).
                Text(SupportLinks.debugStatusLine)
                    .metadataStyle()
                // Whether sync is working, and when it last did. The second meter added
                // for the same reason as the embedding one above it: CloudKit degrades
                // in silence, so an app that has never once exported a record reads
                // exactly like an app with nothing to send. `SCHEMA NOT DEPLOYED` here
                // is the launch-day failure, named (`SyncHealth`).
                Text(SyncHealth.shared.statusLine)
                    .metadataStyle()
                // The one deadline in this build that cannot be undone once it passes.
                // Prose in a header is not a reminder; a line that counts down is. When
                // this reads "enforced", an unattested cloud call is simply refused —
                // and `GeminiProvider.isAvailable` would still say the rung is up, so
                // the failure would arrive looking like a network problem.
                Text(AppCheckSetup.statusLine())
                    .metadataStyle()
                // The breaker. Read this FIRST when capture feels slow: "open" means the
                // cloud rung is being skipped deliberately and the on-device arm is
                // answering, which is a much better explanation than a hung network. The
                // reading we want is the boring one — a breaker that never opens is a
                // provider that never fails.
                Text(CloudHealth.shared.statusLine())
                    .metadataStyle()
                // The Ramble performance contract, live from this device's committed
                // captures: per-tier p50/p95 (capture-end → reveal, dwell counted)
                // against the targets, plus the local-share band. The verdicts here are
                // the phone's own receipts, never the simulator's.
                ForEach(
                    CapturePerformanceReport.measure(CaptureProvenanceStore.shared.all)
                        .footerLines(), id: \.self
                ) { line in
                    Text(line)
                        .metadataStyle()
                }
                // THE MASTER METRIC: four dimensions that must fall and one that must
                // rise. Read this before believing any single-stage improvement — the unit
                // of optimization is effort reduction across the whole loop, and a feature
                // that improves one stage while raising net attention is spend, not
                // progress.
                Text(requiredAttention.footerLine)
                    .metadataStyle()
                // The launch plan's household metrics — activated (both caretakers acted
                // inside the window), retained this week, single-caretaker tracked apart
                // — derived here, never shown as a score anywhere a user would read one.
                if let household = Household.existing(in: context) {
                    Text(
                        HouseholdActivation.measure(
                            household: household, tasks: tasks, entries: changes
                        ).footerLine
                    )
                    .metadataStyle()
                }
                // Product telemetry: whether a sink is installed and the last events it
                // saw. Confirms the boundary is exercised without opening a dashboard.
                Text(
                    Telemetry.sink == nil
                        ? "telemetry: no sink"
                        : "telemetry: on · \(telemetryEnabled ? "sharing" : "opted out")"
                )
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

    /// The Required Attention scorecard, derived fresh on open. `plannedTaskIDs` comes
    /// from today's cached briefing — the set the Brief actually surfaced — so the
    /// orientation dimension measures what the user had to find for themselves.
    private var requiredAttention: RequiredAttention {
        // Orientation is re-owned by the day answer (F-11): the set is what the floor
        // surfaced TODAY (`lastSurfacedAt`). Nil — never an empty set — when nothing was
        // surfaced today, so the row reads `—` rather than a perfect score.
        let surfacedToday = Set(
            tasks.filter { task in task.lastSurfacedAt.map { Calendar.current.isDateInToday($0) } ?? false }
                .compactMap(\.uuid))
        let planned: Set<UUID>? = surfacedToday.isEmpty ? nil : surfacedToday
        return RequiredAttention.measure(
            tasks: tasks, entries: changes,
            corrections: corrections, plannedTaskIDs: planned,
            advisor: AdvisorMetrics.shared)
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
                // stand down rather than growing a second, parallel receipt here. A clear
                // that FAILED gets the opposite treatment: it is said here, in place, and
                // the controls stay so the retry is one tap away.
                if clearOutcome == .cleared {
                    Text("Cleared. The receipt is at the top of this screen.")
                        .metadataStyle()
                } else {
                    if clearOutcome == .failed {
                        Text(
                            "Nothing was cleared — your data couldn't be saved, so every task is still here."
                        )
                        .font(.supporting)
                        .foregroundStyle(Palette.warning)
                    }
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
        // On a phone that JOINED a household, the clear stops at this phone's own data
        // (`DataReset.clearableStores`), and the sentence has to say so — "every task" read
        // as the whole household's plan, which belongs to whoever shared it.
        let joined = Household.existing(in: context).map { !HouseholdSharing.canShare($0) } ?? false
        switch scope {
        case .work where joined:
            return
                "Every task, capture and activity entry on this phone is deleted. The household you joined keeps its tasks. A copy of your data is saved first."
        case .work:
            return
                "Every task, capture and activity entry is deleted. This can't be undone from inside the app — a copy of your data is saved first."
        case .everything where joined:
            return
                "Everything on this phone goes: tasks, captures, history, your profile and your settings. The household you joined keeps its tasks, and you'll be asked who you are in it again. A copy of your data is saved first."
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
    ///
    /// A clear that did not destroy anything writes no receipt and must not raise one
    /// here either — `destroyedData` is the fact, and the card would otherwise say the
    /// data went while the list behind the sheet still holds every task.
    /// **The sheet closes FIRST, and the data goes once it is gone (2026-09-19).**
    ///
    /// This screen holds live `@FetchRequest`s for `TaskItem`, `ChangeLogEntry` and
    /// `Correction`, and derives from all three on every render (the activation line,
    /// the metrics line). Deleting those rows while it is on screen is deleting the
    /// data out from under a bound, live view tree, and it crashed the app — not once,
    /// but in every shape the deletion was tried: object-by-object (`deleteObject:`
    /// snapshotting a torn-down row), as a batch delete merged back in (`mergeChanges`
    /// calling that same `deleteObject:` internally), and after the fact, in the render
    /// that followed a clear which had itself completed. Each of those was a real bug
    /// and each is fixed; none of them was the whole bug, because the last one is not a
    /// deletion bug at all — it is a lifetime bug, and the only reliable cure for a view
    /// reading data that no longer exists is for the view to be gone first.
    ///
    /// Dismissing is also the honest product beat: you asked for everything to go, so
    /// the screen you asked from has nothing left to show. The receipt is not lost —
    /// `DataReset` writes it to `StoreResetLog`, which is durable, so the card is at the
    /// top of Settings the next time it opens, and after a relaunch.
    private func performClear(_ scope: DataReset.Scope) {
        let record = DataReset.clear(
            scope, in: context, metrics: brain.metrics,
            provenance: .shared, verdicts: .shared, readings: .shared)
        pendingScope = nil
        guard record.destroyedData else {
            clearOutcome = .failed
            return
        }
        clearOutcome = .cleared
        pendingReset = record
        backupArchiveURL = record.backupName.flatMap { PersistenceStack.zippedBackup(named: $0) }
        // The offered export was built at open, from data that no longer exists — sharing
        // it after a clear would hand back the very thing the user just deleted.
        exportURL = try? DataExport.writeTemporaryFile(in: context)
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
