//
//  TodayTaskRow.swift
//  Project-Ezra
//
//  The Today sequence's row, in three registers: a Plan action (check-off circle,
//  title, the model's calm rationale, a small overdue marker), a resting/completed
//  row (checked and dimmed in place, driven by the live task's status — no timer),
//  and a Recap row (monochrome, done, non-interactive — the exhale). Priority never
//  renders; position already carries it. Overdue is the one metadata marker
//  (flags philosophy); everything else differentiates by material and position.
//
//  This row does no `DispatchQueue.asyncAfter` / completion-chaining — completion
//  calls straight through and the live status drives the checked-and-dimmed look.
//  (The record surfaces `TaskRow`/`TaskCardView` hold briefly via `Motion.completeHold`
//  so their fade-out reads; that's the one place a completion delay is intended.)
//

import SwiftUI

struct TodayTaskRow: View {
    enum Register { case plan, recap }

    let task: TaskItem
    var rationale: String? = nil
    /// Observable facts for the long-press explanation.
    var facts: [String] = []
    var register: Register = .plan
    var onComplete: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDone: Bool { task.status.isResolved }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.supporting)
                    .foregroundStyle(isDone ? Palette.mutedText : Palette.primaryText)
                    .strikethrough(isDone, color: Palette.mutedText)
                    .lineLimit(1)
                    .animation(Motion.complete, value: isDone)
                if register == .plan, let rationale, !rationale.isEmpty {
                    Text(rationale)
                        .metadataStyle()
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        // Streamed rationale crossfades as the model fills it in on
                        // device, rather than snapping between fact-line and prose.
                        .contentTransition(.opacity)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: Spacing.xs)

            if register == .plan, !isDone, task.isOverdue() {
                Text(overdueLabel)
                    .metadataStyle()
                    .foregroundStyle(Palette.overdue)
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(
            register == .recap ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Palette.primarySurface),
            in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        )
        .opacity(register == .recap ? 0.9 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .onTapGesture { if register == .plan { onOpen?() } }
        // A light tap the instant a task is checked off — fires only on the
        // false→true transition, so pre-done recap rows never buzz on appear.
        .sensoryFeedback(trigger: isDone) { old, new in
            (register == .plan && new && !old) ? .impact(weight: .light) : nil
        }
        .whyAmISeeingThis(facts.isEmpty ? [task.title] : facts)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(register == .plan ? .isButton : [])
    }

    @ViewBuilder
    private var leading: some View {
        switch register {
        case .recap:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: IconSize.body))
                .foregroundStyle(Palette.success)
                .frame(width: LayoutMetrics.recordGlyphColumn, height: LayoutMetrics.recordGlyphColumn)
        case .plan:
            // One symbol that MORPHS circle → checkmark on completion (symbolEffect
            // replace), so the core action lands with a satisfying spring instead of a
            // hard swap. Disabled once done so the checkmark can't be re-tapped.
            Button {
                if !isDone { onComplete?() }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: IconSize.control, weight: isDone ? .regular : .light))
                    .foregroundStyle(isDone ? Palette.success : Palette.secondaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: LayoutMetrics.recordGlyphColumn, height: LayoutMetrics.recordGlyphColumn)
                    .minimumHitTarget()
            }
            .buttonStyle(.pressableIcon)
            .disabled(isDone)
            .animation(Motion.complete, value: isDone)
            .accessibilityLabel(isDone ? "\(task.title), done" : "Complete \(task.title)")
        }
    }

    private var overdueLabel: String {
        let cal = Calendar.current
        guard let due = task.dueDate else { return "Overdue" }
        let days =
            cal.dateComponents(
                [.day], from: cal.startOfDay(for: due), to: cal.startOfDay(for: Date())
            ).day ?? 1
        return "\(max(1, days))d overdue"
    }

    private var accessibilityText: String {
        var parts = [task.title]
        if isDone { parts.append("done") }
        if register == .plan, let rationale, !rationale.isEmpty { parts.append(rationale) }
        return parts.joined(separator: ", ")
    }
}
