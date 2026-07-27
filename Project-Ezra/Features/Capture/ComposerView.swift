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
    /// current user, who is the chip's explicit "You" entry. Computed once here and
    /// passed down as values, so cards don't each own live fetch controllers.
    private var ownerOptions: [String] {
        let me = profiles.first?.linkedMemberID
        return
            familyMembers
            .filter { !$0.isRemoved && $0.uuid != me }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Every live roster name, YOU included — what `AppBrain.resolveOwners` matches a
    /// draft's `ownerName` against at commit. `ownerOptions` can't serve here: it drops
    /// the current user, so a draft owned by your own named member would render as
    /// "not in household" on a card that commit resolves perfectly well.
    private var rosterNames: [String] {
        familyMembers.filter { !$0.isRemoved }.map(\.name)
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
    }

    @State private var text = ""
    @State private var drafts: [TaskDraft] = []
    /// The cards the user deleted this session. The merge filters re-proposals of
    /// them, so a removal can't be undone by the next keystroke's re-parse.
    @State private var removedDrafts = RemovedDraftSet()
    @State private var committed = 0
    @State private var speech = SpeechCaptureService()
    /// True once dictation contributed to this capture — recorded on the Capture row.
    @State private var usedDictation = false
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
    @FocusState private var focused: Bool

    init(resuming: Capture? = nil) {
        self.resuming = resuming
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What's on your mind?")
                    .screenTitleStyle()
                    .padding(.top, Spacing.xs)

                composerField
                    .frame(minHeight: 120, maxHeight: drafts.isEmpty ? 240 : 160)
                    // The field yields room to the cards it produced — but it EASES
                    // instead of snapping. It used to lose 80pt in one frame the
                    // instant the first candidate landed, resizing under the cursor
                    // of someone still mid-sentence.
                    .animation(reduceMotion ? nil : Motion.settle, value: drafts.isEmpty)

                dictationHint
                engineDisclosure

                if drafts.isEmpty {
                    Text(foundNothing ? Self.nothingFoundHint : Self.openingHint)
                        .supportingStyle()
                        .animation(Motion.fade, value: foundNothing)
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
                    .scrollDismissesKeyboard(.interactively)
                }

                footer
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Cancel is a real choice now, because swiping away no longer
                    // destroys anything. "Keep it" is the default; discarding is the
                    // deliberate, destructive one.
                    if drafts.isEmpty && text.isEmpty {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Discard", role: .destructive) { showDiscardConfirm = true }
                    }
                }
            }
            .onAppear {
                focused = true
                restoreIfResuming()
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
            // The live loop: every text change re-triages after a short debounce.
            .onChange(of: text) { _, _ in
                scheduleTriage()
            }
            .onChange(of: speech.state) { _, state in
                if state == .listening { scheduleSilenceStop() }
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
                parse.triageTask?.cancel()
                // The backstop that makes this whole phase worth having: a swipe-down,
                // a phone call, anything that tears the sheet down mid-thought leaves
                // the raw text and every edited draft on disk.
                parkIfUnfinished()
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

    /// A finished parse that produced no candidates. Without this the composer's only
    /// answer to "why is the button dead?" was the same encouraging hint as an empty
    /// field, which reads as the app having quietly failed.
    ///
    /// Keyed on what the ENGINE returned, not on whether cards are on screen: a user
    /// who read three good candidates and deleted all three would otherwise be told
    /// "nothing actionable in that yet" about text the parser understood perfectly —
    /// the message exists to stop the app reading as quietly broken, so it must not
    /// become the lie it was added to prevent.
    private var foundNothing: Bool {
        guard drafts.isEmpty, !brain.isProcessing, !lastParseYieldedCandidates,
            let lastParsedText
        else { return false }
        return lastParsedText == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Live triage loop

    /// Debounce ~400ms, cancel in-flight, drop stale results. The heuristic path
    /// resolves near-instantly; the on-device model takes a beat — either way the
    /// newest text always wins.
    private func scheduleTriage() {
        parse.triageGeneration += 1
        let generation = parse.triageGeneration
        parse.triageTask?.cancel()

        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else {
            drafts = []
            lastParsedText = nil
            lastParseYieldedCandidates = false
            // Nothing dictated survives an emptied field, so the Capture row must not
            // keep claiming this was a voice capture.
            usedDictation = false
            // The user emptied the field. Parking exists so an INTERRUPTION can't destroy a
            // thought — it must not resurrect one that was deliberately erased. Left alone,
            // the parked row keeps the deleted text and Today goes on advertising it as a
            // "capture waiting", which reads as the app ignoring a delete.
            if let parked { AppBrain.discard(parked, in: context) }
            parked = nil
            return
        }

        parse.triageTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, generation == parse.triageGeneration else { return }
            // Everything below is real work (correction-profile build, open-set snapshot,
            // suppression load + prune, embedding warm-up). It runs only AFTER the debounce
            // survives cancellation — never once per keystroke — so a fast typist doesn't
            // pay for parses that are immediately superseded.
            let roster = rosterSnapshot
            let learned = CorrectionProfile.rules(
                from: corrections.map { $0 }, tasks: allTasks.map { $0 })
            let openTasks = openTaskSnapshots
            let suppressions = sessionSuppressions()
            let ownership = ownershipSnapshot
            // Load persisted title vectors into the retrieval memo (once per process) so
            // the first capture of the session doesn't re-embed the whole open set.
            EmbeddingStore.warmUp(openTaskIDs: Set(openTasks.map(\.id)), in: context)
            let result = await brain.triage(
                captured,
                roster: roster,
                learned: learned,
                openTasks: openTasks,
                suppressions: suppressions,
                ownership: ownership,
                onPartial: { partial in
                    // Streaming (device): candidates fill in while the model is
                    // still generating. Stale snapshots drop; edits survive merge.
                    guard generation == self.parse.triageGeneration else { return }
                    Motion.withMotion(Motion.settle) {
                        self.drafts = self.merge(fresh: partial, into: self.drafts)
                    }
                }
            )
            guard !Task.isCancelled, generation == parse.triageGeneration else { return }
            // Persist any title vectors retrieval computed fresh this pass — tiny rows
            // on the app's write context, post-debounce (never per keystroke). The
            // save rides the next commit; an abandoned capture just re-memoizes later.
            EmbeddingStore.persistFresh(openTasks: openTasks, in: context)
            lastParseYieldedCandidates = !result.isEmpty
            // Preserve the user's in-place edits: a re-parse only replaces
            // candidates whose AI reading actually changed.
            Motion.withMotion(Motion.settle) {
                drafts = merge(fresh: result, into: drafts)
            }
            lastParsedText = captured
            announceParseResult()
            // Park as soon as there is something worth keeping, not only on dismiss —
            // it shrinks the window in which the thought lives only in memory to a
            // single debounce.
            parkIfUnfinished()
        }
    }

    /// The open working set as value snapshots, for reverse dependency detection
    /// ("should anything already open wait on this new task?").
    private var openTaskSnapshots: [OpenTaskSnapshot] {
        let open = allTasks.filter { !$0.status.isResolved }
        // Both hoisted out of the loop: the unresolved-id Set used to be rebuilt inside
        // activeBlockers PER TASK (an O(N²) pass on the main thread, per parse), and
        // each task's relationships blob was decoded twice (blockers + parent). One
        // Set, one decode per task, every view derived from it.
        let openIDs = Set(open.compactMap(\.uuid))
        let titlesByID = Dictionary(
            uniqueKeysWithValues: open.compactMap { task in task.uuid.map { ($0, task.title) } })
        return open.compactMap { task in
            guard let id = task.uuid else { return nil }
            let rels = task.relationships
            let active = TaskItem.activeBlockers(from: rels, openIDs: openIDs)
            return OpenTaskSnapshot(
                id: id,
                title: task.title,
                externalBlockerNotes: active.filter { $0.kind == .external }.compactMap(\.note),
                category: task.category,
                updatedAt: task.updatedAt,
                dueDate: task.dueDate,
                isBlocked: !active.isEmpty,
                parentTitle: TaskItem.parentTaskID(from: rels).flatMap { titlesByID[$0] }
            )
        }
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
    private func merge(fresh: [TaskDraft], into current: [TaskDraft]) -> [TaskDraft] {
        DraftMerge.merge(fresh: fresh, into: current, removed: removedDrafts)
    }

    // MARK: - Footer (the Confirm-Creation moment)

    private var footer: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                commitAll()
            } label: {
                HStack {
                    // The "count may still grow" signal, ENABLED state only — the
                    // disabled button no longer moonlights as the progress indicator
                    // (the field's border glow already says "thinking"; the one thing
                    // that looks tappable shouldn't be the one saying "wait").
                    if brain.isProcessing && !drafts.isEmpty {
                        Image(systemName: "sparkles")
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    }
                    Text(ctaTitle)
                        .font(.ctaLabel)
                }
                // `onAccent` is tuned for the gradient; on the muted disabled surface
                // it fails contrast — the disabled state gets the muted pair instead.
                .foregroundStyle(
                    drafts.isEmpty
                        ? AnyShapeStyle(Palette.mutedText) : AnyShapeStyle(Palette.onAccent)
                )
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
            // Sighted users learn "more may still arrive" from the pulsing sparkle;
            // without this, VoiceOver announced a bare count and nothing else.
            .accessibilityValue(brain.isProcessing ? "still reading, the count may change" : "")

            micRow
        }
    }

    private var ctaTitle: String {
        guard !drafts.isEmpty else { return "Add tasks" }
        return "Add \(drafts.count) task\(drafts.count == 1 ? "" : "s")"
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

    /// Persist the in-flight capture. Called on dismiss and after each parse, so the
    /// window in which a thought exists only in memory is as small as possible.
    private func parkIfUnfinished() {
        guard !drafts.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        parked = brain.park(
            drafts, rawCapture: text, source: usedDictation ? .voice : .text,
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
        if let restored = resuming.parkedDrafts, !restored.isEmpty {
            drafts = restored
        } else {
            scheduleTriage()
        }
    }

    private func discard() {
        speech.stop()
        parse.triageTask?.cancel()
        if let parked { AppBrain.discard(parked, in: context) }
        parked = nil
        drafts = []
        removedDrafts = RemovedDraftSet()
        text = ""
        dismiss()
    }

    private func commitAll() {
        guard !drafts.isEmpty else { return }
        speech.stop()
        parse.triageTask?.cancel()
        committed += 1
        // Adopt the parked row rather than creating a second one for the same event.
        brain.commit(
            drafts, rawCapture: text, source: usedDictation ? .voice : .text, parked: parked,
            into: context)
        // "Add N tasks" IS the Confirm-Creation moment, and `commit` IS the creation:
        // every field was visible and editable, and the tasks come into existence here,
        // born `.todo`. There is no second confirm step to run. (A judgment call's Needs
        // Decision flag survives creation — confirming that "figure out if X" exists is
        // not making the call.)
        //
        // Clearing the session state is REQUIRED, not tidiness: `.onDisappear` runs
        // `parkIfUnfinished` after this, and it keys off `drafts`/`text`. Leaving them
        // populated would park a phantom duplicate of the capture just committed, and
        // Today would read "1 capture waiting" after every successful add.
        parked = nil
        drafts = []
        removedDrafts = RemovedDraftSet()
        text = ""
        context.saveChanges()
        loadedSuppressions = nil  // commit wrote new rejections — the session cache is stale
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
                // While the mic owns the field, the keyboard must not: every transcript
                // tick rewrites the whole text from `dictationBase + transcript`, so a
                // manual edit made mid-dictation was silently clobbered a beat later.
                // The field must not LOOK editable while it isn't — hit-testing off,
                // and the state change below drops keyboard focus.
                .allowsHitTesting(!speech.isActive)
                // The field is the product's front door and it was unlabeled —
                // VoiceOver read only the (long, example-laden) placeholder.
                .accessibilityLabel("What's on your mind")
                .accessibilityHint(
                    "Type or dictate anything. Tasks take shape below as you go.")
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
            Text("Listening — pause to finish, or tap the mic to edit by hand.")
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
    /// uncancelled sleeping Task per transcript tick, unbounded by design.
    private func scheduleSilenceStop() {
        parse.silenceTask?.cancel()
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
    /// Bumped on every text change; an in-flight triage that comes back stale drops
    /// its result instead of clobbering fresher candidates.
    var triageGeneration = 0
    var triageTask: Task<Void, Never>?
    /// The single silence-timeout in flight; cancelled and replaced on every
    /// transcript delta, cancelled outright on stop/disappear.
    var silenceTask: Task<Void, Never>?
}

#Preview {
    ComposerView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
