//
//  TaskChainStackView.swift
//  Project-Ezra
//
//  A dependency chain rendered as a physical stack: the actionable root sits on top,
//  with decorative slivers peeking from beneath conveying real depth without claiming
//  to be more cards than the count already states.
//
//  **The pile opens on a SWIPE, and owns no pixels** (2026-09-02).
//
//  Swipe the root card right and the chain fans open; swipe right again and it closes.
//  `allowsFullSwipe` is what makes that one continuous motion instead of a reveal-then-tap.
//  Nothing is drawn for the control — no badge, no chevron, no strip — so the component is
//  exactly the card, the peek slivers and the count, and the card's whole surface stays a
//  single tap target that opens the task like every other row.
//
//  Two earlier shapes were tried and are worth not repeating:
//
//  1. **A count badge Button in the card's top-trailing corner.** It made a stack the only
//     row with two tap targets — one region opened the task, another opened the pile — and
//     it sat exactly where `TaskRow` draws the due label, so a dated root had its date
//     under a control. It also fought the metaphor: slivers say *physical pile*, a chevron
//     says *collapsible list section*.
//  2. **No expansion at all**, on the theory that the detail could show the members. It
//     could not: the common chain is rooted on the task that unblocks the others, so
//     "Renew passport" drew no spine and its members had nowhere to be seen. The row said
//     `▤ 4` while the detail said "Frees up 2" — the chain's size versus its DIRECT
//     dependents — and the two never reconciled. (The detail's dependents section survives
//     from that attempt and is worth keeping: it is the graph's forward direction.)
//
//  The lesson both shared: the count is only honest if something shows you the things it
//  counts, and the list is where the counting happens.
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
    var currentUserID: UUID? = nil
    @Binding var notice: UndoNotice?

    @State private var isExpanded = false

    private var peekCount: Int { min(chain.members.count - 1, 2) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if isExpanded {
                ForEach(Array(chain.members.enumerated()), id: \.element.objectID) {
                    index, member in
                    if index > 0 { blocksConnector }
                    chainRowCard(member)
                }
            } else {
                collapsedPile
            }
        }
    }

    /// The root, sitting on decorative slivers that convey real depth without claiming to
    /// be more cards than the count states.
    private var collapsedPile: some View {
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

            // The depth indicator rides INSIDE the row, beside the blocked hourglass and
            // the step count, rather than overlaying the card's top-trailing corner where
            // the old badge sat — which is where `TaskRow` draws the due label. In the
            // HStack's flow the two cannot collide.
            chainRowCard(chain.root)
        }
        .padding(.bottom, CGFloat(peekCount) * 7)
    }

    /// Which way the dependency runs, restored with the expanded state it belongs to —
    /// seeing the members without seeing their order would be a list, not a chain.
    private var blocksConnector: some View {
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

    /// The minimal row wrapped in the chain-card chrome (surface + border + radius).
    ///
    /// The ROOT's leading swipe belongs to the PILE — swipe right to fan the chain open,
    /// swipe right again to close it — so it suppresses the lifecycle swipe and supplies
    /// its own. `allowsFullSwipe` is what makes it one continuous motion rather than a
    /// reveal-then-tap: the swipe itself expands.
    ///
    /// Every OTHER card is an ordinary task and keeps the ordinary swipes. So the rule
    /// still holds — one channel, one meaning — with the meaning set by what the row IS, a
    /// pile or a task, which is the distinction the card's own chrome already draws.
    @ViewBuilder
    private func chainRowCard(_ task: TaskItem) -> some View {
        let isRoot = task.objectID == chain.root.objectID
        baseCard(task)
            .taskSwipeActions(
                task: task, allTasks: allTasks, currentUserID: currentUserID,
                includesLeading: !isRoot, notice: $notice
            )
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if isRoot {
                    Button {
                        Motion.withMotion(Motion.settle) { isExpanded.toggle() }
                    } label: {
                        Label(
                            isExpanded ? "Collapse" : "Show \(chain.members.count)",
                            systemImage: isExpanded
                                ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    }
                    .tint(Palette.secondaryText)
                }
            }
    }

    private func baseCard(_ task: TaskItem) -> some View {
        TaskRow(
            task: task,
            allTasks: allTasks,
            chainDepth: task.objectID == chain.root.objectID ? chain.members.count : nil,
            blockerSummary: blockerSummary(task),
            stepProgress: task.stepProgress(among: allTasks),
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
}
