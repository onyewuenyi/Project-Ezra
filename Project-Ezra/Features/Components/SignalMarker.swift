//
//  SignalMarker.swift
//  Project-Ezra
//
//  The leading marker on the RECORD surfaces (My Tasks rows + the detail chips).
//  Replaces the retired `PriorityBadgeView` bars: attention is a computed system score
//  and never a badge. A task with nothing to say renders NOTHING (zero footprint), so
//  the row title sits flush against the status glyph — Today (`BriefTaskRow`/
//  `TaskCardView`) stays entirely marker-free by design.
//
//  **One slot, two residents, an explicit precedence.** The slot means "the one thing
//  most demanding your attention", which is honest about it being a composite rather
//  than pretending to encode a single axis:
//
//    1. Needs Decision (Axis 3, a stored attention flag) — `Palette.decisionAccent`
//    2. Urgent (Axis 4, the user's own declared signal) — `Palette.priorityUrgent`
//
//  Needs Decision wins when both are set: "your judgment is required" outranks "this
//  matters now", and `TaskRanking` already forces decisions to the top of the stack so
//  the two rarely compete for the same row anyway.
//
//  What does NOT appear here is the task's TYPE. Choice-shaped work and the
//  `needsDecision` flag are different axes — one is what kind of work this is, the
//  other is why it needs your eyes — and putting both in one glyph position would
//  teach the user they are the same thing. Type differentiates in the detail, which is
//  where the modules live.
//
//  Tokens only — never a hardcoded color or size.
//

import SwiftUI

struct SignalMarker: View {
    var isUrgent: Bool
    /// The stored attention flag — a values call, or an item the AI wasn't sure enough
    /// about. Takes the slot when both are set.
    var needsDecision: Bool = false
    /// Unscaled base glyph size; scales with Dynamic Type via `unit`.
    var size: CGFloat = 14
    /// Hold the column even when there is nothing to show. The record surface sets
    /// this: with zero footprint, marked rows pushed their glyph and title right and
    /// the list's left edge went ragged — the mark stopped being a mark and became a
    /// layout event. A reserved column costs one glyph-width of leading space and
    /// buys every glyph and every title landing on the same two lines.
    var reservesSpace = false

    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 1

    /// A rendered SF symbol is wider than its point size, so the reserved column is
    /// sized to the GLYPH's box and both paths share it — alignment by construction,
    /// not by matching two hand-tuned constants.
    private var columnWidth: CGFloat { size * unit * 1.3 }

    var body: some View {
        if reservesSpace {
            ZStack { markGlyph }
                .frame(width: columnWidth, height: columnWidth)
        } else {
            markGlyph
        }
    }

    @ViewBuilder private var markGlyph: some View {
        if needsDecision {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Palette.decisionAccent)
                .accessibilityLabel("Needs a decision")
                .font(.system(size: size * unit, weight: .semibold))
        } else if isUrgent {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Palette.priorityUrgent)
                .accessibilityLabel("Urgent")
                .font(.system(size: size * unit, weight: .semibold))
        }
    }
}

extension SignalMarker {
    /// Convenience for the common case of reading straight off a task. A RESOLVED task
    /// never wears the decision flag — it is a record, and the flag is about what still
    /// needs you.
    init(task: TaskItem, size: CGFloat = 14, reservesSpace: Bool = false) {
        self.init(
            isUrgent: task.isUrgent,
            needsDecision: task.needsDecision && !task.status.isResolved,
            size: size, reservesSpace: reservesSpace)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Spacing.md) {
        SignalMarker(isUrgent: true)
        HStack {
            SignalMarker(isUrgent: false)
            Text("No signal — zero footprint").metadataStyle()
        }
    }
    .padding()
    .background(Palette.background)
}
