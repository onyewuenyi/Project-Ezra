//
//  TodayView.swift
//  Project-Ezra
//
//  The two-scene cinematic Today briefing:
//
//    Scene 1 — Recap ("what you got done"): a full-screen count-up + cascading
//              titles, which doubles as the cover WHILE the AI advisor reasons the
//              day in the background. No spinner.
//    Scene 2 — the advisor briefing: headline · action plan · tradeoffs · risks. The
//              action steps are tappable and open the task.
//
//  The transition is DATA-driven, never timed: it fires the moment generation
//  completes AND the Recap's entrance animation has played (via
//  `withAnimation`'s completion, not a timer). Input is never locked; a tap on the
//  Recap skips straight to the briefing once it's ready.
//

import CoreData
import SwiftUI

struct TodayView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(AppBrain.self) private var brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openCapture) private var openCapture
    @Environment(\.openInbox) private var openInbox
    @Environment(\.resumeCapture) private var resumeCapture
    @Environment(\.scenePhase) private var scenePhase

    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var changesResults: FetchedResults<ChangeLogEntry>
    @FetchRequest(sortDescriptors: []) private var logsResults: FetchedResults<CapacityLog>
    @FetchRequest(sortDescriptors: []) private var profiles: FetchedResults<UserProfile>

    @State private var sequence: TodaySequenceModel
    @State private var selectedTask: TaskItem?
    @State private var notice: UndoNotice?
    @State private var recapAppeared = false
    @State private var recapEntrancePlayed = false

    init(brain: AppBrain, store: TodayPlanStore) {
        _sequence = State(initialValue: TodaySequenceModel(brain: brain, store: store))
    }

    private var tasks: [TaskItem] { Array(tasksResults) }
    private var tasksByID: [UUID: TaskItem] {
        Dictionary(uniqueKeysWithValues: tasks.compactMap { task in task.uuid.map { ($0, task) } })
    }
    /// AI-handled count for the held-depth tile — excludes the daily "planned" entry.
    private var tidiedCount: Int {
        changesResults.filter { !$0.undone && $0.initiatedBy == .ai && $0.action != "planned" }.count
    }

    /// The plan's actions that still resolve to a real task, paired with it. A merge or a
    /// store reset can leave an id behind; rendering the section from this (rather than
    /// skipping inside the loop) keeps the step numbering contiguous and stops a plan of
    /// entirely-vanished ids from drawing an empty "The plan" header.
    private func liveActions(of plan: GeneratedPlan) -> [(action: PlannedAction, task: TaskItem)] {
        plan.actions.compactMap { action in
            tasksByID[action.taskID].map { (action: action, task: $0) }
        }
    }

    /// What the detail pages through from Today: the advisor's action plan, in the order
    /// it argued for. Swiping walks the briefing rather than the record.
    private var planPeers: [TaskItem] {
        (sequence.plan?.actions ?? []).compactMap { tasksByID[$0.taskID] }
    }

    private var sceneTransition: AnyTransition {
        reduceMotion ? .opacity : Motion.beatRecede
    }

    var body: some View {
        ZStack {
            TodayBackdrop()
            content
        }
        .taskDetailSheet($selectedTask, peers: planPeers)
        .undoNotice($notice)
        .sensoryFeedback(trigger: recapAppeared) { _, landed in
            landed ? .impact(flexibility: .soft) : nil
        }
        .sensoryFeedback(trigger: sequence.isGenerating) { was, now in
            (was && !now) ? .success : nil
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Replan", systemImage: "arrow.triangle.2.circlepath") { sequence.replan() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .task { startIfNeeded() }
        .onChange(of: sequence.isGenerating) { _, generating in
            if !generating { trySwapToBriefing() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restartIfDayRolledOver() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if sequence.resting {
            briefingScene(resting: true)
        } else {
            switch sequence.beat {
            case .recap: recapScene.transition(sceneTransition)
            case .briefing: briefingScene(resting: false).transition(sceneTransition)
            }
        }
    }

    // MARK: - Start + scene transition

    private func startIfNeeded() {
        guard !sequence.started else { return }
        sequence.start(
            tasks: tasks, logs: Array(logsResults),
            currentUserID: profiles.first?.linkedMemberID, context: context)
        playRecapEntrance()
    }

    /// The app can outlive the day it launched in — a phone left on Today overnight, or
    /// (the common case) backgrounded and reopened the next morning from the nudge. Re-arm
    /// the sequence and replay the entrance so the new day gets its briefing instead of
    /// resting on yesterday's.
    private func restartIfDayRolledOver() {
        guard
            sequence.restartIfDayRolledOver(
                now: Date(), tasks: tasks, logs: Array(logsResults),
                currentUserID: profiles.first?.linkedMemberID, context: context)
        else { return }
        recapAppeared = false
        recapEntrancePlayed = false
        playRecapEntrance()
    }

    private func playRecapEntrance() {
        guard sequence.beat == .recap else { return }
        withAnimation(reduceMotion ? Motion.fade : Motion.heroSettle) {
            recapAppeared = true
        } completion: {
            recapEntrancePlayed = true
            trySwapToBriefing()
        }
    }

    private func trySwapToBriefing() {
        withAnimation(reduceMotion ? Motion.fade : Motion.briefingReveal) {
            sequence.showBriefingIfReady(recapEntrancePlayed: recapEntrancePlayed)
        }
    }

    // MARK: - Scene 1: Recap (the exhale + generation cover)

    private var recapScene: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Spacer(minLength: Spacing.xxl)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                CountingNumber(value: recapAppeared ? Double(sequence.recap.count) : 0)
                    .heroDisplayStyle()
                    .animation(reduceMotion ? nil : Motion.countUp, value: recapAppeared)
                Text(sequence.recap.count == 1 ? "thing wrapped up" : "things wrapped up")
                    .supportingStyle()
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(sequence.recap.completedTasks.prefix(5).enumerated()), id: \.element.objectID) {
                    index, task in
                    TodayTaskRow(task: task, register: .recap)
                        .opacity(recapAppeared ? 0.9 : 0)
                        .offset(y: recapAppeared ? 0 : 8)
                        .animation(revealAnimation(index: index), value: recapAppeared)
                }
            }

            Spacer()

            if sequence.isGenerating {
                readingIndicator
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { trySwapToBriefing() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You completed \(sequence.recap.count). Reading your day.")
    }

    /// The quiet "the advisor is reasoning" cue that rides the Recap while generating.
    private var readingIndicator: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: IconSize.caption))
                .foregroundStyle(Palette.accentFlat)
                .symbolEffect(.pulse, options: .repeating)
            Text("Reading your day…")
                .metadataStyle()
        }
    }

    // MARK: - Scene 2: the advisor briefing

    @ViewBuilder
    private func briefingScene(resting: Bool) -> some View {
        if let plan = sequence.plan, !liveActions(of: plan).isEmpty {
            briefingContent(plan, resting: resting)
        } else if sequence.isGenerating {
            readingCover
        } else {
            allClear
        }
    }

    private var readingCover: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: IconSize.display))
                .foregroundStyle(Palette.accentFlat)
                .symbolEffect(.pulse, options: .repeating)
            Text("Reading your day…")
                .font(.sectionHeader)
                .foregroundStyle(Palette.primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func briefingContent(_ plan: GeneratedPlan, resting: Bool) -> some View {
        // The plan is a live surface, not a printed page: the user works it, comes back,
        // and needs to see the difference. Resolved steps read as struck-through record,
        // and the two accented slots — the hero edge and the CTA — follow the first step
        // still OPEN rather than staying pinned to step 1. Crowning a finished task with
        // the day's payoff gradient is the tell that nothing is watching.
        let steps = liveActions(of: plan)
        let next = steps.first { !$0.task.status.isResolved }
        let doneCount = steps.filter { $0.task.status.isResolved }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Headline — the advisor's one-line read (or a plain title on the
                // deterministic fallback).
                Text(plan.headline ?? "Your day")
                    .heroDisplayStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.sm)

                if resting, sequence.dayChanged(currentTasks: tasks) {
                    Button {
                        sequence.replan()
                    } label: {
                        Label("Your day changed — Replan", systemImage: "arrow.triangle.2.circlepath")
                            .font(.controlLabel)
                            .foregroundStyle(Palette.accentFlat)
                    }
                    .buttonStyle(.pressableLink)
                }

                // The action plan — tappable steps that open the task.
                briefingSection("The plan", trailing: planProgress(done: doneCount, of: steps.count)) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(Array(steps.enumerated()), id: \.element.action.taskID) { index, step in
                            actionStep(
                                number: index + 1, task: step.task, line: step.action.rationale,
                                isHero: step.action.taskID == next?.action.taskID)
                        }
                    }
                }

                if let tradeoffs = plan.tradeoffs {
                    briefingSection("Tradeoffs") {
                        Text(tradeoffs).supportingStyle().fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let risks = plan.risks {
                    briefingSection("Risks") {
                        Text(risks).supportingStyle().fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let next {
                    primaryCTA(task: next.task)
                } else {
                    planClearedLine
                }

                if resting, tidiedCount > 0 {
                    Button {
                        openInbox()
                    } label: {
                        HeldDepthView(heldCount: 0, tidiedCount: tidiedCount)
                    }
                    .buttonStyle(.pressable)
                }

                if resting { parkedCapturesLine }
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Unfinished captures, on the RESTING surface only — never inside the played
    /// sequence. One line, present only when the count is non-zero, and dismissible by
    /// acting rather than by a gesture.
    ///
    /// This is the surfacing half of capture durability: parking a thought is only
    /// useful if there is somewhere it can be found again. It also closes the recorded
    /// inbox-confirm gap from the draft side — unconfirmed captures used to rot
    /// invisibly, which is a trust leak in a product whose thesis is honesty.
    ///
    /// It does not grow forever: `BrainSweeps` prunes a long-parked capture (logged and
    /// reversible), so this surface decays like everything else in the product.
    @ViewBuilder private var parkedCapturesLine: some View {
        let parked = AppBrain.parkedCaptures(in: context)
        if !parked.isEmpty {
            Button {
                // Resume the most recent; the rest stay parked and reachable.
                if let newest = parked.first { resumeCapture(newest) }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "tray")
                        .font(.system(size: IconSize.caption))
                    Text(
                        parked.count == 1
                            ? "1 capture waiting" : "\(parked.count) captures waiting"
                    )
                    .font(.metadata)
                }
                .foregroundStyle(Palette.secondaryText)
            }
            .buttonStyle(.pressableLink)
        }
    }

    /// One action on the plan: a tappable step (→ the task) with the advisor's line.
    ///
    /// `isHero` is the first step still OPEN, not step 1 — see `briefingContent`. A
    /// resolved step keeps its place and stays tappable (the record of the day is part of
    /// the briefing), but reads as done: its numeral becomes the status glyph, the title
    /// strikes through, and the whole card recedes.
    private func actionStep(number: Int, task: TaskItem, line: String?, isHero: Bool) -> some View {
        let isDone = task.status.isResolved
        return Button {
            selectedTask = task
        } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
                stepMarker(number: number, task: task)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(isHero ? .sectionHeader : .taskTitle)
                        .foregroundStyle(isDone ? Palette.secondaryText : Palette.primaryText)
                        .strikethrough(isDone, color: Palette.mutedText)
                        .multilineTextAlignment(.leading)
                    if let line, !line.isEmpty, !isDone {
                        Text(line)
                            .metadataStyle()
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.caption, weight: .semibold))
                    .foregroundStyle(Palette.mutedText)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(
                        isHero
                            ? AnyShapeStyle(Palette.elevatedSurface) : AnyShapeStyle(Palette.primarySurface))
            )
            .overlay {
                // The hero action's accent-gradient edge — the day's payoff moment
                // (sanctioned gradient site).
                if isHero {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Palette.accentGradient, lineWidth: 1.5)
                }
            }
            .recessed(isDone)
        }
        .buttonStyle(.pressable)
        .transition(reduceMotion ? .opacity : Motion.cardEntry)
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: isDone)
        .accessibilityLabel(
            isDone ? "\(task.title), \(task.status.label)" : "Step \(number), \(task.title)"
        )
        .accessibilityHint("Opens the task")
    }

    /// The step's leading mark: its number while open, its status glyph once resolved —
    /// one slot, so a finished step never claims a position in the remaining order.
    @ViewBuilder
    private func stepMarker(number: Int, task: TaskItem) -> some View {
        if task.status.isResolved {
            Image(systemName: task.status.symbol)
                .font(.system(size: IconSize.small, weight: .semibold))
                .foregroundStyle(task.status.tint)
                .frame(width: 20, alignment: .leading)
        } else {
            Text("\(number)")
                .font(.controlLabel)
                .monospacedDigit()
                .foregroundStyle(Palette.accentFlat)
                .frame(width: 20, alignment: .leading)
        }
    }

    /// "2 of 5 done", beside the section header — the only count on this surface, and it
    /// reports the user's own progress rather than a backlog. Absent until something is.
    private func planProgress(done: Int, of total: Int) -> String? {
        done > 0 ? "\(done) of \(total) done" : nil
    }

    /// Where the CTA sits once every step is resolved. The briefing stays on screen as the
    /// record of the day — it just stops asking for anything.
    private var planClearedLine: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: IconSize.small))
                .foregroundStyle(Palette.accentFlat)
            Text("That's the plan, all of it.")
                .font(.controlLabel)
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func primaryCTA(task: TaskItem) -> some View {
        Button {
            selectedTask = task
        } label: {
            Label("Start with \(shortTitle(task.title))", systemImage: "arrow.right.circle.fill")
                .font(.ctaLabel)
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    Palette.accentGradient,
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.pressableProminent)
        .padding(.top, Spacing.xs)
    }

    private var allClear: some View {
        EmptyStateView(
            symbol: "checkmark.seal",
            tint: Palette.accentFlat,
            title: "You're all clear",
            message: "Nothing needs planning today. Capture something, or rest.",
            actionTitle: "Capture something",
            action: { openCapture() })
    }

    // MARK: - Shared bits

    private func briefingSection<Content: View>(
        _ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .font(.metadata.weight(.semibold))
                    .foregroundStyle(Palette.mutedText)
                    .textCase(.uppercase)
                    .tracking(0.8)
                if let trailing {
                    Text(trailing)
                        .font(.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Palette.accentFlat)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortTitle(_ title: String) -> String {
        let words = title.split(separator: " ")
        return words.count <= 4 ? title : words.prefix(4).joined(separator: " ") + "…"
    }

    private func revealAnimation(index: Int) -> Animation? {
        if reduceMotion { return Motion.fade }
        return Motion.beatAdvance.delay(min(Double(index) * 0.05, 0.15))
    }
}
