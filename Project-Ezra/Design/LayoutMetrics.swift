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
    /// The home's ask field and the orb beside it (2026-09-25, the importance audit): the
    /// bar is the home's second most important object after the hero task, so it is
    /// larger than a bare hit target — a one-line field 52pt tall, the orb 52pt with a
    /// 34pt lens (the shell's 62/40 bezel ratio), the send disc 36pt inside the field.
    static let composerField: CGFloat = 52
    static let composerOrb: CGFloat = 34
    static let composerInnerControl: CGFloat = 36
    /// Lines a related task's title may take on the detail page's rows — steps,
    /// blockers, dependents, the parent link. Two, not one (2026-09-17): at the
    /// accessibility text sizes a one-line row cut "Book flights for the trip" to "Book
    /// flights for th…" while the home list, which wraps freely, showed the whole
    /// title. A title is one line of intent, but the line is the person's, not the
    /// layout's; two lines keep the row bounded and the words whole.
    static let relatedTitleLines = 2
    /// Lines a LIST row's title may take. One at the reading sizes — the list is a
    /// dense scan, and a row that grows by a line grows the scroll — but two at the
    /// accessibility sizes, where one line held "Pay th…" and "Figure out if t…"
    /// (2026-09-17, accessibility-extra-large): a row whose title cannot be read is
    /// not dense, it is empty.
    static func listTitleLines(for size: DynamicTypeSize) -> Int {
        size.isAccessibilitySize ? 2 : 1
    }
    /// The widest a full-screen surface's content column may grow. The app ships to
    /// iPad and rotates on iPhone (device family 1,2; landscape allowed), and no view
    /// adapted to width until 2026-09-18: on an iPad Air the list ran edge to edge
    /// with the due label a screen-width from its title, and the detail's "Mark done"
    /// was 1300pt wide. Every phone width is below this, so phones are untouched;
    /// wider surfaces centre a column the eye can scan. Sheets are form sheets on
    /// iPad already and need nothing.
    static let readableWidth: CGFloat = 700
    /// The Ramble orb — the object the capture field becomes while the system is
    /// making sense of a ramble, and which becomes the card composition at the reveal.
    ///
    /// Sized as a FRACTION of the surface's narrow dimension rather than a fixed diameter:
    /// this beat is meant to own the screen, and "owns the screen" is a relationship to the
    /// device, not a number of points. `rambleOrbMin` is the floor for a very short surface
    /// (a landscape phone), so the orb never collapses to a dot.
    static let rambleOrbScreenFraction: CGFloat = 0.85
    static let rambleOrbMin: CGFloat = 120
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
    /// Keep this view in a column no wider than `LayoutMetrics.readableWidth`, on the
    /// LEADING edge: the navigation title and the toolbar already sit at the edges, and
    /// a centred column left "My Tasks" a hundred points to the left of its own list on
    /// an iPad. The caller keeps its own full-bleed background outside the column.
    func readableWidth() -> some View {
        frame(maxWidth: LayoutMetrics.readableWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    /// The glyph column (`recordGlyphColumn`, 28pt) scaled along the SAME text style as the
    /// glyph it holds. The glyph tokens grow at accessibility sizes; a fixed 28pt frame
    /// around them did not, and SwiftUI draws an oversized symbol outside its frame — the
    /// home's hero glyph spilled out of the card and over the title (2026-09-29). At the
    /// default content size this is exactly 28pt, so nothing moves for most people.
    func glyphColumn(relativeTo style: Font.TextStyle, alignment: Alignment = .center) -> some View {
        modifier(GlyphColumn(style: style, alignment: alignment))
    }
}

private struct GlyphColumn: ViewModifier {
    @ScaledMetric private var side: CGFloat
    private let alignment: Alignment

    init(style: Font.TextStyle, alignment: Alignment) {
        _side = ScaledMetric(wrappedValue: LayoutMetrics.recordGlyphColumn, relativeTo: style)
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        content.frame(width: side, height: side, alignment: alignment)
    }
}
