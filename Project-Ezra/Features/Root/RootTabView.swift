//
//  RootTabView.swift
//  Project-Ezra
//
//  The app shell, deliberately minimal: four tabs — Today (the cinematic daily
//  briefing), Inbox (the household activity feed), My Tasks (the system of record),
//  and Household — plus a floating circular Capture button that overlays every tab.
//  Review is not a destination; the Today sequence is where the day is framed. First
//  launch presents the onboarding transformation.
//

import CoreData
import SwiftUI

/// The one way any screen opens the global capture composer — injected by the
/// shell so deep views (empty states, cards) never need their own sheet plumbing.
extension EnvironmentValues {
    @Entry var openCapture: () -> Void = {}
    /// Reopen a specific parked capture (the Today "captures waiting" line). Distinct
    /// from `openCapture`, which always begins a fresh one.
    @Entry var resumeCapture: (Capture) -> Void = { _ in }
    /// Jump to the Inbox tab — used by the Today surface's held-depth tile (which
    /// used to open the AI-trail sheet; the trail is now the Inbox tab).
    @Entry var openInbox: () -> Void = {}
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
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)])
    private var changesResults: FetchedResults<ChangeLogEntry>
    @AppStorage("lastInboxSeenAt") private var lastInboxSeenAt: Double = 0
    @State private var showOnboarding: Bool
    @State private var showComposer = false
    /// A parked capture the user chose to resume, from the Today "captures waiting"
    /// line. Nil for a fresh capture — opening the composer always starts a NEW one, so
    /// being interrupted twice never overwrites the first thought.
    @State private var resumingCapture: Capture?
    /// The transient "Added N tasks" receipt, shown after the composer closes.
    @State private var commitNotice: UndoNotice?
    @State private var selection: Int

    init() {
        let onboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
        let seeding = ProcessInfo.processInfo.arguments.contains("-SeedSampleData")
        _showOnboarding = State(initialValue: !onboarded && !seeding)
        // Verification seam: `-InitialTab N` selects the starting tab.
        let args = ProcessInfo.processInfo.arguments
        let initialTab =
            args.firstIndex(of: "-InitialTab").flatMap {
                args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil
            } ?? 0
        // TabView crashes if selection is set to an unavailable tab, so clamp the
        // verification seam to the four valid tab values
        // (0 Today, 1 Inbox, 2 My Tasks, 3 Household).
        _selection = State(initialValue: min(max(initialTab, 0), 3))
    }

    /// Unread Inbox entries — anything logged since the user last opened the tab. Excludes
    /// manual field edits ("edited") the same way the feed does (`isInboxVisible`), so a
    /// timeline-only edit never inflates the badge for something the Inbox won't show.
    private var unreadInboxCount: Int {
        changesResults.filter {
            $0.isInboxVisible && $0.timestamp.timeIntervalSinceReferenceDate > lastInboxSeenAt
        }.count
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sparkles", value: 0) {
                TodayHomeView()
            }
            Tab("Inbox", systemImage: "tray", value: 1) {
                InboxView()
            }
            .badge(unreadInboxCount)
            Tab("My Tasks", systemImage: "checklist", value: 2) {
                TasksHomeView()
            }
            Tab("Household", systemImage: "person.3", value: 3) {
                HouseholdView()
            }
        }
        .tint(Palette.accentFlat)
        .overlay(alignment: .bottomTrailing) { captureButton }
        // The confirm's receipt. It renders HERE, not in the composer, because the sheet
        // is already gone by the time there is anything to report.
        .undoNotice($commitNotice)
        .environment(\.openCapture, { presentComposer(resuming: nil) })
        .environment(\.resumeCapture, { capture in presentComposer(resuming: capture) })
        .environment(\.openInbox, { selection = 1 })
        // Tapping the daily nudge lands on Today, wherever the app was left.
        .onChange(of: briefing.pendingOpenBriefing) { _, pending in
            guard pending else { return }
            selection = 0
            briefing.pendingOpenBriefing = false
        }
        // onDismiss is the invariant's backstop: however the sheet closed (commit,
        // discard, swipe), the next open starts fresh unless \.resumeCapture re-arms it.
        .sheet(
            isPresented: $showComposer,
            onDismiss: {
                resumingCapture = nil
                presentCommitNotice()
            }
        ) {
            ComposerView(resuming: resumingCapture)
        }
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
        }
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
        resumingCapture = capture
        showComposer = true
    }

    /// Show the receipt for a confirm that just happened, once. Deliberately no Undo
    /// button: undoing a batch means deleting the created tasks AND reversing each merge
    /// AND unwinding the blocker edges commit wrote onto OTHER tasks — a half-honest
    /// version of that is worse than none, so per-item Undo stays in the Inbox where it
    /// already works, and this notice claims nothing about it.
    private func presentCommitNotice() {
        guard let summary = brain.lastCommitSummary, !summary.isEmpty else { return }
        brain.lastCommitSummary = nil  // consumed — a dismiss reports its own commit only
        commitNotice = UndoNotice(message: summary.message)
    }

    /// The persistent Capture action: a circular accent-gradient button in the
    /// bottom-trailing corner. Linear's agent button sits INLINE beside its (icon-only,
    /// narrow) tab bar; ours can't — four LABELED tabs make the system capsule too wide
    /// to leave beside-room on this device, so a beside-placement overlaps Household.
    /// Per the plan's documented fallback, we pin it just ABOVE the bar's trailing edge
    /// ("near the bar"), which also keeps it from floating orphaned when the bar
    /// minimizes on scroll. `bottomInset` is a TUNED CONSTANT (the bar geometry isn't
    /// public), not a pixel-lock.
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
        let drafts = await brain.triage(sample, roster: roster)
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
    /// the AI engine so status/confidence/autonomy are exact — see
    /// prev-docs/mock-data-user-flows.md. Never fires in normal runs.
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
