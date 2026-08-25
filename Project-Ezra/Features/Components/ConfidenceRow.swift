//
//  ConfidenceRow.swift
//  Project-Ezra
//
//  Maps the PRD's silent/suggest/ask autonomy tiers to a single quiet line under
//  a task — a read-out of how sure the AI was when it filed this, nothing more.
//
//  The old "Accept" button is gone with the `.inbox` state. It existed to confirm an
//  unconfirmed suggest-tier proposal out of Activity, and there is no such thing any
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
                .font(.glyphCaption())
                .foregroundStyle(Palette.accentFlat)
        case .suggest:
            ProvenanceTag()
        case .ask:
            Image(systemName: "hand.raised.fill")
                .font(.glyphCaption())
                .foregroundStyle(Palette.decisionAccent)
        }
    }

    private var text: String {
        switch task.autonomy {
        case .silent: return task.reasoning.isEmpty ? "Automatically updated" : task.reasoning
        // Falls back to the CONSEQUENCE ("worth a look") rather than naming the author.
        // The gradient tag beside it already says this line came from Ezra rather than
        // from the user; saying it twice, in words, is branding.
        case .suggest: return task.reasoning.isEmpty ? "Worth a look" : task.reasoning
        case .ask: return task.isJudgmentCall ? "Your call to make" : "Needs your input"
        }
    }

    private var color: Color {
        task.autonomy == .ask ? Palette.secondaryText : Palette.mutedText
    }
}

/// The provenance tag — "Ezra wrote this line, not you" — and one of the sanctioned
/// gradient uses.
///
/// It used to read `AI`. The MARK is load-bearing and stays: the trust guardrails require
/// that an AI-authored line be attributable, and stripping the tag would make Ezra's
/// interpretations indistinguishable from the user's own words. The LETTERS are not: the
/// customer never hears "AI", because intelligence is a property of Ezra rather than a
/// feature bolted onto it. A sparkle carries the same provenance without the branding, and
/// it is already the glyph this product uses for Ezra's own work (the Brief's tab, the
/// tidied tile, the change-log's actor badge).
struct ProvenanceTag: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.chipLabelTight)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Palette.accentGradient, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .accessibilityLabel("From Ezra")
    }
}
