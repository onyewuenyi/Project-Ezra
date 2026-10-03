//
//  RootTabView.swift
//  Project-Ezra
//
//  The app shell. Since 2026-09-23 the HOME is Ask (`HouseholdChatView`, opened on the
//  day answer) and the Tasks list is a SHEET behind the header's list button — the same
//  grammar Ask had when the list was the home, swapped. The owner's call, made over the
//  argument that a list answers a glance and a chat answers a question; the two
//  telemetry events that argument turns on (`askAsked`, `tasksOpened`) landed with it.
//  The list was a PUSHED page for a few hours first, and Back from it hit a fault on
//  the owner's phone; the sheet is what was asked for and what the pre-swap shell had
//  proven for three weeks. Before the swap the list was the root and Ask the sheet
//  (2026-09-02 → 2026-09-23); before THAT a system tab bar held Brief · Tasks with the
//  orb beside it (2026-08-18 → 2026-09-02). `docs/surfaces.md` keeps the archaeology.
//
//  Two presentation contexts, one host each (`ShellSurfaces`): the root, whose
//  composer / Activity / Settings serve the Ask home and whose capture door is the orb
//  in the home's composer bar; and the Tasks sheet (`TasksSheet`), whose host parks
//  the 62pt orb bottom-trailing over the list and presents the SAME surfaces from
//  inside the sheet — because a sheet cannot be presented over another from the same
//  presenter. Onboarding and the identity link stay root-only.
//
//  A fully custom bottom bar was built here and REVERTED (2026-08-29, same day): it drew
//  Brief · Capture · Tasks in one hand-rolled glass capsule, which cost the OS's rendering
//  and safe-area management and bought a composition the owner didn't want. Do not
//  resurrect it. The home's composer bar is not that bar: it is the chat's own input,
//  which every chat surface already had, with the orb beside it.
//
//  The Inbox and Household TABS were cut (product shape v2, 2026-08-18) — surfaces cut,
//  systems relocated. The trust surface survives as `ActivityView`; multiplayer survives
//  as substrate (the roster, born-owned tasks, the publish boundary at Confirm) with
//  roster editing one tap deep in either "…" menu.
//

import CoreData
import FoundationModels
import SwiftUI

/// The one way any screen opens the global capture composer — injected by the
/// shell so deep views (empty states, cards) never need their own sheet plumbing.
extension EnvironmentValues {
    @Entry var openCapture: () -> Void = {}
    /// Present the Tasks list — the record, one tap behind the Ask home's list button
    /// (2026-09-23) — on a preset: the glance strip's counts open it filtered, the
    /// button opens it plain (`.none`). A no-op while the list is already up.
    @Entry var openTasks: (TasksPreset) -> Void = { _ in }
    /// Push Manage Household. Reachable from both "…" menus, so the shell owns the push.
    @Entry var openRoster: () -> Void = {}
    /// Present Settings. Reachable from both "…" menus, so the shell owns the sheet.
    @Entry var openSettings: () -> Void = {}
    /// Reopen a specific parked capture (the Today "captures waiting" line). Distinct
    /// from `openCapture`, which always begins a fresh one.
    @Entry var resumeCapture: (Capture) -> Void = { _ in }
    /// Open the Activity screen — the change log with action-aware Undo. Used by the
    /// Tasks header and the Brief's held-depth tile. It is an environment action rather
    /// than a local sheet for the same reason `openCapture` is: the surface has one
    /// mount point, in the shell, and no screen owns it.
    @Entry var openActivity: () -> Void = {}
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
    /// The ROOT context's surfaces — the Ask home's composer, Activity and Settings.
    /// A controller rather than view state so the launch seams and the Siri hand-off
    /// below can reach them; the Tasks sheet owns a second one.
    @State private var surfaces = ShellSurfaceController()
    /// The Tasks list, presented as a sheet from the home's list button (`\.openTasks`),
    /// on the preset the caller named. Item-based, so a count tapped while nothing is
    /// up opens straight onto its subset.
    @State private var tasksPreset: TasksPreset?
    private var showTasks: Bool { tasksPreset != nil }
    /// Manage Household, pushed on the home's own stack from its "…" menu.
    @State private var showRoster = false

