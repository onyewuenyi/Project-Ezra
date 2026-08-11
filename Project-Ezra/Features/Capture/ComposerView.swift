//
//  ComposerView.swift
//  Project-Ezra
//
//  RAMBLE — the core loop, and the product's wow moment. It is NOT an interactive task
//  parser; it is a fast path from messy thought to trusted structure:
//
//      CAPTURE → (submit) → UNDERSTANDING → REVEAL/CONFIRM → CREATE
//
//  The hard invariant, which every decision here serves: **at no point before
//  confirmation may the user see an intermediate AI interpretation presented as truth.**
//  During capture the AI is entirely absent — no parse, no cards, no counts, no
//  classification — because the user owns the conversation while they are still having
//  it. Submit is a deliberate handoff ("got it, I'll take it from here"); the input
//  collapses into one orb; and the reveal presents ONE interpretation.
//
//  The engineering rule that makes that possible: **progressively enrich, never
//  progressively reinterpret.** Structure — how many tasks, in what order — is decided
//  once, at submit, and never changes under the user. The deterministic read is trusted
//  only when it is certain (the user typed the structure, or there is exactly one item);
//  otherwise the model decides while the orb holds the screen. Afterwards the model may
//  improve every card's title and metadata, but it may not re-count or reorder — see
//  `enrich`.
//
//  This replaced a live-parsing composer whose cards appeared, split, merged and
//  vanished while the user typed. That reads as "slow and confused" even when the final
//  answer is excellent: the fix was not to render intermediate states faster but to stop
//  rendering them.
//
import CoreData
import PhotosUI
import SwiftUI
import UIKit

