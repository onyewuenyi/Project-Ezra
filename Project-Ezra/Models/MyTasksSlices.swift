//
//  MyTasksSlices.swift
//  Project-Ezra
//
//  The pure slicing behind the "My Tasks" surface (Linear's "My issues"). Two tabs:
//  Assigned (work owned by me, grouped into the Linear status sections in focus
//  order) and Created (work I authored, newest first, flat). Kept ModelContext-free
//  and side-effect-free so it is exhaustively testable — the view is a thin render
//  over these.
//

import Foundation

/// The two tabs under the "My Tasks" title.
enum MyTasksTab: String, CaseIterable, Identifiable {
    case assigned
    case created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .assigned: return "Assigned"
        case .created: return "Created"
        }
    }
}

/// One display-status section on the Assigned tab: a header (the status) and the
/// chain-grouped entries under it, already stack-ordered.
struct MyTasksSection: Identifiable {
    let status: TaskDisplayStatus
    let entries: [TaskLaneEntry]

    var id: String { status.rawValue }
}

enum MyTasksSlices {
    /// The canonical section order — active pipeline first (In Progress → In Review →
    /// Todo → Backlog), then the resolution ledger (Done → Canceled) at the bottom.
    static let sectionOrder: [TaskDisplayStatus] = [
        .inProgress, .inReview, .todo, .backlog, .done, .canceled,
    ]

    /// The filter-menu predicate: an optional display-status filter and an optional
    /// category filter. `nil` means "All" for either axis. This is also how the
    /// Done/Canceled ledger stays reachable now that the Completed slice is gone —
    /// pick the Done (or Canceled) filter.
    static func applyFilters(_ task: TaskItem, status: TaskDisplayStatus?, category: String?) -> Bool {
        if let status, task.displayStatus != status { return false }
        if let category, task.category != category { return false }
        return true
    }

    /// The Assigned tab: work owned by the current user, chain-grouped, then split
    /// into display-status sections by each entry's ANCHOR (so a dependency chain
    /// sections once, by the state of its front task, and never fractures across
    /// headers). Within a section, entries keep their stack order — Needs Decision
    /// still floats to the top, because `TaskRanking.stackOrder` forces it.
    static func assigned(
        tasks: [TaskItem], currentUserID: UUID?,
        status: TaskDisplayStatus? = nil, category: String? = nil
    ) -> [MyTasksSection] {
        let scoped = tasks.filter {
            $0.isMine(currentUserID: currentUserID) && applyFilters($0, status: status, category: category)
        }
        let entries = laneEntries(from: scoped, allTasks: tasks)
        let grouped = Dictionary(grouping: entries) { $0.anchor.displayStatus }
        return sectionOrder.compactMap { status in
            guard let items = grouped[status], !items.isEmpty else { return nil }
            return MyTasksSection(status: status, entries: items)
        }
    }

    /// The Created tab: work the current user authored (`creatorID == me`), newest
    /// first, flat, across every status — a plain authorship record, not a pipeline.
    static func created(
        tasks: [TaskItem], currentUserID: UUID?,
        status: TaskDisplayStatus? = nil, category: String? = nil
    ) -> [TaskItem] {
        tasks
            .filter {
                $0.creatorID != nil && $0.creatorID == currentUserID
                    && applyFilters($0, status: status, category: category)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The Created tab, chain-grouped like Assigned but FLAT (no status sections) and
    /// ordered newest-first by each entry's anchor `createdAt` — an authorship record
    /// that still stacks dependency chains. No stack-precedence reorder here (that's
    /// Assigned's job); Created reads chronologically.
    static func createdEntries(
        tasks: [TaskItem], currentUserID: UUID?,
        status: TaskDisplayStatus? = nil, category: String? = nil
    ) -> [TaskLaneEntry] {
        let scoped = tasks.filter {
            $0.creatorID != nil && $0.creatorID == currentUserID
                && applyFilters($0, status: status, category: category)
        }
        return laneEntries(from: scoped, allTasks: tasks)
            .sorted { $0.anchor.createdAt > $1.anchor.createdAt }
    }
}

// MARK: - Detail-pager peers (the on-screen order, flattened)

extension TaskLaneEntry {
    /// The entry's tasks in render order — a standalone is itself; a chain unrolls
    /// root-first (`TaskChain.members` is already topologically layered).
    var tasks: [TaskItem] {
        switch self {
        case .single(let task): return [task]
        case .chain(let chain): return chain.members
        }
    }
}

/// Flattens a surface's rendered structure into the linear task order the full-screen
/// detail pages through. Pure, so the "swipe goes where the eye expects" contract is
/// testable without a view.
enum TaskDetailPeers {
    /// Assigned-tab order: sections top-to-bottom, entries within a section in place,
    /// chains unrolled where they sit.
    static func flatten(_ sections: [MyTasksSection]) -> [TaskItem] {
        sections.flatMap { flatten($0.entries) }
    }

    /// Flat-lane order (Created tab, search): entries in place, chains unrolled.
    static func flatten(_ entries: [TaskLaneEntry]) -> [TaskItem] {
        entries.flatMap(\.tasks)
    }
}