    var body: some View {
        ShellSurfaces(
            controller: surfaces, showsOrb: false, coveredAbove: showOnboarding || showTasks,
            openRoster: { showRoster = true },
            openTasks: { preset in if tasksPreset == nil { tasksPreset = preset } }
        ) {
            NavigationStack {
                HouseholdChatView()
                    .navigationDestination(isPresented: $showRoster) { HouseholdRosterView() }
            }
        }
        // A capture committed from inside the sheet closes the sheet and lands here; the
        // merge pill it owes is spoken by THIS host on the way in (`landsOnHome`).
        .sheet(item: $tasksPreset, onDismiss: { surfaces.presentCommitNotice(brain: brain) }) { preset in
            TasksSheet(preset: preset)
        }
        // The arriving caretaker's "which one is you?" — presented by `HouseholdSharing`
        // when an accepted share's household has landed and the phone cannot tell which
        // member the person is. Root-only; if the Tasks sheet is up it waits for it.
        .sheet(item: Bindable(HouseholdSharing.shared).pendingLink) { pending in
            IdentityLinkSheet(pending: pending)
        }
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
            if await seedFixturesIfRequested() == false {
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
            // Campaign 5 / WS4: the boundary pass on the GA runtime — P-A segment and
            // P-D artifact acceptance, the two questions the routing decision turns on.
            await FMPrimitives.runIfRequested(brain: brain)
            // The one model judgment that destroys user data — scored before the runtime
            // changes underneath its 0.85 confidence gate.
            await EmbeddingDiagnostics.runIfRequested()
            await DuplicateSweepEval.runIfRequested(brain: brain)
            await GroupingSweepEval.runIfRequested(brain: brain, in: context)
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
            await openTasksIfRequested()
            await openCaptureIfRequested()
            consumePendingCapture()
            askHouseholdIfRequested()
        }
    }

    /// Deterministic verification seam. `-AskHousehold "question"` sends one question
    /// through the LIVE household store on the Ask home, so a floor answer's rows or
    /// the model's reply — or the honest failure line — is screenshot-reachable without
    /// a keyboard. `-HouseholdChatFixture` seeds a canned thread instead (a cited floor
    /// answer, a model answer, a reply in flight) for a host with no model. `-OpenAsk`
    /// is accepted and does nothing: Ask IS the home (2026-09-23) — a bare launch shows
    /// the day answer, the glance strip, or the nothing-to-ask state on an empty store.
    /// Never fires in normal runs.
    private func askHouseholdIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let facts = HouseholdChatFacts.make(
            tasks: (try? context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? [],
            members: familyMembers, currentUserID: UserProfile.currentMemberID(in: context))
        if args.contains("-HouseholdChatFixture") {
            HouseholdChatStore.shared.seedFixture(
                citing: Array(facts.overdue.prefix(3)).map(\.id))
        }
        if let flag = args.firstIndex(of: "-AskHousehold"), args.indices.contains(flag + 1) {
            HouseholdChatStore.shared.ask(args[flag + 1], facts: facts)
        }
        #endif
    }

