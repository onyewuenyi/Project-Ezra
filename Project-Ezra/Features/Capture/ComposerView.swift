//
//  ComposerView.swift
//  Project-Ezra
//
//  RAMBLE — the core loop, and the product's wow moment. Opening capture is opening a
//  listening intelligence, not filling a form:
//
//      LISTENING → (silence) → UNDERSTANDING → REVEAL/CONFIRM → CREATE → (dismiss)
//                ↘ CAPTURE — the typed escape hatch (Type instead / no mic) → (submit) ↗
//
//  CREATE dismisses immediately. A ✓ "N tasks added" receipt phase used to sit between
//  the commit and the dismiss for 0.9s; it was removed 2026-08-30 because it read as an
//  extra screen. Confirmation is the success haptic and the tasks appearing in the list.
//
//  **The governing invariant for the voice surface:** the orb never asks the user to
//  understand the system; it only reflects that the system is present and receiving
//  them — the reveal is where the system proves understanding. While listening the orb
//  shows RECEPTION (the microphone level as presence), never interpretation: no live
//  transcript, no counts, no cards — a deliberate 2026-08-27 reversal of the two-tone
//  listening transcript. Silence after words is treated as the user's likely completion
//  signal and finishes the capture itself; the system never finishes an EMPTY one.
//
//  The older, deeper invariant is untouched and every decision here still serves it:
//  **at no point before confirmation may the user see an intermediate AI interpretation
//  presented as truth.** While listening and on the typed canvas the AI is entirely
//  absent — no parse, no cards, no counts, no classification — because the user owns
//  the conversation while they are still having it. Submit is a deliberate handoff
//  ("got it, I'll take it from here"); the input collapses into one orb; and the reveal
//  presents ONE interpretation.
//
//  Structure — how many tasks, in what order — is decided ONCE, at submit, and never
//  changes under the user. Who decides it is a single observation: if the user drew the
//  boundaries (lines, bullets, a comma list) the deterministic path reads them and the
//  reveal is immediate; otherwise the orb holds the screen while the semantic authority
//  reads the whole capture. There is no third case, and no enrichment pass afterwards —
//  `Interpretation` refuses a late proposal, so a card set that is on screen is final
//  until the user changes it.
//
//  This replaced a live-parsing composer whose cards appeared, split, merged and
//  vanished while the user typed. That reads as "slow and confused" even when the final
//  answer is excellent: the fix was not to render intermediate states faster but to stop
//  rendering them.
//
import AVFAudio
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

    /// Where in the arc we are. The mic owns `.listening` and nothing is interpreted
    /// there; nothing is parsed in `.capture`; nothing but the orb shows in
    /// `.understanding`; `.confirm` renders one interpretation. The INITIAL phase is
    /// decided in `init` (`initialPhase`), before the first body pass, so the right
    /// surface renders on the very first frame — an entry-time `onAppear` check flashed
    /// whichever surface it was about to leave.
    @State private var phase: RamblePhase
    /// When submit happened — the clock for the performance contract.
    @State private var submittedAt: Date?
    /// Which route produced the cards on screen ("local"/"cloud").
    @State private var structureSource = CaptureRoute.local.metricName
    /// How the parse behind the current cards actually ran — the receipt `commit` turns
    /// into this capture's `CaptureProvenance`. Nil until a route has been taken; the
    /// `.local` arm synthesizes its own, because "no model ran" is a run fact worth
    /// recording rather than an absence.
    @State private var lastRun: CaptureRunTelemetry?
    /// When the current card set arrived. The stagger clock: each card's entrance is
    /// offset from this, so the composition arrives as one thing with a rhythm rather
    /// than appearing all at once or animating per-card forever after.
    @State private var revealedAt: Date?
    /// When the orb took the screen. Backs the dwell floor that stops a fast parse
    /// from flashing the hero morph. Nil off the model routes.
    @State private var understandingSince: Date?
    /// Voice only: how long the user's last word had been hanging when the capture
    /// finished — ≈5000ms when the silence window fired, less on an orb/Done tap.
    /// Captured in `finishListening` (the one place the deadline is still alive) and
    /// stamped onto the receipt at reveal. The contract's clock deliberately EXCLUDES
    /// this: it is the UX parameter the silence window is tuned on, not a pipeline cost.
    @State private var pendingSinceLastWordMs: Int?

    @State private var text = ""
    /// The card set and the reveal boundary that protects it. All AI-originated writes go
    /// through `propose`, which refuses once the user has seen the composition; user edits
    /// go through the binding and are never gated. See `Interpretation`.
    @State private var interpretation = Interpretation()
    /// The cards the user deleted this session. The merge filters re-proposals of
    /// them, so a removal can't be undone by the next keystroke's re-parse.
    @State private var removedDrafts = RemovedDraftSet()
    /// The card most recently dropped from the reveal, with the place it held — what
    /// the Undo pill puts back. One at a time, like every other undo notice: a second
    /// removal replaces it, and the earlier card stays removed.
    @State private var lastRemoved: (draft: TaskDraft, index: Int)?
    /// The "Removed “X”" pill over the reveal page. Removing a candidate was the one
    /// decisive act on the surface with no way back: a mis-tap on the X lost the card,
    /// and `RemovedDraftSet` then kept it out of every re-read. The trust checklist
    /// says the user can undo anything; this is where that was untrue.
    @State private var cardNotice: UndoNotice?
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
    /// The intent path (F-01): the words arrived from Siri or the Action Button, so the
    /// composer submits them on arrival and the person lands on the confirm card.
    private let autoSubmit: Bool
    /// The outcome the revealed cards become steps of, when the person groups them
    /// ("Group as one outcome") — nil means no group. A USER act on the reveal, never a
    /// proposal: the umbrella is born at Create, at the one publish boundary.
    @State private var groupTitle: String?
    @State private var groupPrompt = false
    @State private var groupDraftTitle = ""
    /// The privacy posture (F-03) — a control beside the one door, persisted.
    @AppStorage(CapturePosture.storageKey) private var postureRaw = CapturePosture.open.rawValue
    private var posture: CapturePosture { CapturePosture(rawValue: postureRaw) ?? .open }
    @State private var showDiscardConfirm = false
    /// Set when `brain.commit`'s own save reported a dropped write. The created
    /// `TaskItem`s stay pending in the context either way (`saveChanges` never
    /// rolls back), so "Try Again" is a real retry, not just an apology.
    @State private var showSaveFailedAlert = false
    @State private var pendingCreatedCount = 0
    /// True from a failed commit until a retry succeeds. Disables "Create" —
    /// `finishCommit`'s failure path leaves the just-committed `TaskItem`s
    /// pending, unsaved, in `context`; a second tap would call `brain.commit`
    /// again on the same drafts and insert a duplicate set alongside them.
    @State private var commitPendingRetry = false
    /// Set when a picked photo fails to load/decode — the one stage in
    /// `ingestPhoto` with no fallback (a failed OCR still shows the thumbnail; this
    /// is "nothing happened at all," which otherwise looks identical to a tap that
    /// didn't register).
    @State private var showPhotoImportFailedAlert = false
    /// Distinct from the above: the photo decoded fine but Vision itself threw (or
    /// timed out) rather than simply finding no text — a photo with no text at all is
    /// `ImageTextExtractor`'s documented normal outcome and stays silent, but a genuine
    /// failure must not look identical to "the tap didn't register."
    @State private var showOCRFailedAlert = false
    /// The text the last COMPLETED parse ran against. Only when this matches what's in the
    /// field do we know an empty `drafts` means "the engine found nothing here" rather than
    /// Whether the last completed parse returned any candidates at all, before the
    /// session's removals filtered them. The honest input to `foundNothing`.
    /// When the silence finish will fire — rescheduled on every transcript delta, nil
    /// outside dictation. The orb surface renders its last stretch as quiet microcopy;
    /// the PRIMARY finishing signal is the orb itself calming as the level drains.
    @State private var silenceDeadline: Date?
    /// The one object the whole arc transforms through: orb ↔ field → orb → composition.
    @Namespace private var rambleMorph
    static let rambleMorphID = "ramble"
    /// Set when the orb has been holding long enough that silence would read as stuck.
    @State private var showReassurance = false
    /// "Getting the mic ready…" — shown only when the warm-up runs LONG. The label's
    /// absence is the point: `.preparing` should be a barely perceptible beat, and
    /// announcing states is what makes the orb feel less magical.
    @State private var showPreparingLabel = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    /// Drives the listening surface's photo control. A bare `PhotosPicker` gives no
    /// hook before it presents, and the mic must not stay hot behind it — so the
    /// picker is presented imperatively, after the voice tenure has been ended.
    @State private var showPhotoPicker = false
    /// The text the current card set was read FROM. The confirm page now shows the
    /// capture, editable, so "have the words moved since the answer?" is a real
    /// question — and it is the only thing that earns a Re-read affordance.
    @State private var parsedText = ""
    /// Measured natural height of the confirm page's transcript box (see
    /// `transcriptField`). `TextEditor` does not self-size, and a scroll view inside
    /// the page's scroll view is worse than a box that grows.
    @State private var transcriptHeight: CGFloat = 0
    /// One line of `bodyInput`, measured the same way. The ceiling snaps DOWN to a whole
    /// number of these — a box cut through the middle of a glyph reads as a rendering
    /// fault, not as "there is more below this".
    @State private var transcriptLineHeight: CGFloat = 0

    init(resuming: Capture? = nil, autoSubmit: Bool = false) {
        #if DEBUG
        // `-GroupAs "Title"` lands the reveal already grouped, so the grouped state and
        // the Create CTA it changes are screenshot-reachable without the alert's tap.
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-GroupAs"), args.indices.contains(flag + 1) {
            _groupTitle = State(initialValue: args[flag + 1])
        }
        #endif
        self.resuming = resuming
        self.autoSubmit = autoSubmit
        _phase = State(initialValue: Self.initialPhase(resuming: resuming))
    }

    /// The first phase, decided synchronously before the first body pass so neither
    /// surface ever flashes for a frame: fresh + mic permitted → the sheet opens INTO
    /// listening; a resumed capture lands on the canvas with its words; a denied mic
    /// falls through to typing immediately (Settings stays secondary, beside the field).
    static func initialPhase(resuming: Capture?) -> RamblePhase {
        guard resuming == nil else { return .capture }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-HoldListening") || args.contains("-DriveListeningLevel") {
            return .listening
        }
        #endif
        return AVAudioApplication.shared.recordPermission == .denied ? .capture : .listening
    }

    var body: some View {
        NavigationStack {
            // Tighter once candidates exist: every point of vertical spacing here is a
            // point the card can't use to show a field.
            VStack(alignment: .leading, spacing: Spacing.md) {
                switch phase {
                case .capture: captureSurface
                // ONE branch for both orb tenures, deliberately: a second `case` calling
                // the same builder would be a second `ConditionalContent` arm — the orb's
                // `@State` clock resets at the listening → thinking swap, the mesh
                // re-phases, and matchedGeometry animates a spurious orb→orb morph. The
                // swap must be a parameter change, never an identity change.
                case .listening, .understanding: orbSurface
                case .confirm: confirmSurface
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
            // The canvas's controls are an INSET, not stack members: content is laid
            // out above the bar by construction, so a keyboard transition can never
            // slide the buttons through it — and the bar (solid background) rides
            // above the keyboard, keeping Ramble reachable mid-typing.
            .safeAreaInset(edge: .bottom) {
                switch phase {
                case .capture: captureBar
                case .confirm: confirmBar
                default: EmptyView()
                }
            }
            // Success notification — capture committed is a capstone moment.
            .sensoryFeedback(.success, trigger: committed)
            // The reveal is the product's promise being kept, and it was the one moment
            // in the flow with no feedback of any kind. A light impact, not `.success`:
            // success belongs to the commit, and spending it here would flatten the
            // difference between "here's what I understood" and "it's in your list".
            .sensoryFeedback(.impact(weight: .light), trigger: revealedAt)
            // Dictation start/stop is felt, not just seen — the trigger is the state
            // edge, so the auto-stop lands the same haptic as a tap.
            .sensoryFeedback(.impact(weight: .medium), trigger: speech.state == .listening)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The leading slot is the reflexively-tapped one, so it holds only
                    // SAFE actions. Leaving with words on the canvas parks them — the
                    // capture resumes later untouched — so "Close" is honest and Discard
                    // no longer sits in the spot the thumb goes to by habit.
                    switch phase {
                    case .capture where text.isEmpty, .listening where text.isEmpty:
                        Button("Cancel") { dismiss() }
                    case .capture, .listening:
                        // The transcript mirrors into `text` live even though the orb
                        // surface never shows it, so this label upgrades honestly the
                        // moment there are words to keep — and leaving parks them.
                        Button("Close") { dismiss() }
                    case .understanding:
                        // The one place Back still means something: it cancels a parse
                        // in flight and returns the words to the canvas.
                        Button("Back") { backToCapture() }
                    case .confirm:
                        // The reveal page CARRIES the canvas now — the transcript is
                        // right there, editable — so there is nothing to go back to.
                        // Leaving parks the capture; nothing is lost.
                        Button("Close") { dismiss() }
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    // The one irreversible action in the flow, in the slot reserved for
                    // exactly that, and still behind a confirmation. Offered on the
                    // canvas AND the reveal: the reveal is where a person most often
                    // decides "no, never mind" — and before this their only exit there
                    // was Close, which PARKED the capture and made it reappear at the
                    // top of Tasks as unfinished work they had already decided against.
                    if phase == .capture || phase == .confirm, !text.isEmpty {
                        Button("Discard", role: .destructive) { showDiscardConfirm = true }
                    }
                }
            }
            .onAppear {
                refreshRosterCaches()
                restoreIfResuming()
                if phase == .listening {
                    // Fresh open, mic permitted (decided in `init`): the sheet opens
                    // INTO listening. Opening capture is opening a listening
                    // intelligence, and the keyboard never appears uninvited.
                    beginListening(from: "")
                } else {
                    // The canvas is now always a DELIBERATE landing — a resumed capture
                    // (returning to words in progress) or the mic-denied fallthrough
                    // (typing immediately available) — so the keyboard comes up. The old
                    // "never focus a fresh canvas" rule moved up a level: the fresh
                    // entry is the orb.
                    focused = true
                }
                // Two callers may submit on arrival: the `-OpenCapture` seam (DEBUG, and
                // only when that argument is actually present — a resumed capture from
                // the Tasks row must land on the canvas, not re-parse itself) and the
                // intent path (F-01), where the words came from Siri or the Action Button
                // and the person expects the confirm card, not a canvas.
                var submitsOnArrival = autoSubmit
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-OpenCapture"), !args.contains("-NoSubmit") { submitsOnArrival = true }
                #endif
                if submitsOnArrival, resuming != nil, !text.isEmpty {
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        submit()
                    }
                }
            }
            // The orb's reassurance line — long work must read as calm, never as stuck.
            .onChange(of: phase) { _, newPhase in
                showReassurance = false
                // The last unreachable beat: `-AutoCreate` taps Create for us, so the
                // ✓ receipt and the return-to-where-you-were can be verified headlessly
                // like every other phase. The receipt keeps its real duration — a seam
                // that slowed it down would be verifying something we don't ship.
                #if DEBUG
                if newPhase == .confirm, !interpretation.drafts.isEmpty,
                    ProcessInfo.processInfo.arguments.contains("-AutoCreate")
                {
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        createTasks()
                    }
                }
                #endif
                guard newPhase == .understanding else { return }
                Task {
                    try? await Task.sleep(for: .seconds(Self.reassuranceAfterSeconds))
                    guard phase == .understanding else { return }
                    Motion.withMotion(Motion.fade) { showReassurance = true }
                }
            }
            // The live transcript flows into `text`: base + everything heard so far.
            // INVISIBLE while the orb listens — reception, never interpretation — but
            // always carried: park, the toolbar label, and the finish's fold all read it.
            .onChange(of: speech.transcript) { _, transcript in
                // Only write when the value actually moves: starting the mic resets
                // the transcript to empty, which used to re-assign the same text
                // (minus trailing whitespace) and kick off a full re-parse before a
                // single word had been spoken.
                let next = dictationBase + transcript
                if next != text { text = next }
                guard Self.shouldArmSilence(transcript: transcript) else { return }
                usedDictation = true
                // Armed ONLY here, on words — the system never finishes an empty
                // capture (an open mic over silence just stays present), and once
                // speech has occurred, silence is the user's likely completion signal.
                scheduleSilenceFinish()
            }
            // Nothing happens here on purpose. During capture the user owns the
            // conversation and the AI stays quiet: no parse, no cards, no counts, no
            // classification. The system gets to work at submit, and not before.
            .onChange(of: text) { _, _ in
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let parked
                {
                    // The thought was erased; parking must not keep advertising it. This
                    // is the same destructive path as the explicit `discard()` below, so
                    // it owes the photo the same cleanup — otherwise the JPEG under
                    // `CaptureImageStore` outlives the row that referenced it.
                    if let ref = capturedImageRef { CaptureImageStore.delete(ref) }
                    capturedImageRef = nil
                    capturedThumb = nil
                    usedImage = false
                    AppBrain.discard(parked, in: context)
                    self.parked = nil
                }
            }
            .onChange(of: speech.state) { _, state in
                // Voice and keyboard are one channel at a time: focus drops while the
                // mic is live. The old implicit return (`.idle` → focused) is GONE —
                // every keyboard raise is now a deliberate decision at a named entry
                // into `.capture`, because an automatic flip is how the voice surface
                // would keep summoning the keyboard it exists to replace.
                if speech.isActive { focused = false }
                // The lifecycle invariant — ONE rule for every failure: while the orb
                // is listening, any non-user-initiated drop of speech activity (an
                // interruption's stop, a denial, an engine failure, the simulator's
                // missing transcriber) settles to the canvas with the words heard so
                // far. Never a submit: a capture is only ever interpreted by an act the
                // user witnessed — their silence after words, or their tap. The
                // user-initiated finishes move `phase` before this observer runs, so
                // the guard makes them no-ops here.
                guard phase == .listening else { return }
                switch state {
                case .idle, .denied, .unavailable:
                    parse.silenceTask?.cancel()
                    parse.silenceTask = nil
                    silenceDeadline = nil
                    foldTranscript()
                    Motion.withMotion(Motion.settle) { phase = .capture }
                    focused = true
                case .preparing, .listening:
                    break
                }
            }
            .onChange(of: scenePhase) { _, newScene in
                // Backgrounded mid-listening: stop, fold, settle — and never submit. A
                // suspended silence task must not fire a model call the user didn't
                // witness when the app comes back. `phase` moves first so the state
                // observer above treats the stop as already handled.
                guard newScene == .background, phase == .listening else { return }
                parse.silenceTask?.cancel()
                parse.silenceTask = nil
                silenceDeadline = nil
                phase = .capture
                speech.stop()
                foldTranscript()
            }
            .onDisappear {
                let midListening = phase == .listening && speech.isActive
                speech.stop()
                parse.silenceTask?.cancel()
                silenceDeadline = nil
                parse.parseTask?.cancel()
                parse.levelDriveTask?.cancel()
                // Dismissed mid-listening: the `.onChange` transcript copy may never
                // deliver during teardown, so fold explicitly — the park below must
                // hold every word that was heard, and resume lands them VISIBLY in
                // `.capture`, so the invisible transcript is always seen before it is
                // ever interpreted.
                if midListening { foldTranscript() }
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
                Text(
                    phase == .confirm && !interpretation.drafts.isEmpty
                        ? "Nothing has been created yet. The words and these tasks will be deleted."
                        : "The text and everything parsed from it will be deleted.")
            }
            .alert("Couldn't save", isPresented: $showSaveFailedAlert) {
                Button("Try Again") { retrySave() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text(
                    "Your tasks didn't save. Check your storage and try again — nothing you typed is lost."
                )
            }
            // Presented imperatively so the listening surface's photo control can end
            // the voice tenure BEFORE the picker appears — a `PhotosPicker` offers no
            // hook between the tap and the sheet, and the mic must not stay hot behind
            // it. The canvas's own `imageButton` is still a plain `PhotosPicker`; it has
            // nothing to tear down.
            .photosPicker(
                isPresented: $showPhotoPicker, selection: $photoItem, matching: .images,
                photoLibrary: .shared()
            )
            .alert("Couldn't read that photo", isPresented: $showPhotoImportFailedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try picking it again, or type what it said instead.")
            }
            .alert("Couldn't read the text in that photo", isPresented: $showOCRFailedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The photo was saved. Try again, or type what it said instead.")
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
    /// AI interpretation presented as truth.** During `.listening` the mic owns the
    /// screen and nothing is interpreted; during `.capture` nothing is parsed at all;
    /// during `.understanding` nothing is shown but the orb; `.confirm` renders one
    /// interpretation whose STRUCTURE never changes again.
    enum RamblePhase: Equatable {
        case listening
        case capture
        case understanding
        case confirm
    }

    /// What finishing the listening tenure does with what it heard. Pure, so the finish
    /// decision is testable without a mic.
    enum FinishAction: Equatable {
        case toCanvas
        case submit
    }

    /// The system never finishes an empty capture: silence only becomes a completion
    /// signal once speech has occurred, so the timer arms on words and never on state.
    static func shouldArmSilence(transcript: String) -> Bool {
        !transcript.isEmpty
    }

    /// "Said nothing, finished anyway" gets the canvas, not a "Nothing actionable"
    /// reveal — that reveal answers a question about words, and there were none.
    static func finishAction(trimmed: String) -> FinishAction {
        trimmed.isEmpty ? .toCanvas : .submit
    }

    /// When "still working" reassurance joins the orb, so a long ramble reads as calm
    /// rather than stuck. Deliberately not a progress affordance.
    static let reassuranceAfterSeconds: TimeInterval = 8

    /// Submit — the deliberate handoff. "Got it, I'll take it from here."
    ///
    /// Two paths, one contract. The FAST path renders the deterministic read and reveals it;
    /// the REASONING path holds the orb until the model answers and reveals that. Either way
    /// exactly one interpretation reaches the screen, and once it does nothing the system
    /// produces may change it (`Interpretation`).
    ///
    /// The fast path deliberately does not run the model at all. That is a routing POLICY
    /// (see `CaptureRoute`), not a claim that simple captures don't deserve intelligence —
    /// it is here because a model result that lands after the reveal is refused anyway, so
    /// spending the battery to generate one would buy nothing.
    ///
    /// `fromVoice` is a PARAMETER, never derived from `usedDictation` — that flag is
    /// sticky for the session (dictate → Type instead → edit → Ramble would wrongly buy
    /// the thinking beat on a typed submit). Only `finishListening` passes true.
    private func submit(fromVoice: Bool = false) {
        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return }
        // The baseline the confirm page's Re-read affordance is measured against: these
        // are the exact words the card set about to appear was read from.
        parsedText = captured
        focused = false
        speech.stop()
        submittedAt = Date()
        // A typed submit is not a voice one, however the words first arrived: without
        // this, a voice capture followed by a typed Re-read would stamp the earlier
        // run's silence-window measurement onto the typed receipt.
        if !fromVoice { pendingSinceLastWordMs = nil }
        // The channel, as one of five words — never the words themselves (`Telemetry`).
        Telemetry.log(
            .captureStarted(
                channel: resuming?.source == .siri
                    ? .siri : capturedImageRef != nil ? .photo : fromVoice ? .voice : .typed))

        let localStarted = Date()
        let local = AppBrain.provisionalDrafts(captured, learned: sessionRules())
        let localMs = Int(Date().timeIntervalSince(localStarted) * 1000)
        // Device-first, escalate on evidence (2026-08-29): the deterministic read above
        // IS the default interpretation, and the capture transmits only when
        // `CaptureEscalation` finds observable evidence it fell short — an empty read,
        // a big dump, one draft against many boundary signals, an unresolved spoken
        // detail, dropped content. Most captures reveal this read directly: instant,
        // private, free. The check itself is microseconds of string work.
        // The decision is a VALUE (`CaptureFlow.plan`, test-pinned): the posture outranks
        // the router, one thought on an on-device posture runs the private engine, and
        // otherwise the device-first router decides, voice-aware.
        let plan = CaptureFlow.plan(
            text: captured, localRead: local, fromVoice: fromVoice, posture: posture,
            privateModelAvailable: PrivateCaptureEngine.modelAvailable(),
            boundaryPassAvailable: OnDeviceSegmenter.isRoutingEnabled
                && PrivateCaptureEngine.modelAvailable())
        let decision = (route: plan.route, escalation: plan.escalation)
        let route = decision.route
        structureSource = route.metricName

        // Verification seam: hold the Understanding beat so the orb can actually be looked
        // at. The simulator's parse finishes in a couple of seconds, which is the right
        // outcome and the wrong condition for reviewing a fourteen-second animation — before
        // this, judging the orb meant catching it between two screenshots.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HoldUnderstanding") {
            Motion.withMotion(Motion.heroSettle) { phase = .understanding }
            return
        }
        #endif

        // The ledger is split between here and `AppBrain.triage` on purpose, and the
        // split is "who knows what ACTUALLY ran". `.local` never reaches the brain, so it
        // is counted here; the cloud arm is counted there, after the availability
        // degrade — a `.cloud` route on a device that turns out to have no reachable
        // provider runs on-device, and a counter that recorded the intent would report
        // paid calls that never happened. Counting it in both places was the first
        // version of this and double-counted every model parse.
        switch route {
        case .local:
            // On-device posture, SEVERAL things: the boundary pass. Same orb, same confirm
            // card, and — because the posture forbids the network — a refusal lands on the
            // deterministic read rather than on the authority. The person gets the better
            // of the two answers this device can give, and never a worse one than before.
            if plan.arm == .boundaryPass {
                IntelligenceLedger.shared.record(.onDevice, for: .ramble)
                understandingSince = .now
                Motion.withMotion(Motion.heroSettle) { phase = .understanding }
                parkIfUnfinished(force: true)
                parse.parseTask?.cancel()
                parse.parseTask = Task {
                    let learned = sessionRules()
                    let outcome = await OnDeviceSegmenter.segment(
                        text: captured, learned: learned, ownership: ownershipSnapshot)
                    guard !Task.isCancelled else { return }
                    var run = CaptureRunTelemetry.local(
                        segmentation: Segmentation.structure(of: captured).label,
                        cloudAvailable: CloudModel.isReachable(for: .ramble))
                    run.parseMs = Int(Date().timeIntervalSince(localStarted) * 1000)
                    let final: [TaskDraft]
                    if case .accepted(let drafts, let fragments) = outcome {
                        run.rung = IntelligenceRung.onDevice.rawValue
                        run.engineName = "on-device(segment→\(fragments))"
                        final = drafts
                    } else {
                        // The refusal is provenance, not an error: it is how the arm's
                        // shortfalls get tuned, and the person sees the same read they
                        // would have seen with the arm switched off.
                        if case .refused(let refusal) = outcome {
                            run.outcome = Instrument.oneLine(refusal.label)
                        }
                        final = local
                    }
                    lastRun = run
                    await holdOrbToMinimumDwell(floor: Motion.orbLocalDwellSeconds)
                    guard !Task.isCancelled else { return }
                    parse.parseTask = nil
                    if interpretation.propose(final) {
                        reveal()
                    } else {
                        ModelMetrics.shared.recordRefusedProposal()
                    }
                    parkIfUnfinished(force: true)
                }
                return
            }
            // On-device posture + ONE thought + a model present: the single-thought
            // envelope the local model was measured to win (Private Capture's engine),
            // behind the same orb, landing on the same confirm card. With no model, both
            // on-device arms fall to the deterministic read exactly as before.
            if plan.arm == .privateEngine {
                IntelligenceLedger.shared.record(.onDevice, for: .ramble)
                understandingSince = .now
                Motion.withMotion(Motion.heroSettle) { phase = .understanding }
                parkIfUnfinished(force: true)
                parse.parseTask?.cancel()
                parse.parseTask = Task {
                    let learned = sessionRules()
                    let outcome = await PrivateCaptureEngine().finish(text: captured, learned: learned)
                    guard !Task.isCancelled else { return }
                    var run = CaptureRunTelemetry.local(
                        segmentation: Segmentation.structure(of: captured).label,
                        cloudAvailable: CloudModel.isReachable(for: .ramble))
                    run.parseMs = Int(Date().timeIntervalSince(localStarted) * 1000)
                    run.rung = IntelligenceRung.onDevice.rawValue
                    lastRun = run
                    await holdOrbToMinimumDwell(floor: Motion.orbLocalDwellSeconds)
                    guard !Task.isCancelled else { return }
                    parse.parseTask = nil
                    if interpretation.propose([outcome.draft]) {
                        reveal()
                    } else {
                        ModelMetrics.shared.recordRefusedProposal()
                    }
                    parkIfUnfinished(force: true)
                }
                return
            }
            IntelligenceLedger.shared.record(route.rung, for: .ramble)
            // The deterministic arm is measured too. It is the baseline the authority has
            // to beat, and a baseline with no number can't be one. Measured p50: 3ms.
            var run = CaptureRunTelemetry.local(
                segmentation: Segmentation.structure(of: captured).label,
                cloudAvailable: CloudModel.isReachable(for: .ramble))
            run.parseMs = localMs
            // The local route's cost, recorded where it is actually paid. It is the
            // baseline the cloud arm is judged against, and a baseline nobody measures
            // is an assumption.
            ModelMetrics.shared.recordProvisionalPass(latencyMs: localMs)
            lastRun = run
            if fromVoice {
                // A spoken capture earns the thinking beat even on the deterministic
                // route: the voice surface IS the orb, and cards flashing up the frame
                // after silence reads as "it didn't actually listen". Same-branch phase
                // change — only the status word animates; the orb decays from its
                // listening floor. The dwell runs inside `parse.parseTask`, so Back and
                // Discard cancel it exactly like the cloud arm's parse.
                understandingSince = .now
                Motion.withMotion(Motion.heroSettle) { phase = .understanding }
                parkIfUnfinished(force: true)
                parse.parseTask?.cancel()
                parse.parseTask = Task {
                    // The LOCAL floor: the read is ~2ms, so this dwell IS the reveal
                    // latency. A candidate UX beat judged on video, not a number the
                    // animation was shrunk to — see `Motion.orbLocalDwellSeconds`.
                    await holdOrbToMinimumDwell(floor: Motion.orbLocalDwellSeconds)
                    guard !Task.isCancelled else { return }
                    parse.parseTask = nil
                    if interpretation.propose(local) {
                        reveal()
                    } else {
                        ModelMetrics.shared.recordRefusedProposal()
                    }
                    parkIfUnfinished(force: true)
                }
            } else {
                // Typed structure reveals instantly — byte-identical to the pre-voice
                // arc: the user drew the boundaries, and a beat here would be theatre.
                interpretation.propose(local)
                reveal()
                parkIfUnfinished(force: true)
            }
        case .cloud:
            // The orb holds the screen and the result is the reveal. Nothing here may
            // tell the user which rung is thinking — a "thinking in the cloud" state
            // would be an intermediate semantic disclosure in everything but name, and
            // the reveal contract's whole point is that the user receives one answer,
            // not a progress report on how it was produced. That applies equally to the
            // offline degrade beneath this arm.
            understandingSince = .now
            Motion.withMotion(Motion.heroSettle) { phase = .understanding }
            parkIfUnfinished(force: true)
            runParse(captured, route: route, escalation: decision.escalation)
        }
    }

    /// The arrival. Everything that makes the reveal land as an ANSWER rather than a
    /// screen change happens here, in one place: the phase change on the hero spring, the
    /// stagger clock the cards ride in on, and the haptic — the flow's emotional peak had
    /// been the one moment in the app with no feedback of any kind.
    private func reveal() {
        revealedAt = .now
        // The contract's clock, computed ONCE and fed to both consumers — the receipt
        // (per-capture, persisted, what `CapturePerformanceReport` folds) and
        // `ModelMetrics` (the last-write footer scalar) — so the two can never
        // disagree about what the number means. Dwell is INSIDE it by owner decision:
        // perceived latency is honest latency. `parsedText` is the exact words this
        // card set was read from, so the tier describes what was actually parsed.
        if let submittedAt {
            let confirmMs = Int(Date().timeIntervalSince(submittedAt) * 1000)
            lastRun?.confirmMs = confirmMs
            lastRun?.tier = CapturePerformanceContract.Tier.tier(for: parsedText).rawValue
            lastRun?.sinceLastWordMs = pendingSinceLastWordMs
            lastRun?.fromVoice = pendingSinceLastWordMs != nil
            ModelMetrics.shared.recordConfirmReached(
                latencyMs: confirmMs, source: structureSource)
        }
        Motion.withMotion(Motion.heroSettle) { phase = .confirm }
        announceReveal()
    }

    /// The ONE model parse a capture gets, and it runs only on a model route — its
    /// result IS the reveal. There is deliberately no "enrich the already-revealed set"
    /// arm any more: `Interpretation` refuses a late proposal, so an arm that tried would
    /// be dead code that looked alive.
    ///
    /// `route` is passed through rather than re-derived: which rung thinks was decided
    /// once, at submit, and a second call to `CaptureRoute.route` here could disagree
    /// with the first if connectivity changed in between — the user would then be
    /// waiting behind an orb for an arm the router no longer believes in.
    private func runParse(
        _ captured: String, route: CaptureRoute,
        escalation: CaptureEscalationReason? = nil
    ) {
        parse.parseTask?.cancel()
        parse.parseTask = Task {
            let roster = rosterSnapshot
            let learned = sessionRules()
            let openTasks = openTaskSnapshots
            let suppressions = sessionSuppressions()
            let ownership = ownershipSnapshot
            EmbeddingStore.warmUp(openTaskIDs: Set(openTasks.map(\.id)), in: context)

            // THE BOUNDARY PASS, before anything is transmitted (WS4 / Campaign 5).
            //
            // The deterministic read under-segmented this capture, which is a BOUNDARY
            // failure and the one thing the on-device model is being asked for. It names
            // where each outcome begins, the app cuts the person's own words there, and
            // the existing validator judges the result. Accepted, the capture never leaves
            // the device and the orb's beat covers the whole pass; refused, the cloud arm
            // below runs exactly as it does today. The arm can only ever REMOVE a
            // transmission — it is unreachable on any other escalation reason, and it
            // cannot propose anything the validator has not cleared.
            //
            // Inert until `OnDeviceSegmenter.isRoutingEnabled` (see that file's header:
            // the GA report flips it, not an argument here).
            let segmentStarted = Date()
            if OnDeviceSegmenter.attempts(escalation),
                case .accepted(let segmented, let fragments) = await OnDeviceSegmenter.segment(
                    text: captured, learned: learned, ownership: ownership)
            {
                guard !Task.isCancelled else { return }
                parse.parseTask = nil
                var receipt = CaptureRunTelemetry.local(
                    segmentation: Segmentation.structure(of: captured).label,
                    cloudAvailable: CloudModel.isReachable(for: .ramble))
                receipt.rung = IntelligenceRung.onDevice.rawValue
                receipt.engineName = "on-device(segment→\(fragments))"
                // The receipt still names the reason the capture was ABOUT to transmit —
                // that is the provenance the escalation signals are tuned from, and the
                // arm's whole claim is that this reason was answered without the network.
                receipt.escalationReason = escalation?.rawValue
                receipt.parseMs = Int(Date().timeIntervalSince(segmentStarted) * 1000)
                lastRun = receipt
                IntelligenceLedger.shared.record(.onDevice, for: .ramble)
                await holdOrbToMinimumDwell(floor: Motion.orbMinimumDwellSeconds)
                guard !Task.isCancelled else { return }
                if interpretation.propose(segmented) {
                    reveal()
                } else {
                    ModelMetrics.shared.recordRefusedProposal()
                }
                parkIfUnfinished(force: true)
                return
            }

            // No partial handler: streamed snapshots would expose structure growing,
            // which is the whole thing this architecture exists to prevent. The
            // deadline's salvage still applies — it becomes the timeout path into
            // the reveal.
            let result = await brain.triage(
                captured, roster: roster, learned: learned, openTasks: openTasks,
                suppressions: suppressions, ownership: ownership, route: route,
                escalation: escalation)
            guard !Task.isCancelled else { return }
            parse.parseTask = nil
            EmbeddingStore.persistFresh(openTasks: openTasks, in: context)
            var receipt = result.telemetry
            // Why this capture cost a cloud call — the router's evidence, stamped on
            // the receipt so the escalation signals are tuned from provenance, not
            // recollection.
            receipt.escalationReason = escalation?.rawValue
            lastRun = receipt

            // The authority said "nothing here" (F-02): a spoken capture the verifier read
            // as a caught conversation, and the model — allowed to return nothing —
            // did. Settle to the canvas with the words, no cards, no error: the person can
            // read what was heard and type, or close and let it park.
            if result.drafts.isEmpty, escalation == .conversation,
                result.telemetry.outcome == "success" || result.telemetry.outcome == "salvaged"
            {
                await holdOrbToMinimumDwell(floor: Motion.orbMinimumDwellSeconds)
                guard !Task.isCancelled else { return }
                Motion.withMotion(Motion.heroSettle) { phase = .capture }
                focused = true
                parkIfUnfinished(force: true)
                return
            }
            // The model decides the structure; if it found nothing, the deterministic
            // read is the honest fallback rather than an empty screen.
            let final =
                result.drafts.isEmpty
                ? AppBrain.provisionalDrafts(captured, learned: learned) : result.drafts
            // The answer exists; the orb may not have finished arriving. Hold it to its
            // floor BEFORE proposing, so the reveal and the morph-out happen on the same
            // frame — waiting after the propose would leave the cards built and hidden,
            // and any cancellation in between would strand a revealed set behind an orb.
            await holdOrbToMinimumDwell(floor: Motion.orbMinimumDwellSeconds)
            guard !Task.isCancelled else { return }
            // Refused if the user somehow got to a reveal first (a race we don't expect,
            // but the guard is the point — it can't be argued with).
            if interpretation.propose(merge(fresh: final, into: interpretation.drafts)) {
                reveal()
            } else {
                ModelMetrics.shared.recordRefusedProposal()
            }
            // Zero tolerance, checked rather than assumed: whichever way that branch went,
            // a revealed set must be exactly what the user was shown.
            interpretation.assertNotMutated("after the model parse landed")
            parkIfUnfinished(force: true)
        }
    }

    /// Wait out whatever is left of the orb's minimum presence, if anything.
    ///
    /// The floor is a PARAMETER because the two routes deserve different beats (see
    /// `Motion.orbLocalDwellSeconds` vs `orbMinimumDwellSeconds`) and the call site is
    /// the only place that knows which path this is — an explicit argument beats the
    /// function sniffing route state. Almost always a no-op on the cloud path: it
    /// returns immediately for every capture slower than the floor, which is the
    /// population this product was built around.
    private func holdOrbToMinimumDwell(floor: TimeInterval) async {
        guard let understandingSince else { return }
        let remaining = floor - Date().timeIntervalSince(understandingSince)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    /// Back to the canvas with the words intact — nothing has been committed. The
    /// interpretation reopens: the user is about to say more, so the next parse is allowed
    /// to speak again. Their existing cards and any edits ride along.
    private func backToCapture() {
        groupTitle = nil  // a re-read is a new interpretation; the group was of the old cards
        parse.parseTask?.cancel()
        parse.parseTask = nil
        interpretation.reopen()
        understandingSince = nil
        pendingSinceLastWordMs = nil
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
    private func merge(fresh: [TaskDraft], into current: [TaskDraft]) -> [TaskDraft] {
        DraftMerge.merge(fresh: fresh, into: current, removed: removedDrafts)
    }

    // MARK: - The four surfaces

    /// CAPTURE — the typed canvas, the deliberate escape hatch. The AI is entirely
    /// absent here.
    ///
    /// The layout is two regions with different jobs: CONTENT (title, subtitle, the
    /// field) lives here, and the CONTROLS live in `captureBar`, pinned below as a
    /// safe-area inset. They used to share one stack, and every keyboard transition
    /// relaid the stack out — the button cluster tracked the keyboard faster than the
    /// field resized, so the buttons visibly slid through the content mid-transition.
    /// As an inset, the content is always laid out ABOVE the bar and nothing can cross
    /// anything; the bar also rides above the keyboard, so Ramble stays one tap away
    /// while typing instead of hiding under it.
    @ViewBuilder private var captureSurface: some View {
        Text("What's on your mind?")
            .screenTitleStyle()
            .padding(.top, Spacing.xs)
        Text("Dump it all here. I'll sort it out.")
            .supportingStyle()

        imageChip
        // GROWS with the words, between a floor and a ceiling — and never past the ROOM.
        // Never `maxHeight: .infinity`: the field's ZStack holds a TextEditor (itself
        // scrollable and greedy) and with no ceiling the layout pass doesn't settle —
        // the composer never presents at all. The floor keeps an empty canvas inviting;
        // the ceiling stops a long dump from pushing Ramble off screen, after which the
        // editor scrolls internally. Before this the box was a fixed 200–460pt, so one
        // typed line sat in a large empty rectangle with the keyboard up — the canvas
        // read as unfinished rather than generous.
        //
        // **The room clamp is what keeps Ramble above the keyboard, and it was measured
        // in, not reasoned in (2026-09-12).** With the keyboard up, the content region
        // above the bar shrinks to whatever the keyboard leaves; the title, subtitle and
        // this field's 160pt floor add up to more than that once the 154pt bar (Ramble
        // present) is subtracted, and a VStack that cannot shrink its children OVERFLOWS
        // — the inset bar rode 31pt under the keyboard, and the bottom of the primary
        // CTA with it. The bar had already been reordered once so the secondary row
        // took the loss instead; that moved the symptom, not the cause. A GeometryReader
        // in the field's slot reports exactly the room the stack has left, the field
        // takes at most that, and the bar is never pushed anywhere. The floor below is
        // one line, so the editor never collapses to a hairline on a short screen.
        GeometryReader { room in
            let height = min(
                clampedCanvasHeight, max(Self.canvasCompressedFloor, room.size.height))
            composerField
                .frame(height: height)
                .animation(Motion.settle, value: height)
                .overlay { transcriptHeightOracle }
                .matchedGeometryEffect(id: Self.rambleMorphID, in: rambleMorph)
        }
    }

    /// The canvas's control bar — the design system's pinned-CTA pattern (solid
    /// surface, safe-area inset, rides the keyboard). One structure, top to bottom:
    /// the mic hint when there is one (beside the control it explains, not floating
    /// mid-canvas), the primary Ramble CTA once there are words, and the compact
    /// input-mode row. Two capsules of one size, one row — the stacked, mismatched
    /// pills read as loose parts.
    private var captureBar: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            dictationHint
                .animation(Motion.fade, value: speech.state)
            // Three capsules in one row do not fit every width with their full labels,
            // and a capsule whose label wraps to two lines ("Speak / instead", "Add a /
            // photo") reads as a rendering fault on the product's front door. Every label
            // is single-line and fixed-width, so a candidate that would wrap is one that
            // does not fit — and the row degrades in the order the labels EARN their
            // room. The posture label goes last: "Read anywhere" / "On device" is the
            // privacy posture in the person's own words (F-03), and a bare padlock is not
            // that sentence. The mic and the photo are universal glyphs, both already
            // carry accessibility labels, so they yield first. "Speak instead" survives
            // wherever it fits.
            ViewThatFits(in: .horizontal) {
                inputModeRow(
                    mic: canSubmit ? "Speak instead" : "Speak", photo: "Add a photo", postureLabelled: true)
                inputModeRow(mic: "Speak", photo: "Photo", postureLabelled: true)
                inputModeRow(mic: nil, photo: nil, postureLabelled: true)
                inputModeRow(mic: nil, photo: nil, postureLabelled: false)
            }
            // Ramble appears only once there is something to ramble about. A disabled
            // primary button on an empty canvas is a dead affordance occupying the
            // spot the live one should own. It sits LAST — nearest the thumb and the
            // keyboard's top edge — because the secondary row above it was the half
            // getting clipped when the keyboard came up, and the primary CTA is the
            // one control in the bar that must never be.
            if canSubmit { rambleButton }
        }
        // Deliberately NOT animated. The empty and non-empty states are different
        // CONTAINERS (a stacked primary vs. a compact row), and asking SwiftUI to
        // interpolate between two structures cross-fades them into each other —
        // overlapping capsules and doubled labels for the length of the animation. The
        // swap happens on the first keystroke, where instant is also simply correct.
        .animation(nil, value: canSubmit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .background(Palette.background)
    }

    /// One candidate width of the input-mode row. See the `ViewThatFits` in `captureBar`.
    /// A nil label is the glyph-only form of that capsule.
    private func inputModeRow(mic: String?, photo: String?, postureLabelled: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            micButton(mic)
            imageButton(photo)
            Spacer(minLength: 0)
            postureChip(labelled: postureLabelled)
        }
    }

    /// The privacy posture, as a control beside the door (F-03). Bordered secondary,
    /// never the gradient; the accent marks the ON state only. Its state is also what
    /// `DataBoundary` says in Settings, so the sentence and the switch cannot disagree.
    private var postureChip: some View { postureChip(labelled: true) }

    private func postureChip(labelled: Bool) -> some View {
        Button {
            postureRaw = posture.toggled.rawValue
        } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: posture.glyph)
                    .font(.glyphCaption())
                if labelled {
                    Text(posture.label)
                        .font(.chipLabel)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(posture == .onDevice ? Palette.accentFlat : Palette.secondaryText)
            .padding(.horizontal, Spacing.sm)
            .frame(height: 32)
            .background(
                Capsule().strokeBorder(
                    posture == .onDevice ? Palette.accentFlat.opacity(0.6) : Palette.border, lineWidth: 1))
        }
        .buttonStyle(.pressable)
        .minimumHitTarget()
        .accessibilityLabel(
            posture == .onDevice ? "Captures stay on this device" : "Captures may use the cloud"
        )
        .accessibilityHint("Switches the capture privacy posture")
        .accessibilityAddTraits(posture == .onDevice ? .isSelected : [])
    }

    /// The submit affordance — the deliberate handoff, wearing the design system's
    /// primary-CTA treatment: the accent gradient on a full-height capsule, exactly
    /// like Create and the pinned detail CTA. (An `accentFlat` variant shipped briefly
    /// on the "don't spend the gradient twice in one flow" argument; the owner read it
    /// as off-system — 2026-08-27 — and the rule stands: one primary-CTA treatment,
    /// everywhere a primary CTA appears. The arc's build comes from the reveal's
    /// pacing, not from withholding the house style.) Rendered only when there is
    /// something to ramble about, so it never needs a disabled state.
    private var rambleButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkle")
                Text("Ramble").font(.ctaLabel)
            }
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Palette.accentGradient, in: Capsule())
        }
        .buttonStyle(.pressableProminent)
        // ⌘↩ from a hardware keyboard (iPad, a Mac keyboard on the phone): the canvas is
        // the typing landing, and a typist's hands are already on the keys.
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Ramble — turn what you said into tasks")
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !readingImage
    }

    /// LISTENING / UNDERSTANDING — one calm object, two tenures. The orb owns the
    /// screen; everything else is supporting cast, and the generous emptiness around it
    /// is what makes it feel important. No spinner, no progress, no counts, no candidate
    /// titles, no live transcript: while listening the orb shows RECEPTION (the mic
    /// level as presence), and while understanding the engine may revise its
    /// interpretation arbitrarily behind it — the screen must not move either way.
    @ViewBuilder private var orbSurface: some View {
        // The orb is sized from the surface, not from itself: "owns the screen" is a
        // relationship to the device, not a number of points. `GeometryReader` gives a
        // CONCRETE size to work from — `maxHeight: .infinity` on this screen previously hung
        // the layout pass and the composer never presented at all.
        GeometryReader { proxy in
            let orbSize = max(
                LayoutMetrics.rambleOrbMin,
                min(proxy.size.width, proxy.size.height) * LayoutMetrics.rambleOrbScreenFraction
            )
            VStack(spacing: Spacing.lg) {
                Spacer(minLength: 0)
                RambleOrb(diameter: orbSize, mode: orbMode)
                    .matchedGeometryEffect(id: Self.rambleMorphID, in: rambleMorph)
                    // Tappable, never button-shaped: no chrome, no press style — an
                    // object that happens to finish the capture when touched. The
                    // affordance is deliberately unexplained on screen (silence is the
                    // primary finish; the tap is explicit control for those who find
                    // it), but VoiceOver users are told, because for them it IS the
                    // primary control. Every modifier below is unconditional so the
                    // orb's view identity survives the tenure swap.
                    .contentShape(Circle())
                    .onTapGesture {
                        guard phase == .listening else { return }
                        // Listening: the tap is "done — make sense of it". Any other
                        // speech state (a hung warm-up, a mic that never arrived):
                        // the tap is an exit, because an orb that swallows taps over
                        // a dead mic is a locked door.
                        if speech.state == .listening {
                            finishListening()
                        } else {
                            typeInstead()
                        }
                    }
                    // DECORATIVE to assistive technology, deliberately — and only since
                    // the explicit controls below exist. The orb used to BE the finish
                    // control, so it had to announce itself as a button; now Done, the
                    // photo control and Type instead are real, labelled, reachable
                    // targets, and a fourth unlabelled "Done" over the whole screen
                    // would be a duplicate a VoiceOver user has to step past. Every
                    // modifier here stays unconditional so the orb's view identity
                    // survives the listening → thinking swap.
                    .accessibilityHidden(true)
                statusWord
                auxLine
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The controls are an OVERLAY, never members of the stack. The orb's
            // diameter is derived from THIS surface's geometry, so anything occupying
            // vertical room in the stack silently shrinks the hero — and the orb owning
            // the screen is the whole point of the surface. Overlaid, the row floats in
            // the orb's lower field and the orb is exactly the size it was.
            .overlay(alignment: .bottom) {
                if phase == .listening {
                    VStack(spacing: Spacing.md) {
                        // The privacy posture, on the door most people actually use.
                        // It lived only on the typed canvas's bar — so the person who
                        // opened INTO listening (the default) and was about to say
                        // something private had no way to see, let alone set, whether
                        // it would stay on the device without leaving the surface
                        // first. Same chip, same persisted switch; read at submit.
                        postureChip
                        listeningControls
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    /// The listening surface's three explicit controls — one for each direction out of
    /// voice: a photo instead, done now, or the keyboard. They are the only chrome on
    /// this screen and they sit at the very bottom, so the orb keeps the field above
    /// them; the generous emptiness between the two is what makes the orb feel important
    /// rather than parked on a toolbar.
    ///
    /// The orb stays tappable-to-finish underneath. That tap was always the explicit
    /// control for whoever found it; this row is what makes it findable, and what makes
    /// the other two exits reachable without leaving the surface first.
    private var listeningControls: some View {
        HStack(spacing: Spacing.md) {
            circleControl("photo", label: "Add a photo instead") { photoInsteadOfListening() }
            endVoiceButton
            circleControl("keyboard", label: "Type instead") { typeInstead() }
        }
        .padding(.bottom, Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    /// A secondary control on the orb surface: icon only, solid, quiet. Never glass
    /// (glass desaturates and there is nothing behind it here to refract) and never
    /// text-bearing — a label at this size would compete with the one primary.
    private func circleControl(
        _ systemImage: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.glyphAction())
                .foregroundStyle(Palette.secondaryText)
                .frame(width: LayoutMetrics.hitTarget, height: LayoutMetrics.hitTarget)
                .background(Palette.secondarySurface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressableIcon)
        .accessibilityLabel(label)
    }

    /// END VOICE — the deliberate handoff, made explicit. Silence still finishes a
    /// capture on its own (that is the calm path, and the reason there is no "tap to
    /// finish" copy on the orb), but waiting out five seconds when you already know you
    /// are done is a wait with nothing in it. This wears the house primary-CTA treatment
    /// for the same reason Ramble and Create do — it is the primary action of the screen
    /// it is on, and one gradient capsule at the bottom edge does not compete with a
    /// screen-filling orb.
    private var endVoiceButton: some View {
        Button {
            // Identical to the orb's tap, including the dead-mic escape: a Done button
            // over a warm-up that never arrived must not swallow the press.
            if speech.state == .listening { finishListening() } else { typeInstead() }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark")
                Text("Done").font(.ctaLabel)
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, Spacing.xl)
            .frame(height: 52)
            .background(Palette.accentGradient, in: Capsule())
        }
        .buttonStyle(.pressableProminent)
        .accessibilityLabel("Done — make sense of it")
        .accessibilityHint("Dictation also finishes on its own after a pause")
    }

    /// Photo, from the listening surface. A photo is a different input channel, and the
    /// mic cannot stay hot behind a picker — so this ENDS the voice tenure exactly the
    /// way Type instead does (words kept, nothing interpreted) and lands on the canvas
    /// with the picker already open.
    ///
    /// `phase` moves FIRST, before the stop: the speech-state observer's lifecycle rule
    /// treats any non-user drop as a fall-back-to-canvas *with the keyboard up*, and
    /// this is a user-initiated exit toward a camera roll, not toward a cursor.
    private func photoInsteadOfListening() {
        parse.silenceTask?.cancel()
        parse.silenceTask = nil
        silenceDeadline = nil
        Motion.withMotion(Motion.settle) { phase = .capture }
        speech.stop()
        foldTranscript()
        focused = false
        showPhotoPicker = true
    }

    /// Listening feeds the mic level in; every other tenure is the thinking gesture.
    /// This mode is the ONLY thing that changes at the silence swap — the orb keeps its
    /// view identity (one `switch` branch), so the contraction is a decay from the
    /// listening floor, never a re-mount.
    private var orbMode: RambleOrb.Mode {
        phase == .listening ? .listening(speech.audioLevel) : .thinking
    }

    /// The status word is supporting cast: a plain in-place crossfade, no movement, no
    /// scale — never an animated headline competing with the orb. The space keeps the
    /// line's height reserved while `.preparing` stays unlabeled.
    private var statusWord: some View {
        Text(statusText.isEmpty ? " " : statusText)
            .font(.sectionHeader)
            .foregroundStyle(Palette.primaryText)
            .contentTransition(.opacity)
            .animation(Motion.fade, value: statusText)
    }

    private var statusText: String {
        switch phase {
        case .understanding: return "Making sense of it"
        case .listening where speech.state == .preparing:
            // A barely perceptible beat: no label unless the warm-up runs long —
            // announcing states is what makes the orb feel less magical.
            return showPreparingLabel ? "Getting the mic ready…" : ""
        case .listening: return "Listening"
        default: return ""
        }
    }

    /// One auxiliary slot under the status word — reassurance in both tenures, always
    /// the metadata register, never the primary signal.
    @ViewBuilder private var auxLine: some View {
        if phase == .listening {
            listeningCountdown
        } else if showReassurance {
            // Honest about WHY it is still working: "a big one" was the only copy, and
            // it read under a three-item capture stalled on a dead network (2026-09-02).
            // The dump's size is a fact the router already computed; the stall is not
            // something the orb should explain.
            Text(
                CaptureRoute.captureDepth(for: text) != nil
                    ? "Still working — that was a big one." : "Still working on it."
            )
            .metadataStyle()
            .transition(.opacity)
        }
    }

    /// The silence window's visible tail. Muted microcopy only — the PRIMARY finishing
    /// signal is the orb itself calming as the level envelope drains; a ring or a
    /// countdown from the start would put a timer on thinking out loud, which is the
    /// opposite of a ramble.
    @ViewBuilder private var listeningCountdown: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let remaining = silenceDeadline.map { $0.timeIntervalSince(timeline.date) } ?? 0
            Text("Finishing up — keep talking to continue.")
                .metadataStyle()
                .opacity(remaining > 0 && remaining <= Self.countdownVisibleSeconds ? 1 : 0)
                .animation(Motion.fade, value: remaining <= Self.countdownVisibleSeconds)
        }
        .frame(height: Spacing.md)
    }

    /// The microcopy appears only for the tail of the silence window.
    static let countdownVisibleSeconds: TimeInterval = 2

    /// REVEAL / CONFIRM — the answer AND the words it was read from, as ONE scrollable
    /// page.
    ///
    /// The reveal used to show cards alone. That put the user in the position of judging
    /// "did it understand me?" with the *me* half missing: the capture they had just
    /// spoken was gone from the screen at exactly the moment it mattered most, and the
    /// only route back to it ("Say more") looked like a Cancel. The transcript now leads
    /// the page — editable, because it is their text — with the cards beneath it and the
    /// whole surface scrolling as one thing.
    ///
    /// Nothing here breaks the reveal contract. The cards on screen are still final
    /// against the SYSTEM (`Interpretation` refuses a late proposal); editing the
    /// transcript is a user act, and only a user act unlocks a second reading, which is
    /// precisely what `Re-read` does and why it appears only once the words have moved.
    ///
    /// The keyboard is never raised on arrival. This is a page you READ first; the
    /// cursor comes up when the field is tapped and leaves on a scroll or a tap outside.
    @ViewBuilder private var confirmSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(
                        interpretation.drafts.isEmpty
                            ? "Nothing actionable in that" : "Here's what I understood"
                    )
                    .screenTitleStyle()
                    if !interpretation.drafts.isEmpty {
                        Text(
                            Self.revealSubtitle(
                                count: interpretation.drafts.count, asks: unresolvedAskCount)
                        )
                        .supportingStyle()
                        .contentTransition(.numericText())
                        .animation(Motion.fade, value: unresolvedAskCount)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .matchedGeometryEffect(id: Self.rambleMorphID, in: rambleMorph)

                // A caption over the words. The box is the user's own capture, editable —
                // but under a title that says "what I understood", an unlabelled text box
                // read as a notes field, and its editability (the whole reason it is on
                // the page) went unnoticed. One quiet line says what it is and what it does.
                Text(transcriptCaption)
                    .metadataStyle()
                    .padding(.top, Spacing.xs)
                transcriptField
                addMoreRow

                if interpretation.drafts.isEmpty {
                    Text(Self.nothingFoundHint).supportingStyle()
                    keepAsOneTaskButton
                } else {
                    ConfirmCreationList(
                        drafts: $interpretation.editableDrafts,
                        ownerOptions: ownerOptions,
                        rosterNames: rosterNames,
                        onAddToRoster: { addToRoster($0) },
                        onRemove: { noteRemoval(of: $0) },
                        revealedAt: revealedAt
                    )
                    if interpretation.drafts.count >= 2 { groupRow }
                }
            }
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.md)
        }
        .alert("Group as one outcome", isPresented: $groupPrompt) {
            TextField("Outcome, e.g. Trip to Lagos", text: $groupDraftTitle)
            Button("Group") {
                let title = groupDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { Motion.withMotion(Motion.settle) { groupTitle = title } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These \(interpretation.drafts.count) tasks become its steps, in this order.")
        }
        // The keyboard is a guest on this page: it leaves the moment the user does
        // anything else with the surface.
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        // The removal's way back. The pill floats over the page's own bottom edge —
        // above the pinned Create bar, which is a safe-area inset — so it never covers
        // the CTA and never competes with it: one undo, four seconds, then gone.
        .undoNotice($cardNotice)
    }

    /// The one detail the reveal can ask for, counted across the cards.
    private var unresolvedAskCount: Int {
        interpretation.drafts.filter { $0.unresolved.contains(.date) }.count
    }

    /// The subtitle under "Here's what I understood": the count, and the ask when there is
    /// one. The ask is the only thing on the page that wants something BACK, and it used
    /// to be findable only by scanning every card for the one "When?" chip — VoiceOver
    /// users were told at the reveal; sighted users were not.
    static func revealSubtitle(count: Int, asks: Int) -> String {
        let things = count == 1 ? "1 thing" : "\(count) things"
        switch asks {
        case 0: return things
        case 1: return things + " · 1 needs a date"
        default: return things + " · \(asks) need a date"
        }
    }

    /// What the transcript box is, in the register of the channel it came through.
    private var transcriptCaption: String {
        switch captureSource {
        case .voice: return "What I heard — edit it if I misheard."
        case .image: return "What the photo said — edit it if I misread."
        default: return "What you wrote — edit it to change the tasks."
        }
    }

    /// The person's own act of grouping — "these are one thing" — at the one place a task
    /// comes into existence. A bordered secondary like "Keep it as one task": Create stays
    /// the page's one primary. Nothing here is proposed by the system; the umbrella is
    /// born at Create as the outcome the cards become steps of, in the order shown, and
    /// the list renders it as a deck. (The AI proposing a group is a separate change.)
    @ViewBuilder private var groupRow: some View {
        if let groupTitle {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "square.stack.3d.up")
                    .font(.glyphCaption())
                    .foregroundStyle(Palette.secondaryText)
                Text("Grouped as “\(groupTitle)”")
                    .supportingStyle()
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Button {
                    Motion.withMotion(Motion.settle) { self.groupTitle = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.glyphCaption())
                        .foregroundStyle(Palette.mutedText)
                }
                .buttonStyle(.plain)
                .minimumHitTarget()
                .accessibilityLabel("Ungroup")
            }
            .padding(.top, Spacing.sm)
            .transition(.opacity)
        } else {
            // When the capture NAMED its outcome ("Lagos trip: …"), the button carries the
            // name and one tap groups — the person's own words, read back, never a guess
            // (ungroup and tap again to rename through the alert). Otherwise the alert.
            let named = CaptureFlow.suggestedOutcomeTitle(from: text)
            Button {
                if let named {
                    Motion.withMotion(Motion.settle) { groupTitle = named }
                } else {
                    groupDraftTitle = ""
                    groupPrompt = true
                }
            } label: {
                Label(
                    named.map { "Group as “\($0)”" } ?? "Group as one outcome",
                    systemImage: "square.stack.3d.up"
                )
                .font(.controlLabel)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .padding(.horizontal, Spacing.md)
                .frame(height: 40)
                .background(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                .frame(minHeight: LayoutMetrics.hitTarget)
            }
            .buttonStyle(.pressable)
            .padding(.top, Spacing.sm)
            .accessibilityHint(
                named == nil
                    ? "Names an outcome these tasks become the steps of"
                    : "Makes these tasks the steps of that outcome")
        }
    }

    /// The person's answer to "nothing actionable in that": it is a task to them. A
    /// bordered secondary, never the gradient — Create stays the page's one primary, and
    /// this is a way forward, not a destination. Lands through the user's own edit path,
    /// so the reveal boundary is untouched: the system proposed nothing.
    private var keepAsOneTaskButton: some View {
        Button {
            guard let draft = CaptureFlow.keepAsOneTask(text: text, learned: sessionRules()) else {
                return
            }
            Motion.withMotion(Motion.settle) {
                interpretation.editableDrafts = [draft]
            }
            revealedAt = .now
        } label: {
            Label("Keep it as one task", systemImage: "plus")
                .font(.controlLabel)
                .foregroundStyle(Palette.primaryText)
                .padding(.horizontal, Spacing.md)
                .frame(height: 40)
                .background(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                .frame(minHeight: LayoutMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Makes one task from exactly what you said, with the details still editable")
    }

    /// A card left the reveal. Record it for the merge (so a re-read cannot resurrect
    /// it) AND offer the way back, in the same breath: the pill restores the card to the
    /// place it held and forgets the removal, so Undo is a true inverse.
    private func noteRemoval(of draft: TaskDraft) {
        let index = interpretation.drafts.firstIndex { $0.id == draft.id } ?? interpretation.drafts.count
        removedDrafts.record(draft)
        lastRemoved = (draft, index)
        cardNotice = UndoNotice(message: "Removed “\(draft.title)”") {
            restoreLastRemoved()
        }
    }

    private func restoreLastRemoved() {
        guard let removed = lastRemoved else { return }
        lastRemoved = nil
        removedDrafts.forget(removed.draft)
        Motion.withMotion(Motion.settle) {
            var drafts = interpretation.editableDrafts
            drafts.insert(removed.draft, at: min(removed.index, drafts.count))
            interpretation.editableDrafts = drafts
        }
    }

    /// The capture, as the user gave it, on the page where they judge what was made of
    /// it. Auto-growing: `TextEditor` does not self-size, and a fixed box leaves a short
    /// capture floating in emptiness while a long one needs a second scroll view inside
    /// the page's own. Past `transcriptMaxHeight` it scrolls internally, which by then is
    /// what the reader expects of a long transcript.
    private var transcriptField: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                .fill(Palette.primarySurface)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .strokeBorder(
                            focused
                                ? AnyShapeStyle(Palette.accentFlat) : AnyShapeStyle(Palette.border),
                            lineWidth: focused ? 1.5 : 1
                        )
                }
                .animation(Motion.fade, value: focused)

            TextEditor(text: $text)
                .focused($focused)
                .font(.bodyInput)
                .foregroundStyle(Palette.primaryText)
                .scrollContentBackground(.hidden)
                .padding(Spacing.sm)
                .accessibilityLabel("What you said")
                .accessibilityHint("Edit it, then Re-read to update the tasks.")
        }
        .frame(height: clampedTranscriptHeight)
        .animation(Motion.settle, value: clampedTranscriptHeight)
        .overlay { transcriptHeightOracle }
    }

    /// The measured natural height of the transcript, clamped to the page's budget.
    private var clampedTranscriptHeight: CGFloat {
        fieldHeight(min: Self.transcriptMinHeight, max: Self.transcriptMaxHeight)
    }

    /// Natural height for a growing field, between a floor and a ceiling. At the ceiling
    /// the height snaps DOWN to a whole number of lines: the editor scrolls internally
    /// from there, and a line sliced through the middle reads as clipping rather than as
    /// an invitation to scroll.
    private func fieldHeight(min minHeight: CGFloat, max maxHeight: CGFloat) -> CGFloat {
        let chrome = Spacing.sm * 2 + Self.transcriptEditorInset
        let natural = transcriptHeight + chrome
        if natural <= maxHeight { return max(natural, minHeight) }
        guard transcriptLineHeight > 0 else { return maxHeight }
        let lines = max(1, ((maxHeight - chrome) / transcriptLineHeight).rounded(.down))
        return chrome + lines * transcriptLineHeight
    }

    /// The height oracle: the same string, in the same font, at the same width — laid out
    /// at its ideal height and never drawn. `fixedSize` is what makes it honest; without
    /// it the measurement would be clamped by the very frame it exists to decide. The
    /// second, one-glyph measurement is the line height the ceiling snaps to.
    private var transcriptHeightOracle: some View {
        GeometryReader { proxy in
            let inner = proxy.size.width - Spacing.sm * 2 - Self.transcriptEditorHorizontalInset
            ZStack(alignment: .topLeading) {
                measuredHeight(of: text.isEmpty ? " " : text, width: inner) { transcriptHeight = $0 }
                measuredHeight(of: "A", width: inner) { transcriptLineHeight = $0 }
            }
            .hidden()
        }
        .allowsHitTesting(false)
    }

    private func measuredHeight(
        of string: String, width: CGFloat, into report: @escaping (CGFloat) -> Void
    ) -> some View {
        Text(string)
            .font(.bodyInput)
            .frame(width: max(1, width), alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size.height, initial: true) { _, height in
                            report(height)
                        }
                }
            }
    }

    /// The canvas field's measured height, clamped to the canvas's own budget — a
    /// taller floor than the confirm page's transcript (an empty canvas is an
    /// invitation) and a taller ceiling (a long dump is what this surface is for).
    private var clampedCanvasHeight: CGFloat {
        fieldHeight(min: Self.canvasMinHeight, max: Self.canvasMaxHeight)
    }
    private static let canvasMinHeight: CGFloat = 160
    private static let canvasMaxHeight: CGFloat = 420
    /// The floor under the room clamp: one input line. Below this the editor is a
    /// hairline with a cursor in it, which is worse than letting the bar lose a few
    /// points on a screen that short — and no portrait phone this app runs on is.
    private static let canvasCompressedFloor: CGFloat = LayoutMetrics.hitTarget

    /// A short capture must still read as a box, not a chip.
    private static let transcriptMinHeight: CGFloat = 88
    /// …and a long one must not push every card off the first screen.
    private static let transcriptMaxHeight: CGFloat = 220
    /// `TextEditor` adds its own text-container insets around the string; the oracle is a
    /// plain `Text` and has to account for them on BOTH axes or the box measures short.
    /// The horizontal one matters more than it looks: measuring 10pt too wide wraps one
    /// line fewer than the editor will, and the field renders a line short of its own
    /// content — which is what a clipped last line actually is.
    private static let transcriptEditorInset: CGFloat = Spacing.md
    private static let transcriptEditorHorizontalInset: CGFloat = 10

    /// Adding to a revealed capture. The transcript above is editable, so this row
    /// carries only the two channels a keyboard cannot reach — and `Re-read` appears
    /// ONLY once the words have actually moved. A standing re-read button on an
    /// untouched capture invites the user to audit an answer they were handed a second
    /// ago, which is exactly the cognitive work the product exists to remove.
    private var addMoreRow: some View {
        HStack(spacing: Spacing.sm) {
            // "Say more", never "Speak instead" — on this page the mic ADDS to a capture
            // that has already been read, and the tasks below stay.
            micButton("Say more")
            imageButton
            Spacer(minLength: 0)
            if transcriptEdited { rereadButton.transition(.opacity) }
        }
        .animation(Motion.fade, value: transcriptEdited)
    }

    /// Have the words moved since the cards were read from them?
    private var transcriptEdited: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != parsedText
    }

    private var rereadButton: some View {
        Button {
            reread()
        } label: {
            Label("Re-read", systemImage: "sparkle")
                .font(.controlLabel)
                .foregroundStyle(Palette.accentFlat)
                .padding(.horizontal, Spacing.md)
                .frame(height: 40)
                .background(Palette.accentSoft, in: Capsule())
                .frame(minHeight: LayoutMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Read the edited text again and update the tasks")
    }

    /// The user changed their own words on the reveal page. That is exactly the event
    /// `Interpretation.reopen` exists for — the system may speak again because the person
    /// spoke again — so this is the documented RE-SUBMIT path, not a second parse of the
    /// same capture: existing cards and any edits on them ride along through `merge`.
    private func reread() {
        parse.parseTask?.cancel()
        parse.parseTask = nil
        interpretation.reopen()
        submit()
    }

    /// The confirm page's pinned CTA — the same `safeAreaInset` treatment the canvas
    /// uses, for the same reason: in the content stack a keyboard transition relays the
    /// button through the page, and as an inset it rides above the keyboard instead.
    private var confirmBar: some View {
        VStack(spacing: Spacing.xs) {
            // The one thing a card can't be missing — the title binding has no
            // trim/empty guard (a user can select-all-delete it), so this is what
            // stops a blank, hard-to-find row from ever reaching the store, rather
            // than a guard buried in `createTasks()` that would silently drop the
            // card the user is looking at.
            if hasBlankTitledDraft {
                Text("Give every task a title before creating.")
                    .font(.supporting)
                    .foregroundStyle(Palette.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                createTasks()
            } label: {
                Text(createTitle)
                    .font(.ctaLabel)
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Palette.accentGradient, in: Capsule())
                    .contentTransition(.numericText())
                    .animation(Motion.fade, value: createTitle)
            }
            .buttonStyle(.pressableProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(interpretation.drafts.isEmpty || hasBlankTitledDraft || commitPendingRetry)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.sm)
        .background(Palette.background)
    }

    private var createTitle: String {
        let merged = interpretation.drafts.filter { $0.acceptedDuplicate != nil }.count
        return Self.createTitle(
            created: interpretation.drafts.count - merged, merged: merged, group: groupTitle)
    }

    /// The CTA says what pressing it DOES. "Create 3 tasks" over a set where one card
    /// merges into an existing task was a small lie the commit pill then had to correct
    /// a second later; the button is the last thing read before the commit, and it
    /// should be the first place the truth is stated.
    static func createTitle(created: Int, merged: Int, group: String? = nil) -> String {
        // Grouped, the button names the OUTCOME being created and the steps it gets —
        // the umbrella is the one task the cards did not show.
        if let group, created >= 2 {
            let base = "Create “\(group)” · \(created) steps"
            return merged == 0 ? base : base + " · merge \(merged)"
        }
        let createPart = created == 1 ? "Create 1 task" : "Create \(created) tasks"
        switch (created, merged) {
        case (_, 0): return createPart
        case (0, 1): return "Merge into existing task"
        case (0, _): return "Merge \(merged) into existing tasks"
        default: return createPart + " · merge \(merged)"
        }
    }

    /// `ConfirmCreationCard.titleBinding` has no trim/empty guard, so a card can
    /// reach here with a blank title (select-all-delete). Blocking Create — rather
    /// than silently excluding the card at commit — keeps every card the user sees
    /// accounted for in what gets created.
    private var hasBlankTitledDraft: Bool {
        interpretation.drafts.contains {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Speak the settled interpretation, once, at the reveal.
    ///
    /// **The arrival is the whole emotional beat of the arc**, and it was silent to a
    /// screen-reader user: sighted users get the orb dissolving into cards, a stagger and
    /// a haptic; VoiceOver got a layout change and no statement that anything had
    /// happened. This function existed for that and had lost its call site — it described
    /// a live parse ("candidates appear as you talk") that no longer exists, and nothing
    /// invoked it.
    ///
    /// It announces the SETTLED result and nothing before it, which the architecture now
    /// makes trivially true: there is exactly one interpretation and one reveal, so there
    /// is no intermediate state that could be spoken by mistake. It NAMES the tasks up to
    /// a small cap rather than only counting them — "three tasks" tells a sighted user
    /// nothing they can't see and tells a blind user nothing at all, whereas the titles
    /// are the answer to "did it understand me?", which is the question the reveal exists
    /// to answer.
    ///
    /// A no-op when VoiceOver is off.
    private func announceReveal() {
        let drafts = interpretation.drafts
        guard !drafts.isEmpty else {
            AccessibilityNotification.Announcement("Nothing actionable in that.").post()
            return
        }
        let titles = drafts.prefix(Self.spokenTitleCap).map(\.title)
        let remainder = drafts.count - titles.count
        var message = "\(drafts.count) task\(drafts.count == 1 ? "" : "s"): "
        message += titles.joined(separator: ", ")
        if remainder > 0 { message += ", and \(remainder) more" }
        // The one ask the reveal can carry (see `TaskDraft.unresolved`) — spoken because
        // it is the only thing on the surface that wants something back.
        let asks = drafts.filter { $0.unresolved.contains(.date) }.count
        if asks > 0 { message += ". \(asks == 1 ? "One task needs" : "\(asks) tasks need") a date" }
        AccessibilityNotification.Announcement(message + ".").post()
    }

    /// How many titles the reveal announcement names before summarising the rest. Four
    /// is about where a spoken list stops being a sentence and starts being a recitation
    /// the listener has to hold in their head.
    private static let spokenTitleCap = 4

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
        guard
            !interpretation.drafts.isEmpty
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        parse.lastParkAt = Date()
        parked = brain.park(
            interpretation.drafts, rawCapture: text, source: captureSource,
            imageRef: capturedImageRef,
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
        interpretation = Interpretation()
    }

    private func discard() {
        speech.stop()
        parse.silenceTask?.cancel()
        parse.silenceTask = nil
        silenceDeadline = nil
        parse.parseTask?.cancel()
        parse.parseTask = nil
        // Discard is the one destructive path — the photo goes with the thought.
        if let ref = capturedImageRef { CaptureImageStore.delete(ref) }
        capturedImageRef = nil
        if let parked { AppBrain.discard(parked, in: context) }
        parked = nil
        interpretation = Interpretation()
        removedDrafts = RemovedDraftSet()
        lastRemoved = nil
        cardNotice = nil
        lastRun = nil
        text = ""
        dismiss()
    }

    /// CREATE — the only place tasks come into existence. Nothing before this wrote to
    /// the store, which is what makes the whole arc safe to iterate behind.
    private func createTasks() {
        guard !interpretation.drafts.isEmpty else { return }
        speech.stop()
        parse.parseTask?.cancel()
        parse.parseTask = nil
        let count = interpretation.drafts.count
        brain.commit(
            interpretation.drafts, rawCapture: text, source: captureSource,
            imageRef: capturedImageRef,
            parked: parked, telemetry: lastRun, groupTitle: groupTitle, into: context)
        finishCommit(count: count)
    }

    /// Shared by the initial commit and a retried save. `context.saveChanges()`
    /// deliberately never rolls back on failure — the created `TaskItem`s stay
    /// pending in the context either way — so a failed commit isn't lost, only
    /// unconfirmed: this checks `brain.lastCommitSummary`, and either plays the
    /// real receipt or asks before the composer claims success it can't back up.
    private func finishCommit(count: Int) {
        guard brain.lastCommitSummary?.saveFailed != true else {
            pendingCreatedCount = count
            commitPendingRetry = true
            showSaveFailedAlert = true
            return
        }
        commitPendingRetry = false
        // Success notification moved here (from the point of calling `commit`) so a
        // dropped save never plays the success haptic right before the failure alert.
        committed += 1
        // Clearing is REQUIRED, not tidiness: `.onDisappear` runs `parkIfUnfinished`,
        // and it keys off `drafts`/`text` — leaving them populated would park a phantom
        // duplicate of the capture just committed.
        parked = nil
        interpretation = Interpretation()
        removedDrafts = RemovedDraftSet()
        lastRemoved = nil
        cardNotice = nil
        lastRun = nil  // spent: this receipt belongs to the capture just committed
        text = ""
        loadedSuppressions = nil  // commit wrote new rejections — the session cache is stale
        parse.cachedRules = nil  // likewise new corrections
        // Straight back to whatever the user was doing — capture is something you do
        // mid-life, not a place you go.
        //
        // There was a ✓ "N tasks added" receipt here, held for 0.9s before dismissing, and
        // it was REMOVED (2026-08-30, owner's call): it read as an extra screen standing
        // between Create and getting on with things. Confirmation now comes from the two
        // things that were always the stronger signals anyway — the success haptic
        // (`sensoryFeedback(.success, trigger: committed)`) and the tasks themselves,
        // visible in the list the moment the sheet is gone.
        //
        // The count is deliberately no longer stated anywhere. A merge still speaks,
        // because that is the one outcome the list cannot show you: `RootTabView`'s
        // `presentCommitNotice` pill fires on `CommitSummary.messageBeyondReceipt`.
        dismiss()
    }

    /// "Try Again" on the save-failed alert. The composer's own state (drafts,
    /// text, the parked capture) was never cleared on failure, so this is a plain
    /// retry of the same write rather than a re-parse or a second commit.
    private func retrySave() {
        let saved = context.saveChanges()
        brain.lastCommitSummary?.saveFailed = !saved
        finishCommit(count: pendingCreatedCount)
    }

    // MARK: - Field

    private var composerField: some View {
        ZStack(alignment: .topLeading) {
            // **A quiet container, always.** The bare-ground field was designed for a
            // canvas that led the screen; now the canvas is the deliberate typing
            // landing, and on device the borderless version read as unfinished — a
            // cursor floating over muted example text with no affordance saying
            // "words go here". Rest state is the calmest possible box (surface +
            // hairline); the accent border and glow remain reserved for the one live
            // moment (the model reading), so the upgrade still means something.
            RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                .fill(Palette.primarySurface)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .strokeBorder(
                            fieldIsLive
                                ? AnyShapeStyle(Palette.accentGradient)
                                : AnyShapeStyle(Palette.border),
                            lineWidth: fieldIsLive ? 1.5 : 1
                        )
                }
                // Soft glow while the model is thinking. (The mic is never hot on the
                // canvas any more — listening owns its own surface, the orb.)
                .shadow(
                    color: fieldIsLive ? Palette.accentGlow : .clear,
                    radius: fieldIsLive ? 16 : 0
                )
                .animation(Motion.glowPulse.repeatWhileTrue(fieldIsLive), value: fieldIsLive)

            if text.isEmpty {
                Text(
                    "Renew passport, book dentist, figure out if I should quit the side project, call mom…"
                )
                .foregroundStyle(Palette.mutedText)
                .font(.bodyInput)
                // EXACTLY the insertion point's origin: the editor below is padded by
                // `Spacing.sm`, and `TextEditor`'s own text container adds ~5pt of
                // lead and ~8pt of top inset. The placeholder must sit where the
                // first typed glyph will land, so the cursor blinks BEFORE it — the
                // native pattern. Misaligned, the cursor draws ON the first glyph,
                // which reads as a rendering bug (it was, on the first device run).
                .padding(.leading, Spacing.sm + 5)
                .padding(.top, Spacing.sm + 8)
                .padding(.trailing, Spacing.sm + 5)
                .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .focused($focused)
                .font(.bodyInput)
                .foregroundStyle(Palette.primaryText)
                .scrollContentBackground(.hidden)
                .padding(Spacing.sm)
                // The field is the typed escape hatch and it was unlabeled —
                // VoiceOver read only the (long, example-laden) placeholder.
                .accessibilityLabel("What's on your mind")
                .accessibilityHint("Type anything. It becomes tasks when you Ramble.")
        }
    }

    /// The field glows while the model reads. (The speech term is gone: the mic never
    /// runs while the canvas is showing, which is what made deleting the two-tone
    /// transcript safe.)
    private var fieldIsLive: Bool { brain.isProcessing }

    // MARK: - Dictation

    /// Capture by photo — the third input mode. Library-only in V1 (`PhotosPicker`
    /// is out-of-process, so no privacy prompt); the live camera is the recorded
    /// fast-follow. Recognized text streams into the SAME field the keyboard and
    /// the mic feed, so the rolling parse needs no new path.
    private var imageButton: some View { imageButton("Add a photo") }

    /// Nil title = glyph only (the row's tightest widths).
    private func imageButton(_ title: String?) -> some View {
        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
            Label(readingImage ? "Reading…" : (title ?? "Add a photo"), systemImage: "photo")
                .labelStyle(CapsuleLabelStyle(iconOnly: title == nil && !readingImage))
                .font(.controlLabel)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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
        let data: Data?
        do {
            // Unlike every model call in the app, this had no deadline: an iCloud-only
            // asset needing a slow download could hang "Reading…" indefinitely.
            data = try await ModelDeadline.race(timeout: ModelDeadline.photoImportSeconds) {
                try await item.loadTransferable(type: Data.self)
            }
        } catch {
            showPhotoImportFailedAlert = true
            return
        }
        guard let data, let image = UIImage(data: data), let cgImage = image.cgImage else {
            showPhotoImportFailedAlert = true
            return
        }
        if let previous = capturedImageRef { CaptureImageStore.delete(previous) }
        capturedImageRef = CaptureImageStore.save(data)
        capturedThumb = image
        usedImage = true
        do {
            let recognized = try await ModelDeadline.race(timeout: ModelDeadline.photoImportSeconds) {
                try await ImageTextExtractor.text(from: cgImage)
            }
            // A photo with no text in it is `ImageTextExtractor`'s documented normal
            // outcome, not a failure — stays silent.
            guard !recognized.isEmpty else { return }
            // Entering through `text` is the whole design: onChange → the rolling parse.
            text = text.isEmpty ? recognized : text + "\n" + recognized
        } catch {
            if error is CancellationError {
                // The sheet was dismissed while OCR was running. The file was already
                // saved at this point; clean it up now so it doesn't persist without a
                // Capture row to reference it.
                if let ref = capturedImageRef { CaptureImageStore.delete(ref) }
                capturedImageRef = nil
                capturedThumb = nil
                usedImage = false
            } else {
                // A genuine Vision failure (or a timeout) is NOT the same outcome as "no
                // text found" — collapsing them made a failed read indistinguishable from
                // "the tap didn't register."
                showOCRFailedAlert = true
            }
        }
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

    /// Nil title = glyph only (the row's tightest widths).
    private func micButton(_ title: String?) -> some View {
        // Always the compact form: the way INTO voice is the orb the sheet opens on —
        // reaching this canvas means the user chose typing (or the mic can't lead),
        // so a full-width Speak here would argue with the landing they picked. It
        // matches `imageButton` exactly; the old stacked, mismatched pair read as
        // loose parts. (The active states are gone: the mic never runs while the
        // canvas is showing — Speak returns to the orb.)
        Button {
            let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            beginListening(from: base.isEmpty ? "" : base + " ")
        } label: {
            // "Instead" only once there is something to do instead OF.
            Label(title ?? "Speak", systemImage: "mic.fill")
                .labelStyle(CapsuleLabelStyle(iconOnly: title == nil))
                .font(.controlLabel)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(micUsable ? Palette.primaryText : Palette.mutedText)
                .padding(.horizontal, Spacing.md)
                .frame(height: 40)
                .background(Palette.secondarySurface, in: Capsule())
                // Visual capsule stays 40pt; the TOUCHABLE region meets the HIG
                // minimum — this is tapped at arm's length while multitasking.
                .frame(minHeight: LayoutMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!micUsable)
        .accessibilityLabel("Dictate")
    }

    /// Whether Speak can lead anywhere. Denied is knowable BEFORE any attempt
    /// (`AVAudioApplication`), so the canvas can disable the button and show the
    /// Settings hint at entry rather than mounting an orb that bounces straight back.
    private var micUsable: Bool {
        if case .unavailable = speech.state { return false }
        if speech.state == .denied { return false }
        return AVAudioApplication.shared.recordPermission != .denied
    }

    /// Why the mic can't lead, when it can't — denied (Settings SECONDARY; typing is
    /// already available right here) or unavailable. The listening states themselves
    /// live on the orb surface now; the canvas never hosts a hot mic.
    @ViewBuilder private var dictationHint: some View {
        if case .unavailable(let message) = speech.state {
            Text(message)
                .metadataStyle()
                .transition(.opacity)
        } else if !micUsable {
            HStack(spacing: Spacing.xs) {
                Text("Microphone access is off.")
                    .metadataStyle()
                Button("Open Settings") { openSettings() }
                    .font(.metadata.weight(.semibold))
                    .foregroundStyle(Palette.accentFlat)
                    .buttonStyle(.pressableLink)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Listening

    /// Open the mic INTO the orb. `base` is what the transcript appends after — empty
    /// on the fresh open, the canvas's words plus a separating space when Speak
    /// re-enters from typing (the field → orb morph comes free from the matched pair).
    private func beginListening(from base: String) {
        // Speak can be entered from the REVEAL page as well as the canvas, and there the
        // interpretation is already revealed — so the next parse would be refused and the
        // user's new words would vanish into a no-op. The person is about to speak again,
        // which is the one event that lets the system speak again; their existing cards
        // and edits ride along through `merge`. A no-op on every other entry.
        interpretation.reopen()
        dictationBase = base
        focused = false
        showPreparingLabel = false
        Motion.withMotion(Motion.settle) { phase = .listening }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-DriveListeningLevel") {
            driveCannedLevel()
            return
        }
        if args.contains("-HoldListening") { return }
        #endif
        Task {
            try? await Task.sleep(for: .seconds(Self.preparingLabelAfterSeconds))
            guard phase == .listening, speech.state == .preparing else { return }
            Motion.withMotion(Motion.fade) { showPreparingLabel = true }
        }
        // The warm-up watchdog. `.preparing` can legitimately run long (the first-run
        // speech-model download) — the label above reassures — but it can also hang
        // forever (seen on the simulator: the transcriber's locale query never
        // returned), which would strand the user on a silent orb with a dead mic: no
        // transcript ever arrives, so the silence finish never arms. Past the
        // deadline, stopping the service drives `.idle`, and the lifecycle rule does
        // what it does for every non-user drop: settle to the canvas with the
        // keyboard up. Generous on purpose — a slow download must not be cut off.
        Task {
            try? await Task.sleep(for: .seconds(Self.preparingWatchdogSeconds))
            guard phase == .listening, speech.state == .preparing else { return }
            speech.stop()
        }
        Task { await speech.start() }
    }

    /// The escape hatch's action, and the orb's accessibility escape: keep whatever was
    /// said, put the keyboard up.
    private func typeInstead() {
        parse.silenceTask?.cancel()
        parse.silenceTask = nil
        silenceDeadline = nil
        speech.stop()
        foldTranscript()
        Motion.withMotion(Motion.settle) { phase = .capture }
        focused = true
    }

    /// Silence's completion signal, and the orb tap's. Idempotent by construction: the
    /// timer and a tap can land on the same beat, and the second caller finds the mic
    /// already stopped and bails on the guard.
    private func finishListening() {
        guard phase == .listening, speech.state == .listening else { return }
        // The silence-window measurement, read while the deadline is still alive: how
        // long the last word had been hanging when the capture finished. ≈5000 when
        // the timer fired this; less when a tap did. The receipt's UX parameter.
        pendingSinceLastWordMs = Self.sinceLastWord(deadline: silenceDeadline, now: Date())
        // Cancel FIRST: the tap/timer race must not double-finish, and a submit below
        // must not leave a live timer behind the understanding beat.
        parse.silenceTask?.cancel()
        parse.silenceTask = nil
        silenceDeadline = nil
        speech.stop()
        foldTranscript()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.finishAction(trimmed: trimmed) {
        case .toCanvas:
            Motion.withMotion(Motion.settle) { phase = .capture }
            focused = true
        case .submit:
            submit(fromVoice: true)
        }
    }

    /// Pull what the mic heard into `text` explicitly. The live `.onChange` mirror
    /// usually keeps them equal, but a delta arriving during teardown may never
    /// deliver — and everything downstream (park, submit, the toolbar label) reads
    /// `text`. Callers gate on the listening tenure, so a stale transcript from an
    /// earlier dictation can never overwrite typed edits.
    private func foldTranscript() {
        guard !speech.transcript.isEmpty else { return }
        let folded = dictationBase + speech.transcript
        if folded != text { text = folded }
    }

    /// How long a transcript silence runs before the capture finishes itself. Generous
    /// on purpose: the product's core scenario is a RAMBLE — an overloaded person
    /// thinking out loud — and thinking pauses routinely pass 2.5s, which is where the
    /// old window sat; it cut people off mid-thought and the tail of the ramble was
    /// gone. A DELIBERATE fixed five seconds: deterministic and understandable beats
    /// adaptive — make it energy-aware only if real usage shows cut-offs.
    private static let silenceStopSeconds: Double = 5

    /// Milliseconds from the last transcript delta to `now`. The deadline is armed at
    /// last-delta + `silenceStopSeconds`, so the delta's instant is recoverable from it
    /// without a second clock — nil deadline (no words ever armed it) → nil. Pure, so
    /// the arithmetic is testable without a mic.
    static func sinceLastWord(deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return nil }
        let lastDelta = deadline.addingTimeInterval(-silenceStopSeconds)
        return Int(now.timeIntervalSince(lastDelta) * 1000)
    }

    /// "Getting the mic ready…" appears only past this — the same progressive
    /// disclosure as the 8s reassurance line.
    private static let preparingLabelAfterSeconds: TimeInterval = 2

    /// A warm-up still `.preparing` past this is treated as a drop, not a download.
    private static let preparingWatchdogSeconds: TimeInterval = 30

    /// Arm (or re-arm) the silence finish. ONE cancellable handle, cancel-and-replace
    /// per transcript delta — the old shape spawned an uncancelled sleeping Task per
    /// tick, unbounded by design. The deadline is published so the orb surface can show
    /// the window's visible tail as quiet microcopy.
    private func scheduleSilenceFinish() {
        parse.silenceTask?.cancel()
        silenceDeadline = Date().addingTimeInterval(Self.silenceStopSeconds)
        parse.silenceTask = Task {
            try? await Task.sleep(for: .seconds(Self.silenceStopSeconds))
            guard !Task.isCancelled, phase == .listening, speech.state == .listening
            else { return }
            finishListening()
        }
    }

    #if DEBUG
    /// `-DriveListeningLevel`: feed the level monitor a canned reception-test envelope
    /// (silence → whisper → conversational → emphatic → pause) at buffer cadence, so
    /// the audio-reactive orb is verifiable headlessly — a screen recording of this run
    /// is the reception test's input. Implies the `-HoldListening` hold (no real mic).
    private func driveCannedLevel() {
        parse.levelDriveTask?.cancel()
        parse.levelDriveTask = Task {
            let envelope: [Double] = [
                0, 0, 0, 0.02, 0.03, 0.02, 0,
                0.10, 0.14, 0.12, 0.16, 0.11, 0.13,
                0.30, 0.42, 0.38, 0.45, 0.35, 0.40,
                0.62, 0.75, 0.68, 0.80, 0.70, 0.66,
                0.20, 0.08, 0.02, 0, 0, 0, 0,
            ]
            while !Task.isCancelled {
                for raw in envelope {
                    guard !Task.isCancelled else { return }
                    speech.audioLevel.ingest(rawLevel: raw)
                    try? await Task.sleep(for: .milliseconds(85))
                }
            }
        }
    }
    #endif

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
    /// The single silence-finish in flight; cancelled and replaced on every
    /// transcript delta, cancelled outright on finish/escape/disappear.
    var silenceTask: Task<Void, Never>?
    /// DEBUG `-DriveListeningLevel` only: the canned-envelope feeder.
    var levelDriveTask: Task<Void, Never>?
}

#Preview {
    ComposerView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}

/// A `Label` that keeps its icon and drops its title on the input-mode row's tightest
/// widths. A style rather than two `Label`s so the capsule's font, padding and height are
/// written once; `ViewThatFits` picks which form renders.
private struct CapsuleLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: Spacing.inline) {
                configuration.icon
                configuration.title
            }
        }
    }
}
