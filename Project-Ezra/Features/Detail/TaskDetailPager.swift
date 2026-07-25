//
//  TaskDetailPager.swift
//  Project-Ezra
//
//  The full-screen detail SURFACE: the chrome (nav bar, back chevron, "…" menu, the
//  "n of N" counter, edge-swipe dismiss) wrapped around a horizontally-paged stack of
//  `TaskDetailView` pages. A left/right swipe moves to the neighbouring task without
//  ever leaving full screen — the "work the list" loop.
//
//  What "neighbouring" means is decided by the presenting surface, not here: each call
//  site hands `taskDetailSheet(_:peers:)` the ordered task list it is CURRENTLY showing
//  (My Tasks sections flattened with chains unrolled, the search results, the Today
//  briefing's plan steps, Household's coordination/timeline list). So the swipe lands on
//  the row above or below the one you tapped.
//
//  Two deliberate choices:
//  • The peer list is SNAPSHOTTED on open. A background sweep or a live re-rank must not
//    shuffle pages under the user's thumb mid-swipe.
//  • Resolving a task ADVANCES rather than dismissing — the resolved page drops out and
//    the next peer slides in; the cover closes only when there is no next peer.
//

import CoreData
import SwiftUI

struct TaskDetailPager: View {
    /// The task the user tapped — always the first page shown, and the fallback if the
    /// page list ever empties out from under us.
    let opened: TaskItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Frozen in `init` — see the snapshot note above. Resolved as State (not a computed
    /// property) from the first render, so the initial `scrollPosition` lands on the
    /// opened task during the very first layout pass instead of a frame later.
    @State private var pages: [TaskItem]
    @State private var currentID: NSManagedObjectID?
    /// Interactive left-edge swipe-to-dismiss (the chevron promises push semantics).
    @State private var dragOffset: CGFloat = 0

    /// `peers` is the presenting surface's on-screen order; empty (or missing `opened`)
    /// collapses to a single page — the pre-pager behaviour.
    init(opened: TaskItem, peers: [TaskItem] = []) {
        self.opened = opened
        // A peer list that doesn't contain the tapped task is stale (or was never given)
        // — fall back to the single page rather than paging somewhere unexpected.
        let list = peers.contains { $0.objectID == opened.objectID } ? peers : [opened]
        _pages = State(initialValue: list)
        _currentID = State(initialValue: opened.objectID)
    }

    /// Deleted objects (a merge-duplicate can remove one) would fault on access — a page
    /// only ever renders a live task.
    private var livePages: [TaskItem] {
        pages.filter { !$0.isDeleted && $0.managedObjectContext != nil }
    }

    private var currentIndex: Int? {
        currentID.flatMap { id in livePages.firstIndex { $0.objectID == id } }
    }

    private var currentTask: TaskItem {
        currentIndex.map { livePages[$0] } ?? opened
    }

    var body: some View {
        NavigationStack {
            pageStack
                .background(Palette.background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                    }
                    if livePages.count > 1, let index = currentIndex {
                        ToolbarItem(placement: .principal) {
                            Text("\(index + 1) of \(livePages.count)")
                                .metadataStyle()
                                .monospacedDigit()
                                .accessibilityLabel("Task \(index + 1) of \(livePages.count)")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        TaskMoreMenu(task: currentTask, onResolved: advanceAfterResolve)
                    }
                }
        }
        .overlay(alignment: .leading) { edgeSwipeCatcher }
        .offset(x: dragOffset)
        .sensoryFeedback(.selection, trigger: currentID)
    }

    // MARK: - The paged stack

    private var pageStack: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(livePages) { task in
                    TaskDetailView(
                        task: task,
                        isActive: task.objectID == currentID,
                        onResolved: advanceAfterResolve
                    )
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentID)
        // VoiceOver can't perform a paging swipe — give it the two moves explicitly.
        .accessibilityAction(named: "Next task") { step(by: 1) }
        .accessibilityAction(named: "Previous task") { step(by: -1) }
    }

    private func step(by offset: Int) {
        guard let index = currentIndex else { return }
        let target = index + offset
        guard livePages.indices.contains(target) else { return }
        withAnimation(reduceMotion ? Motion.fade : Motion.beatAdvance) {
            currentID = livePages[target].objectID
        }
    }

    /// The current task left the working set. Slide to the next peer, then drop the
    /// resolved page once the scroll has landed (mutating `pages` mid-scroll glitches the
    /// paging offset). No next peer → the surface has nothing left to show, so dismiss.
    private func advanceAfterResolve() {
        guard let index = currentIndex, livePages.indices.contains(index + 1) else {
            dismiss()
            return
        }
        let resolvedID = livePages[index].objectID
        withAnimation(reduceMotion ? Motion.fade : Motion.beatAdvance) {
            currentID = livePages[index + 1].objectID
        } completion: {
            pages.removeAll { $0.objectID == resolvedID }
        }
    }

    // MARK: - Edge-swipe dismiss (honors the back chevron's platform contract)

    /// A 20pt leading catcher, layered ABOVE the paging scroll so the edge drag reads as
    /// "go back" while a drag anywhere else pages between tasks.
    private var edgeSwipeCatcher: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in dragOffset = max(0, value.translation.width) }
                    .onEnded { value in
                        if value.translation.width > 80 {
                            dismiss()
                        } else {
                            withAnimation(reduceMotion ? nil : Motion.snap) { dragOffset = 0 }
                        }
                    }
            )
    }
}

// MARK: - "…" menu (secondary actions on the page you're looking at)

/// Lives on the pager's toolbar rather than inside a page: several pages stay mounted at
/// once, and each contributing its own toolbar item would duplicate the button.
struct TaskMoreMenu: View {
    @ObservedObject var task: TaskItem
    let onResolved: () -> Void

    @Environment(\.managedObjectContext) private var context
    @State private var actionPulse = 0

    var body: some View {
        Menu {
            if task.status.isResolved {
                Button {
                    actionPulse += 1
                    task.reopenAndReblock(in: context)
                    try? context.save()
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    actionPulse += 1
                    task.killAndResurface(in: context)
                    try? context.save()
                    onResolved()
                } label: {
                    Label("Cancel task", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
    }
}

#Preview("Paging between three tasks") {
    @Previewable @State var opened: TaskItem?
    @Previewable @State var peers: [TaskItem] = []

    return Color.clear
        .taskDetailSheet($opened, peers: peers)
        .environment(\.managedObjectContext, PersistenceStack.scratch)
        .onAppear {
            let made = [
                TaskItem(
                    title: "Renew passport", category: "Travel", status: .doing,
                    confidence: 0.85, reasoning: "Filed under Travel from the wording.",
                    isUrgent: true, rawCapture: "renew my passport before the trip"),
                TaskItem(title: "Book the flights", category: "Travel", status: .todo),
                TaskItem(title: "Call the plumber", category: "Home", status: .todo),
            ]
            peers = made
            opened = made[1]
        }
}
