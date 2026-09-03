//
//  TaskLaneList.swift
//  Project-Ezra
//
//  The shared list machinery behind the "My Tasks" surface — extracted from the old
//  per-slice list views so the Assigned (sectioned) and Created (flat) tabs, plus the
//  search sheet, all render rows the same way and complete/cancel through one
//  undo-aware path. Dependency-linked work renders as the chain stack — a ROW that looks
//  deeper, not a container: it stopped expanding in place on 2026-09-01, so every entry
//  here now answers a tap the same way. Everything else is a one-line `TaskRow`.
//
//  This file owns the row gesture map, because the swipes belong to the ENTRY (a chain
//  swipes as one thing, acting on its root) while the tap and long-press belong to the
//  row — see `TaskLaneEntryView` and `TaskRow`'s header.
//

import CoreData
import SwiftUI

// MARK: - Shared filtering (search + category)

/// The one place the browse filters are defined, so every surface agrees. Search is a
/// fast, local, case-insensitive substring over the title.
enum TaskSlice {
    static func matches(_ task: TaskItem, search: String, category: String?) -> Bool {
        if let category, task.category != category { return false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return task.title.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Pure lane grouping (chain-aware)

/// Builds the lane entries for a set of tasks: dependency-linked work collapses into a
/// `TaskChain`, everything else stays a standalone task — then sorts both kinds
/// together under the one stack precedence.
func laneEntries(from scoped: [TaskItem], allTasks: [TaskItem]) -> [TaskLaneEntry] {
    // One rank-key pass over the FULL working set, shared by chain construction (root
    // selection + layering) and lane ordering — so a chain's front card is chosen under the
    // exact keys that position the chain in the lane.
    let keys = TaskRanking.rankKeys(for: allTasks)
    let (chains, loose) = TaskChainGrouping.computeChains(in: scoped, rankKeys: keys)
    return sortedLaneEntries(
        chains.map(TaskLaneEntry.chain) + loose.map(TaskLaneEntry.single), keys: keys)
}

/// Orders mixed chain/single entries by each entry's anchor under the stack
/// precedence, so a chain and a loose task interleave by real priority.
func sortedLaneEntries(_ entries: [TaskLaneEntry], keys: [UUID: RankKey]) -> [TaskLaneEntry] {
    return entries.sorted { a, b in
        guard let ka = a.anchor.uuid.flatMap({ keys[$0] }),
            let kb = b.anchor.uuid.flatMap({ keys[$0] })
        else { return false }
        return TaskRanking.stackOrder(ka, kb)
    }
}

// MARK: - Undo-aware resolution (one behavior, resurfacing-aware)

@MainActor
func completeTask(
    _ task: TaskItem, in context: NSManagedObjectContext, tasks: [TaskItem],
    notice: Binding<UndoNotice?>
) {
    let steps = task.stepProgress(among: tasks)
    let unblocked = task.completeAndResurface(in: context)
    context.saveChanges()
    notice.wrappedValue = .resolution(
        "Completed", task.title, unblocked: unblocked, steps: steps
    ) {
        task.reopenAndReblock(in: context)
        context.saveChanges()
    }
}

@MainActor
func cancelTask(
    _ task: TaskItem, in context: NSManagedObjectContext, tasks: [TaskItem],
    notice: Binding<UndoNotice?>
) {
    let steps = task.stepProgress(among: tasks)
    let unblocked = task.killAndResurface(in: context)
    context.saveChanges()
    notice.wrappedValue = .resolution(
        "Canceled", task.title, unblocked: unblocked, steps: steps
    ) {
        task.reopenAndReblock(in: context)
        context.saveChanges()
    }
}

/// The leading swipe's action — **the same move the detail's pinned CTA would make**,
/// through the same seam (`performRecommendedAction`). That identity is the whole reason
/// a swipe whose verb varies by row is safe to ship: the gesture is a faster entry point
/// to an action the user already reads in the detail, not a second vocabulary.
///
/// `.resolve` detours through `completeTask` because resolving is the one arm that owes
/// the user a way back, and that function already owns the undo pill and the resurfacing.
@MainActor
func performRecommended(
    _ action: RecommendedAction, on task: TaskItem, in context: NSManagedObjectContext,
    tasks: [TaskItem], notice: Binding<UndoNotice?>
) {
    if action == .resolve {
        completeTask(task, in: context, tasks: tasks, notice: notice)
        return
    }
    Motion.withMotion(Motion.decide) {
        _ = task.performRecommendedAction(action, among: tasks, in: context)
    }
    context.saveChanges()
}

// MARK: - The row gesture map (swipes)

/// The two swipes, applied to a ROW rather than to a lane entry — which matters for a
/// chain: collapsed, only the root is on screen and swiping it acts on the root; expanded,
/// every member is its own row and must swipe independently. Attaching this to the entry
/// would have made an expanded member's swipe act on the root instead.
struct TaskSwipeActions: ViewModifier {
    let task: TaskItem
    let allTasks: [TaskItem]
    let currentUserID: UUID?
    /// A collapsed chain root gives its LEADING edge to the pile — swipe right expands the
    /// stack — so it suppresses this one and supplies its own. Every other row keeps the
    /// lifecycle swipe. The meaning still doesn't vary per task: it varies by what the row
    /// IS, a pile or a task, which is the same distinction the card already draws.
    var includesLeading: Bool = true
    @Binding var notice: UndoNotice?
    @Environment(\.managedObjectContext) private var context

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                // Leading = advance the lifecycle, and it is the SAME move the detail's
                // pinned CTA would make. Absent when `recommendedAction` returns nil,
                // which is exactly someone else's task — "not yours to advance" becomes a
                // gesture that isn't there rather than a button that lies.
                if includesLeading,
                    let action = task.recommendedAction(
                        among: allTasks, currentUserID: currentUserID)
                {
                    Button {
                        performRecommended(
                            action, on: task, in: context, tasks: allTasks, notice: $notice)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    .tint(Palette.accentFlat)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Trailing = the reversible "not now". Absent on a resolved row: nothing
                // left to cancel, and its leading swipe already offers Reopen.
                if !task.status.isResolved {
                    Button(role: .destructive) {
                        cancelTask(task, in: context, tasks: allTasks, notice: $notice)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }
    }
}

extension View {
    func taskSwipeActions(
        task: TaskItem, allTasks: [TaskItem], currentUserID: UUID?,
        includesLeading: Bool = true, notice: Binding<UndoNotice?>
    ) -> some View {
        modifier(
            TaskSwipeActions(
                task: task, allTasks: allTasks, currentUserID: currentUserID,
                includesLeading: includesLeading, notice: notice))
    }
}

// MARK: - One lane entry (single row or a chain stack)

/// Renders a single `TaskLaneEntry`: a minimal `TaskRow` or the whole chain stack.
/// No dividers — Linear parity (row height carries the rhythm). Resolved rows read as
/// a record — a static glyph, no swipe/complete. Shared by the sectioned and flat lists.
struct TaskLaneEntryView: View {
    let entry: TaskLaneEntry
    let allTasks: [TaskItem]
    let othersRoster: [FamilyMember]
    /// Drives the leading swipe's verb. Defaults to nil, which `recommendedAction` treats
    /// as "no profile yet" and falls through to the normal lifecycle — it never wrongly
    /// suppresses the swipe, so a call site that hasn't threaded it stays correct.
    var currentUserID: UUID? = nil
    @Binding var selectedTask: TaskItem?
    @Binding var notice: UndoNotice?
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        switch entry {
        case .single(let task):
            let resolved = task.status.isResolved
            TaskRow(
                task: task,
                allTasks: allTasks,
                blockerSummary: task.blockerSummary(among: allTasks),
                stepProgress: task.stepProgress(among: allTasks),
                ownerDisplayName: task.ownerDisplayName(among: othersRoster),
                ownerPhotoData: task.ownerPhotoData(among: othersRoster),
                interactive: !resolved,
                onComplete: resolved
                    ? nil : { completeTask(task, in: context, tasks: allTasks, notice: $notice) },
                onCancel: resolved
                    ? nil : { cancelTask(task, in: context, tasks: allTasks, notice: $notice) },
                onOpen: { selectedTask = task }
            )
            .taskSwipeActions(
                task: task, allTasks: allTasks, currentUserID: currentUserID, notice: $notice)
        case .chain(let chain):
            // The stack applies the swipes PER MEMBER itself — collapsed that is just the
            // root, expanded it is each card — so this does not wrap them here.
            TaskChainStackView(
                chain: chain,
                allTasks: allTasks,
                onComplete: { completeTask($0, in: context, tasks: allTasks, notice: $notice) },
                onCancel: { cancelTask($0, in: context, tasks: allTasks, notice: $notice) },
                onOpen: { selectedTask = $0 },
                blockerSummary: { $0.blockerSummary(among: allTasks) },
                ownerDisplayName: { $0.ownerDisplayName(among: othersRoster) },
                ownerPhotoData: { $0.ownerPhotoData(among: othersRoster) },
                currentUserID: currentUserID,
                notice: $notice
            )
            .padding(.vertical, Spacing.sm)
        }
    }
}

// MARK: - Assigned tab (display-status sections)

struct AssignedSectionsView: View {
    let sections: [MyTasksSection]
    let allTasks: [TaskItem]
    let othersRoster: [FamilyMember]
    /// Threaded to the rows so the leading swipe can name the right verb.
    var currentUserID: UUID? = nil
    let searchIsActive: Bool
    /// "Show all N" on a capped ledger section — flips the STATUS FILTER to that
    /// section, the documented isolation path, rather than growing a second
    /// expansion mechanism the filter would then fight.
    var onShowAll: (TaskStatus) -> Void = { _ in }
    @Binding var selectedTask: TaskItem?
    @Binding var notice: UndoNotice?
    @Environment(\.openCapture) private var openCapture

    var body: some View {
        if sections.isEmpty {
            // An empty list gets the way OUT of empty. Only when the emptiness is real,
            // though: a search that matched nothing needs a different filter, not a new
            // task, and offering capture there would answer a question nobody asked.
            EmptyStateView(
                symbol: "square.stack.3d.up",
                title: searchIsActive ? "No matches" : "Nothing assigned to you",
                message: searchIsActive
                    ? "Nothing here matches. Try a different filter."
                    : "Work assigned to you shows up here, grouped by state — ordered by what deserves attention, never by folder.",
                actionTitle: searchIsActive ? nil : "Capture something",
                action: searchIsActive ? nil : { openCapture() }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            sectionHeader(section)
                            ForEach(section.entries) { entry in
                                TaskLaneEntryView(
                                    entry: entry, allTasks: allTasks, othersRoster: othersRoster,
                                    currentUserID: currentUserID,
                                    selectedTask: $selectedTask, notice: $notice)
                            }
                            if section.hiddenCount > 0 {
                                Button {
                                    onShowAll(section.status)
                                } label: {
                                    Text(
                                        "Show all \(section.entries.count + section.hiddenCount)"
                                    )
                                    .font(.controlLabel)
                                    .foregroundStyle(Palette.mutedText)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.pressableLink)
                                .minimumHitTarget()
                                .accessibilityHint(
                                    "Filter to \(section.status.label) to see every entry")
                            }
                        }
                    }
                }
                .padding(Spacing.lg)
            }
            // iOS 27's `swipeActionsContainer` is what lets rows carry `.swipeActions`
            // OUTSIDE a `List`. Without it this surface would have had to become a `List`
            // — losing the no-divider rhythm, the custom row backgrounds and the chain
            // card chrome — or hand-roll a drag gesture.
            .swipeActionsContainer()
        }
    }

    private func sectionHeader(_ section: MyTasksSection) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: section.status.symbol)
                .font(.glyphCaption(.semibold))
                .foregroundStyle(section.status.tint)
            Text(section.status.label)
                .metadataStyle()
                .textCase(.uppercase)
                .tracking(0.6)
            Text("\(section.entries.count)")
                .metadataStyle()
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.bottom, Spacing.xxs)
    }
}

