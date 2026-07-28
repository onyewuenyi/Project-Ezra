//
//  TaskLaneList.swift
//  Project-Ezra
//
//  The shared list machinery behind the "My Tasks" surface — extracted from the old
//  per-slice list views so the Assigned (sectioned) and Created (flat) tabs, plus the
//  search sheet, all render rows the same way and complete/cancel through one
//  undo-aware path. Dependency-linked work still renders as the collapsible chain
//  stack; everything else is a one-line `TaskRow`.
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
    let unblocked = task.completeAndResurface(in: context)
    context.saveChanges()
    notice.wrappedValue = .resolution("Completed", task.title, unblocked: unblocked) {
        task.reopenAndReblock(in: context)
        context.saveChanges()
    }
}

@MainActor
func cancelTask(
    _ task: TaskItem, in context: NSManagedObjectContext, tasks: [TaskItem],
    notice: Binding<UndoNotice?>
) {
    let unblocked = task.killAndResurface(in: context)
    context.saveChanges()
    notice.wrappedValue = .resolution("Canceled", task.title, unblocked: unblocked) {
        task.reopenAndReblock(in: context)
        context.saveChanges()
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
                ownerDisplayName: task.ownerDisplayName(among: othersRoster),
                ownerPhotoData: task.ownerPhotoData(among: othersRoster),
                interactive: !resolved,
                onComplete: resolved
                    ? nil : { completeTask(task, in: context, tasks: allTasks, notice: $notice) },
                onCancel: resolved
                    ? nil : { cancelTask(task, in: context, tasks: allTasks, notice: $notice) },
                onOpen: { selectedTask = task }
            )
        case .chain(let chain):
            TaskChainStackView(
                chain: chain,
                allTasks: allTasks,
                onComplete: { completeTask($0, in: context, tasks: allTasks, notice: $notice) },
                onCancel: { cancelTask($0, in: context, tasks: allTasks, notice: $notice) },
                onOpen: { selectedTask = $0 },
                blockerSummary: { $0.blockerSummary(among: allTasks) },
                ownerDisplayName: { $0.ownerDisplayName(among: othersRoster) },
                ownerPhotoData: { $0.ownerPhotoData(among: othersRoster) }
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
    let searchIsActive: Bool
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
                                    selectedTask: $selectedTask, notice: $notice)
                            }
                        }
                    }
                }
                .padding(Spacing.lg)
            }
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
                            selectedTask: $selectedTask, notice: $notice)
                    }
                }
                .padding(Spacing.lg)
            }
        }
    }
}
