//
//  MetadataChip.swift
//  Project-Ezra
//
//  The one metadata-capsule shell. Previously three ad-hoc copies drifted apart
//  (TaskDetailView.chip with a border + 44pt tap target; ConfirmCreationCard.pill,
//  a borderless dense capsule with a magic-number `5` pad; the chain-stack badge).
//  Now one tokenized component with two intentional densities — the difference is
//  a parameter, not an accident.
//
//  Source of truth: docs/design-system-managing-chaos.md
//

import SwiftUI

enum MetadataChipDensity {
    /// Standalone editable property chip (the detail sheet): bordered, ≥44pt tap
    /// target, imposes the `supporting` font + primary/muted foreground. The visual
    /// capsule stays short — `hitTarget` extends only the touchable region.
    case standard
    /// Dense inline chip in a horizontal scroller (the confirm-creation card): a bare
    /// capsule that imposes neither font nor color, so each chip keeps its own 12pt
    /// metadata type and per-state tint.
    case compact
}

/// A metadata capsule. Wrap any label content; pick the density for the context.
struct MetadataChip<Content: View>: View {
    var density: MetadataChipDensity = .standard
    /// Standard only: dims the foreground to `mutedText` (the "add / not-set" affordance).
    var muted: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        switch density {
        case .standard:
            row
                .font(.supporting.weight(.medium))
                .foregroundStyle(muted ? Palette.mutedText : Palette.primaryText)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Palette.secondarySurface, in: Capsule())
                .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
                .frame(minHeight: LayoutMetrics.hitTarget)
                .contentShape(Rectangle())
        case .compact:
            // Same trick as `.standard`: the visual capsule stays dense (~22pt), the
            // TOUCHABLE region grows to the HIG minimum. These aren't display chips —
            // every one on the confirm card is a Menu or Button at the exact moment
            // the product asks for correction input, and a missed tap that scrolls
            // instead of opening the menu is a tax on the learning signal.
            row
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(Palette.secondarySurface, in: Capsule())
                .frame(minHeight: LayoutMetrics.hitTarget)
                .contentShape(Rectangle())
        }
    }

    private var row: some View { HStack(spacing: Spacing.xxs) { content } }
}