// MARK: - Created tab (flat, chain-stacked, no dividers, newest first)

struct CreatedFlatView: View {
    let entries: [TaskLaneEntry]
    let allTasks: [TaskItem]
    let othersRoster: [FamilyMember]
    /// Threaded to the rows so the leading swipe can name the right verb.
    var currentUserID: UUID? = nil
    let searchIsActive: Bool
    @Binding var selectedTask: TaskItem?
    @Binding var notice: UndoNotice?
    @Environment(\.openCapture) private var openCapture

    var body: some View {
        if entries.isEmpty {
            // This screen said "everything you capture shows up here" and then gave the
            // user no way to capture — the most literal dead end in the product.
            EmptyStateView(
                symbol: "square.and.pencil",
                title: searchIsActive ? "No matches" : "Nothing created yet",
                message: searchIsActive
                    ? "Nothing you created matches. Try a different filter."
                    : "Everything you capture shows up here, newest first — a record of what you've added.",
                actionTitle: searchIsActive ? nil : "Capture something",
                action: searchIsActive ? nil : { openCapture() }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        TaskLaneEntryView(
                            entry: entry, allTasks: allTasks, othersRoster: othersRoster,
                            currentUserID: currentUserID,
                            selectedTask: $selectedTask, notice: $notice)
                    }
                }
                .padding(Spacing.lg)
            }
            // iOS 27's `swipeActionsContainer` is what lets rows carry `.swipeActions`
            // OUTSIDE a `List`. Without it this surface would have had to become a `List`
            // — losing the no-divider rhythm, the custom row backgrounds and the chain
            // card chrome — or hand-roll a drag gesture.
            .swipeActionsContainer()
        }
    }
}
