//
//  TaskDeckView.swift
//  Project-Ezra
//
//  A dependency chain rendered as a GROUP WITH A CURRENT TASK (2026-09-12) — replacing the
//  chain STACK (a pile of cards that fanned open vertically on a swipe).
//
//  The mental model: **a group represents one outcome; the list shows the next actionable
//  task in that outcome; horizontal swipe moves through the group's tasks.** The task
//  stays the primary object — the card is a real `TaskRow`, with the glyph column, the
//  due label and the owner avatar every other row has — and the group is context around
//  it: a caption naming the outcome, a position, and a sliver of the next card at the
//  trailing edge saying there is one.
//
//  The intelligence hierarchy, stated once:
//
//      AI            "what belongs together?"   (membership — capture-time `childOf`,
//                                                the umbrella; nothing in this file)
//      deterministic "what depends on what?"    (`TaskChainGrouping.prerequisites`,
//                                                the ONE place blockers and steps meet)
//      deterministic "what is actionable?"      (`TaskChain.root`: the first member with
//                                                nothing left to wait on — a waiting
//                                                member never leads while one can move)
//      this view     "what do I show right now?" (the front card, and the page you swiped to)
//
//  What the group is NOT: a visible umbrella row. The container task that names the
//  outcome is the caption here (`TaskChain.umbrella`), never a card — "do I complete Trip
//  to Lagos?" is not a question the list should raise while steps remain. It surfaces as
//  an ordinary row the moment its last step resolves. Done members leave the deck: the
//  group is the REMAINING work, so the position reads "1/2" once two of four are done,
//  not "3/4".
//
//  **The gesture map on a deck card, and the one rule behind it — one channel, one
//  meaning.** Horizontal is NAVIGATION here (swipe left → next, right → previous, hard
//  edges, no wrap: it is an ordered workflow, not a carousel), so the lifecycle swipes
//  every other row carries are ABSENT, never overloaded. The lifecycle moves to the
//  glyph: the status glyph on a deck card is the same interactive control the container
//  spine's step rows carry (`TaskRow.glyphInteractive`), the row's explicit completion
//  target in the column that already means "state". Tap the rest of the row → the detail
//  of the SHOWN member, whose pager walks this same deck in this same order (peers are
//  the chain's members, umbrella last — tap the caption to reach it). Long-press → the
//  full menu.
//
//  This reverses the 2026-09-01 "a ROW that looks deeper, not a container" call
//  deliberately: the detail pager already paged the members, and the list gains the same
//  grammar one level up instead of a second one (a vertical fan). The trailing peek is
//  the cue — slivers UNDER a card said "pile"; a sliver at the edge says "there is another
//  in that direction", which is exactly the gesture.
//
//  Two layout notes worth keeping. The card's chrome BLEEDS into the list's gutter (the
//  horizontal scroll is widened by `Spacing.md` each side and the row content is inset by
//  the same), so the glyph column stays on the list's column — one row leaving it reads
//  as a different kind of thing. And the peek is small on purpose (`peek` − card spacing
//  = 12pt): discoverable, not decorative; no page dots, the "n/m" carries position.
//

import CoreData
import SwiftUI

struct TaskDeckView: View {
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

    /// The card the person has swiped to. Nil reads as the front.
    @State private var shownID: NSManagedObjectID?

    /// How much of the next card shows at the trailing edge, INCLUDING the card gap.
    private static let peek: CGFloat = Spacing.lg

    private var members: [TaskItem] { chain.deckMembers }

    private var shownIndex: Int {
        members.firstIndex { $0.objectID == shownID } ?? 0
    }

    private var title: String { chain.umbrella?.title ?? "Linked tasks" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            caption
            pager
        }
        // A member resolving (or a re-rank) can retire the shown card; fall back to the
        // front rather than leaving the position pointing at nothing.
        .onChange(of: members.map(\.objectID)) { _, ids in
            if let shownID, !ids.contains(shownID) { self.shownID = nil }
        }
    }

    // MARK: - Caption: the outcome, and where you are in it

    private var caption: some View {
        HStack(spacing: Spacing.xs) {
            Text(title)
                .metadataStyle()
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Text("\(shownIndex + 1)/\(members.count)")
                .metadataStyle()
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .contentShape(Rectangle())
        // The caption is the way UP: the umbrella's own detail carries every step,
        // including the done ones this deck no longer shows.
        .onTapGesture { if let umbrella = chain.umbrella { onOpen(umbrella) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title), \(members.count) tasks left, showing \(shownIndex + 1)")
        .accessibilityAddTraits(chain.umbrella == nil ? [] : .isButton)
        .accessibilityHint(chain.umbrella == nil ? "" : "Opens the outcome")
    }

    // MARK: - The deck

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Spacing.sm) {
                ForEach(members, id: \.objectID) { member in
                    card(member)
                        .containerRelativeFrame(.horizontal) { length, _ in length - Self.peek }
                        .id(member.objectID)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $shownID)
        .scrollIndicators(.hidden)
        // Bleed into the gutter so the card chrome sits outside the row's content and the
        // glyph column stays aligned with every other row (see the header).
        .padding(.horizontal, -Spacing.md)
        .animation(Motion.settle, value: members.map(\.objectID))
    }

    /// One card: the member as a real `TaskRow` in the card chrome, the glyph its
    /// completion target, no lifecycle swipes — horizontal is navigation here.
    private func card(_ task: TaskItem) -> some View {
        TaskRow(
            task: task,
            allTasks: allTasks,
            glyphInteractive: true,
            blockerSummary: blockerSummary(task),
            stepProgress: task.stepProgress(among: allTasks),
            ownerDisplayName: ownerDisplayName(task),
            ownerPhotoData: ownerPhotoData(task),
            onComplete: { onComplete(task) },
            onCancel: onCancel.map { cb in { cb(task) } },
            onOpen: { onOpen(task) }
        )
        .padding(.horizontal, Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.primarySurface)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                }
        }
    }
}
