//
//  RootTabView.swift
//  Project-Ezra
//
//  The app shell: the SYSTEM tab bar (Brief · Tasks) with one app-owned control beside it
//  in the same row — the circular Capture orb (`captureOrbButton`). The loop IS the
//  navigation: you ramble in, you work the Tasks. Review is not a destination; first
//  launch presents the onboarding transformation.
//
//  The Brief was CUT on 2026-09-02 (two equal pillars: Ramble/Capture and the Advisor);
//  its tab, sequence, seams and reminder are gone. Tasks is the floor of the tab range.
//
//  **The division of labour, and the rule for changing anything here:** the OS owns the
//  tab bar — its rendering, selection, safe area and accessibility — and the app owns
//  exactly one control, because iOS 27 publishes no way to place a custom view inline with
//  an EXPANDED tab bar (`tabViewBottomAccessoryPlacement` is get-only, and `.inline` only
//  happens once the bar minimizes). Positioning the orb ourselves is therefore the
//  smallest custom chrome that can express "the orb is always beside the bar". Any change
//  that would require modifying the native bar's visual hierarchy is the wrong approach.
//
//  A fully custom bottom bar was built here and REVERTED (2026-08-29, same day): it drew
//  Brief · Capture · Tasks in one hand-rolled glass capsule, which cost the OS's rendering
//  and safe-area management and bought a composition the owner didn't want. Do not
//  resurrect it.
//
//  The Inbox and Household TABS were cut (product shape v2, 2026-08-18) — surfaces cut,
//  systems relocated. The trust surface survives as `ActivityView`, a sheet this shell
//  owns; multiplayer survives as substrate (the roster, born-owned tasks, the publish
//  boundary at Confirm) with roster editing one tap deep in the Tasks "…" menu.
//
//  Activity is mounted HERE, once, on purpose. It is reachable from two places (the
//  Tasks header and the Brief's held-depth tile) and belongs to neither; the last time a
//  surface's only mount point lived inside another surface's conditional container, a
//  change to that container silently deleted it for three weeks (`MyTasksHeader`).
//

import CoreData
import FoundationModels
import SwiftUI

/// The one way any screen opens the global capture composer — injected by the
/// shell so deep views (empty states, cards) never need their own sheet plumbing.
extension EnvironmentValues {
    @Entry var openCapture: () -> Void = {}
    /// Ask about everything — the household inquiry, summoned as a sheet from where you
    /// are (F-12), with the same bubble glyph the task pager uses for its own scope.
    @Entry var openAsk: () -> Void = {}
    /// Reopen a specific parked capture (the Today "captures waiting" line). Distinct
    /// from `openCapture`, which always begins a fresh one.
    @Entry var resumeCapture: (Capture) -> Void = { _ in }
    /// Open the Activity screen — the change log with action-aware Undo. Used by the
    /// Tasks header and the Brief's held-depth tile. It is an environment action rather
    /// than a local sheet for the same reason `openCapture` is: the surface has one
    /// mount point, in the shell, and no screen owns it.
    @Entry var openActivity: () -> Void = {}
}

/// One presentation of the capture composer. Fresh id per open — every open is a new
/// session by construction, and `sheet(item:)` hands this value to the content
/// closure directly (see `RootTabView.composerSession` for why that's load-bearing).
private struct ComposerSession: Identifiable {
    let id = UUID()
    let resuming: Capture?
    var autoSubmit = false
}

