//
//  Typography.swift
//  Project-Ezra
//
//  Type scale from the design system. SF Pro + Dynamic Type throughout: every token
//  is the doc's exact point size at the default content size, scaled through
//  UIFontMetrics so the whole app tracks the user's text-size setting. Tokens are
//  computed so they re-resolve when the size category changes.
//  Tracking is size-specific: tighten large text, leave body near zero.
//

import SwiftUI
import UIKit

/// The doc's pt size, scaled along the given text style's Dynamic Type curve.
private func scaledToken(
    _ size: CGFloat, _ weight: UIFont.Weight, relativeTo style: UIFont.TextStyle
)
    -> Font
{
    Font(UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight)))
}

/// A rounded-design variant of `scaledToken` — for the large display numerals where
/// the rounded face reads warmer at size.
private func scaledRoundedToken(
    _ size: CGFloat, _ weight: UIFont.Weight, relativeTo style: UIFont.TextStyle
)
    -> Font
{
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    let rounded = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
    return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: rounded))
}

extension Font {
    /// 72pt UltraLight rounded — the Today Recap's completed-count numeral. The thin
    /// display numeral. Never hardcode 72 in a view — use this token (and
    /// `heroNumeralStyle()` for its tracking).
    static var heroNumeral: Font { scaledRoundedToken(72, .ultraLight, relativeTo: .largeTitle) }
    /// 64pt Bold rounded — the cinematic count-up numeral and the advisor briefing's
    /// headline. The BOLD big-display token (heroNumeral is too thin for a Wrapped-scale
    /// moment). Use with `heroDisplayStyle()`.
    static var heroDisplay: Font { scaledRoundedToken(64, .bold, relativeTo: .largeTitle) }
    /// 34pt Bold — "What should I work on?"
    static var heroLarge: Font { scaledToken(34, .bold, relativeTo: .largeTitle) }
    /// 28pt Semibold — screen titles
    static var screenTitle: Font { scaledToken(28, .semibold, relativeTo: .title1) }
    /// 17pt Semibold — section headers
    static var sectionHeader: Font { scaledToken(17, .semibold, relativeTo: .headline) }
    /// 16pt Medium — task titles
    static var taskTitle: Font { scaledToken(16, .medium, relativeTo: .callout) }
    /// 14pt Regular — supporting text
    static var supporting: Font { scaledToken(14, .regular, relativeTo: .subheadline) }
    /// 12pt Regular — metadata
    static var metadata: Font { scaledToken(12, .regular, relativeTo: .caption1) }

    // Controls & input — the token set the button/field call sites route through.
    /// 17pt Semibold — primary CTA labels (Capture, Show me, Manage these).
    static var ctaLabel: Font { scaledToken(17, .semibold, relativeTo: .headline) }
    /// 15pt Semibold — compact CTA labels (empty-state actions).
    static var ctaCompact: Font { scaledToken(15, .semibold, relativeTo: .subheadline) }
    /// 13pt Semibold — small control labels (decision bars, Undo, Accept).
    static var controlLabel: Font { scaledToken(13, .semibold, relativeTo: .footnote) }
    /// 16pt Regular — composer / editor input text.
    static var bodyInput: Font { scaledToken(16, .regular, relativeTo: .callout) }
    /// 20pt Semibold — inline nav titles (Today's leading toolbar title).
    static var navTitle: Font { scaledToken(20, .semibold, relativeTo: .title3) }
}

/// SF Symbol point sizes, tokenized so glyphs scale with the type system rather than
/// scattered `.system(size:)` literals. Micro chip metrics (10/11) stay bespoke.
enum IconSize {
    static let display: CGFloat = 40  // empty-state / calm-state glyphs
    static let control: CGFloat = 22  // complete circle, prominent controls
    static let action: CGFloat = 18  // composer mic, inline actions
    static let body: CGFloat = 16  // trail row markers
    static let small: CGFloat = 14  // section header icons
    static let caption: CGFloat = 12  // metadata glyphs, chevrons
}

/// Convenience text-style modifiers that bundle font + size-specific tracking + color.
extension View {
    /// The hero-numeral treatment: `heroNumeral` font with tightened tracking
    /// (~-2% — large type reads loose at default spacing, spec §4.2). Shared by the
    /// Recap numeral and the day-framing title card.
    func heroNumeralStyle() -> some View {
        self.font(.heroNumeral)
            .tracking(-1.4)  // ~-0.02em at 72pt
            .foregroundStyle(Palette.primaryText)
    }

    /// The bold big-display treatment (count-up numerals, briefing headline):
    /// `heroDisplay` with tightened tracking. Pairs with a leading multiline layout.
    func heroDisplayStyle() -> some View {
        self.font(.heroDisplay)
            .tracking(-1.2)  // ~-0.02em at 64pt
            .foregroundStyle(Palette.primaryText)
    }

    func heroLargeStyle() -> some View {
        self.font(.heroLarge)
            .tracking(-0.6)  // ~-0.02em at 34pt
            .foregroundStyle(Palette.primaryText)
    }

    func screenTitleStyle() -> some View {
        self.font(.screenTitle)
            .tracking(-0.4)
            .foregroundStyle(Palette.primaryText)
    }

    func sectionHeaderStyle() -> some View {
        self.font(.sectionHeader)
            .foregroundStyle(Palette.primaryText)
    }

    func taskTitleStyle() -> some View {
        self.font(.taskTitle)
            .foregroundStyle(Palette.primaryText)
    }

    func supportingStyle() -> some View {
        self.font(.supporting)
            .foregroundStyle(Palette.secondaryText)
    }

    func metadataStyle() -> some View {
        self.font(.metadata)
            .foregroundStyle(Palette.mutedText)
    }
}
