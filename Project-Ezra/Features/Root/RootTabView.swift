//
//  RootTabView.swift
//  Project-Ezra
//
//  The app shell, now two tabs and a button — Brief (the cinematic daily briefing) and
//  Tasks (the system of record), plus the floating circular Capture button. The loop IS
//  the navigation: you ramble in, you glance at the Brief, you work the Tasks. Review is
//  not a destination; first launch presents the onboarding transformation.
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
}

struct RootTabView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @Environment(\.managedObjectContext) private var context
    @Environment(AppBrain.self) private var brain
    @Environment(BriefingReminder.self) private var briefing
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    private var familyMembers: [FamilyMember] { Array(familyMembersResults) }
    @State private var showOnboarding: Bool
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
    @State private var composerSession: ComposerSession?
    /// The transient "Added N tasks" receipt, shown after the composer closes.
    @State private var commitNotice: UndoNotice?
    @State private var selection: Int

    init() {
        let onboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
        // Verification seams skip onboarding: both exist to reach a screen state
        // directly, and a first-run cover would fight the presentation they drive.
        let seeding =
            ProcessInfo.processInfo.arguments.contains("-SeedSampleData")
            || ProcessInfo.processInfo.arguments.contains("-OpenCapture")
        _showOnboarding = State(initialValue: !onboarded && !seeding)
        // Verification seam: `-InitialTab N` selects the starting tab.
        let args = ProcessInfo.processInfo.arguments
        let initialTab =
            args.firstIndex(of: "-InitialTab").flatMap {
                args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil
            } ?? 0
        // TabView crashes if selection is set to an unavailable tab, so clamp the
        // verification seam to the two valid tab values (0 Brief, 1 Tasks). The old
        // range was 0…3; a stale `-InitialTab 3` now lands on Tasks rather than crashing.
        _selection = State(initialValue: min(max(initialTab, 0), 1))
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Brief", systemImage: "sparkles", value: 0) {
                BriefHomeView()
            }
            Tab("Tasks", systemImage: "checklist", value: 1) {
                TasksHomeView()
            }
        }
        .tint(Palette.accentFlat)
        .overlay(alignment: .bottomTrailing) { captureButton }
        // The confirm's receipt. It renders HERE, not in the composer, because the sheet
        // is already gone by the time there is anything to report — which also puts it
        // ABOVE the floating tab bar, so it needs the same tuned inset the FAB uses or
        // it prints across the tab labels.
        .undoNotice($commitNotice, bottomInset: Spacing.xxl)
        .environment(\.openCapture, { presentComposer(resuming: nil) })
        .environment(\.resumeCapture, { capture in presentComposer(resuming: capture) })
        .environment(\.openActivity, { showActivity = true })
        // Tapping the daily nudge lands on the Brief, wherever the app was left.
        .onChange(of: briefing.pendingOpenBriefing) { _, pending in
            guard pending else { return }
            selection = 0
            briefing.pendingOpenBriefing = false
        }
        // Item-based, so however the sheet closed (commit, discard, swipe) the session
        // clears with it — the next open starts fresh unless \.resumeCapture re-arms it.
        .sheet(item: $composerSession, onDismiss: { presentCommitNotice() }) { session in
            ComposerView(resuming: session.resuming)
        }
        .sheet(isPresented: $showActivity) { ActivityView() }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                hasOnboarded = true
                showOnboarding = false
            }
        }
        .task {
            // A cold launch from the nudge can set the flag before `onChange` is
            // watching, so catch it here too.
            if briefing.pendingOpenBriefing {
                selection = 0
                briefing.pendingOpenBriefing = false
            }
            if ProcessInfo.processInfo.arguments.contains("-SeedFlowFixtures") {
                // Flow fixtures own their identity setup (a named "you" member + owned
                // tasks), so bootstrap is deliberately not called here.
                seedFlowFixturesIfRequested()
            } else if ProcessInfo.processInfo.arguments.contains("-SeedTodayFixtures") {
                // Today fixtures own their identity setup too (see TodayFixtures.seed).
                seedTodayFixturesIfRequested()
            } else {
                // Guarantee the current user exists as a real household member before any
                // surface computes `isMine` or any capture stamps ownership.
                UserProfile.bootstrapIdentity(in: context)
                await seedIfRequested()
            }
            await runBriefDiagnosticsIfRequested()
            await runCaptureCompareIfRequested()
            await runCaptureDiagnosticsIfRequested()
            await runRambleEvalIfRequested()
            #if DEBUG
            await AdvisorDiagnostics.runIfRequested()
            // Gold-standard-first routing discovery: which cases measurably need depth.
            await AdvisorBenchmark.runIfRequested()
            // Coverage reads the LIVE store (the fixtures next door answer a different
            // question), so it runs here where the real context is in scope.
            AdvisorCoverageDiagnostics.runIfRequested(in: context)
            #endif
            openActivityIfRequested()
            await openCaptureIfRequested()
        }
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

    /// Verification seam: `-RambleEval` runs the labeled eval set through **every arm
    /// available on this host**, scoring each against the SAME shared floors
    /// (`RambleEval.Floors`) and printing a per-field PASS/FAIL table plus named misses
    /// to stdout.
    ///
    /// It used to run "the ACTIVE engine" — one arm, whichever the host happened to
    /// select — and print percentages with no floors attached, so reading it meant
    /// eyeballing numbers against literals in a test file. That is how the front door
    /// went unmeasured: CI held the heuristic arm to the floors, the device printed the
    /// on-device arm's numbers next to nothing, and an unstructured spoken blob failed
    /// to segment while every number in the suite stayed green.
    ///
    /// Both arms run whenever both exist, deliberately. The interesting output is not
    /// either table but the DIFFERENCE, and a baseline the cloud arm must beat has to be
    /// measured on the same hardware in the same run — not inherited from CI.
    ///
    /// Non-destructive: nothing commits, same rule as `-CaptureDiagnostics`. DEBUG-only,
    /// like the fixture set it reads.
    private func runRambleEvalIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-RambleEval") else { return }
        print("=== RAMBLE EVAL ===")
        print("host engine: \(brain.status.description)")

        // The deterministic arm always exists — it is the offline arm of everything, so
        // it is never "not applicable", only sometimes not the one that ships.
        await runEvalArm("heuristic") { utterance in
            let intents = try await HeuristicEngine().triage(rawText: utterance)
            return IntentResolver.resolve(intents)
        }

        // The on-device arm, only where there is one. `brain.triage` is the REAL front
        // door — the same path a capture takes — which is the whole point: scoring a
        // hand-assembled approximation of it would reproduce the original mistake in a
        // new place.
        // The on-device arm is DEGRADED OFFLINE CAPTURE, not a rung the router can
        // choose — it is reached only when the cloud is unreachable. Scored so the
        // offline experience has a number, never so it can be compared as a peer.
        if brain.status.isOnDevice {
            await runEvalArm("degraded-offline", expectsModel: true) { utterance in
                await brain.triage(utterance, route: .cloud, allowHedge: false).drafts
            }
        } else {
            print("\n(degraded-offline arm skipped — no on-device model on this host)")
        }

        // The cloud arm — the one the routing change is FOR, and the reason both arms
        // above run in the same command: the numbers only mean something next to each
        // other, on the same hardware, in the same run.
        if CloudModel.isAvailable {
            // `allowHedge: false` — this arm must measure the CLOUD arm, not the blend the
            // composer ships. With hedging on, a slow cloud call is answered by the local
            // model and scored under a "cloud" heading, and the served-call delta still
            // looks correct because the cloud calls really were issued. The blend is the
            // right product behaviour and the wrong measurement.
            await runEvalArm("cloud(\(CloudModel.provider.identifier))", expectsModel: true) {
                utterance in
                await brain.triage(utterance, route: .cloud, allowHedge: false).drafts
            }
        } else {
            print("\n(cloud arm skipped — no provider installed; CloudModel.provider is inert)")
        }

        print("=== END RAMBLE EVAL ===")
        #endif
    }

    #if DEBUG
    /// Score one arm and print its table, WITH proof of which engine actually answered.
    ///
    /// `expectsModel` is the load-bearing parameter, and it exists because the first
    /// version of this seam reproduced the exact failure it was built to catch. On a
    /// host where `SystemLanguageModel.default.availability == .available` but the model
    /// catalog is empty (a real simulator state: *"There are no underlying assets … for
    /// asset set com.apple.modelcatalog"*), every generation throws and
    /// `AppBrain.triage` degrades to the heuristic — **by design**, because capture must
    /// never fail. The arm then produces the fallback's drafts, scores the fallback's
    /// numbers, and prints "on-device: ALL FLOORS HELD".
    ///
    /// Availability is a claim about a model EXISTING; it is not evidence that one
    /// ANSWERED. So the arm proves it: the `ModelMetrics` delta across the run says how
    /// many calls were served, and an arm that expected a model and served none is
    /// reported as **DEGRADED** rather than as a pass. A green table nobody can trust is
    /// worse than no table.
    ///
    /// A thrown error is reported as a failed ARM rather than a failed run, so one
    /// broken arm never hides another's numbers.
    private func runEvalArm(
        _ name: String, expectsModel: Bool = false,
        resolve: @escaping (String) async throws -> [TaskDraft]
    ) async {
        let before = ModelMetrics.shared.stats[.captureTriage] ?? ModelMetrics.Stats()
        let started = Date()
        do {
            let report = try await RambleEval.score(resolve: resolve)
            let seconds = Date().timeIntervalSince(started)
            let after = ModelMetrics.shared.stats[.captureTriage] ?? ModelMetrics.Stats()
            let served = after.served - before.served
            let failed = (after.failures - before.failures) + (after.timeouts - before.timeouts)

            print(report.table(against: .standard, arm: name))
            print(
                String(
                    format: "arm %@ took %.1fs · model calls served %d · failed %d",
                    name, seconds, served, failed))
            // DEGRADED is a RATIO, not a zero test.
            //
            // It used to fire only on `served == 0`, and that let the worst possible
            // report through: a cloud arm that served 2 of 52 calls printed "ALL FLOORS
            // HELD" with numbers identical to the heuristic's, because 96% of the corpus
            // had quietly scored the deterministic fallback. One survivor was enough to
            // suppress the warning. A partially degraded arm is not a weaker version of
            // a degraded arm — it is the same lie with better camouflage, because the
            // table looks plausible instead of empty.
            //
            // `lastError` is printed with it: an arm can now say WHY it degraded, which
            // is the difference between "re-run somewhere else" and a diagnosis. Without
            // it the only signal was a count, and a count cannot distinguish a missing
            // model from a rejected request.
            let attempted = served + failed
            let servedShare = attempted > 0 ? Double(served) / Double(attempted) : 0
            if expectsModel && (attempted == 0 || servedShare < 0.9) {
                let reason = ModelMetrics.shared.stats[.captureTriage]?.lastError
                print(
                    """
                    ⚠️  ARM DEGRADED — "\(name)" served \(served)/\(attempted) call\
                    \(attempted == 1 ? "" : "s"); the rest scored the DETERMINISTIC \
                    fallback, so this table describes the fallback, not \(name). \
                    \(reason.map { "Last error: \($0)." } ?? "No error label recorded.") \
                    Fix the arm before treating any number above as a baseline.
                    """)
            }
        } catch {
            print("arm \(name) FAILED: \(AppBrain.errorLabel(error))")
        }
    }
    #endif

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
    private func presentComposer(resuming capture: Capture?) {
        // Warm the model + retrieval substrate NOW: the sheet-presentation animation
        // absorbs the cost, so the first parse doesn't pay it against the user's pause.
        AppBrain.prewarmCapture(in: context)
        brain.lastCommitSummary = nil
        composerSession = ComposerSession(resuming: capture)
    }

    /// Show the receipt for a confirm that just happened, once — and ONLY for what the
    /// composer's own ✓ moment couldn't say. The count is delivered in the sheet now
    /// ("5 tasks added"), so re-announcing it here made the arc end twice; a merge
    /// target still needs naming, because that is the one thing the count leaves open.
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

    /// The persistent Capture action: a circular accent-gradient button in the
    /// bottom-trailing corner. Linear's agent button sits INLINE beside its (icon-only,
    /// narrow) tab bar; with four labeled tabs ours couldn't — the system capsule was too
    /// wide to leave beside-room, so it was pinned just ABOVE the bar's trailing edge
    /// ("near the bar"), which also keeps it from floating orphaned when the bar
    /// minimizes on scroll. `bottomInset` is a TUNED CONSTANT (the bar geometry isn't
    /// public), not a pixel-lock.
    ///
    /// The two-tab collapse frees the width the original beside-placement wanted, and it
    /// is deliberately NOT taken here: this is a layout change with a real chance of
    /// colliding with the bar's own minimize behaviour, and it belongs to a beat that can
    /// be looked at in the simulator rather than riding along with a structural cut.
    private var captureButton: some View {
        Button {
            // Opening the composer from here always starts a NEW capture — a stale
            // resume target from an earlier \.resumeCapture must not leak into it
            // (it could be committed or deleted by now).
            presentComposer(resuming: nil)
        } label: {
            Image(systemName: "plus")
                .font(.glyphControl(.semibold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 52, height: 52)
                .background(Palette.accentGradient, in: Circle())
                // The one piece of app chrome floating over scrolling content joins the
                // glass system: an interactive Liquid Glass lens over the brand gradient
                // (specular edge + native press response). Falls back to the plain
                // gradient under Reduce Transparency / Increase Contrast.
                .overlay { captureGlass }
                .shadow(color: Palette.accentGlow, radius: 12, y: 4)
        }
        .buttonStyle(.pressableProminent)
        .accessibilityLabel("Capture a task")
        .padding(.trailing, Spacing.md)
        .padding(.bottom, Spacing.xxl)
    }

    /// The interactive Liquid Glass lens over the Capture button's gradient — present
    /// only when the accessibility settings allow glass (else the plain gradient shows).
    @ViewBuilder
    private var captureGlass: some View {
        if !reduceTransparency && contrast != .increased {
            Color.clear.glassEffect(.regular.interactive(), in: Circle())
        }
    }

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

    /// Verification seam for the ONE thing only real hardware can answer: how the
    /// capture pipeline behaves against a live on-device model.
    ///
    /// `-CaptureDiagnostics` runs a deliberately long ramble through the active engine
    /// and prints the result — tier, wall-clock, draft count, and the `ModelMetrics`
    /// tallies — to stdout, where `devicectl process launch --console` can read it.
    /// Everything here was previously legible only as text on a DEBUG footer, i.e. only
    /// to a human holding the phone, which is why "device-verify" had stayed a checklist
    /// someone had to perform rather than a thing that could simply be run.
    ///
    /// Deliberately does NOT commit: this measures the parse, and leaving a pile of
    /// tasks behind would make the seam destructive to re-run.
    /// `-BriefDiagnostics` — prove the CLOUD BRIEF end to end, headlessly.
    ///
    /// **Why this exists as a seam rather than a footer reading.** The MAX_TOKENS bug was
    /// unit-proven and operationally broken for weeks: the profile was right, a per-call
    /// `GenerationOptions` overrode it, and every cloud briefing returned
    /// `finishReason: MAX_TOKENS` while the UI simply showed the deterministic tail. The
    /// only visible symptom was a briefing that read a bit flat. Nothing failed, nothing
    /// was logged where anyone looked, and the fix for it was itself unverifiable without
    /// standing in the app watching a DEBUG footer.
    ///
    /// So this prints the whole chain as facts: which tier ANSWERED, whether the reply is
    /// actually voiced or merely a ranked list wearing a headline, the token accounting,
    /// and the typed error when it fails. A cloud tier that silently degrades now says so
    /// in one line.
    ///
    /// Non-destructive: generates a plan and prints it, commits nothing.
    private func runBriefDiagnosticsIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-BriefDiagnostics") else { return }
        print("=== BRIEF DIAGNOSTICS ===")
        print("engine: \(brain.status.description)")
        print("cloud provider reachable: \(CloudModel.isAvailable) (\(CloudModel.label))")

        let all = TaskItem.fetchAll(in: context)
        let live = all.filter { $0.status.isLive }
        guard !live.isEmpty else {
            print("no live tasks — run with -SeedTodayFixtures to give the advisor something to plan")
            print("=== END BRIEF DIAGNOSTICS ===")
            return
        }
        let request = TodayPlanRequest.make(
            candidateItems: TaskRanking.sorted(live, among: all, now: Date()),
            allTasks: all, recapCount: 0, typicalCompleted: nil, now: Date())
        print("candidates: \(request.candidates.count)")

        let started = Date()
        let plan = await brain.todayPlan(for: request, in: context)
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        // The claim under test. A deterministic plan is a ranked list with fact lines and
        // no tradeoffs or risks — structurally distinguishable from an advisor's voice,
        // which is exactly why "the Brief looked fine" was never evidence.
        let voiced = plan.tier != PlanTier.deterministic && plan.tradeoffs != nil && plan.risks != nil
        print("tier that ANSWERED: \(plan.tier)  ·  \(ms)ms")
        print("headline: \(plan.headline ?? "—")")
        print(
            "actions: \(plan.actions.count) · tradeoffs: \(plan.tradeoffs != nil) · risks: \(plan.risks != nil)"
        )
        print(
            voiced
                ? "✅ VOICED — the advisor answered"
                : "⚠️  NOT VOICED — this is the deterministic tail wearing a headline")
        if plan.tier == PlanTier.deterministic {
            print(
                "   why: err \(brain.planMetrics.lastError ?? "none") · availability \(brain.planMetrics.lastAvailability ?? "?")"
            )
        }
        let m = brain.planMetrics
        print(
            "metrics: last tier \(m.lastTier ?? "—") · \(m.lastLatencyMs)ms · "
                + "prompt \(m.lastPromptTokens) · output \(m.lastOutputTokens) · "
                + "err \(m.lastError ?? "none") · availability \(m.lastAvailability ?? "?")")
        print(
            "metrics: tiers — on-device \(m.onDeviceCount) · cloud \(m.cloudCount) · rules \(m.deterministicCount)"
        )
        print("=== END BRIEF DIAGNOSTICS ===")
        #endif
    }

    /// `-CaptureCompare "<your ramble>"` — the same words, read by every arm, printed
    /// side by side. Add `-WithCloud` to include the paid rung.
    ///
    /// **The manual-judgment instrument.** `RambleEval` answers "does this match the
    /// labels?" over a frozen corpus; that is the right question for regressions and the
    /// wrong one for "is this good?". Quality on YOUR OWN messy sentences is a thing a
    /// person has to read and decide, and until now the only way to see a reading was to
    /// capture it in the app and inspect cards — one arm, no comparison, no way to tell
    /// which reader you were looking at.
    ///
    /// It matters more on the Spark plan than it would otherwise. Unstructured capture
    /// routes to the cloud, the cloud is rationed, and what actually serves the ramble is
    /// the DEGRADED OFFLINE arm — the one device evidence says is weakest at exactly this
    /// job. Whether that is tolerable to live with is a judgment call, and this is the
    /// tool for making it on real input instead of on the corpus.
    ///
    /// The cloud arm is OPT-IN (`-WithCloud`) because one eval sweep exhausts a day's
    /// free quota, which then breaks real capture — measuring the product must not cost
    /// you the product.
    private func runCaptureCompareIfRequested() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-CaptureCompare") else { return }
        let text =
            args.indices.contains(flag + 1) && !args[flag + 1].hasPrefix("-")
            ? args[flag + 1]
            : "renew my passport before the trip and book flights after it comes through"

        print("=== CAPTURE COMPARE ===")
        print("input (\(text.count) chars): \(text)")
        // What PRODUCTION would do with this input, before any arm runs — so the
        // comparison is read against the route the user would actually get.
        let structure = Segmentation.structure(of: text)
        print("structure: \(structure.label) → route \(CaptureRoute.route(for: text).metricName)")

        await compareArm("deterministic (always available)") {
            IntentResolver.resolve(try await HeuristicEngine().triage(rawText: text))
        }

        if brain.status.isOnDevice {
            await compareArm("degraded-offline (on-device)") {
                let engine = FoundationModelsEngine(sessionSource: .onDevice)
                let intents = try await engine.triage(
                    rawText: text, context: TriageContext(), onPartial: nil)
                return IntentResolver.resolve(intents)
            }
        } else {
            print("\n— degraded-offline: no on-device model on this host")
        }

        if args.contains("-WithCloud") {
            guard CloudModel.isAvailable else {
                print("\n— cloud: no provider configured")
                print("=== END CAPTURE COMPARE ===")
                return
            }
            await compareArm("cloud (the semantic authority)") {
                let engine = FoundationModelsEngine(sessionSource: .cloud)
                let intents = try await engine.triage(
                    rawText: text, context: TriageContext(), onPartial: nil)
                return IntentResolver.resolve(intents)
            }
        } else {
            print("\n— cloud: skipped (pass -WithCloud to spend a call)")
        }
        print("=== END CAPTURE COMPARE ===")
        #endif
    }

    #if DEBUG
    /// One arm's reading, printed as the DRAFTS THEMSELVES rather than as counts.
    ///
    /// Counts are what the old diagnostics gave ("11 drafts · 3 dated"), and they cannot
    /// answer the only question that matters here: did it understand the sentence? A
    /// wrong split and a right one both count as two.
    private func compareArm(
        _ name: String, resolve: @escaping () async throws -> [TaskDraft]
    ) async {
        let started = Date()
        do {
            let drafts = try await resolve()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("\n── \(name) — \(drafts.count) task\(drafts.count == 1 ? "" : "s") · \(ms)ms ──")
            if drafts.isEmpty { print("   (nothing)") }
            for (i, d) in drafts.enumerated() {
                var line = "  \(i + 1). \(d.title)  [\(d.category)]"
                if let due = d.dueDate {
                    line += " · due \(Self.dayFormatter.string(from: due))"
                    if d.dueReason != nil { line += " (inferred)" }
                }
                if let owner = d.ownerName { line += " · @\(owner)" }
                if let blocker = d.blockedBy { line += " · waits on \(blocker)" }
                if d.isJudgmentCall { line += " · JUDGMENT" }
                if d.unresolved.contains(.date) { line += " · asks WHEN?" }
                print(line)
            }
        } catch {
            print("\n── \(name) — FAILED: \(AppBrain.errorLabel(error))")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
    #endif

    private func runCaptureDiagnosticsIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CaptureDiagnostics") else { return }
        // Long, messy, and full of the shapes that make the model work: dates, a
        // delegation, a blocker, judgment calls, and a duplicate of a seeded task.
        let ramble =
            String(repeating: "", count: 1) + """
                ok brain dump time — renew my passport before the trip, and book flights \
                for that trip but only after the passport comes through, oil change is \
                overdue by like two weeks now, should I keep paying for the gym I honestly \
                never use, call mom back she left three voicemails, daycare enrollment \
                forms are due Friday, finish the Q3 deck for the board thing, return the \
                amazon package before the window closes, figure out if the side project is \
                still worth it or if I should let it go, pay the water bill it's the second \
                notice, ask Maya to sort out the insurance renewal, schedule the kitchen \
                plumber once the contractor calls back, and renew my passport
                """
        print("=== CAPTURE DIAGNOSTICS ===")
        print("engine: \(brain.status.description)")
        print("input: \(ramble.count) chars")
        // The provisional arm FIRST — it is what the user now sees, and the gap
        // between these two numbers is the whole instant-capture claim, in one
        // re-runnable line. Also printed at three input lengths, because the
        // coalesce window is tuned on how this scales, not on how it reads once.
        for cut in [ramble.count / 3, (ramble.count * 2) / 3, ramble.count] {
            let slice = String(ramble.prefix(cut))
            let started = Date()
            let provisional = AppBrain.provisionalDrafts(slice)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print(
                "provisional @\(cut) chars: \(provisional.count) drafts · \(elapsed)ms "
                    + "· owners \(provisional.compactMap(\.ownerName).count) "
                    + "· dated \(provisional.compactMap(\.dueDate).count)")
        }
        let started = Date()
        let drafts = await brain.triage(ramble).drafts
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        print("drafts: \(drafts.count)")
        print("wall clock: \(elapsed)ms")
        print(
            "proposals: \(drafts.reduce(0) { $0 + $1.edgeProposals.count }) "
                + "· owners: \(drafts.compactMap(\.ownerName).count) "
                + "· blockers: \(drafts.compactMap(\.blockedBy).count) "
                + "· dated: \(drafts.compactMap(\.dueDate).count)")
        for line in ModelMetrics.shared.footerLines() { print("metrics: \(line)") }
        await runContinuousDiagnosticsArm(ramble: ramble)
        print("=== END CAPTURE DIAGNOSTICS ===")
    }

    /// The A/B arm for the CONTINUOUS capture session (`CaptureConversation`): the
    /// same ramble fed as three growing snapshots — the shape the rolling chain
    /// produces — with per-turn wall-clock, draft counts, and token accounting. The
    /// continuous session becomes the composer's default the day these numbers beat
    /// the single-use baseline above on real hardware; until then it is measured,
    /// not shipped (the capture-deadline precedent: tuned on evidence).
    private func runContinuousDiagnosticsArm(ramble: String) async {
        guard brain.status.isOnDevice else {
            print("continuous: skipped (engine is not on-device)")
            return
        }
        // Three prefixes at natural clause boundaries, ending with the full text —
        // turn 1 initial, turns 2-3 suffix continuations.
        let cuts = [ramble.count / 3, (ramble.count * 2) / 3, ramble.count]
        let snapshots = cuts.map { String(ramble.prefix($0)) }
        let conversation = CaptureConversation(context: TriageContext())
        for (index, snapshot) in snapshots.enumerated() {
            let turn = CaptureConversation.turn(
                from: conversation.coveredText, to: snapshot)
            let turnLabel: String
            switch turn {
            case .initial: turnLabel = "initial"
            case .continuation(let suffix): turnLabel = "continuation(+\(suffix.count) chars)"
            case .revision: turnLabel = "revision"
            }
            let started = Date()
            do {
                let intents = try await conversation.triage(
                    rawText: snapshot, context: TriageContext(), onPartial: nil)
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                let prompt = CaptureConversation.prompt(for: turn)
                let tokens =
                    (try? await SystemLanguageModel.default.tokenCount(for: prompt)) ?? -1
                print(
                    "continuous turn \(index + 1)/\(snapshots.count) [\(turnLabel)]: "
                        + "\(intents.count) intents · \(elapsed)ms · prompt \(tokens) tok")
            } catch {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                print(
                    "continuous turn \(index + 1)/\(snapshots.count) [\(turnLabel)]: "
                        + "FAILED after \(elapsed)ms · \(AppBrain.errorLabel(error))")
            }
        }
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

    /// Deterministic verification seam. Launch with `-SeedTodayFixtures` to populate
    /// data that exercises every beat of the Today sequence — Recap (recent
    /// completions), Docket (due/overdue/decisions), a blocked-and-blocking chain,
    /// and `CapacityLog` history driving the personalized/divergent/cold-start
    /// baselines. See `TodayFixtures`. Never fires in normal runs.
    private func seedTodayFixturesIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-SeedTodayFixtures") else { return }
        // Force a fresh seed every launch with the arg set (device iteration): wipe
        // prior task data + the Today cache first, so a used store still shows the set.
        TodayFixtures.reset(in: context)
        TodayFixtures.seed(into: context)
        hasOnboarded = true
        showOnboarding = false
    }
}

#Preview {
    RootTabView()
        .environment(AppBrain())
        .environment(BriefingReminder())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
