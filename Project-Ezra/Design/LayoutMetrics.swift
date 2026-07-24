//
//  LayoutMetrics.swift
//  Project-Ezra
//
//  Layout constants — the same role `Spacing`/`Radius` play, for the column and
//  tap-target metrics that were previously hardcoded per row type (28 / 32 / 44).
//  (Named `LayoutMetrics`, not `Layout`, to avoid clashing with SwiftUI's `Layout`.)
//  Source of truth: docs/design-system-managing-chaos.md
//

import CoreGraphics

enum LayoutMetrics {
    /// The leading status/completion-glyph column width on the dense record and Today
    /// rows — the single value the title aligns under. Replaces the scattered `28`s (and
    /// TodayTaskRow's `32`) so the left rail is consistent across every list.
    static let recordGlyphColumn: CGFloat = 28
    /// The minimum interactive tap target (HIG). Every tappable glyph/control reserves
    /// at least this, even when its visual glyph is smaller than the column.
    static let hitTarget: CGFloat = 44
}