struct RootTabView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @Environment(\.managedObjectContext) private var context
    @Environment(AppBrain.self) private var brain
    /// Gates the bar orb's timeline — a permanently-mounted animation has no business
    /// running while the app is backgrounded. (The Reduce Transparency / Increase Contrast
    /// reads that used to live here went with the FAB's hand-rolled glass lens; the bar
    /// routes through `.glassChrome`, which owns both fallbacks itself.)
    @Environment(\.scenePhase) private var scenePhase
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    private var familyMembers: [FamilyMember] { Array(familyMembersResults) }
    @State private var showOnboarding: Bool

    init() {
        // Onboarding is decided once, before the first body pass, from the persisted flag —
        // so a returning user never sees the cover flash for a frame.
        _showOnboarding = State(initialValue: !UserDefaults.standard.bool(forKey: "hasOnboarded"))
    }
    /// The Activity screen's one mount point. Deliberately not a tab and deliberately
    /// not badged: the trust surface is something you go to when you want to check or
    /// undo, never something that asks to be visited (guardrail 1, calm over
    /// engagement — the unread TAB BADGE died with the tab, and good riddance; the
    /// per-row unread dots survive inside, where they answer "what's new since I looked"
    /// for someone who already chose to look).
    @State private var showActivity = false
    /// The presented composer session, item-based ON PURPOSE: with the paired
    /// `isPresented` + `resumingCapture` shape, SwiftUI evaluated the sheet's content
    /// closure once with the STALE nil resume target and re-evaluated with the real
    /// one only after `ComposerView` had already mounted and run its restore — so a
    /// resume silently opened a fresh composer (verified via the `-OpenCapture`
    /// console seam). `sheet(item:)` hands the closure the value itself; the race is
    /// unrepresentable. `resuming` nil = a fresh capture — opening the composer always
    /// starts a NEW one, so being interrupted twice never overwrites the first thought.
    @State private var composerSession: ComposerSession? = nil
    @State private var showAsk = false
    /// Private Capture — the long-press sibling of the capture orb. A Bool, not a
    /// session type: the mode has no resume semantics (one thought, kept or not).
    /// The transient "Added N tasks" receipt, shown after the composer closes.
    @State private var commitNotice: UndoNotice? = nil
    /// Whether the keyboard is up. The orb hides under it (`body`): the composer's
    /// capture bar owns that space while a keyboard is showing.
    @State private var keyboardUp = false


    var body: some View {
        // The orb belongs to the BAR, and the keyboard covers the bar. Both
        // `.overlay` on the TabView and a ZStack sibling with `.ignoresSafeArea(.keyboard)`
        // laid the orb out against the keyboard-reduced bounds — it rode up and sat on
        // the Ask composer's Send button (measured twice, 2026-09-02) — so the fix is
        // explicit: while the keyboard is up the orb is hidden and its timeline paused.
        // An orb beside no bar means nothing; hiding it is the truthful state, not a
        // workaround. Keyboard avoidance inside the tabs is untouched.
        ZStack(alignment: .bottomTrailing) {
            // ONE surface and one verb beside it. The tab bar went with the Brief and
            // the Ask tab (F-12): Tasks is the record, the orb is capture, and Ask is a
            // sheet summoned from the Tasks header — the same grammar as the task
            // pager's Ask bubble, so asking is one gesture at every scope.
            TasksHomeView()
                // The tab bar used to supply the bottom inset the list scrolled clear
                // of; with the bar gone the orb would sit over the last row. One inset,
                // sized to the orb and its padding, so the list ends above it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: Self.captureButtonDiameter + Spacing.md * 2)
                }
            captureOrbButton
                .opacity(keyboardUp ? 0 : 1)
                .allowsHitTesting(!keyboardUp)
                .animation(Motion.fade, value: keyboardUp)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in keyboardUp = true }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in keyboardUp = false }
        .undoNotice($commitNotice, bottomInset: Spacing.xxl)
        .environment(\.openCapture, { presentComposer(resuming: nil) })
        .environment(\.resumeCapture, { capture in presentComposer(resuming: capture) })
        .environment(\.openActivity, { showActivity = true })
        .environment(\.openAsk, { showAsk = true })
        .sheet(isPresented: $showAsk) { HouseholdChatView() }
        // Item-based, so however the sheet closed (commit, discard, swipe) the session
        // clears with it — the next open starts fresh unless \.resumeCapture re-arms it.
        .sheet(item: $composerSession, onDismiss: { presentCommitNotice() }) { session in
            ComposerView(resuming: session.resuming, autoSubmit: session.autoSubmit)
        }
        .sheet(isPresented: $showActivity) { ActivityView() }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                hasOnboarded = true
                showOnboarding = false
            }
        }
        .task { await onLaunch() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumePendingCapture() }
        }
    }

    /// Everything the shell does once at launch — identity, seeds, the diagnostic
    /// seams, the verification seams. Hoisted out of `body` when the root became a
    /// ZStack (the orb's keyboard fix) so the launch sequence reads in one place.
    private func onLaunch() async {
        do {
            // The daily nudge used to route here (`pendingOpenBriefing` → `selection = 0`,
            // both on `onChange` and on this cold-launch path). Both are gone with the
            // Brief: nothing schedules that notification any more, and an assignment to a
            // destination the bar renders as unavailable is exactly the kind of dead path
            // that quietly comes back. the app now sends no notifications at all.
            if ProcessInfo.processInfo.arguments.contains("-SeedFlowFixtures") {
                // Flow fixtures own their identity setup (a named "you" member + owned
                // tasks), so bootstrap is deliberately not called here.
                seedFlowFixturesIfRequested()
                       } else {
                // Guarantee the current user exists as a real household member before any
                // surface computes `isMine` or any capture stamps ownership.
                UserProfile.bootstrapIdentity(in: context)
                await seedIfRequested()
            }
            await LaunchSeams(brain: brain, context: context, familyMembers: familyMembers).run()
            #if DEBUG
            // FM viability diagnosis: refuses to share a launch with -RambleEval
            // (which prewarms the state it measures) — the guard is inside.
            await FMDiagnostics.runIfRequested(brain: brain)
            // Campaign 3: the Private Capture envelope (bounded single-intent FM).
            await QuickCaptureDiagnostics.runIfRequested(brain: brain)
            await AdvisorDiagnostics.runIfRequested()
            // Gold-standard-first routing discovery: which cases measurably need depth.
            await AdvisorBenchmark.runIfRequested()
            // The Ask tab's eval: the floor and retrieval cases (CI-tested) plus the
            // model arm's grounding, served ratio and latency (device numbers).
            await HouseholdChatEval.runIfRequested(brain: brain)
            // Coverage reads the LIVE store (the fixtures next door answer a different
            // question), so it runs here where the real context is in scope.
            AdvisorCoverageDiagnostics.runIfRequested(in: context)
            #endif
            openActivityIfRequested()
            await openCaptureIfRequested()
            consumePendingCapture()
            askHouseholdIfRequested()
        }
    }

    /// Deterministic verification seam. `-AskHousehold "question"` sends one question
    /// through the LIVE household store on the Ask tab (pair with `-InitialTab 2`), so
    /// a floor answer's rows or the model's reply — or the honest failure line — is
    /// screenshot-reachable without a keyboard. `-HouseholdChatFixture` seeds a canned
    /// thread instead (a cited floor answer, a model answer, a reply in flight) for a
    /// host with no model. Never fires in normal runs.
    private func askHouseholdIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let facts = HouseholdChatFacts.make(
            tasks: (try? context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? [],
            members: familyMembers, currentUserID: UserProfile.currentMemberID(in: context))
        if args.contains("-HouseholdChatFixture") {
            HouseholdChatStore.shared.seedFixture(
                citing: Array(facts.overdue.prefix(3)).map(\.id))
            showAsk = true
        }
        if let flag = args.firstIndex(of: "-AskHousehold"), args.indices.contains(flag + 1) {
            HouseholdChatStore.shared.ask(args[flag + 1], facts: facts)
            showAsk = true
        }
        #endif
    }

    /// Deterministic verification seam. Launch with `-OpenActivity` to present the
    /// Activity screen, which stopped being a tab in the v2 collapse and is now two taps
    /// deep behind the Tasks "…" menu — a Menu, and opening one needs a tap Accessibility
    /// blocks here. The screen that has to prove "every AI action is undoable" should
    /// stay reviewable without one. Never fires in normal runs.
    private func openActivityIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-OpenActivity") else { return }
        showActivity = true
    }

    /// Deterministic verification seam. Launch with `-OpenCapture ["text"]` to present
    /// the composer at launch — the one capture surface no other arg could reach
    /// (synthetic taps are blocked here, and the composer only opens from a tap). With
    /// a text argument the seam parks that text as a `Capture` and RESUMES it, and the
    /// composer submits it for us, so every phase of the Ramble arc is screenshot-
    /// reachable headlessly. Two companion flags pick which one you land on:
    /// `-NoSubmit` holds the capture canvas, and `-AutoCreate` taps Create so the ✓
    /// receipt and the return are reachable too. Never fires in normal runs.
    private func openCaptureIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-OpenCapture") else { return }
        var target: Capture?
        if args.indices.contains(flag + 1), !args[flag + 1].hasPrefix("-") {
            let capture = Capture(rawText: args[flag + 1], source: .text, in: context)
            // Parked with drafts pending — exactly the shape resume re-parses from.
            capture.parkedDrafts = []
            context.insert(capture)
            context.saveChanges()
            target = capture
        }
        // Let the launch render pass settle before presenting over it.
        try? await Task.sleep(for: .milliseconds(300))
        presentComposer(resuming: target)
    }

    /// The one way the composer is presented. Every entry point (the FAB, `openCapture`,
    /// `resumeCapture`) warms the substrate, sets the resume target explicitly — a stale
    /// one must never leak into a fresh capture — and clears any unconsumed commit
    /// summary, so a seed-path commit can't fire a receipt on a later dismiss.
    private func presentComposer(resuming capture: Capture?, autoSubmit: Bool = false) {
        // Warm the model + retrieval substrate NOW: the sheet-presentation animation
        // absorbs the cost, so the first parse doesn't pay it against the user's pause.
        AppBrain.prewarmCapture(in: context)
        brain.lastCommitSummary = nil
        composerSession = ComposerSession(resuming: capture, autoSubmit: autoSubmit)
    }

    /// Words handed over by an App Intent (F-01) — "Hey Siri, tell Ezra…", the Action
    /// Button, Shortcuts. Parked as a `Capture` (the shape a dismissed composer leaves)
    /// and resumed with `autoSubmit`, so the person lands on the confirm card: nothing
    /// said is retyped, nothing is created without the one human moment.
    private func consumePendingCapture() {
        guard let pending = PendingCapture.shared.consume() else { return }
        let capture = Capture(rawText: pending.words, source: pending.source, in: context)
        capture.parkedDrafts = []
        context.insert(capture)
        context.saveChanges()
        presentComposer(resuming: capture, autoSubmit: true)
    }

    /// Speak for a confirm that just happened, once — and ONLY about a MERGE.
    ///
    /// This used to be justified as "what the composer's ✓ receipt couldn't say", the
    /// receipt having delivered the count. That receipt was removed on 2026-08-30 (it read
    /// as an extra screen), so this pill is now the ONLY thing that speaks after a commit —
    /// and it still deliberately says nothing about the count. The list the user just
    /// landed on shows the new tasks; a merge is the one outcome it cannot show, because
    /// the merged capture is folded into a task that was already there.
    ///
    /// Deliberately no Undo button: undoing a batch means deleting the created tasks AND
    /// reversing each merge AND unwinding the blocker edges commit wrote onto OTHER
    /// tasks — a half-honest version of that is worse than none, so per-item Undo stays
    /// in Activity where it already works, and this notice claims nothing about it.
    private func presentCommitNotice() {
        guard let summary = brain.lastCommitSummary, !summary.isEmpty else { return }
        brain.lastCommitSummary = nil  // consumed — a dismiss reports its own commit only
        guard let message = summary.messageBeyondReceipt else { return }
        commitNotice = UndoNotice(message: message)
    }

    // MARK: - The Capture orb

    /// The persistent Capture action: a circular Liquid Glass button holding a live mini
    /// `RambleOrb`, parked bottom-trailing IN THE SAME ROW as the system tab bar's capsule
    /// — Linear's agent-button placement, which the two-tab collapse finally leaves room
    /// for, and which this file's retired FAB comment wanted but deferred.
    ///
    /// It is the app's ONE piece of bottom chrome. The bar beside it is the OS's: iOS 27
    /// publishes no way to put a custom control inline with an expanded tab bar
    /// (`tabViewBottomAccessoryPlacement` is get-only and `.inline` only happens once the
    /// bar minimizes), so positioning this button is the smallest custom chrome that can
    /// express "the orb is always beside the bar".
    ///
    /// **Every line of the composition is load-bearing**, and all three ways to get it
    /// wrong were made and caught in the simulator during the custom-bar pass:
    ///
    /// - **Glass is the BACKGROUND, never a wrapper.** `.glassChrome` draws as
    ///   `content.overlay { glass }` and, on its flat (Reduce Transparency / Increase
    ///   Contrast) path, REPLACES content with a filled shape. Wrapped around the orb it
    ///   would put the orb under a glass sheet — and DELETE it under either setting.
    /// - **No `GlassEffectContainer`.** A container groups its descendants into the glass
    ///   rendering pass, which blurs them; the orb would smear. A container earns its
    ///   place only when two glass elements must morph, and the system's bar is not in our
    ///   view tree to morph with.
    /// - **No tint, no coloured shadow, no dark well.** Glass is recessive chrome and the
    ///   orb supplies the only saturation. The well the old CTA needed existed because the
    ///   orb sat on `accentGradient` — the same two hues it is built from — and had no
    ///   value separation; on neutral glass it has plenty.
    private var captureOrbButton: some View {
        Button {
            // Byte-identical to the FAB's and the CTA's action. Opening from here always
            // starts a NEW capture — a stale resume target from an earlier
            // \.resumeCapture must not leak in (it could be committed or deleted by now).
            presentComposer(resuming: nil)
        } label: {
            RambleOrb(
                diameter: Self.captureOrbDiameter,
                frameInterval: Motion.orbBarFrameInterval,
                paused: barOrbPaused
            )
            .frame(width: Self.captureButtonDiameter, height: Self.captureButtonDiameter)
            .background { Color.clear.glassChrome(in: Circle(), interactive: true) }
        }
        .buttonStyle(.pressable)
        // The second orb's front door: long-press = Private Capture ("I know the
        // thing", device-only), tap = Ramble ("let me dump this out") — the owner's
        // entry-point decision, 2026-08-30. `simultaneousGesture` so the Button's
        // tap keeps working untouched.
        // `RambleOrb` is `.accessibilityHidden(true)` — it is atmosphere — so the button
        // has no other label source.
        .accessibilityLabel("Capture a task")
        .padding(.trailing, Spacing.md)
        .padding(.bottom, Spacing.md)
    }

    /// Whether the bar orb's timeline should stop. It is mounted for the whole app
    /// lifetime — unlike the capture beat's orb, which exists only while someone waits —
    /// so it runs only while it can actually be seen.
    ///
    /// KNOWN GAP, pre-existing and not caused by the move to the native bar: this does not
    /// cover `taskDetailSheet`, which is a `fullScreenCover` presented by `TasksHomeView`
    /// rather than by this shell, so the orb keeps animating underneath a full-screen task
    /// detail.
    ///
    /// **`.background`, not `!= .active`.** The stricter test also catches `.inactive`,
    /// which is not "nobody is looking": it fires for the app switcher, Control Centre, an
    /// incoming call — and, in the simulator, for the window merely not being key, which
    /// left the orb frozen in every headless check (caught by sampling the orb's pixels
    /// across a breath and finding them byte-identical, against a full-screen capture orb
    /// that changed every frame). Those states are brief and mostly still visible, so the
    /// saving was nil and the cost was an orb that looked dead.
    private var barOrbPaused: Bool {
        keyboardUp || composerSession != nil || showActivity || showOnboarding || showAsk
            || scenePhase == .background
    }

    /// The Capture button's diameter, set to the system tab bar capsule's MEASURED height
    /// so the two are the same size and read as one row rather than a bar with something
    /// parked beside it. Grown from the retired FAB's 52pt on 2026-08-29.
    private static let captureButtonDiameter: CGFloat = 62

    /// The orb inside it, preserving the 11pt glass bezel the old 52/30 pairing had: the
    /// bezel is what makes this read as a lens set into a button rather than a bare orb
    /// floating next to the bar.
    private static let captureOrbDiameter: CGFloat = 40


    /// Deterministic verification seam. Launch with `-SeedSampleData` to run the
    /// sample brain-dump through the active engine and skip onboarding. Never fires
    /// in normal runs.
    private func seedIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-SeedSampleData") else { return }
        let existing = (try? context.count(for: NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? 0
        guard existing == 0 else {
            hasOnboarded = true
            return
        }
        let sample = """
            renew my passport
            book flights for the trip after passport is done
            oil change is overdue
            should I keep paying for the gym I never use
            call mom back
            daycare enrollment forms due Friday
            finish the Q3 deck
            return the amazon package
            figure out if the side project is still worth it
            pay the water bill
            """
        let roster = familyMembers.filter { !$0.isRemoved }
            .map { RosterPerson(name: $0.name, relationship: $0.relationship.label) }
        let drafts = await brain.triage(sample, roster: roster).drafts
        // `commit` is the confirm, so the seeded screens show a real working set.
        // Judgment calls arrive wearing their Needs Decision flag; low-confidence items
        // do NOT — the confirm is the review that flag was asking for.
        brain.commit(drafts, rawCapture: sample, into: context)
        context.saveChanges()
        hasOnboarded = true
        showOnboarding = false
    }

    /// Deterministic verification seam. Launch with `-SeedFlowFixtures` to populate
    /// hand-built data covering every core user flow except onboarding, bypassing
    /// the AI engine so status/confidence/autonomy are exact. The fixtures below are
    /// the walkthrough now — the doc that described them was written against the
    /// retired suggested/ready/inProgress vocabulary. Never fires in normal runs.
    private func seedFlowFixturesIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-SeedFlowFixtures") else { return }
        let existing = (try? context.count(for: NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? 0
        guard existing == 0 else {
            hasOnboarded = true
            return
        }
        SampleFlowFixtures.seed(into: context)
        hasOnboarded = true
        showOnboarding = false
    }

}

#Preview {
    RootTabView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
