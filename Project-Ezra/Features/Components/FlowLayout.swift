//
//  FlowLayout.swift
//  Project-Ezra
//
//  A minimal wrapping layout (`Layout` conformance) — lays subviews left-to-right and
//  wraps to a new line when the next one won't fit. Used by the task detail's
//  property-chip row (Linear-style), where the number and width of chips vary.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = Spacing.xs
    var lineSpacing: CGFloat = Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                maxRowWidth = max(maxRowWidth, x - spacing)
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        maxRowWidth = max(maxRowWidth, x - spacing)
        let width = maxWidth.isFinite ? min(maxRowWidth, maxWidth) : maxRowWidth
        return CGSize(width: max(0, width), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