    /// Deterministic verification seam. The Tasks list is a sheet since 2026-09-23, and
    /// every seam the list's own `.task` reads (`-OpenTaskDetail`, the filter presets,
    /// the deck page, the grouping row) fires only once the sheet is up — so the shell
    /// presents it first for any of them, and for a bare `-OpenTasks`. `-OpenRoster`
    /// pushes Manage Household on the HOME's stack; `-OpenSettings` — and the two
    /// destructive seams Settings performs on arrival — present the root's sheet unless
    /// the list is being shown, in which case `TasksSheet` presents its own over the
    /// list. `-DismissTasksAfter <seconds>` closes the sheet again, so the return to the
    /// home — the path that faulted as a push — stays re-measurable. Never fires in
    /// normal runs.
    private func openTasksIfRequested() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let wantsTasks = args.contains(where: Self.tasksSurfaceArgs.contains)
        if wantsTasks { tasksPreset = .plain }
        // `-TasksPreset overdue|dueToday|inProgress|waiting|decisions|done` opens the
        // sheet the way a glance-strip count does (2026-09-23) — the tap is blocked, the
        // filtered state was not otherwise reachable.
        if let flag = args.firstIndex(of: "-TasksPreset"), args.indices.contains(flag + 1) {
            switch args[flag + 1] {
            case "overdue": tasksPreset = TasksPreset(tab: .everyone, attention: .overdue)
            case "dueToday": tasksPreset = TasksPreset(tab: .everyone, attention: .dueToday)
            case "inProgress": tasksPreset = TasksPreset(tab: .everyone, status: .doing)
            case "waiting": tasksPreset = TasksPreset(tab: .everyone, attention: .waiting)
            case "decisions": tasksPreset = TasksPreset(tab: .everyone, attention: .decisions)
            case "done": tasksPreset = TasksPreset(tab: .everyone, status: .done)
            default: break
            }
        }
        if args.contains("-OpenRoster") { showRoster = true }
        if !wantsTasks, args.contains(where: Self.settingsArgs.contains) { surfaces.showSettings = true }
        if wantsTasks, let flag = args.firstIndex(of: "-DismissTasksAfter"), args.indices.contains(flag + 1),
            let seconds = Double(args[flag + 1])
        {
            try? await Task.sleep(for: .seconds(seconds))
            tasksPreset = nil
        }
        #endif
    }

    #if DEBUG
    /// The launch arguments the Tasks page reads in its own `.task`. Listed once, here,
    /// so a seam added to the list cannot be added without the sheet that reaches it.
    static let tasksSurfaceArgs = [
        "-OpenTasks", "-OpenTaskDetail", "-OpenSearch", "-CompleteListRow", "-FilterStatus",
        "-FilterCategory", "-MyTasksTab",
        "-TasksPreset",
        // Not the grouping seams (2026-09-26): the proposal row lives on the HOME since
        // the calm pass, and opening the sheet over it hid the very row they seed.
        "-DeckPage",
    ]
    static let settingsArgs = ["-OpenSettings", "-ClearAllTasks", "-ResetEverything"]
    #endif

    /// Deterministic verification seam. Launch with `-OpenActivity` to present the
    /// Activity screen, which stopped being a tab in the v2 collapse and is now two taps
    /// deep behind the Tasks "…" menu — a Menu, and opening one needs a tap Accessibility
    /// blocks here. The screen that has to prove "every AI action is undoable" should
    /// stay reviewable without one. Never fires in normal runs.
    private func openActivityIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-OpenActivity") else { return }
        surfaces.showActivity = true
        #endif
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
        #if DEBUG
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
        surfaces.presentComposer(resuming: target, brain: brain, in: context)
        #endif
    }

    /// Words handed over by an App Intent (F-01) — "Hey Siri, tell Ezra…", the Action
    /// Button, Shortcuts. Parked as a `Capture` (the shape a dismissed composer leaves)
    /// and resumed with `autoSubmit`, so the person lands on the confirm card: nothing
    /// said is retyped, nothing is created without the one human moment. Presented from
    /// the ROOT, so if the Tasks sheet is up it is closed first and the composer follows
    /// once the dismissal has settled — presenting into a dismissal in progress is the
    /// one shape SwiftUI drops on the floor.
    private func consumePendingCapture() {
        guard let pending = PendingCapture.shared.consume() else { return }
        let capture = Capture(rawText: pending.words, source: pending.source, in: context)
        capture.parkedDrafts = []
        context.insert(capture)
        context.saveChanges()
        Task {
            if showTasks {
                tasksPreset = nil
                try? await Task.sleep(for: .milliseconds(450))
            }
            surfaces.presentComposer(resuming: capture, autoSubmit: true, brain: brain, in: context)
        }
    }

    /// **The one gate on every seeding seam, and the reason it is `#if DEBUG` rather
    /// than an argument check.**
    ///
    /// `-ResetAndSeedEvalCorpus` destroys the store. Guarded only on its own name it was
    /// compiled into Release, where the safety it relies on — "nobody passes launch
    /// arguments to a shipped app" — is a property of how the app is usually started,
    /// not of the binary. Release hygiene asks the opposite question: can a seam reach a
    /// cohort member's real work AT ALL? Compiled out, the answer is no by construction,
    /// and the destructive path stops being something a reviewer has to reason about.
    ///
    /// Returns true when a fixture seed ran and built its own household — those seeds
    /// construct a named "you" member and owned tasks, so `onLaunch` must NOT also
    /// bootstrap an identity or the store ends up with two. Returning the fact, rather
    /// than testing the argument list in both places, is what keeps the seeding arm and
    /// the bootstrapping arm exhaustive together: a new seed added here cannot forget to
    /// suppress the bootstrap, because there is only one place that decides.
    private func seedFixturesIfRequested() async -> Bool {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains(where: Self.fixtureSeedArgs.contains) else {
            return false
        }
        seedFlowFixturesIfRequested()
        seedEvalCorpusIfRequested()
        return true
        #else
        return false
        #endif
    }

    /// Deterministic verification seam. Launch with `-SeedSampleData` to run the
    /// sample brain-dump through the active engine and skip onboarding. Never fires
    /// in normal runs, and is compiled out of Release entirely — a seam that writes a
    /// working set into the user's store has no business existing in the shipped binary.
    private func seedIfRequested() async {
        #if DEBUG
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
        let decision = CaptureFlow.route(for: sample)
        let drafts = await brain.triage(
            sample, roster: roster, route: decision.route, escalation: decision.escalation
        ).drafts
        // `commit` is the confirm, so the seeded screens show a real working set.
        // Judgment calls arrive wearing their Needs Decision flag; low-confidence items
        // do NOT — the confirm is the review that flag was asking for.
        brain.commit(drafts, rawCapture: sample, into: context)
        context.saveChanges()
        hasOnboarded = true
        showOnboarding = false
        #endif
    }

    #if DEBUG
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

    /// The seeds that build their own household, so `onLaunch` skips the identity
    /// bootstrap for them. Listed once rather than tested one-by-one: the arm that
    /// bootstraps and the arm that seeds have to stay exhaustive together, and a new
    /// seed added to only one of them creates a second "You" nobody notices.
    private static let fixtureSeedArgs = [
        "-SeedFlowFixtures", "-SeedEvalCorpus", "-ResetAndSeedEvalCorpus",
    ]

    /// Deterministic verification seam. `-SeedEvalCorpus` seeds the hands-on evaluation
    /// corpus — the flow fixtures plus every surface they leave unreachable — under the
    /// same empty-store guard as its two siblings.
    ///
    /// `-ResetAndSeedEvalCorpus` is the destructive twin, and the one that matters on a
    /// device already holding real work: nothing else here can reach a known state,
    /// because every seed above refuses a non-empty store. It routes through
    /// `DataReset.clear`, which already takes a safety copy and writes the
    /// `StoreResetRecord` Settings surfaces with a link to the backup — a second wipe
    /// path is a second place that has to remember to do that.
    ///
    /// The scope is `.everything`, not `.work`, for two reasons. `SampleFlowFixtures`
    /// constructs a profile and a household unconditionally, so surviving identity would
    /// leave two of each and an ambiguous `current(in:)`. And an evaluation wants the
    /// local metrics starting from zero: a kept-rate carrying months of real dogfooding
    /// is not a reading of the corpus in front of you. `.everything` re-bootstraps an
    /// identity on its way out, which the sweep below removes so the fixtures land on the
    /// empty store they were written against.
    ///
    /// The arg name is the confirmation — nothing destructive happens under the plain
    /// `-SeedEvalCorpus` name. Never fires in normal runs.
    private func seedEvalCorpusIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let resets = args.contains("-ResetAndSeedEvalCorpus")
        guard resets || args.contains("-SeedEvalCorpus") else { return }
        if resets {
            DataReset.clear(
                .everything, in: context, metrics: brain.metrics,
                provenance: .shared, verdicts: .shared, readings: .shared)
            for name in ["UserProfile", "FamilyMember", "Household", "HouseholdSettings"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: name)
                (try? context.fetch(request))?.forEach(context.delete)
            }
            context.saveChanges()
        } else {
            let existing = (try? context.count(for: NSFetchRequest<TaskItem>(entityName: "TaskItem"))) ?? 0
            guard existing == 0 else {
                hasOnboarded = true
                return
            }
        }
        EvalCorpus.seed(into: context)
        hasOnboarded = true
        showOnboarding = false
    }
    #endif

}