struct ComposerView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppBrain.self) private var brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Backs the owner proposal (see `OwnerProposer`) and the on-device
    /// resolve-person tool. A solo install has nobody to hand work to, so the whole
    /// ownership ladder terminates at the capturer.
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    private var familyMembers: [FamilyMember] { Array(familyMembersResults) }
    /// The learning loop's inputs: past corrections (+ tasks, for keyword context).
    @FetchRequest(sortDescriptors: []) private var correctionsResults: FetchedResults<Correction>
    @FetchRequest(sortDescriptors: []) private var allTasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var profiles: FetchedResults<UserProfile>
    private var corrections: [Correction] { Array(correctionsResults) }
    private var allTasks: [TaskItem] { Array(allTasksResults) }

    /// The delegatable roster for the confirm cards' owner chips — everyone but the
    /// current user, who is the chip's explicit "You" entry. MEMOIZED: the filter +
    /// map + localized SORT ran on every composer body evaluation — every keystroke,
    /// every streamed partial — for a roster that only changes via `addToRoster`
    /// in-session. Refreshed there and at appear.
    @State private var ownerOptions: [String] = []

    /// Every live roster name, YOU included — what `AppBrain.resolveOwners` matches a
    /// draft's `ownerName` against at commit. `ownerOptions` can't serve here: it drops
    /// the current user, so a draft owned by your own named member would render as
    /// "not in household" on a card that commit resolves perfectly well.
    @State private var rosterNames: [String] = []

    private func refreshRosterCaches() {
        let me = profiles.first?.linkedMemberID
        ownerOptions =
            familyMembers
            .filter { !$0.isRemoved && $0.uuid != me }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        rosterNames = familyMembers.filter { !$0.isRemoved }.map(\.name)
    }

    /// Grow the roster from an unresolvable owner chip, so commit can then resolve the
    /// name the card is already showing. This is the "explicit human step" the no-mint
    /// policy in `AppBrain.resolveOwners` points at — a real tap, on a name the user is
    /// looking at, never an inference. Deliberately no sheet: the name is already known,
    /// and everything else about a member (relationship, photo) is editable in Household.
    private func addToRoster(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            !familyMembers.contains(where: {
                !$0.isRemoved && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            })
        else { return }
        let member = FamilyMember(name: trimmed, in: context)
        member.household = Household.current(in: context)
        context.saveChanges()
        refreshRosterCaches()  // the one in-session mutation path
    }

    /// Where in the arc we are. Nothing is parsed in `.capture`; nothing but the orb
    /// shows in `.understanding`; `.confirm` renders one interpretation.
    @State private var phase: RamblePhase = .capture
    /// When submit happened — the clock for the performance contract.
    @State private var submittedAt: Date?
    /// Which producer decided the structure on screen ("local"/"model").
    @State private var structureSource = "local"

    @State private var text = ""
    @State private var drafts: [TaskDraft] = []
    /// The cards the user deleted this session. The merge filters re-proposals of
    /// them, so a removal can't be undone by the next keystroke's re-parse.
    @State private var removedDrafts = RemovedDraftSet()
    @State private var committed = 0
    @State private var speech = SpeechCaptureService()
    /// True once dictation contributed to this capture — recorded on the Capture row.
    @State private var usedDictation = false
    /// Image capture V1 (library → OCR → the normal text pipeline). The photo's
    /// bytes live as a container file; `capturedImageRef` is what `Capture.imageRef`
    /// persists. `usedImage` feeds provenance the same way `usedDictation` does.
    @State private var photoItem: PhotosPickerItem?
    @State private var capturedImageRef: String?
    @State private var capturedThumb: UIImage?
    @State private var usedImage = false
    /// True while a picked photo is being read — the image button's busy state.
    @State private var readingImage = false
    /// The text already present when dictation started; live transcript appends to it.
    @State private var dictationBase = ""
    /// Live-parse bookkeeping in a reference box, NOT observable on purpose: these
    /// values mutate on every keystroke and transcript delta, and as plain `@State`
    /// each mutation bought a redundant view invalidation — nothing in `body` reads
    /// them. `@State` here only pins the box's lifetime to the view's.
    @State private var parse = LiveParseState()
    /// The user's past "no"s, loaded once per composer session — they only change at commit
    /// (which writes new `SuppressionRecord`s and dismisses). Loading also lazily prunes
    /// expired/orphaned rows, so caching keeps that off the per-keystroke path.
    @State private var loadedSuppressions: [RelationshipSuppression]?
    /// The durable row behind this session. Created at PARSE time, not commit time, so
    /// dismissing the sheet parks the thought instead of destroying it. Adopted by
    /// `commit` on confirm; deleted only by an explicit Discard.
    @State private var parked: Capture?
    /// The capture this session restored from, if any — so reopening resumes rather
    /// than starting a second parked row for the same thought.
    private let resuming: Capture?
    @State private var showDiscardConfirm = false
    /// The text the last COMPLETED parse ran against. Only when this matches what's in the
    /// field do we know an empty `drafts` means "the engine found nothing here" rather than
    /// "it hasn't looked yet" — the difference between an honest message and a lie.
    @State private var lastParsedText: String?
    /// Whether the last completed parse returned any candidates at all, before the
    /// session's removals filtered them. The honest input to `foundNothing`.
    @State private var lastParseYieldedCandidates = false
    /// When the silence auto-stop will fire — rescheduled on every transcript delta,
    /// nil outside dictation. The hero bar renders its last stretch as a draining ring.
    @State private var silenceDeadline: Date?
    /// The small mic capsule and the listening hero share this morph.
    @Namespace private var voiceMorph
    /// The one object the whole arc transforms through: field → orb → composition.
    @Namespace private var rambleMorph
    static let rambleMorphID = "ramble"
    /// Set when the orb has been holding long enough that silence would read as stuck.
    @State private var showReassurance = false
    @FocusState private var focused: Bool

    init(resuming: Capture? = nil) {
        self.resuming = resuming
    }

    var body: some View {
        NavigationStack {
            // Tighter once candidates exist: every point of vertical spacing here is a
            // point the card can't use to show a field.
            VStack(alignment: .leading, spacing: Spacing.md) {
                switch phase {
                case .capture: captureSurface
                case .understanding: understandingSurface
                case .confirm: confirmSurface
                case .created(let count): createdSurface(count)
                }
            }
            .padding(Spacing.lg)
            .background(Palette.background)
            // Tap the empty space to put the keyboard away. Without this there was no
            // way out of it at all when a parse produced no cards: the only
            // keyboard-dismissing scroll view is the draft list, which doesn't exist
            // then, and dragging the sheet dismisses the whole composer. Children
            // (field, chips, buttons) take their own taps first, so this only ever
            // catches the space between them.
            .contentShape(Rectangle())
            .onTapGesture { focused = false }
            // Success notification — capture committed is a capstone moment.
            .sensoryFeedback(.success, trigger: committed)
            // Dictation start/stop is felt, not just seen — the trigger is the state
            // edge, so the auto-stop lands the same haptic as a tap.
            .sensoryFeedback(.impact(weight: .medium), trigger: speech.state == .listening)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Cancel is a real choice, because swiping away no longer destroys
                    // anything. From the reveal, "Back" returns to the canvas with the
                    // words intact — nothing has been committed yet.
                    switch phase {
                    case .capture where text.isEmpty:
                        Button("Cancel") { dismiss() }
                    case .capture:
                        Button("Discard", role: .destructive) { showDiscardConfirm = true }
                    case .understanding, .confirm:
                        Button("Back") { backToCapture() }
                    case .created:
                        EmptyView()
                    }
                }
            }
            .onAppear {
                focused = true
                refreshRosterCaches()
                restoreIfResuming()
                // Verification seam: a resumed capture from `-OpenCapture` submits itself
                // so the understanding/reveal phases are screenshot-reachable headlessly
                // (synthetic taps are blocked on this host). `-NoSubmit` stays on the
                // canvas for the capture-phase shot. Never fires in normal runs.
                #if DEBUG
                    if resuming != nil, !text.isEmpty,
                        !ProcessInfo.processInfo.arguments.contains("-NoSubmit")
                    {
                        Task {
                            try? await Task.sleep(for: .milliseconds(250))
                            submit()
                        }
                    }
                #endif
            }
            // The orb's reassurance line — long work must read as calm, never as stuck.
            .onChange(of: phase) { _, newPhase in
                showReassurance = false
                guard newPhase == .understanding else { return }
                Task {
                    try? await Task.sleep(for: .seconds(Self.reassuranceAfterSeconds))
                    guard phase == .understanding else { return }
                    Motion.withMotion(Motion.fade) { showReassurance = true }
                }
            }
            // Live transcript flows into the field: base text + everything heard so far.
            .onChange(of: speech.transcript) { _, transcript in
                // Only write when the value actually moves: starting the mic resets
                // the transcript to empty, which used to re-assign the same text
                // (minus trailing whitespace) and kick off a full re-parse before a
                // single word had been spoken.
                let next = dictationBase + transcript
                if next != text { text = next }
                if !transcript.isEmpty { usedDictation = true }
                scheduleSilenceStop()
            }
            // Nothing happens here on purpose. During capture the user owns the
            // conversation and the AI stays quiet: no parse, no cards, no counts, no
            // classification. The system gets to work at submit, and not before.
            .onChange(of: text) { _, _ in
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let parked
                {
                    // The thought was erased; parking must not keep advertising it.
                    AppBrain.discard(parked, in: context)
                    self.parked = nil
                }
            }
            .onChange(of: speech.state) { _, state in
                if state == .listening { scheduleSilenceStop() } else { silenceDeadline = nil }
                // Voice and keyboard are one channel at a time: focus drops while the
                // mic is live (a retained keyboard could still type into the field the
                // transcript is about to rewrite) and returns when dictation ends, so
                // the hand-off back to typing is seamless.
                if speech.isActive {
                    focused = false
                } else if state == .idle {
                    focused = true
                }
            }
            .onDisappear {
                speech.stop()
                parse.silenceTask?.cancel()
                parse.parseTask?.cancel()
                // The backstop that makes this whole phase worth having: a swipe-down,
                // a phone call, anything that tears the sheet down mid-thought leaves
                // the raw text and every edited draft on disk.
                parkIfUnfinished(force: true)
            }
            .confirmationDialog(
                "Discard this capture?", isPresented: $showDiscardConfirm, titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { discard() }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("The text and everything parsed from it will be deleted.")
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Empty states

    private static let openingHint =
        "Dump it all — one thing or a whole messy list. Tasks take shape below as you go; fix anything that's off, then add them."
    private static let nothingFoundHint =
        "Nothing actionable in that yet. Try phrasing it as something to do — “call the dentist”, “decide about the gym” — and it'll take shape here."

    // MARK: - The Ramble arc: submit → understand → reveal

    /// Which stage of the arc is on screen. The whole point of the phase machine is the
    /// hard invariant: **at no point before confirmation may the user see an intermediate
    /// AI interpretation presented as truth.** During `.capture` nothing is parsed at all;
    /// during `.understanding` nothing is shown but the orb; `.confirm` renders one
    /// interpretation whose STRUCTURE never changes again.
    enum RamblePhase: Equatable {
        case capture
        case understanding
        case confirm
        case created(Int)
    }

    /// How long the ✓ receipt holds before the sheet closes.
    private static let createdReceiptSeconds: TimeInterval = 0.9
    /// When "still working" reassurance joins the orb, so a long ramble reads as calm
    /// rather than stuck. Deliberately not a progress affordance.
    static let reassuranceAfterSeconds: TimeInterval = 8

    /// Submit — the deliberate handoff. "Got it, I'll take it from here."
    ///
    /// Structure is decided HERE and never changes again. The deterministic read is
    /// trusted only when it is certain (the user typed the structure, or there is exactly
    /// one item); otherwise the model decides and the orb holds the screen until it
    /// answers. Either way the user never watches boundaries move.
    private func submit() {
        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return }
        focused = false
        speech.stop()
        let local = AppBrain.provisionalDrafts(captured, learned: sessionRules())
        let trusted = Segmentation.structureIsCertain(captured) && !local.isEmpty
        submittedAt = Date()

        if trusted {
            // Certain structure — reveal at once. This is how the common cases meet
            // "submit → stable confirmation" without waiting on generation.
            drafts = local
            structureSource = "local"
            Motion.withMotion(Motion.heroSettle) { phase = .confirm }
            recordConfirmReached()
        } else {
            structureSource = "model"
            Motion.withMotion(Motion.heroSettle) { phase = .understanding }
        }
        parkIfUnfinished(force: true)
        runParse(captured, revealWhenDone: !trusted)
    }

    /// The ONE model parse a capture gets. When the reveal is already on screen this
    /// only ENRICHES the stable set (never re-counts, never reorders); when the orb is
    /// holding, its result is what reveals.
    private func runParse(_ captured: String, revealWhenDone: Bool) {
        parse.parseTask?.cancel()
        parse.parseTask = Task {
            let roster = rosterSnapshot
            let learned = sessionRules()
            let openTasks = openTaskSnapshots
            let suppressions = sessionSuppressions()
            let ownership = ownershipSnapshot
            EmbeddingStore.warmUp(openTaskIDs: Set(openTasks.map(\.id)), in: context)
            // No partial handler: streamed snapshots would expose structure growing,
            // which is the whole thing this architecture exists to prevent. The
            // deadline's salvage still applies — it becomes the timeout path into
            // the reveal.
            let result = await brain.triage(
                captured, roster: roster, learned: learned, openTasks: openTasks,
                suppressions: suppressions, ownership: ownership)
            guard !Task.isCancelled else { return }
            parse.parseTask = nil
            EmbeddingStore.persistFresh(openTasks: openTasks, in: context)
            lastParsedText = captured
            lastParseYieldedCandidates = !result.drafts.isEmpty

            if revealWhenDone {
                // The model decides the structure; if it found nothing, the
                // deterministic read is the honest fallback rather than an empty screen.
                let final =
                    result.drafts.isEmpty
                    ? AppBrain.provisionalDrafts(captured, learned: learned) : result.drafts
                drafts = merge(fresh: final, into: drafts)
                Motion.withMotion(Motion.heroSettle) { phase = .confirm }
                recordConfirmReached()
            } else {
                // ENRICHMENT ONLY. The shown structure wins: the model may improve every
                // card's title and metadata, but it may not change how many there are or
                // what order they are in.
                enrich(with: result.drafts)
            }
            parkIfUnfinished(force: true)
        }
    }

    /// Fill metadata onto the revealed set without reinterpreting it. Cards the model
    /// didn't claim keep what they have; model drafts that claim nothing are dropped and
    /// counted, so local-vs-model structural disagreement is visible rather than guessed.
    private func enrich(with fresh: [TaskDraft]) {
        guard !fresh.isEmpty else { return }
        let before = drafts
        let merged = merge(fresh: fresh, into: before)
        // The invariant, enforced at the seam rather than trusted: enrichment may not
        // change the count or the order of what the user is already reading.
        let kept = before.map { existing in
            merged.first(where: { $0.id == existing.id }) ?? existing
        }
        if merged.count != before.count {
            ModelMetrics.shared.recordStructureDisagreement()
        }
        Motion.withMotion(Motion.fade) { drafts = kept }
        if let submittedAt {
            ModelMetrics.shared.recordEnrichment(
                latencyMs: Int(Date().timeIntervalSince(submittedAt) * 1000))
        }
    }

    private func recordConfirmReached() {
        guard let submittedAt else { return }
        ModelMetrics.shared.recordConfirmReached(
            latencyMs: Int(Date().timeIntervalSince(submittedAt) * 1000),
            source: structureSource)
    }

    /// Back to the canvas with the words intact — nothing has been committed.
    private func backToCapture() {
        parse.parseTask?.cancel()
        parse.parseTask = nil
        Motion.withMotion(Motion.settle) { phase = .capture }
        focused = true
    }

    /// The learned-correction rules, built once per composer session. Correction rows
    /// are only written at commit, which dismisses the session — so every parse of a
    /// session sees identical rules, and rebuilding them per parse (a pass over all
    /// corrections and tasks with a reflection sort) was pure spike on the pause path.
    private func sessionRules() -> [LearnedRule] {
        if let cached = parse.cachedRules { return cached }
        let rules = CorrectionProfile.rules(from: corrections.map { $0 }, tasks: allTasks.map { $0 })
        parse.cachedRules = rules
        return rules
    }

    /// The open working set as value snapshots, for reverse dependency detection
    /// ("should anything already open wait on this new task?"). Served by the
    /// change-invalidated cache — rolling parses read this per chained parse, and
    /// rebuilding an identical set each time was the audit's A3.
    private var openTaskSnapshots: [OpenTaskSnapshot] {
        OpenTaskSnapshotCache.shared.snapshots(in: context)
    }

    /// The session's suppression set — loaded (and pruned) once, then reused for every
    /// re-parse. Invalidated at commit, which is also when new records are written.
    private func sessionSuppressions() -> [RelationshipSuppression] {
        if let cached = loadedSuppressions { return cached }
        let loaded = SuppressionStore.load(
            in: context, existingTaskIDs: Set(allTasks.compactMap(\.uuid)))
        loadedSuppressions = loaded
        return loaded
    }

    /// Household roster as value snapshots (live members only — soft-deleted
    /// people keep attribution but aren't "the household" any more).
    private var rosterSnapshot: [RosterPerson] {
        familyMembers
            .filter { !$0.isRemoved }
            .map { RosterPerson(name: $0.name, relationship: $0.relationship.label) }
    }

    /// Everything `OwnerProposer` needs, snapshotted as values so the proposer stays a
    /// pure function. Empty on a solo install, which makes the whole feature a no-op.
    private var ownershipSnapshot: OwnershipContext {
        // Dead work until sync ships: `OwnerProposer.propose` bails to `.mine` before
        // reading any of this while `HouseholdSync.isLive` is false (the spoken-name
        // rung reads the draft, not this context) — so the three full passes over
        // every task below fed a ladder that never looked at them, per parse.
        guard HouseholdSync.isLive else { return .none }
        let me = profiles.first?.linkedMemberID
        let others = familyMembers.filter { !$0.isRemoved && $0.uuid != me }
        guard !others.isEmpty else { return .none }

        let namesByID = Dictionary(uniqueKeysWithValues: others.map { ($0.uuid, $0.name) })
        // Loads count LIVE, workload-counting tasks only — the same basis as
        // `MemberLoad.activeCount`, so a shelf of reference notes can't make someone
        // read as overloaded and stop receiving proposals.
        let live = allTasks.filter { $0.status.isLive }
        let counts = live.reduce(into: [UUID: Int]()) { totals, task in
            if let owner = task.ownerID { totals[owner, default: 0] += 1 }
        }
        let plates = others.map { counts[$0.uuid] ?? 0 }.sorted()
        let median = plates.isEmpty ? 0 : plates[plates.count / 2]

        let candidates = others.map { member in
            let count = counts[member.uuid] ?? 0
            return OwnerCandidate(
                memberID: member.uuid, name: member.name, activeCount: count,
                isOverloaded: count >= 4 && count >= median * 2)
        }
        // History spans EVERY task, resolved included — how work has been divided is a
        // longer-running fact than what is open right now.
        let history = allTasks.compactMap { task -> OwnerHistoryEntry? in
            guard let owner = task.ownerID, let name = namesByID[owner]
            else { return nil }
            return OwnerHistoryEntry(
                category: task.category, ownerName: name,
                isHumanEstablished: task.ownerOrigin == .human)
        }
        let ownersByTaskID = allTasks.reduce(into: [UUID: String]()) { map, task in
            if let id = task.uuid, let owner = task.ownerID, let name = namesByID[owner] {
                map[id] = name
            }
        }
        return OwnershipContext(
            candidates: candidates, history: history, ownersByTaskID: ownersByTaskID)
    }

    /// Keep cards stable across re-parses and streaming partials: `DraftMerge`
    /// matches by the AI's reading of the line, transplants identity, re-applies
    /// the user's edits over the fresh values, and honors the session's removals.
    private func merge(
        fresh: [TaskDraft], into current: [TaskDraft], keepingUnmatched: Bool = false
    ) -> [TaskDraft] {
        DraftMerge.merge(
            fresh: fresh, into: current, removed: removedDrafts,
            keepingUnmatched: keepingUnmatched)
    }

    // MARK: - The four surfaces

    /// CAPTURE — a thought canvas, not a task field. The AI is entirely absent here.
    @ViewBuilder private var captureSurface: some View {
        Text("What's on your mind?")
            .screenTitleStyle()
            .padding(.top, Spacing.xs)
        Text("Dump it all here. I'll sort it out.")
            .supportingStyle()

        imageChip
        composerField
            .frame(minHeight: 120, maxHeight: 280)
            .matchedGeometryEffect(id: Self.rambleMorphID, in: rambleMorph)

        dictationHint
            .animation(Motion.fade, value: speech.state)

        Spacer(minLength: 0)

        VStack(spacing: Spacing.sm) {
            rambleButton
            voiceOrMicRow
        }
    }

    /// The submit affordance — the deliberate handoff.
    private var rambleButton: some View {
        Button { submit() } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkle")
                Text("Ramble").font(.ctaLabel)
            }
            .foregroundStyle(
                canSubmit ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(Palette.mutedText)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                canSubmit
                    ? AnyShapeStyle(Palette.accentGradient)
                    : AnyShapeStyle(Palette.secondarySurface),
                in: Capsule()
            )
        }
        .buttonStyle(.pressableProminent)
        .disabled(!canSubmit)
        .accessibilityLabel("Ramble — turn what you wrote into tasks")
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !readingImage
    }

    /// UNDERSTANDING — one calm object. No spinner, no progress, no counts, no
    /// candidate titles: the engine may revise its interpretation arbitrarily behind
    /// this and the screen must not move.
    @ViewBuilder private var understandingSurface: some View {
        Spacer(minLength: 0)
        VStack(spacing: Spacing.lg) {
            RambleOrb()
                .matchedGeometryEffect(id: Self.rambleMorphID, in: rambleMorph)
            Text("Making sense of it")
                .font(.sectionHeader)
                .foregroundStyle(Palette.primaryText)
            if showReassurance {
                Text("Still working — that was a big one.")
                    .metadataStyle()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Making sense of what you wrote")
        Spacer(minLength: 0)
    }

    /// REVEAL / CONFIRM — the answer, as one composition. Tasks own the viewport.
    @ViewBuilder private var confirmSurface: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(drafts.isEmpty ? "Nothing actionable in that" : "Here's what I understood")
                .screenTitleStyle()
            if !drafts.isEmpty {
                Text(drafts.count == 1 ? "1 thing" : "\(drafts.count) things")
                    .supportingStyle()
            }
        }
        .padding(.top, Spacing.xs)
        .matchedGeometryEffect(id: Self.rambleMorphID, in: rambleMorph)

        if drafts.isEmpty {
            Text(Self.nothingFoundHint).supportingStyle()
            Spacer(minLength: 0)
        } else {
            ScrollView {
                ConfirmCreationList(
                    drafts: $drafts,
                    ownerOptions: ownerOptions,
                    rosterNames: rosterNames,
                    onAddToRoster: { addToRoster($0) },
                    onRemove: { removedDrafts.record($0) }
                )
                .padding(.top, Spacing.xxs)
            }
        }

        VStack(spacing: Spacing.sm) {
            Button { createTasks() } label: {
                Text(createTitle)
                    .font(.ctaLabel)
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Palette.accentGradient, in: Capsule())
            }
            .buttonStyle(.pressableProminent)
            .disabled(drafts.isEmpty)

            Button("Add another") { backToCapture() }
                .font(.controlLabel)
                .foregroundStyle(Palette.secondaryText)
                .frame(height: LayoutMetrics.hitTarget)
                .buttonStyle(.pressableLink)
        }
    }

    private var createTitle: String {
        drafts.count == 1 ? "Create 1 task" : "Create \(drafts.count) tasks"
    }

    /// DONE — a short, satisfying receipt, then back to whatever the user was doing.
    @ViewBuilder private func createdSurface(_ count: Int) -> some View {
        Spacer(minLength: 0)
        VStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.glyphDisplay(.semibold))
                .foregroundStyle(Palette.accentFlat)
                .transition(.scale.combined(with: .opacity))
            Text(count == 1 ? "1 task added" : "\(count) tasks added")
                .font(.sectionHeader)
                .foregroundStyle(Palette.primaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        Spacer(minLength: 0)
    }

    /// The voice hero / mic row, unchanged in behavior — capture keeps both input modes.
    @ViewBuilder private var voiceOrMicRow: some View {
        if speech.isActive {
            VoiceHeroBar(
                monitor: speech.audioLevel,
                silenceDeadline: silenceDeadline,
                silenceWindow: Self.silenceStopSeconds,
                onStop: { toggleDictation() }
            )
            .matchedGeometryEffect(id: "voice", in: voiceMorph)
        } else {
            micRow
                .matchedGeometryEffect(id: "voice", in: voiceMorph)
        }
    }


    /// Speak the outcome of a completed parse. The composer's whole promise is that
    /// candidates appear as you talk — visible motion a screen-reader user got no
    /// version of, so the live surface was silent to them. Announced on COMPLETED
    /// parses only (never per streamed partial), so it informs instead of chattering.
    /// A no-op when VoiceOver is off.
    private func announceParseResult() {
        let message: String
        if drafts.isEmpty {
            guard lastParseYieldedCandidates == false else { return }
            message = "Nothing actionable found yet."
        } else {
            message = "\(drafts.count) task\(drafts.count == 1 ? "" : "s") ready to review."
        }
        AccessibilityNotification.Announcement(message).post()
    }

    /// Persist the in-flight capture. Called on dismiss (`force`, always writes) and
    /// after each completed parse — throttled there, because rolling parses complete
    /// far more often than the old at-pause cadence and each park is an O(capture)
    /// encode plus a synchronous save. The thought is never at risk for longer than
    /// the throttle window, and the drafts are derived (resume re-parses `rawText`).
    /// One provenance rule: voice outranks image outranks typing. Dictation is the
    /// flagship input, and `.image` claims exactly the captures whose words came
    /// from a photo without speech.
    private var captureSource: CaptureSource {
        usedDictation ? .voice : (usedImage ? .image : .text)
    }

    private func parkIfUnfinished(force: Bool = false) {
        guard !drafts.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        parse.lastParkAt = Date()
        parked = brain.park(
            drafts, rawCapture: text, source: captureSource, imageRef: capturedImageRef,
            into: parked, in: context)
    }

    /// Resume a parked capture: its verbatim text and its edited drafts, exactly as
    /// they were left. A payload that can no longer be decoded (a `TaskDraft` shape
    /// change) falls back to re-parsing from `rawText` — the raw text is irreplaceable,
    /// the drafts are derived.
    private func restoreIfResuming() {
        // A resume target must be a LIVE, still-parked row. A committed row is spent
        // (resuming it would re-parse text that already became tasks) and a deleted
        // row is a fault waiting to crash — either way the honest degrade is a fresh
        // capture, which is what the presenting button intended.
        guard let resuming, parked == nil,
            resuming.managedObjectContext != nil, !resuming.isDeleted, resuming.isParked
        else { return }
        parked = resuming
        text = resuming.rawText
        // A parked image capture restores its photo chip with its words.
        if let ref = resuming.imageRef,
            let image = UIImage(contentsOfFile: CaptureImageStore.url(for: ref).path)
        {
            capturedImageRef = ref
            capturedThumb = image
            usedImage = true
        }
        // A resumed capture lands in CAPTURE with its words, awaiting a fresh submit.
        // Resuming is not re-deciding: the user re-reads what they wrote and rambles
        // again, rather than being handed an interpretation they never asked for twice.
        drafts = []
    }

    private func discard() {
        speech.stop()
        parse.parseTask?.cancel()
        parse.parseTask = nil
        // Discard is the one destructive path — the photo goes with the thought.
        if let ref = capturedImageRef { CaptureImageStore.delete(ref) }
        capturedImageRef = nil
        if let parked { AppBrain.discard(parked, in: context) }
        parked = nil
        drafts = []
        removedDrafts = RemovedDraftSet()
        text = ""
        dismiss()
    }

    /// CREATE — the only place tasks come into existence. Nothing before this wrote to
    /// the store, which is what makes the whole arc safe to iterate behind.
    private func createTasks() {
        guard !drafts.isEmpty else { return }
        speech.stop()
        parse.parseTask?.cancel()
        parse.parseTask = nil
        let count = drafts.count
        committed += 1
        brain.commit(
            drafts, rawCapture: text, source: captureSource, imageRef: capturedImageRef,
            parked: parked, into: context)
        // Clearing is REQUIRED, not tidiness: `.onDisappear` runs `parkIfUnfinished`,
        // and it keys off `drafts`/`text` — leaving them populated would park a phantom
        // duplicate of the capture just committed.
        parked = nil
        drafts = []
        removedDrafts = RemovedDraftSet()
        text = ""
        loadedSuppressions = nil  // commit wrote new rejections — the session cache is stale
        parse.cachedRules = nil  // likewise new corrections
        // A short, satisfying receipt, then back to whatever the user was doing —
        // capture is something you do mid-life, not a place you go.
        Motion.withMotion(Motion.heroSettle) { phase = .created(count) }
        Task {
            try? await Task.sleep(for: .seconds(Self.createdReceiptSeconds))
            dismiss()
        }
    }

    // MARK: - Field

    private var composerField: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                .fill(Palette.primarySurface)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .strokeBorder(
                            fieldIsLive
                                ? AnyShapeStyle(Palette.accentGradient)
                                : AnyShapeStyle(Palette.border),
                            lineWidth: fieldIsLive ? 1.5 : 0.5
                        )
                }
                // Soft glow while the model is thinking — and while the mic is hot:
                // the field is where the words land, so it participates in listening.
                .shadow(
                    color: fieldIsLive ? Palette.accentGlow : .clear,
                    radius: fieldIsLive ? 16 : 0
                )
                .animation(Motion.glowPulse.repeatWhileTrue(fieldIsLive), value: fieldIsLive)

            if text.isEmpty && !speech.isActive {
                Text(
                    "Renew passport, book dentist, figure out if I should quit the side project, call mom…"
                )
                .foregroundStyle(Palette.mutedText)
                .font(.bodyInput)
                .padding(.horizontal, Spacing.md + 4)
                .padding(.vertical, Spacing.md + 8)
                .allowsHitTesting(false)
            }

            if speech.isActive {
                // The live transcript, honest about what's settled: finalized words in
                // primary, the in-flight hypothesis in muted — the field is already
                // non-interactive while the mic owns it, so a read-only surface swap
                // loses nothing and gains the two-tone truth. Same font and padding
                // tokens as the editor so the crossfade holds its geometry.
                ScrollView {
                    Text(listeningTranscript)
                        .font(.bodyInput)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                }
                .defaultScrollAnchor(.bottom)
                .padding(Spacing.md)
                .accessibilityLabel("Live transcript")
            } else {
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.bodyInput)
                    .foregroundStyle(Palette.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.md)
                    // The field is the product's front door and it was unlabeled —
                    // VoiceOver read only the (long, example-laden) placeholder.
                    .accessibilityLabel("What's on your mind")
                    .accessibilityHint(
                        "Type or dictate anything. Tasks take shape below as you go.")
            }
        }
        .animation(Motion.fade, value: speech.isActive)
    }

    /// The field participates in both live states: the model reading, or the mic hot.
    private var fieldIsLive: Bool { brain.isProcessing || speech.state == .listening }

    /// Settled words (typed base + finalized speech) in primary; the in-flight
    /// hypothesis in muted — visually honest about what may still be revised.
    private var listeningTranscript: AttributedString {
        var settled = AttributedString(dictationBase + speech.finalizedText)
        settled.foregroundColor = Palette.primaryText
        var volatile = AttributedString(speech.volatileText)
        volatile.foregroundColor = Palette.mutedText
        return settled + volatile
    }

    // MARK: - Dictation

    private var micRow: some View {
        HStack(spacing: Spacing.sm) {
            micButton
            imageButton
            Spacer(minLength: 0)
        }
    }

    /// Capture by photo — the third input mode. Library-only in V1 (`PhotosPicker`
    /// is out-of-process, so no privacy prompt); the live camera is the recorded
    /// fast-follow. Recognized text streams into the SAME field the keyboard and
    /// the mic feed, so the rolling parse needs no new path.
    private var imageButton: some View {
        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
            Label(readingImage ? "Reading…" : "Add a photo", systemImage: "photo")
                .font(.controlLabel)
                .foregroundStyle(readingImage ? Palette.accentFlat : Palette.primaryText)
                .padding(.horizontal, Spacing.md)
                .frame(height: 40)
                .background(
                    readingImage ? Palette.accentSoft : Palette.secondarySurface, in: Capsule()
                )
                .frame(minHeight: LayoutMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(readingImage)
        .accessibilityLabel("Add a photo of a list or note")
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                await ingestPhoto(item)
                photoItem = nil
            }
        }
    }

    /// Photo → file → thumbnail → OCR → the field. Losing any stage keeps the
    /// earlier ones: a failed OCR still shows the thumbnail (the user sees the
    /// photo landed and can type what it said); a failed file write still runs OCR
    /// (the words must never be lost to a disk hiccup).
    private func ingestPhoto(_ item: PhotosPickerItem) async {
        readingImage = true
        defer { readingImage = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data), let cgImage = image.cgImage
        else { return }
        if let previous = capturedImageRef { CaptureImageStore.delete(previous) }
        capturedImageRef = CaptureImageStore.save(data)
        capturedThumb = image
        usedImage = true
        let recognized = (try? await ImageTextExtractor.text(from: cgImage)) ?? ""
        guard !recognized.isEmpty else { return }
        // Entering through `text` is the whole design: onChange → the rolling parse.
        text = text.isEmpty ? recognized : text + "\n" + recognized
    }

    /// The picked photo, disclosed above the field — provenance the user can see
    /// and remove. Removing the chip deletes the FILE and the provenance; the
    /// recognized words stay in the field, where they are already the user's text.
    @ViewBuilder private var imageChip: some View {
        if let capturedThumb {
            HStack(spacing: Spacing.xs) {
                Image(uiImage: capturedThumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                Button {
                    if let ref = capturedImageRef { CaptureImageStore.delete(ref) }
                    capturedImageRef = nil
                    self.capturedThumb = nil
                    usedImage = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: LayoutMetrics.hitTarget, height: LayoutMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressableIcon)
                .accessibilityLabel("Remove the photo")
                Spacer(minLength: 0)
            }
            .transition(.opacity)
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
                // Visual capsule stays 40pt; the TOUCHABLE region meets the HIG
                // minimum — this is the flagship input mode's primary control,
                // tapped at arm's length while multitasking.
                .frame(minHeight: LayoutMetrics.hitTarget)
                .contentShape(Rectangle())
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
            Text("Listening — pause to finish, or tap stop to edit by hand.")
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
            parse.silenceTask?.cancel()
            speech.stop()
        } else {
            // Append live transcript after existing text, with a separating space.
            let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dictationBase = base.isEmpty ? "" : base + " "
            Task { await speech.start() }
        }
    }

    /// How long a transcript silence runs before dictation stops itself. Generous on
    /// purpose: the product's core scenario is a RAMBLE — an overloaded person thinking
    /// out loud — and thinking pauses routinely pass 2.5s, which is where the old
    /// window sat; it cut people off mid-thought and the tail of the ramble was gone.
    private static let silenceStopSeconds: Double = 5

    /// Auto-stop after a stretch of no new transcript, so the user doesn't have to.
    /// ONE cancellable handle, cancel-and-replace per delta — the old shape spawned an
    /// uncancelled sleeping Task per transcript tick, unbounded by design. The
    /// deadline is published so the hero bar can make the last stretch VISIBLE —
    /// the silent cut-off was the old design's worst dictation sin.
    private func scheduleSilenceStop() {
        parse.silenceTask?.cancel()
        silenceDeadline = Date().addingTimeInterval(Self.silenceStopSeconds)
        parse.silenceTask = Task {
            try? await Task.sleep(for: .seconds(Self.silenceStopSeconds))
            guard !Task.isCancelled, speech.state == .listening else { return }
            speech.stop()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// One quiet line on the fallback path, honesty-first: on-device and rules-engine
    /// captures produce visibly different cards (proposals, streaming, the "?" state
    /// exist only on-device), and without this the user's only signal was a DEBUG
    /// footer — degradation read as inconsistency. Suppressed under XCTest so view
    /// tests don't all sprout an extra line.
    ///
    /// It annotates RESULTS, never the empty field. Greeting every capture with it
    /// put a caveat ahead of the instruction that actually helps someone start typing,
    /// and repeated a standing device condition as if it were news — the nagging the
    /// guardrails refuse. Beside the cards it explains something the user can see.
    @ViewBuilder private var engineDisclosure: some View {
        if case .fallback(let reason) = brain.status, reason != "test" {
            Text("On-device intelligence unavailable — using quick rules.")
                .metadataStyle()
        }
    }
}

/// The composer's per-keystroke bookkeeping: the debounce generation and the two
/// in-flight tasks. A plain reference type, deliberately NOT `@Observable` — these
/// mutate on every keystroke and transcript delta, and nothing in the view's `body`
/// reads them, so observing them only bought a redundant render pass per event.
final class LiveParseState {
    /// The one parse a submitted capture gets. Cancelled by Back, Discard and Create.
    var parseTask: Task<Void, Never>?
    /// The learned-correction rules for this session (see `sessionRules`).
    var cachedRules: [LearnedRule]?
    /// The last park write, so the durable row is updated rather than duplicated.
    var lastParkAt: Date?
    /// The single silence-timeout in flight; cancelled and replaced on every
    /// transcript delta, cancelled outright on stop/disappear.
    var silenceTask: Task<Void, Never>?
}

#Preview {
    ComposerView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
