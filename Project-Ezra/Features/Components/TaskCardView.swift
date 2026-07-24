//
//  TaskCardView.swift
//  Project-Ezra
//
//  The atomic task card. No priority colors, no tag clutter, no persistent status
//  badges — just the title, a light metadata line, and the single AI autonomy row.
//  Completion is fast (<200ms fade+scale with a brief green flash), never a lingering
//  animation, because an active user completes many of these a day.
//

import SwiftUI

struct TaskCardView: View {
    let task: TaskItem
    var showsCompletion: Bool = true
    /// Whether the AI-reasoning row (`ConfidenceRow`) renders. Tasks screen passes
    /// `false` — the board is meant to read as a clean Kanban card, not a triage
    /// surface; Today and Inbox keep the default `true`.
    var showsConfidence: Bool = true
    /// Tasks-board-only: replaces the leading completion circle with a large owner
    /// avatar (bigger than the title — the dominant element on the card), since
    /// Tasks is the multiplayer view where "who" matters more than a quick-complete
    /// tap. Mutually exclusive with `showsCompletion` in practice — the Tasks board
    /// passes `showsCompletion: false` alongside this and completes via a swipe
    /// gesture instead (`.swipeToComplete(...)`). Today/Inbox never set this.
    var showsLeadingAvatar: Bool = false
    var onComplete: (() -> Void)? = nil
    var onAcceptSuggestion: (() -> Void)? = nil
    /// When set, the card body becomes tappable to open the detail sheet. The inner
    /// complete circle and Accept button still win their own touches (they're Buttons),
    /// so there's no gesture conflict — and the card is never wrapped in a Button.
    var onOpen: (() -> Void)? = nil
    /// The "after X (+N)" line, resolved from the task's active blocker references by
    /// the parent (which holds the task list). Nil when nothing active blocks it.
    var blockerSummary: String? = nil
    /// The owner's display name, resolved from `task.ownerID` against the
    /// `FamilyMember` roster by the parent (which holds it). Nil for the user's own
    /// tasks, or if the referenced person was since deleted.
    var ownerDisplayName: String? = nil
    /// The owner's photo bytes, resolved from `task.ownerID` against the `FamilyMember`
    /// roster by the parent. Nil for the user's own tasks or an owner without a photo.
    var ownerPhotoData: Data? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompleting = false

    /// The AI's live observation about this task, derived from the resolved blocker
    /// summary the parent handed us (nil summary ⇒ not blocked) plus the task's own
    /// fields — no second walk of the task graph needed here.
    private var assessment: TaskAssessment {
        task.assessment(isBlocked: blockerSummary != nil)
    }

    /// Whether the trailing chip shows anything.
    private var showsChip: Bool {
        !assessment.isClean
    }
    @State private var completions = 0
    /// Tasks-board-only swipe-to-complete tracking (right swipe, replacing the
    /// hidden completion circle there). Stays 0 and inert whenever
    /// `showsLeadingAvatar` is false — Today/Inbox never engage this.
    @State private var dragOffset: CGFloat = 0
    private let swipeCompleteThreshold: CGFloat = 88

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            if showsLeadingAvatar {
                leadingAvatar
            } else if showsCompletion {
                completeButton
            }

