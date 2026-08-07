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
//  so candidates fill in progressively within a single parse — and the parse
//  ROLLS: input arriving while a parse streams never cancels it (its cards are
//  landing live); a follow-up over the fuller text chains at completion, and a
//  max-wait bound fires the first parse of a burst even when dictation deltas
//  arrive faster than the debounce can ever survive. The old shape cancelled the
//  in-flight generation on every delta, so "cards take shape as you talk" was
//  structurally "cards appear when you stop"; now the mid-ramble screen is the
//  product's signature moment on both engines (the heuristic is instant, so its
//  rolling cadence is simply the max-wait tick).
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
    /// When the silence auto-stop will fire — rescheduled on every transcript delta,
    /// nil outside dictation. The hero bar renders its last stretch as a draining ring.
    @State private var silenceDeadline: Date?
    /// The small mic capsule and the listening hero share this morph.
    @Namespace private var voiceMorph
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
                    // The hint states declare opacity transitions; this is the
                    // animation that actually drives them — without it every state
                    // change snapped.
                    .animation(Motion.fade, value: speech.state)

                if drafts.isEmpty {
                    Text(foundNothing ? Self.nothingFoundHint : Self.openingHint)
                        .supportingStyle()
                        .animation(Motion.fade, value: foundNothing)
                    Spacer(minLength: 0)
                } else {
                    engineDisclosure
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
            // Dictation start/stop is felt, not just seen — the trigger is the state
            // edge, so the auto-stop lands the same haptic as a tap.
            .sensoryFeedback(.impact(weight: .medium), trigger: speech.state == .listening)
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
                refreshRosterCaches()
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
                parse.debounceTask?.cancel()
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

    /// The rolling cadence, three numbers:
    /// - `debounce`: the quiet gap after which a burst of input is worth parsing.
    /// - `maxParseDeferral`: how long continuous input may keep resetting that
    ///   debounce before a parse fires anyway. Dictation's volatile hypotheses land
    ///   faster than the debounce can ever survive, so without this bound the
    ///   flagship input mode never parsed until the speaker stopped.
    /// - `parkThrottle`: the floor between mid-session park writes (an O(capture)
    ///   encode + synchronous save) now that rolling parses complete far more often
    ///   than the old at-pause cadence. Raw text is never at risk for longer than
    ///   this window, and dismissal always parks unthrottled.
    private static let debounceMilliseconds = 400
    private static let maxParseDeferralSeconds: TimeInterval = 1.2
    private static let parkThrottleSeconds: TimeInterval = 2

    /// The input edge of the loop: debounce quiet gaps, bound continuous bursts by
    /// `maxParseDeferralSeconds` — and never disturb a parse that is already
    /// streaming (its candidates are landing on screen; a follow-up chains the
    /// moment it completes instead).
    private func scheduleTriage() {
        parse.debounceTask?.cancel()

        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else {
            // Everything in flight is now about text that no longer exists.
            parse.parseEpoch += 1
            parse.parseTask?.cancel()
            parse.parseTask = nil
            parse.burstStartedAt = nil
            parse.preparedCandidates = []
            parse.enrichedText = nil
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

        // A parse is already streaming; don't disturb it. Whether a follow-up is
        // needed is decided at its completion, by comparing the field against what
        // it actually parsed — no flag to keep honest.
        if parse.parseTask != nil { return }

        let now = Date()
        let burstStart = parse.burstStartedAt ?? now
        parse.burstStartedAt = burstStart
        if now.timeIntervalSince(burstStart) >= Self.maxParseDeferralSeconds {
            startParse()
        } else {
            parse.debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
                guard !Task.isCancelled else { return }
                startParse()
            }
        }
    }

    /// One parse, start to finish: prep the context, run the engine with streaming
    /// partials, apply the completed result, chain the follow-up if the field moved
    /// while it ran. Exactly one parse runs at a time — `scheduleTriage` defers to a
    /// running one, so the only caller-side invariant is `parse.parseTask == nil`.
    private func startParse() {
        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return }
        parse.burstStartedAt = nil
        parse.parseEpoch += 1
        let epoch = parse.parseEpoch

        parse.parseTask = Task {
            // Everything below is real work (correction-profile build, open-set snapshot,
            // suppression load + prune, embedding warm-up). It runs only once a burst
            // earns a parse — never once per keystroke — so a fast typist doesn't pay
            // for input that is immediately superseded.
            let roster = rosterSnapshot
            let learned = sessionRules()
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
                preparedCandidates: parse.preparedCandidates,
                onPartial: { partial in
                    // Streaming (device): candidates fill in while the model is still
                    // generating — including while the user keeps talking. Snapshots
                    // from an invalidated epoch drop; edits survive merge; cards the
                    // snapshot hasn't reached yet are KEPT (only a completed parse
                    // may drop a card).
                    guard epoch == self.parse.parseEpoch else { return }
                    Motion.withMotion(Motion.settle) {
                        self.drafts = self.merge(
                            fresh: partial, into: self.drafts, keepingUnmatched: true)
                    }
                }
            )
            guard !Task.isCancelled, epoch == parse.parseEpoch else { return }
            parse.parseTask = nil
            // This parse's retrieval becomes the NEXT parse's prompt candidates —
            // the chain is how the model gets a candidate package without first-draft
            // latency ever paying for retrieval (audit A1).
            parse.preparedCandidates = result.candidates
            // Persist any title vectors retrieval computed fresh this pass — tiny rows
            // on the app's write context, post-debounce (never per keystroke). The
            // save rides the next commit; an abandoned capture just re-memoizes later.
            EmbeddingStore.persistFresh(openTasks: openTasks, in: context)
            lastParseYieldedCandidates = !result.drafts.isEmpty
            // Preserve the user's in-place edits: a re-parse only replaces
            // candidates whose AI reading actually changed.
            Motion.withMotion(Motion.settle) {
                drafts = merge(fresh: result.drafts, into: drafts)
            }
            lastParsedText = captured
            announceParseResult()
            // Park as soon as there is something worth keeping, not only on dismiss —
            // it shrinks the window in which the thought lives only in memory.
            parkIfUnfinished()
            // The field moved while this parse ran (dictation deltas, more typing).
            // Chain the follow-up immediately: the debounce's job — don't parse
            // mid-burst — has been done by the parse's own duration.
            if text.trimmingCharacters(in: .whitespacesAndNewlines) != captured {
                startParse()
            } else if result.suggestsEnrichment, parse.enrichedText != captured {
                // Single-shot backstop: the burst produced no chain, so the model
                // never saw candidates and duplicate/child proposals couldn't land.
                // ONE re-parse over the same text with the now-ready package —
                // bounded by the marker, and an enrichment run carries candidates so
                // it can never suggest another.
                parse.enrichedText = captured
                startParse()
            }
        }
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

            // Voice as the hero while listening: the small capsule morphs into the
            // full listening bar — level meter, 64pt stop control, silence countdown —
            // and morphs back on stop. Under Reduce Motion the morph is a crossfade.
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
        .animation(reduceMotion ? Motion.fade : Motion.capsuleExpand, value: speech.isActive)
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

    /// Persist the in-flight capture. Called on dismiss (`force`, always writes) and
    /// after each completed parse — throttled there, because rolling parses complete
    /// far more often than the old at-pause cadence and each park is an O(capture)
    /// encode plus a synchronous save. The thought is never at risk for longer than
    /// the throttle window, and the drafts are derived (resume re-parses `rawText`).
    private func parkIfUnfinished(force: Bool = false) {
        guard !drafts.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if !force, let last = parse.lastParkAt,
            Date().timeIntervalSince(last) < Self.parkThrottleSeconds
        {
            return
        }
        parse.lastParkAt = Date()
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
        parse.parseEpoch += 1
        parse.debounceTask?.cancel()
        parse.parseTask?.cancel()
        parse.parseTask = nil
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
        parse.parseEpoch += 1
        parse.debounceTask?.cancel()
        parse.parseTask?.cancel()
        parse.parseTask = nil
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
        parse.cachedRules = nil  // likewise new corrections
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
    /// Bumped whenever in-flight work must be invalidated — a parse starting, the
    /// field emptied, commit/discard. A parse captures the value at start; its
    /// streamed partials and final result apply only while still current.
    var parseEpoch = 0
    /// The sleeping debounce; cancelled and replaced per input event.
    var debounceTask: Task<Void, Never>?
    /// The one running parse. New input never cancels it — its candidates are
    /// streaming onto the screen; it is superseded only at its own completion.
    var parseTask: Task<Void, Never>?
    /// When the current burst of unparsed input began — the max-wait clock. Cleared
    /// when a parse starts.
    var burstStartedAt: Date?
    /// The last completed parse's retrieval set — the next parse's prompt
    /// candidates (audit A1: candidates ride the chain).
    var preparedCandidates: [RetrievalCandidate] = []
    /// The text an enrichment re-parse already ran for, so the single-shot
    /// backstop fires at most once per settled text.
    var enrichedText: String?
    /// The learned-correction rules for this session (see `sessionRules`).
    var cachedRules: [LearnedRule]?
    /// The last mid-session park write, for the throttle.
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
