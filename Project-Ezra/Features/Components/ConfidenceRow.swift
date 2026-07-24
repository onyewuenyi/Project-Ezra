//
//  ConfidenceRow.swift
//  Project-Ezra
//
//  Maps the PRD's silent/suggest/ask autonomy tiers to a single quiet line under
//  a task. This is the one place the user interacts with an AI decision directly,
//  so it stays one tap: Accept for suggest-tier, nothing to do for silent.
//

import SwiftUI

struct ConfidenceRow: View {
    let task: TaskItem
    var onAccept: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.inline) {
            icon
                // On Accept (suggest→silent) the symbol swaps in place (Motion HIG:
                // animated symbols); a mixed swap falls back to a clean crossfade.
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.metadata)
                .foregroundStyle(color)
                .lineLimit(1)

            // Accept is offered only while the task is still an unconfirmed proposal at
            // the suggest tier; accepting confirms it out of the Inbox, so the
            // button retires itself.
            if task.status == .inbox, task.autonomy == .suggest, let onAccept {
                Spacer(minLength: Spacing.xs)
                Button("Accept", action: onAccept)
                    .font(.metadata.weight(.semibold))
                    .foregroundStyle(Palette.accentFlat)
                    .buttonStyle(.pressableLink)
                    .transition(.opacity)
            }
        }
        // Accepting (Inbox → Active) crossfades the row's icon/label/button.
        .animation(Motion.fade, value: task.status)
    }

    @ViewBuilder private var icon: some View {
        switch task.autonomy {
        case .silent:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: IconSize.caption))
                .foregroundStyle(Palette.accentFlat)
        case .suggest:
            AITag()
        case .ask:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: IconSize.caption))
                .foregroundStyle(Palette.accentStart)
        }
    }

    private var text: String {
        switch task.autonomy {
        case .silent: return task.reasoning.isEmpty ? "Automatically updated" : task.reasoning
        case .suggest: return task.reasoning.isEmpty ? "AI suggestion" : task.reasoning
        case .ask: return task.isJudgmentCall ? "Your call to make" : "Needs your input"
        }
    }

    private var color: Color {
        task.autonomy == .ask ? Palette.secondaryText : Palette.mutedText
    }
}

/// The small "AI" tag — one of the sanctioned gradient uses. Rendered ≥24px wide.
struct AITag: View {
    var body: some View {
        Text("AI")
            .font(.system(size: 10, weight: .bold))  // micro: bespoke chip metrics
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Palette.accentGradient, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}
