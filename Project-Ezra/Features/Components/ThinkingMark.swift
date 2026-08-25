//
//  ThinkingMark.swift
//  Project-Ezra
//
//  The SECOND scale of visible thought, and the last one there will be.
//
//  Visible thinking in Ezra has exactly two scales. The first is the full-screen
//  `RambleOrb` — the capture arc's signature moment, a screen-filling mesh sphere that
//  earns its cost because the whole beat is about waiting well. The second is this: one
//  small mark, for the rare places elsewhere where deliberate thought has to be visible
//  because the user is standing there with nothing else to look at.
//
//  **One glyph, one meaning: "Ezra is thinking."** The dotted-orb vocabulary it is drawn
//  from ships nine states — searching, solving, composing, and so on. Ezra uses one, on
//  purpose: per-activity states narrate the model's internals, which is chain-of-thought
//  theater dressed as feedback, and this product has already deleted one version of that
//  (the live parse's streaming cards). The user does not need to know whether Ezra is
//  "searching" or "composing". They need to know it is working and that it will stop.
//
//  **Exactly two placements, and both are exceptions rather than defaults:**
//  1. The Advisor's presence-time deep-thinking exception — the bounded case where a hard
//     judgment could not be precomputed and the user is looking at the task detail while
//     it runs (Challenge 9).
//  2. The Brief's mid-day recomposition, beside the "your brief changed" hint.
//
//  **Where it must never appear:**
//  - The capture canvas. That surface has ZERO AI presence by contract; a thinking mark
//    there would reintroduce the thing the four-phase arc exists to remove.
//  - As a standing "AI is here" badge. It marks work in flight, never a capability.
//  - For rungs 0–2. Facts, cache and on-device reads are fast, and their invisibility is
//    the shipped "reserved rhythm" decision — a mark there would make the product look
//    busier than it is, which is the opposite of the point.
//  - As a replacement for the Ramble orb. Different scale, different job.
//
//  It is deliberately NOT progress-shaped: no track, no arc, no percentage, no
//  determinate anything. The rule the orb learned the hard way applies at this size too —
//  if it ever reads as a loader, the fix is slower and more organic motion, never a
//  progress affordance.
//

import SwiftUI

struct ThinkingMark: View {
    /// Dots in the ring. Three reads as an ellipsis ("…"), which is a typing metaphor and
    /// the wrong one — this is deliberation, not composition. Five is enough to read as a
    /// ring at 14pt and few enough to stay a mark rather than a spinner.
    private static let dotCount = 5

    /// One full cycle. Slow enough to read as deliberate rather than busy — a spinner
    /// lives around 1s, and the distance from that number is the whole design.
    private static let period: Double = 2.4

    /// Overall size. Sized to sit on a line of `supporting` text without displacing it.
    var size: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { canvas, canvasSize in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: Self.period)) / Self.period
                let radius = canvasSize.width / 2
                let dotRadius = canvasSize.width * 0.11
                let center = CGPoint(x: radius, y: radius)

                for index in 0..<Self.dotCount {
                    let fraction = Double(index) / Double(Self.dotCount)
                    let angle = (fraction - 0.25) * 2 * .pi
                    let position = CGPoint(
                        x: center.x + cos(angle) * (radius - dotRadius),
                        y: center.y + sin(angle) * (radius - dotRadius))
                    // The travelling emphasis: each dot brightens as the phase passes it.
                    // Under Reduce Motion the timeline is paused, so this freezes at a
                    // legible arrangement rather than disappearing — the mark still says
                    // "working", it just stops moving (the `RambleOrb` precedent).
                    let distance = abs(((fraction - phase) + 1).truncatingRemainder(dividingBy: 1))
                    let proximity = 1 - min(distance, 1 - distance) * 2
                    let opacity = reduceMotion ? 0.55 : 0.25 + 0.6 * max(0, proximity)
                    canvas.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: position.x - dotRadius, y: position.y - dotRadius,
                                width: dotRadius * 2, height: dotRadius * 2)),
                        with: .color(Palette.secondaryText.opacity(opacity)))
                }
            }
        }
        .frame(width: size, height: size)
        // Strictly monochrome. The design system's two-hue rule is satisfied by
        // construction here — a thinking mark that used the accent gradient would compete
        // with the primary CTA, which is the one place that treatment belongs.
        .accessibilityHidden(true)
    }
}

/// The mark with its one sanctioned label. A thinking state that says nothing to
/// VoiceOver is a silent freeze for anyone not looking at the pixels.
struct ThinkingLine: View {
    var label = "Thinking"

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ThinkingMark()
            Text(label)
                .font(.supporting)
                .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Spacing.lg) {
        ThinkingMark()
        ThinkingLine()
        ThinkingLine(label: "Rethinking your brief")
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.background)
}
