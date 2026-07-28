//
//  TaskChainStackView.swift
//  Project-Ezra
//
//  A dependency chain rendered as a physical stack: the actionable root sits on top,
//  with decorative slivers peeking from beneath conveying real depth without claiming
//  to be more cards than the badge already states. Expanding reveals every member as
//  its own independently-interactive row — tasks stay first-class citizens even
//  inside a stack. The stack physics (collapsed peeks, the count badge, the "blocks ↓"
//  connectors) are unchanged; only the content each card wraps is now the Linear-
//  minimal `TaskRow` instead of the old metadata-heavy card.
//

import CoreData
import SwiftUI

struct TaskChainStackView: View {
    let chain: TaskChain
    /// The full working set, threaded into each row's status menu.
    var allTasks: [TaskItem] = []
    var onComplete: (TaskItem) -> Void
    var onCancel: ((TaskItem) -> Void)? = nil
    var onOpen: (TaskItem) -> Void
    var blockerSummary: (TaskItem) -> String?
    var ownerDisplayName: (TaskItem) -> String?
    var ownerPhotoData: (TaskItem) -> Data?

    @State private var isExpanded = false

    private var peekCount: Int { min(chain.members.count - 1, 2) }

    var body: some View {
        Group {
            if isExpanded {
                expanded
            } else {
                collapsed
            }
        }
    }

    private var collapsed: some View {
        ZStack(alignment: .bottom) {
            ForEach(0..<max(peekCount, 0), id: \.self) { index in
                let layer = peekCount - index  // furthest-back drawn first
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.secondarySurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    }
                    .frame(height: 10)
                    .padding(.horizontal, CGFloat(layer) * 6)
                    .offset(y: CGFloat(layer) * 7)
                    // Solid peek slivers read as crisp stacked cards; the old opacity
                    // fade layered translucent rectangles over the black background into
                    // a dirty halo (the muddiness). Depth comes from inset + offset.
                    .accessibilityHidden(true)
            }

            chainRowCard(chain.root)
                .overlay(alignment: .topTrailing) {
                    stackBadge.padding(8)
                }
        }
        .padding(.bottom, CGFloat(peekCount) * 7)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(chain.members.enumerated()), id: \.element.objectID) {
                index, member in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    if index > 0 {
                        HStack(spacing: Spacing.xxs) {
                            Rectangle()
                                .fill(Palette.border)
                                .frame(width: 2, height: 12)
                                .padding(.leading, Spacing.md)
                            Label("blocks", systemImage: "arrow.down")
                                .labelStyle(.titleAndIcon)
                                .font(.metadata)
                                .foregroundStyle(Palette.mutedText)
                        }
                        .accessibilityHidden(true)
                    }
                    chainRowCard(member)
                        .overlay(alignment: .topTrailing) {
                            if index == 0 { stackBadge.padding(8) }
                        }
                }
            }
        }
    }

    /// The minimal row wrapped in the chain-card chrome (surface + border + radius).
    private func chainRowCard(_ task: TaskItem) -> some View {
        TaskRow(
            task: task,
            allTasks: allTasks,
            blockerSummary: blockerSummary(task),
            ownerDisplayName: ownerDisplayName(task),
            ownerPhotoData: ownerPhotoData(task),
            onComplete: { onComplete(task) },
            onCancel: onCancel.map { cb in { cb(task) } },
            onOpen: { onOpen(task) }
        )
        .padding(.horizontal, Spacing.md)
        .background(
            Palette.primarySurface,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
    }

    private var stackBadge: some View {
        Button {
            Motion.withMotion(Motion.settle) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.chipLabelTight)
                Text("\(chain.members.count)")
                    .font(.chipLabel)
                Image(systemName: "chevron.down")
                    .font(.glyphNano(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(Motion.snap, value: isExpanded)
            }
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(Palette.secondarySurface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Palette.border, lineWidth: 0.5)
            }
            .frame(minWidth: LayoutMetrics.hitTarget, minHeight: LayoutMetrics.hitTarget)
        }
        .buttonStyle(.pressableIcon)
        .accessibilityLabel(
            isExpanded
                ? "Collapse chain of \(chain.members.count) linked tasks"
                : "Expand chain of \(chain.members.count) linked tasks")
    }
}
