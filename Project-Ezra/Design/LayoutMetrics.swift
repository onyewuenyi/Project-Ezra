//
//  LayoutMetrics.swift
//  Project-Ezra
//
//  Layout constants — the same role `Spacing`/`Radius` play, for the column and
//  tap-target metrics that were previously hardcoded per row type (28 / 32 / 44).
//  (Named `LayoutMetrics`, not `Layout`, to avoid clashing with SwiftUI's `Layout`.)
//  Source of truth: docs/design-system-managing-chaos.md
//

import SwiftUI

enum LayoutMetrics {
    /// The leading status/completion-glyph column width on the dense record and Today
    /// rows — the single value the title aligns under. Replaces the scattered `28`s (and
    /// BriefTaskRow's `32`) so the left rail is consistent across every list.
    static let recordGlyphColumn: CGFloat = 28
    /// The minimum interactive tap target (HIG). Every tappable glyph/control reserves
    /// at least this, even when its visual glyph is smaller than the column.
    static let hitTarget: CGFloat = 44
    /// The Ramble orb — the object the capture field becomes while the system is
    /// making sense of a ramble, and which becomes the card composition at the reveal.
    ///
    /// Sized as a FRACTION of the surface's narrow dimension rather than a fixed diameter:
    /// this beat is meant to own the screen, and "owns the screen" is a relationship to the
    /// device, not a number of points. `rambleOrbMin` is the floor for a very short surface
    /// (a landscape phone), so the orb never collapses to a dot.
    static let rambleOrbScreenFraction: CGFloat = 0.85
    static let rambleOrbMin: CGFloat = 120
    /// The voice hero control's diameter — the composer's listening-state stop button,
    /// the one control operated mid-thought at arm's length. Deliberately larger than
    /// `hitTarget`: it is the surface's focal point, not merely reachable.
    static let voiceHero: CGFloat = 64
    /// The My Tasks header row's fixed height. Its controls come and go with the
    /// household roster — the ownership tabs appear the moment a second member exists —
    /// and pinning the row makes that a change in WHAT the header holds rather than how
    /// tall it is, so the list underneath never reflows. Sized to the taller resident
    /// (the tab pill, `sectionHeader` text + `Spacing.xxs`), which the compact filter
    /// capsule then centres within.
    static let tasksHeaderRow: CGFloat = 32
    /// The label column on a diagnostics label/value row (`ActivityDetailView`). Fixed so
    /// dozens of stacked readings share one gutter and the values form a scannable column
    /// — the whole point of that screen is comparing runs, which a ragged left edge defeats.
    static let diagnosticLabelColumn: CGFloat = 116
}

extension View {
    /// Grow a compact control's tap target to the HIG minimum (`LayoutMetrics.hitTarget`)
    /// WITHOUT changing its visual footprint: the interactive region expands symmetrically
    /// into surrounding whitespace, then negative padding restores the original layout size.
    /// The glyph never moves — the extra hit area reaches into the gap around it. Apply to a
    /// completion/status glyph whose visual box (`visualSize`) is smaller than 44pt; a near
    /// miss on the app's core completion control should still complete, not open the detail.
    func minimumHitTarget(around visualSize: CGFloat = LayoutMetrics.recordGlyphColumn) -> some View {
        let inset = max(0, (LayoutMetrics.hitTarget - visualSize) / 2)
        return
            padding(inset)
            .contentShape(Rectangle())
            .padding(-inset)
    }
}
