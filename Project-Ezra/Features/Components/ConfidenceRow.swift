//
//  ConfidenceRow.swift
//  Project-Ezra
//
//  Maps the PRD's silent/suggest/ask autonomy tiers to a single quiet line under
//  a task — a read-out of how sure the AI was when it filed this, nothing more.
//
//  The old "Accept" button is gone with the `.inbox` state. It existed to confirm an
//  unconfirmed suggest-tier proposal out of the Inbox, and there is no such thing any
//  more: a `TaskItem` comes into existence at Confirm, so every task on screen has
//  already been accepted by a human. The tier survives as provenance.
//

import SwiftUI

struct ConfidenceRow: View {
    let task: TaskItem

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
        }
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
                .foregroundStyle(Palette.decisionAccent)
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
            .font(.chipLabelTight)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Palette.accentGradient, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}