            VStack(alignment: .leading, spacing: Spacing.inline) {
                Text(task.title)
                    .taskTitleStyle()
                    // Blocked recedes the title with a contrast-aware dim — never a blur
                    // (glass-on-content reads muddy). The card already names *why* via
                    // the lock label in the metadata row below, so it needs no extra
                    // marker (unlike the dense `TaskRow`).
                    .recessed(assessment.isBlocked)

                HStack(spacing: Spacing.inline) {
                    Label(task.category, systemImage: TaskCategory.symbol(for: task.category))
                        .labelStyle(.titleAndIcon)
                        .font(.metadata)
                        .foregroundStyle(Palette.secondaryText)
                    // Delegation is quiet but visible: solo users never see this row
                    // grow; multiplayer attribution appears only when a task is
                    // someone else's. Suppressed when the big leading avatar already
                    // shows who this is — never show the same identity twice on one card.
                    if !showsLeadingAvatar, let owner = ownerDisplayName {
                        Text("·").foregroundStyle(Palette.mutedText)
                        HStack(spacing: Spacing.xxs) {
                            OwnerAvatarBadge(name: owner, photoData: ownerPhotoData, size: 22)
                            Text(owner)
                                .font(.metadata)
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    if let due = task.dueDate {
                        Text("·").foregroundStyle(Palette.mutedText)
                        Text(dueText(due))
                            .font(.metadata)
                            .foregroundStyle(isOverdue(due) ? Palette.warning : Palette.secondaryText)
                    }
                    if let effort = task.effortLabel {
                        Text("·").foregroundStyle(Palette.mutedText)
                        Text("~\(effort)")
                            .font(.metadata)
                            .foregroundStyle(Palette.mutedText)
                    }
                    if let blockerSummary {
                        Text("·").foregroundStyle(Palette.mutedText)
                        // The summary carries its own preposition ("after …" for a
                        // tracked task, "waiting on …" for an untracked wait), so a
                        // blocked card always says why.
                        Label(blockerSummary, systemImage: "lock")
                            .font(.metadata)
                            .foregroundStyle(Palette.mutedText)
                            .lineLimit(1)
                    }
                }

                if showsConfidence {
                    ConfidenceRow(task: task, onAccept: onAcceptSuggestion)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if showsChip {
                AssessmentChip(assessment: assessment)
                    .transition(Motion.chip)
            }
        }
        // State transitions rather than teleporting: the blocked dim and the chip
        // crossfade together, so it stays legible under Reduce Motion (padding/
        // background are state-independent).
        .animation(Motion.fade, value: task.status)
        .padding(Spacing.md)
        .background(
            Palette.primarySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
        .overlay {
            // Transient green flash during the completion motion only.
            if isCompleting {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.success.opacity(0.18))
            }
        }
        .background(alignment: .leading) {
            // The swipe-to-complete reveal (Tasks board only — inert elsewhere
            // since dragOffset never leaves 0). Intensity and checkmark opacity
            // both ramp with progress toward the threshold, so the card previews
            // the outcome before the user commits.
            if dragOffset > 0 {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.success.opacity(min(1, dragOffset / swipeCompleteThreshold) * 0.5))
                    .overlay(alignment: .leading) {
                        Image(systemName: "checkmark")
                            .font(.system(size: IconSize.control, weight: .bold))
                            .foregroundStyle(Palette.success)
                            .padding(.leading, Spacing.lg)
                            .opacity(min(1, dragOffset / swipeCompleteThreshold))
                    }
            }
        }
        .offset(x: dragOffset)
        .scaleEffect(isCompleting ? 0.96 : 1)
        .opacity(isCompleting ? 0 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture {
            if !isCompleting { onOpen?() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    guard showsLeadingAvatar, value.translation.width > 0, !isCompleting else { return }
                    let raw = value.translation.width
                    dragOffset =
                        raw < swipeCompleteThreshold
                        ? raw : swipeCompleteThreshold + (raw - swipeCompleteThreshold) * 0.15
                }
                .onEnded { _ in
                    guard showsLeadingAvatar else { return }
                    if dragOffset >= swipeCompleteThreshold {
                        dragOffset = 0
                        complete()
                    } else {
                        withAnimation(reduceMotion ? nil : Motion.snap) { dragOffset = 0 }
                    }
                }
        )
        // Soft tick on completion — a high-frequency action, so not `.success`.
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: completions)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
        .accessibilityHint(onOpen != nil ? "Opens task details" : "")
        .accessibilityActions {
            // Available regardless of whether completion is a tap (circle) or a
            // swipe (Tasks board) — VoiceOver users need this action either way,
            // since a custom swipe gesture isn't a reliable VoiceOver interaction.
            if onComplete != nil {
                Button("Complete") { complete() }
            }
            if task.status == .inbox, task.autonomy == .suggest, let onAcceptSuggestion {
                Button("Accept suggestion", action: onAcceptSuggestion)
            }
        }
    }

    /// The dominant visual on a Tasks-board card: bigger than the title, bigger than
    /// anything else here. Always shows *someone* — the delegated owner, or a
    /// generic "Me" glyph for the user's own tasks — so every card on this
    /// multiplayer board reads "whose is this" at a glance, not just delegated ones.
    private var leadingAvatar: some View {
        OwnerAvatarBadge(
            name: ownerDisplayName ?? "Me",
            photoData: ownerPhotoData,
            isMe: ownerDisplayName == nil,
            size: 52
        )
    }

    private var completeButton: some View {
        Button {
            complete()
        } label: {
            Image(systemName: "circle")
                .font(.system(size: IconSize.control, weight: .light))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 44, height: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressableIcon)
        .accessibilityLabel("Complete \(task.title)")
    }

    private func complete() {
        guard !isCompleting else { return }
        completions += 1  // fires the completion haptic regardless of Reduce Motion
        if reduceMotion {
            onComplete?()
            return
        }
        withAnimation(Motion.complete) {
            isCompleting = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.completeHold) {
            onComplete?()
        }
    }

    private func dueText(_ date: Date) -> String {
        let cal = Calendar.current
        // An overdue date says so plainly — honesty over a decoratively tinted weekday.
        if isOverdue(date) {
            let days =
                cal.dateComponents(
                    [.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())
                ).day ?? 1
            return "\(days)d overdue"
        }
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    private func isOverdue(_ date: Date) -> Bool {
        date < Calendar.current.startOfDay(for: Date())
    }

    private var accessibilityText: String {
        var parts = [task.title, task.category]
        if let owner = ownerDisplayName {
            parts.append("\(owner)'s task")
        } else if showsLeadingAvatar {
            parts.append("your task")
        }
        if let effort = task.effortLabel { parts.append("about \(effort)") }
        if assessment.needsDecision != nil {
            parts.append("needs decision")
        } else if assessment.isBlocked {
            parts.append("blocked")
        } else if assessment.isUnowned {
            parts.append("up for grabs")
        }
        if let blockerSummary { parts.append(blockerSummary) }
        if let due = task.dueDate {
            parts.append(isOverdue(due) ? dueText(due) : "due \(dueText(due))")
        }
        return parts.joined(separator: ", ")
    }
}
