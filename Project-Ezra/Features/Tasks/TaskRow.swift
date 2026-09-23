//
//  TaskRow.swift
//  Project-Ezra
//
//  The dense record row — the My Tasks surface's atom, redrawn Linear-minimal:
//  `[status glyph | title | trailing owner avatar]`, nothing else. Where the old row
//  carried a "Decide" chip, a due label, and a blocker line, those all move off the
//  row (Needs Decision lives in the full-screen detail now; priority/due manifest as
//  position via `TaskRanking`). What stays: the blocked treatment (a contrast-aware
//  dim + a small `hourglass` marker — never a blur; glass-on-content reads muddy) and
//  full accessibility (state enumerated verbally).
//
//  **The gesture map (2026-09-01), and the rule behind it: one channel, one meaning, on
//  every row type — where a row can't support a meaning the channel is ABSENT, never
//  repurposed.**
//
//      Tap          the whole row → open the detail. ONE target, no holes.
//      Swipe →      the task's `recommendedAction`, through `performRecommendedAction`
//                   — the same move the detail's pinned CTA would make. Absent when that
//                   returns nil, which is exactly someone else's task.
//      ← Swipe      Cancel (reversible, undo pill). Absent on a resolved row.
//      Long-press   the full menu: any status, Urgent, Cancel.
//
//  The leading glyph used to BE a four-state status menu, which made the row's second tap
//  target — tapping a task in one place opened it and in another changed its state, and a
//  chain root had a third (the expander, now gone). It is an indicator now; the verbs it
//  offered live on the swipe (the common next move) and the long-press (any move).
//
//  The trailing avatar answers "whose is this?": a person's avatar when it's someone
//  else's, a dashed unassigned ring when it's shared/unowned, nothing when it's mine.
//

import CoreData
import SwiftUI

