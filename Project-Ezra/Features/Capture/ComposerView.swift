//
//  ComposerView.swift
//  Project-Ezra
//
//  The global capture point. Two visible affordances only: type or speak — and
//  the parse happens LIVE: candidates appear below the field while the user is
//  still writing (or talking), re-triaged on a short debounce with stale results
//  cancelled. Nothing is gated on confidence; every candidate appears, wrong
//  fields and all, because a visible mistake the user can fix in one tap is
//  cheaper than an item withheld in a queue (no-gating-at-capture decision).
//
//  The single human-in-the-loop moment is the Confirm-Creation card list: every
//  AI-inferred field pre-filled and editable, one CTA to add the batch. Each
//  field edit is diffed against the AI's frozen snapshot at commit and becomes a
//  Correction row — the local learning signal.
//
//  On device, Foundation Models streams partial generation through `onPartial`,
//  so candidates fill in progressively within a single parse. The heuristic
//  engine — what the simulator always runs — is effectively instant, so the felt
//  behavior is live either way. Continuous mid-utterance re-parse remains on the
//  debounce trigger (restarting a generation per keystroke is waste); a
//  continuous session is the future upgrade.
//

import CoreData
import SwiftUI
import UIKit

struct ComposerView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppBrain.self) private var brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Gates the ownership check (see `AppBrain.applyOwnershipGate`), backs the
    /// on-device resolve-person tool — a non-empty roster is what makes "who does
    /// this belong to?" a genuinely open question.
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    private var familyMembers: [FamilyMember] { Array(familyMembersResults) }
    /// The learning loop's inputs: past corrections (+ tasks, for keyword context).
    @FetchRequest(sortDescriptors: []) private var correctionsResults: FetchedResults<Correction>
    @FetchRequest(sortDescriptors: []) private var allTasksResults: FetchedResults<TaskItem>
    private var corrections: [Correction] { Array(correctionsResults) }
    private var allTasks: [TaskItem] { Array(allTasksResults) }

    @State private var text = ""
    @State private var drafts: [TaskDraft] = []
    @State private var committed = 0
    @State private var speech = SpeechCaptureService()
    /// True once dictation contributed to this capture — recorded on the Capture row.
    @State private var usedDictation = false
    /// The text already present when dictation started; live transcript appends to it.
    @State private var dictationBase = ""
    /// Bumped on every transcript change so a stale silence-timeout can no-op itself.
    @State private var silenceGeneration = 0
    /// Bumped on every text change; an in-flight triage that comes back stale drops
    /// its result instead of clobbering fresher candidates.
    @State private var triageGeneration = 0
    @State private var triageTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What's on your mind?")
                    .screenTitleStyle()
                    .padding(.top, Spacing.xs)

                composerField
                    .frame(minHeight: 120, maxHeight: drafts.isEmpty ? 240 : 160)

                dictationHint

                if drafts.isEmpty {
                    Text(
                        "Dump it all — one thing or a whole messy list. Tasks take shape below as you go; fix anything that's off, then add them."
                    )
                    .supportingStyle()
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        ConfirmCreationList(drafts: $drafts)
                            .padding(.top, Spacing.xxs)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }

                footer
            }
            .padding(Spacing.lg)
            .background(Palette.background)
            // Success notification — capture committed is a capstone moment.
            .sensoryFeedback(.success, trigger: committed)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
            // Live transcript flows into the field: base text + everything heard so far.
            .onChange(of: speech.transcript) { _, transcript in
                text = dictationBase + transcript
                if !transcript.isEmpty { usedDictation = true }
                scheduleSilenceStop()
            }
            // The live loop: every text change re-triages after a short debounce.
            .onChange(of: text) { _, _ in
                scheduleTriage()
            }
            .onChange(of: speech.state) { _, state in
                if state == .listening { scheduleSilenceStop() }
            }
            .onDisappear {
                speech.stop()
                triageTask?.cancel()
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Live triage loop

    /// Debounce ~400ms, cancel in-flight, drop stale results. The heuristic path
    /// resolves near-instantly; the on-device model takes a beat — either way the
    /// newest text always wins.
    private func scheduleTriage() {
        triageGeneration += 1
        let generation = triageGeneration
        triageTask?.cancel()

        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else {
            drafts = []
            return
        }

        let roster = rosterSnapshot
        let learned = CorrectionProfile.rules(
            from: corrections.map { $0 }, tasks: allTasks.map { $0 })
        let openTasks = openTaskSnapshots
        triageTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, generation == triageGeneration else { return }
            let result = await brain.triage(
                captured,
                roster: roster,
                learned: learned,
                openTasks: openTasks,
                onPartial: { partial in
                    // Streaming (device): candidates fill in while the model is
                    // still generating. Stale snapshots drop; edits survive merge.
                    guard generation == self.triageGeneration else { return }
                    Motion.withMotion(Motion.settle) {
                        self.drafts = self.merge(fresh: partial, into: self.drafts)
                    }
                }
            )
            guard !Task.isCancelled, generation == triageGeneration else { return }
            // Preserve the user's in-place edits: a re-parse only replaces
            // candidates whose AI reading actually changed.
            Motion.withMotion(Motion.settle) {
                drafts = merge(fresh: result, into: drafts)
            }
        }
    }

    /// The open working set as value snapshots, for reverse dependency detection
    /// ("should anything already open wait on this new task?").
    private var openTaskSnapshots: [OpenTaskSnapshot] {
        let open = allTasks.filter { !$0.status.isResolved }
        return open.compactMap { task in
            guard let id = task.uuid else { return nil }
            // Derive the active blockers ONCE and reuse for both the notes and isBlocked
            // (this used to call activeBlockers + hasActiveBlockers, decoding twice).
            let active = task.activeBlockers(among: open)
            return OpenTaskSnapshot(
                id: id,
                title: task.title,
                externalBlockerNotes: active.filter { $0.kind == .external }.compactMap(\.note),
                category: task.category,
                updatedAt: task.updatedAt,
                dueDate: task.dueDate,
                isBlocked: !active.isEmpty,
                dismissedDuplicateIDs: task.relationships
                    .filter { $0.kind == .duplicate && $0.dismissed }
                    .compactMap(\.targetID)
            )
        }
    }

    /// Household roster as value snapshots (live members only — soft-deleted
    /// people keep attribution but aren't "the household" any more).
    private var rosterSnapshot: [RosterPerson] {
        familyMembers
            .filter { !$0.isRemoved }
            .map { RosterPerson(name: $0.name, relationship: $0.relationship.label) }
    }

    /// Keep an edited card stable across re-parses: match fresh candidates to
    /// existing ones by their AI snapshot; keep the edited version when the AI's
    /// own reading didn't change, adopt the fresh one when it did.
    private func merge(fresh: [TaskDraft], into current: [TaskDraft]) -> [TaskDraft] {
        fresh.map { candidate in
            if let kept = current.first(where: { $0.aiOriginal == candidate.aiOriginal }) {
                return kept
            }
            return candidate
        }
    }

    // MARK: - Footer (the Confirm-Creation moment)

    private var footer: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                commitAll()
            } label: {
                HStack {
                    if brain.isProcessing {
                        Image(systemName: "sparkles")
                            .symbolEffect(.pulse, options: .repeating)
                    }
                    Text(ctaTitle)
                        .font(.ctaLabel)
                }
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    (drafts.isEmpty
                        ? AnyShapeStyle(Palette.secondarySurface)
                        : AnyShapeStyle(Palette.accentGradient)),
                    in: Capsule()
                )
            }
            .buttonStyle(.pressableProminent)
            .disabled(drafts.isEmpty)

            micRow
        }
    }

    private var ctaTitle: String {
        if drafts.isEmpty {
            return brain.isProcessing ? "Sorting…" : "Add tasks"
        }
        return "Add \(drafts.count) task\(drafts.count == 1 ? "" : "s")"
    }

    private func commitAll() {
        guard !drafts.isEmpty else { return }
        speech.stop()
        triageTask?.cancel()
        committed += 1
        let created = brain.commit(
            drafts, rawCapture: text, source: usedDictation ? .voice : .text, into: context)
        // "Add N tasks" IS the Confirm-Creation moment: every field was visible
        // and editable, so the batch moves Inbox → Active here. (A judgment
        // call's Needs Decision flag survives confirm — see `TaskItem.confirm`.)
        for task in created { task.confirm() }
        try? context.save()
        dismiss()
    }

    // MARK: - Field

    private var composerField: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                .fill(Palette.primarySurface)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .strokeBorder(
                            brain.isProcessing
                                ? AnyShapeStyle(Palette.accentGradient)
                                : AnyShapeStyle(Palette.border),
                            lineWidth: brain.isProcessing ? 1.5 : 0.5
                        )
                }
                // Soft glow while the model is thinking.
                .shadow(
                    color: brain.isProcessing ? Palette.accentGlow : .clear,
                    radius: brain.isProcessing ? 16 : 0
                )
                .animation(
                    Motion.glowPulse.repeatWhileTrue(brain.isProcessing), value: brain.isProcessing)

            if text.isEmpty {
                Text(
                    "Renew passport, book dentist, figure out if I should quit the side project, call mom…"
                )
                .foregroundStyle(Palette.mutedText)
                .font(.bodyInput)
                .padding(.horizontal, Spacing.md + 4)
                .padding(.vertical, Spacing.md + 8)
                .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .focused($focused)
                .font(.bodyInput)
                .foregroundStyle(Palette.primaryText)
                .scrollContentBackground(.hidden)
                .padding(Spacing.md)
        }
    }

    // MARK: - Dictation

    private var micRow: some View {
        HStack(spacing: Spacing.sm) {
            micButton
            Spacer(minLength: 0)
        }
    }

    private var micButton: some View {
        let listening = speech.state == .listening
        let active = speech.isActive
        return Button {
            toggleDictation()
        } label: {
            Label(active ? "Listening…" : "Speak instead", systemImage: "mic.fill")
                .font(.controlLabel)
                .foregroundStyle(micTint)
                .padding(.horizontal, Spacing.md)
                .frame(height: 40)
                .background(active ? Palette.accentSoft : Palette.secondarySurface, in: Capsule())
                .shadow(color: active ? Palette.accentGlow : .clear, radius: active ? 12 : 0)
                .symbolEffect(.variableColor, options: .repeating, isActive: listening && !reduceMotion)
        }
        .buttonStyle(.pressable)
        .animation(Motion.glowPulse.repeatWhileTrue(active), value: speech.state)
        .disabled(isMicDisabled)
        .accessibilityLabel(active ? "Stop dictation" : "Dictate")
    }

    private var micTint: Color {
        switch speech.state {
        case .listening, .preparing: return Palette.accentFlat
        case .unavailable: return Palette.mutedText
        default: return Palette.primaryText
        }
    }

    private var isMicDisabled: Bool {
        if case .unavailable = speech.state { return true }
        return false
    }

    @ViewBuilder private var dictationHint: some View {
        switch speech.state {
        case .preparing:
            Text("Getting the mic ready…")
                .metadataStyle()
                .transition(.opacity)
        case .listening:
            Text("Listening — pause and it'll stop on its own.")
                .font(.metadata)
                .foregroundStyle(Palette.accentFlat)
                .transition(.opacity)
        case .denied:
            HStack(spacing: Spacing.xs) {
                Text("Microphone access is off.")
                    .metadataStyle()
                Button("Open Settings") { openSettings() }
                    .font(.metadata.weight(.semibold))
                    .foregroundStyle(Palette.accentFlat)
                    .buttonStyle(.pressableLink)
            }
            .transition(.opacity)
        case .unavailable(let message):
            Text(message)
                .metadataStyle()
                .transition(.opacity)
        default:
            EmptyView()
        }
    }

    private func toggleDictation() {
        if speech.isActive {
            speech.stop()
        } else {
            // Append live transcript after existing text, with a separating space.
            let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dictationBase = base.isEmpty ? "" : base + " "
            Task { await speech.start() }
        }
    }

    /// Auto-stop after ~2.5s of no new transcript, so the user doesn't have to.
    private func scheduleSilenceStop() {
        silenceGeneration += 1
        let generation = silenceGeneration
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if generation == silenceGeneration, speech.state == .listening {
                speech.stop()
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    ComposerView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
