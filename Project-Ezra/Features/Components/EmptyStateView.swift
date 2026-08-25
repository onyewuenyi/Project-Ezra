//
//  EmptyStateView.swift
//  Project-Ezra
//
//  Because the store ships empty (no seeded samples), every screen's empty state
//  is a real, designed moment — calm, never a dead end. Answers "where am I / what
//  can I do here" with a single clear action.
//

import SwiftUI

struct EmptyStateView: View {
    let symbol: String
    /// Glyph tint. Neutral by default; Today's calm/all-clear states pass the accent
    /// because clearing out is a positive payoff, not a dead end.
    var tint: Color = Palette.secondaryText
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.glyphDisplay(.light))
                .foregroundStyle(tint)
                .padding(.bottom, Spacing.xxs)

            Text(title)
                .sectionHeaderStyle()
                .multilineTextAlignment(.center)

            Text(message)
                .supportingStyle()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.ctaCompact)
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
                        .background(Palette.accentGradient, in: Capsule())
                }
                .buttonStyle(.pressableProminent)
                .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

#Preview {
    EmptyStateView(
        symbol: "tray",
        title: "Nothing here yet",
        message: "Nothing to triage. Capture something and Ezra will sort it.",
        actionTitle: "Capture a task",
        action: {}
    )
    .background(Palette.background)
}
