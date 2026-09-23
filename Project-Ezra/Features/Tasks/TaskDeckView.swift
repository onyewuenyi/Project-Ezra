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
//  What the caption carries, and why (added the same day, after the first screenshots):
//  the OUTCOME's due date — hiding the umbrella row hid the one date that explains why
//  its steps matter; a "N waiting" count for members blocked in the deck or by the world,
//  named rather than surfaced (tap it to page to the first stuck card — the person asks,
//  the deck never pushes); and for a bare chain, its STORY in execution order as the
//  title, because "Linked tasks" said nothing and "this, then that" is what a chain IS.
//  A page landing gives the picker's selection tick. The glyph is a control under the
//  same rule as the row's leading swipe — present exactly when `recommendedAction` is.
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
    /// The umbrella owner's avatar in the caption — smaller than the row's 18pt so it sits
    /// with metadata text rather than beside a title.
    private static let captionAvatar: CGFloat = 14

    private var members: [TaskItem] { chain.deckMembers }

    private var shownIndex: Int {
        members.firstIndex { $0.objectID == shownID } ?? 0
    }

    private var title: String { chain.groupTitle }

    /// The OUTCOME's deadline — the umbrella's due date, in the row's compact vocabulary.
    /// Hiding the umbrella row hid the one date that explains why its steps matter; the
    /// caption is where it belongs now. Nil for a bare chain or an undated outcome.
    private var outcomeDue: DueLabel? {
        chain.umbrella.flatMap { DueLabel.make(for: $0, style: .compact) }
    }

    /// Members that are waiting on something — a blocker inside the deck or a wait in the
    /// world. Named as a count rather than surfaced as a card: the deck leads with what can
    /// move, and "1 waiting" says the rest without pushing a stuck task to the front.
    private var waitingCount: Int {
        members.count { $0.hasActiveBlockers(among: allTasks) }
    }

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
        .onAppear { openRequestedPage() }
    }

    /// Deterministic verification seam. `-DeckPage N` opens every deck on its Nth card
    /// (1-based), so a paged state — the caption's position, a waiting card's line — is
    /// screenshot-reachable: the swipe is a gesture, and gestures are blocked headlessly.
    /// Never fires in normal runs; compiled out of Release.
    private func openRequestedPage() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-DeckPage"), args.indices.contains(flag + 1),
            let page = Int(args[flag + 1]), members.indices.contains(page - 1)
        else { return }
        shownID = members[page - 1].objectID
        #endif
    }

    // MARK: - Caption: the outcome, and where you are in it

    private var caption: some View {
        HStack(spacing: Spacing.xs) {
            Text(title)
                .metadataStyle()
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
                .truncationMode(.tail)
            if let umbrella = chain.umbrella, let owner = ownerDisplayName(umbrella) {
                // Whose outcome, when it is not yours — the row's avatar, caption-sized,
                // so a deck in the household's shared scope answers "whose project?"
                // the way its cards answer "whose step?".
                AvatarView(
                    source: .owner(name: owner, photoData: ownerPhotoData(umbrella), isMe: false),
                    size: Self.captionAvatar)
            }
            if let due = outcomeDue {
                Text("·")
                    .metadataStyle()
                Text(due.text)
                    .font(.chipLabel)
                    .foregroundStyle(due.isOverdue ? Palette.overdue : Palette.mutedText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: Spacing.sm)
            if waitingCount > 0 {
                // Tappable: the deck never pushes a stuck card forward, but a person may
                // ask to see it — a tap pages to the first waiting member. A child gesture
                // wins over the caption's own tap, so this does not open the umbrella.
                Text("\(waitingCount) waiting")
                    .font(.chipLabel)
                    .foregroundStyle(Palette.mutedText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                    .onTapGesture { showFirstWaiting() }
                Text("·")
                    .metadataStyle()
            }
            // "1/1" is noise: a single remaining card has no position, only its
            // outcome's context, which the caption already gives.
            if members.count > 1 {
                Text("\(shownIndex + 1)/\(members.count)")
                    .metadataStyle()
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            // The caption opens the way UP; the chevron the parked row wears — at the end
            // of the line, where that row wears it — says so.
            Image(systemName: "chevron.right")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
        }
        .contentShape(Rectangle())
        // The way UP: the umbrella's own detail carries every step, including the done
        // ones this deck no longer shows. A bare chain has no umbrella, so its caption
        // opens the ROOT — whose page lists what finishing it frees up, and whose pager
        // walks the whole chain.
        .onTapGesture { onOpen(chain.umbrella ?? chain.root) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(captionAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(chain.umbrella == nil ? "Opens the first task" : "Opens the outcome")
        .accessibilityActions {
            if waitingCount > 0 { Button("Show what's waiting") { showFirstWaiting() } }
        }
    }

    private func showFirstWaiting() {
        guard let first = members.first(where: { $0.hasActiveBlockers(among: allTasks) }) else {
            return
        }
        Motion.withMotion(Motion.settle) { shownID = first.objectID }
    }

    private var captionAccessibilityLabel: String {
        var parts = [title]
        if let umbrella = chain.umbrella, let owner = ownerDisplayName(umbrella) {
            parts.append("\(owner)'s")
        }
        if let due = chain.umbrella.flatMap({ DueLabel.make(for: $0, style: .full) }) {
            parts.append(due.isOverdue ? due.text : "due \(due.text)")
        }
        parts.append("\(members.count) tasks left, showing \(shownIndex + 1)")
        if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        return parts.joined(separator: ", ")
    }

    // MARK: - The deck

    private var pager: some View {
        ScrollView(.horizontal) {
            // Tops aligned: a waiting card carries a second line and is taller, so a
            // centred stack would let a peeking sliver poke above the front card. Top
            // alignment keeps every card's title on one baseline and lets the taller
            // one extend below, where the difference reads as depth rather than a slip.
            LazyHStack(alignment: .top, spacing: Spacing.sm) {
                ForEach(members, id: \.objectID) { member in
                    card(member)
                        .containerRelativeFrame(.horizontal) { length, _ in length - Self.peek }
                        // Its own ideal height, whatever the stack proposes: the lazy
                        // stack sizes itself from the first card it lays out, and a
                        // taller card paged to later was given that height and spilled
                        // its second line past the card chrome at accessibility sizes.
                        .fixedSize(horizontal: false, vertical: true)
                        .id(member.objectID)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $shownID)
        .scrollIndicators(.hidden)
        // A page landing is a selection — the same light tick a picker gives, so the
        // hard edges and the snap read as an ordered workflow under the thumb rather than
        // a carousel that merely stopped. Never on the advance a completion causes: that
        // moment already has the success haptic, and `shownID` resets to nil there.
        .sensoryFeedback(.selection, trigger: shownID) { _, new in new != nil }
        // Bleed into the gutter so the card chrome sits outside the row's content and the
        // glyph column stays aligned with every other row (see the header).
        .padding(.horizontal, -Spacing.md)
        .animation(Motion.settle, value: members.map(\.objectID))
        // **Paging without the gesture (2026-09-20).** `TaskDetailPager` already gives
        // its horizontal pager "Next task" / "Previous task" actions for exactly this
        // reason; the deck did not, so reaching a card meant a three-finger scroll or
        // traversing into cards a lazy stack has not built yet. Same interaction, same
        // affordance — the inconsistency was the bug.
        .accessibilityAction(named: "Next task") { step(by: 1) }
        .accessibilityAction(named: "Previous task") { step(by: -1) }
    }

    /// Move the deck one card, for the accessibility actions above. Clamped rather than
    /// wrapped: a pager that silently loops is disorienting when you cannot see it.
    private func step(by offset: Int) {
        let ids = members.map(\.objectID)
        guard !ids.isEmpty else { return }
        let current = shownID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = current + offset
        guard ids.indices.contains(next) else { return }
        withAnimation(Motion.settle) { shownID = ids[next] }
    }

    /// One card: the member as a real `TaskRow` in the card chrome, the glyph its
    /// completion target, no lifecycle swipes — horizontal is navigation here.
    ///
    /// The glyph is a control under the SAME rule as the plain row's leading swipe:
    /// present exactly when `recommendedAction` is — absent on someone else's task, so
    /// "not yours to advance" holds in the household's shared scope whether the row is
    /// loose or in a deck.
    private func card(_ task: TaskItem) -> some View {
        let advanceable = task.recommendedAction(among: allTasks, currentUserID: currentUserID) != nil
        return TaskRow(
            task: task,
            allTasks: allTasks,
            glyphInteractive: advanceable,
            blockerSummary: blockerSummary(task),
            stepProgress: task.stepProgress(among: allTasks),
            ownerDisplayName: ownerDisplayName(task),
            ownerPhotoData: ownerPhotoData(task),
            interactive: advanceable,
            // In a deck with a waiting member EVERY card reserves the second line: the
            // horizontal scroll view takes its height from the first card it lays out,
            // and a taller card paged to later was clipped — `fixedSize` gave the card
            // its height, not the scroll view. Uniform from the first layout is the
            // only shape that neither clips nor hops. Decks with no waits stay one line.
            subtitle: blockerSummary(task) ?? (waitingCount > 0 ? " " : nil),
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