/// The Tasks list as the home presents it: its own stack (the roster pushes inside it),
/// its own `ShellSurfaces` host (the orb bottom-trailing, and the composer, Activity and
/// Settings presented from INSIDE the sheet — the root's would queue behind it), and a
/// Done button on the list itself. Everything the list used to be as the root, one
/// sheet up.
struct TasksSheet: View {
    var preset: TasksPreset = .plain
    @State private var surfaces = ShellSurfaceController()
    @State private var showRoster = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShellSurfaces(
            controller: surfaces, showsOrb: true,
            openRoster: { showRoster = true },
            openTasks: { _ in },
            landsOnHome: { dismiss() }
        ) {
            NavigationStack {
                TasksHomeView(preset: preset)
                    .navigationDestination(isPresented: $showRoster) { HouseholdRosterView() }
            }
        }
        // A page, not a form sheet, on iPad: the record surface wants the room.
        .presentationSizing(.page)
        .task {
            #if DEBUG
            // Settings over the LIST when both are asked for — the destructive seams
            // want the rebuilt record behind them, and `-DismissAfterClear` closes
            // Settings to show it.
            let args = ProcessInfo.processInfo.arguments
            if args.contains(where: RootTabView.settingsArgs.contains) {
                try? await Task.sleep(for: .milliseconds(400))
                surfaces.showSettings = true
            }
            #endif
        }
    }
}

#Preview {
    RootTabView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
