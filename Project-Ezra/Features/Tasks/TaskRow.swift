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
//  full accessibility (state enumerated verbally). Quick actions live in
//  a Linear-style long-press context menu (Done · Status · Urgent · Cancel) —
//  the system lift-and-pop, no custom gesture.
//
//  The leading glyph is the four-state `StatusGlyphView` menu (.todo · .doing ·
//  .done · .canceled), so complete/cancel/re-stage is one tap from the row. The trailing avatar answers "whose is this?":
//  a person's avatar when it's someone else's, a dashed unassigned ring when it's
//  shared/unowned, and nothing at all when it's mine.
//

import CoreData
import SwiftUI

struct TaskRow: View {
    let task: TaskItem
    /// The full working set, so the leading status menu's transitions stay graph-accurate.
    var allTasks: [TaskItem] = []
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
    /// Whether the leading glyph is a tappable state menu. A resolved record row passes
    /// `false` for a static glyph.
    var interactive: Bool = true
    var onComplete: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    @Environment(\.managedObjectContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompleting = false
    /// True while a finger is held on the row — drives the Linear-style press
    /// highlight that communicates what's about to lift into the context menu.
    @State private var isPressingForMenu = false
    /// Toggled (never read) to fire the error haptic below — a dropped save here has
    /// no alert to show (a flat list row owns no presentation), but silence would mean
    /// a tap that looked like it worked and wasn't persisted goes completely unnoticed.
    /// The mutation itself is left pending on `task`, matching every other save-check
    /// in the app: unconfirmed, not lost.
    @State private var saveFailed = false

    private var isBlocked: Bool { blockerSummary != nil }

    /// The row's compact due vocabulary: "3d over" (overdue token) · "Today" ·
    /// a weekday inside the week ("Fri") · a short date beyond it ("Sep 12").
    private var dueLabel: (text: String, isOverdue: Bool)? {
        guard !task.status.isResolved, let due = task.dueDate,
            let days = TaskItem.daysUntil(due, now: Date())
        else { return nil }
        if days < 0 { return ("\(-days)d over", true) }
        if days == 0 { return ("Today", false) }
        if days < 7 {
            return (due.formatted(.dateTime.weekday(.abbreviated)), false)
        }
        return (due.formatted(.dateTime.month(.abbreviated).day()), false)
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

            StatusGlyphView(
                task: task, allTasks: allTasks, interactive: interactive, onPick: handlePick
            )
            .recessed(isBlocked)

            Text(task.title)
                .taskTitleStyle()
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
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
            if let due = dueLabel {
                Text(due.text)
                    .font(.chipLabel)
                    .foregroundStyle(due.isOverdue ? Palette.overdue : Palette.mutedText)
                    .monospacedDigit()
                    .recessed(isBlocked)
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
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Palette.secondarySurface)
                .opacity(isPressingForMenu ? 1 : 0)
        )
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
        .accessibilityActions {
            if onComplete != nil { Button("Complete") { complete() } }
            if onCancel != nil { Button("Cancel Task") { onCancel?() } }
        }
        .sensoryFeedback(.error, trigger: saveFailed)
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
        if task.isUrgent { parts.append("urgent") }
        if task.needsDecision && !task.status.isResolved { parts.append("needs a decision") }
        if isBlocked { parts.append("blocked") }
        if let stepProgress { parts.append(stepProgress.label) }
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