struct TaskRow: View {
    let task: TaskItem
    /// The full working set, so the context menu's transitions stay graph-accurate.
    var allTasks: [TaskItem] = []
    /// Whether the status glyph is a control — the state menu, the same component the
    /// container spine's step rows carry — rather than an indicator. Off on the plain
    /// list row, where the glyph would be the row's second tap target and the leading
    /// swipe already carries the lifecycle. ON inside a group's deck (`TaskDeckView`),
    /// where horizontal is navigation and the swipes are absent, so the glyph is the
    /// row's explicit completion target — one control, in the one column that already
    /// means "state". Picks route through the same undo-aware seams as the menu.
    var glyphInteractive: Bool = false
    /// The "waiting on X" phrase — kept ONLY to drive the blocked dim + marker (the
    /// text itself is no longer rendered on the row). Nil when nothing blocks it.
    var blockerSummary: String? = nil
    /// How far this task's own steps have got, when it has any — computed by the list
    /// (like `blockerSummary`) rather than by every row against the full set. Nil for the
    /// ordinary task with no breakdown, which is nearly all of them.
    var stepProgress: StepProgress? = nil
    /// The owner's name resolved against the *others* roster (so it's non-nil only when
    /// the task belongs to someone else). Nil means mine or shared.
    var ownerDisplayName: String? = nil
    var ownerPhotoData: Data? = nil
    /// Whether this row accepts ACTIONS — the long-press menu and the press highlight
    /// that precedes it. A resolved record row passes `false`: it is a record, not a
    /// queue entry. (It used to also mean "the leading glyph is a tappable state menu";
    /// the glyph is an indicator now, so this governs the menu alone.)
    var interactive: Bool = true
    /// A second line under the title, when the row has something to SAY about where it
    /// sits: a deck card names what it waits on ("after Renew passport"); a step rendered
    /// outside its deck — its siblings filtered away, or a search hit — names its outcome
    /// ("Part of Trip to Lagos"). Nil on the ordinary list row, which stays one line and
    /// carries a wait as the dim + hourglass alone.
    var subtitle: String? = nil
    /// A second arrival: when this row SURFACED rather than was created. A container's
    /// row is hidden behind its deck while steps remain and appears the moment the last
    /// one resolves — the list passes that moment here so the row washes in exactly like
    /// a just-confirmed one. Same window, same wash: a row that wasn't there a moment ago.
    var surfacedAt: Date? = nil
    var onComplete: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    @Environment(\.managedObjectContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isCompleting = false
    /// True while a finger is held on the row — drives the Linear-style press
    /// highlight that communicates what's about to lift into the context menu.
    @State private var isPressingForMenu = false
    /// The arrival wash: a just-confirmed task lands with a soft accent tint that fades
    /// over a couple of seconds. Create dismisses the composer immediately and states no
    /// count (2026-08-30) — the tasks themselves are the receipt — so the list has to
    /// show WHICH rows just arrived, or the receipt is a list that looks the same as
    /// before with more in it. Keyed to `confirmedAt`, so only the commit's own rows
    /// wash, and only for the few seconds after it.
    @State private var arrivalWash = false
    /// Toggled (never read) to fire the error haptic below — a dropped save here has
    /// no alert to show (a flat list row owns no presentation), but silence would mean
    /// a tap that looked like it worked and wasn't persisted goes completely unnoticed.
    /// The mutation itself is left pending on `task`, matching every other save-check
    /// in the app: unconfirmed, not lost.
    @State private var saveFailed = false

    private var isBlocked: Bool { blockerSummary != nil }

    /// Whether a row is arriving from a commit that just happened. The window is short
    /// on purpose: a row scrolled into view a minute later is not arriving, and a
    /// relaunch must never re-wash yesterday's captures.
    static let arrivalWindow: TimeInterval = 8

    static func isFreshArrival(confirmedAt: Date?, now: Date = Date()) -> Bool {
        guard let confirmedAt else { return false }
        let age = now.timeIntervalSince(confirmedAt)
        return age >= 0 && age < arrivalWindow
    }

    /// The row's compact due vocabulary — "3d over" · "Today" · "Fri" · "Sep 12" — from
    /// the ONE `DueLabel` the detail chip also reads, so the two can't drift again.
    private var dueLabel: DueLabel? { DueLabel.make(for: task, style: .compact) }

    /// How long since a resolved row was resolved — the ledger's WHEN. Nil on live work
    /// (the due label owns that slot) and on a resolved task with no recorded moment.
    private var resolvedAge: String? {
        guard task.status.isResolved, let at = task.completedAt else { return nil }
        return RelativeAge.compact(at)
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // The user's attention Signal surfaces as a leading mark here (the record
            // surface) — Urgent, or nothing at all (zero footprint). Position is
            // driven by the computed attention score via TaskRanking, never a badge. A
            // blocked row recesses uniformly, so the mark and status glyph dim with the
            // title rather than reading half-disabled.
            SignalMarker(task: task, reservesSpace: true)
                .recessed(isBlocked)

            // An INDICATOR, never a control. It used to open a status menu, which made
            // the row's second tap target — tapping a task in one place opened it and in
            // another changed its state. The state-setting it offered now lives on the
            // gestures: the leading swipe for the recommended next move, the long-press
            // menu for any arbitrary status.
            StatusGlyphView(
                task: task, allTasks: allTasks, interactive: glyphInteractive,
                onPick: glyphInteractive ? { handlePick($0) } : nil
            )
            .recessed(isBlocked)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(task.title)
                    .taskTitleStyle()
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(LayoutMetrics.listTitleLines(for: dynamicTypeSize))
                    .truncationMode(.tail)
                // Only when there is something to say. Reserving the line on every deck
                // card was tried — a blank second line reads as a card missing its
                // subtitle, the title floating above the glyph's centre — so a deck's
                // cards may differ in height by a line, and the deck aligns their TOPS.
                if let subtitle {
                    Text(subtitle)
                        .supportingStyle()
                        .foregroundStyle(Palette.mutedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Crisp, never blurred — a blocked row recedes via a contrast-aware dim
            // plus the marker below, not by frosting its own text (glass-on-content).
            .recessed(isBlocked)

            if isBlocked { BlockedIndicator() }
            if let stepProgress { StepProgressIndicator(progress: stepProgress) }

            Spacer(minLength: Spacing.xs)

            // WHEN, because position cannot carry it: ranking explains which row
            // outranks which, but two neighbours — one due today, one undated — read
            // identically without this. Only a real date earns the ink (undated shows
            // nothing), only live work (a resolved row is a record; its due is over),
            // and overdue wears the one token that means exactly that.
            // The WHEN token is one word to the eye — "1d over", "Sun", "2h ago" — and
            // holds its width: at accessibility sizes, beside the avatar column, the
            // HStack folded "1d over" into "1d" over "over" (2026-09-18). The title is
            // the part that yields; it has two lines there for exactly this.
            if let due = dueLabel {
                Text(due.text)
                    .font(.chipLabel)
                    .foregroundStyle(due.isOverdue ? Palette.overdue : Palette.mutedText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .recessed(isBlocked)
            } else if let age = resolvedAge {
                // A resolved row is a record, and a record says when. Same slot, the
                // quietest register, in `RelativeAge`'s vocabulary ("2h ago") rather than
                // the due label's ("Fri") so the two never read as the same claim.
                Text(age)
                    .font(.chipLabel)
                    .foregroundStyle(Palette.mutedText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            trailingAvatar
        }
        // Dividers are gone in My Tasks (Linear parity), so the row carries its own
        // vertical rhythm — a taller min height keeps the list from reading cramped.
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .opacity(isCompleting ? 0 : 1)
        .onTapGesture { if !isCompleting { onOpen?() } }
        // Press-and-hold feedback (Linear-style): the row highlights under the finger
        // the moment the hold starts, then the system lift takes over. The highlight
        // and the context-menu preview share ONE rounded shape, so the card you see
        // darkening is exactly the card that lifts — a seamless handoff.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(Palette.accentSoft)
                    .opacity(arrivalWash ? 1 : 0)
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(Palette.secondarySurface)
                    .opacity(isPressingForMenu ? 1 : 0)
            }
        )
        .onAppear {
            guard
                Self.isFreshArrival(confirmedAt: task.confirmedAt)
                    || Self.isFreshArrival(confirmedAt: surfacedAt)
            else { return }
            arrivalWash = true
            // Held long enough to be seen after the composer sheet finishes leaving, then
            // gone — a wash, never a badge. A fade is motion-safe, so Reduce Motion keeps it.
            withAnimation(Motion.arrivalWashFade.delay(Motion.arrivalWashHold)) { arrivalWash = false }
        }
        .contentShape(
            .contextMenuPreview, RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        )
        .contextMenu {
            if interactive && !isCompleting {
                contextMenuContent
            }
        }
        // A pure pressing sensor: infinite duration means the perform closure never
        // fires — we only want touch-down/up. `pressing` flips false on release,
        // drag-away, or when the context-menu recognizer takes over, so the highlight
        // hands off to (or retreats from) the system pop on its own.
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40) {
        } onPressingChanged: { pressing in
            guard interactive, !isCompleting else { return }
            withAnimation(Motion.press) { isPressingForMenu = pressing }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        // **Gated on `interactive`, like the swipe and the menu (2026-09-20).** These
        // were gated only on the closures being non-nil, and the list passes those
        // whenever the task is unresolved — so on SOMEONE ELSE'S task, where the leading
        // swipe is deliberately absent and the long-press menu is deliberately inert,
        // VoiceOver was still offered "Complete". "Not yours to advance" is one of this
        // product's stated invariants and it held for the eyes and broke for everyone
        // else. `interactive` is exactly `!resolved && recommendedAction != nil`, which
        // is the rule the other two channels already use, and the deck passes the same
        // `advanceable` flag — so all four channels now agree.
        .accessibilityActions {
            if interactive, onComplete != nil { Button("Complete") { complete() } }
            if interactive, onCancel != nil { Button("Cancel Task") { onCancel?() } }
        }
        .sensoryFeedback(.error, trigger: saveFailed)
        // Completing from the row had no haptic at all — a tap that resolves a task is
        // the one row moment that deserves the success tick the composer's Create gives.
        // Keyed to the fade-out, so it lands once, as the row leaves.
        .sensoryFeedback(.success, trigger: isCompleting) { _, now in now }
    }

    // MARK: - Long-press quick actions

    /// The Linear-style long-press menu: Done / Status / Urgent / Cancel. Every
    /// action routes through the same seams as the leading glyph menu — `handlePick`
    /// for state moves (undo-aware Done/Cancel), `setUrgent` for the signal toggle
    /// (mirroring the detail chip).
    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            handlePick(.done)
        } label: {
            Label("Mark Done", systemImage: "checkmark.circle")
        }

        Menu {
            ForEach(TaskStatus.pickable) { state in
                Button {
                    if state != task.status { handlePick(state) }
                } label: {
                    Label {
                        Text(state.label)
                    } icon: {
                        Image(systemName: state == task.status ? "checkmark" : state.symbol)
                    }
                }
            }
        } label: {
            Label("Status", systemImage: task.status.symbol)
        }

        Button {
            toggleUrgent()
        } label: {
            Label(task.isUrgent ? "Clear Urgent" : "Mark Urgent", systemImage: "exclamationmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            handlePick(.canceled)
        } label: {
            Label("Cancel Task", systemImage: "xmark.circle")
        }
    }

    // MARK: - Trailing avatar (whose is this?)

    @ViewBuilder
    private var trailingAvatar: some View {
        if let ownerDisplayName {
            // Someone else's — their avatar.
            AvatarView(
                source: .owner(name: ownerDisplayName, photoData: ownerPhotoData, isMe: false),
                size: 18)
        } else if task.ownerID == nil {
            // Shared / unassigned — Linear's dashed unassigned ring.
            Image(systemName: "person.crop.circle.dashed")
                .font(.glyphAction())
                .foregroundStyle(Palette.mutedText)
        }
        // Mine → nothing.
    }

    // MARK: - Behavior

    /// The leading-menu pick: Done / Canceled route through the parent's undo-aware
    /// callbacks when present (so completing from the row shows the same undo as a
    /// swipe); every other state applies in place.
    private func handlePick(_ state: TaskStatus) {
        switch state {
        case .done:
            if onComplete != nil { complete() } else { applyDirect(state) }
        case .canceled:
            if let onCancel { onCancel() } else { applyDirect(state) }
        default:
            applyDirect(state)
        }
    }

    private func applyDirect(_ state: TaskStatus) {
        Motion.withMotion(Motion.decide) { task.setStatus(state, in: context) }
        if !context.saveChanges() { saveFailed.toggle() }
        // A lifecycle move is the cheapest honest escalation signal there is: the task's
        // facts just changed, so its cached Advisor reading is stale and the next open
        // would pay for a cold judgment while the user watches. Think it through now.
        //
        // This is one of the two call sites that replaced the Brief's
        // `primeAdvisorForPlannedWork` when the Brief was switched off (the other is
        // `TaskDetailPager`, which primes the peers a swipe away). Bounded to one call per
        // tap, and `precompute` filters the rest on its own terms — the gate makes a
        // trivial task free, `.shallow` judgments are skipped, and `CloudBudget`
        // holds speculative work to half the daily cap.
        TaskAdvisorStore.shared.precompute(task: task, among: allTasks)
    }

    /// The Signal toggle from the long-press menu — routes through the shared mutation
    /// seam (which logs to the task's Activity timeline + recomputes attention), then saves.
    private func toggleUrgent() {
        task.setUrgent(!task.isUrgent, among: allTasks, in: context)
        if !context.saveChanges() { saveFailed.toggle() }
    }

    private func complete() {
        guard !isCompleting, let onComplete else { return }
        if reduceMotion {
            onComplete()
            return
        }
        withAnimation(Motion.complete) { isCompleting = true }
        // Hold briefly so the fade-out reads, then commit (was DispatchQueue.asyncAfter).
        Task {
            try? await Task.sleep(for: .seconds(Motion.completeHold))
            onComplete()
        }
    }

    private var accessibilityText: String {
        var parts = [task.title, task.status.label]
        // **The due label is the one thing on the row that position cannot say** — which
        // is the entire reason it is drawn — and `children: .combine` under an explicit
        // label DROPS it, so VoiceOver got every flag on the row and never the date.
        // `.full` rather than the visual `.compact`: "3d over" is a glance, "3 days
        // overdue" is a sentence, and the overdue arm already says the word.
        if let due = DueLabel.make(for: task, style: .full) {
            parts.append(due.isOverdue ? due.text : "due \(due.text)")
        } else if let resolvedAge {
            parts.append(resolvedAge)
        }
        if task.isUrgent { parts.append("urgent") }
        if task.needsDecision && !task.status.isResolved { parts.append("needs a decision") }
        // Sighted, the blocked row shows WHAT it waits on; spoken, "blocked" alone made
        // the reader open the task to learn the same thing the row was already carrying.
        if isBlocked { parts.append(blockerSummary.map { "blocked, \($0)" } ?? "blocked") }
        if let stepProgress { parts.append(stepProgress.label) }
        // A subtitle that is only whitespace is a HEIGHT RESERVATION, not a sentence —
            // `TaskDeckView` passes a single space to keep non-waiting cards the same
            // height as waiting ones. Spoken verbatim it produced "Book flights, To do,
            // due Friday, , " — a trailing empty component and a spurious pause on every
            // card in any deck that contains a waiting member (2026-09-20).
            if let subtitle, !isBlocked,
                !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                parts.append(subtitle)
            }
        if let ownerDisplayName {
            parts.append("owned by \(ownerDisplayName)")
        } else if task.ownerID == nil {
            parts.append("unassigned")
        }
        return parts.joined(separator: ", ")
    }
}

/// A hairline divider inset to the row's text, the way dense lists separate
/// records without drawing a heavy grid.
struct TaskRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 0.5)
            // Inset under the title: the leading signal mark is zero-footprint when
            // absent, so align to the status glyph column + gap.
            .padding(.leading, LayoutMetrics.recordGlyphColumn + Spacing.sm)
    }
}

#Preview {
    let a = TaskItem(title: "Buy groceries", status: .doing)
    let b = TaskItem(title: "Renew passport", status: .todo, needsDecision: true)
    return VStack(spacing: 0) {
        TaskRow(task: a)
        TaskRowDivider()
        TaskRow(task: b)
    }
    .padding(.horizontal, Spacing.lg)
    .background(Palette.background)
    .environment(\.managedObjectContext, PersistenceStack.scratch)
}
