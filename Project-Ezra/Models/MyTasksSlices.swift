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

/// What a section on the Assigned tab is headed by. Almost always a lifecycle state
/// — but `.reference` is deliberately NOT one.
///
/// A reference item ("the wifi password is hunter2") is owned and live yet never
/// needs to complete, so filing it under "Todo" claims it is queued work, which it
/// is not. Giving it its own section is the honest rendering, and it is also the
/// visible symptom of a deferred question: the task primitive is currently doing two
/// jobs (execution and knowledge). This section is the seam a future
/// knowledge/execution split would cut along — see `docs/task-model.md`.
enum MyTasksSectionKind: Hashable {
    case status(TaskStatus)
    case reference

    var label: String {
        switch self {
        case .status(let status): return status.label
        case .reference: return "Reference"
        }
    }

    var rawValue: String {
        switch self {
        case .status(let status): return status.rawValue
        case .reference: return "reference"
        }
    }
}

/// One section on the Assigned tab: a header and the chain-grouped entries under it,
/// already stack-ordered.
struct MyTasksSection: Identifiable {
    let kind: MyTasksSectionKind
    let entries: [TaskLaneEntry]

    var id: String { kind.rawValue }
}

enum MyTasksSlices {
    /// The canonical section order — live pipeline first (In Progress → Todo), then
    /// the resolution ledger (Done → Canceled), then the reference shelf last. Kept
    /// last on purpose: it is a record you consult, never a queue you work.
    static let sectionOrder: [MyTasksSectionKind] = [
        .status(.doing), .status(.todo), .status(.done), .status(.canceled), .reference,
    ]

    /// Which section a task heads. A LIVE reference item goes to the reference shelf;
    /// a resolved one goes to Done/Canceled like anything else, because at that point
    /// it really is a resolution record.
    static func sectionKind(for task: TaskItem) -> MyTasksSectionKind {
        if task.status.isLive, task.workIntent == .reference { return .reference }
        return .status(task.status)
    }

    /// The filter-menu predicate: an optional status filter and an optional category
    /// filter. `nil` means "All" for either axis. This is also how the Done/Canceled
    /// ledger stays reachable now that the Completed slice is gone — pick the Done
    /// (or Canceled) filter.
    static func applyFilters(_ task: TaskItem, status: TaskStatus?, category: String?) -> Bool {
        if let status, task.status != status { return false }
        if let category, task.category != category { return false }
        return true
    }

    /// The Assigned tab: work owned by the current user, chain-grouped, then split
    /// into sections by each entry's ANCHOR (so a dependency chain sections once, by
    /// the state of its front task, and never fractures across headers). Within a
    /// section, entries keep their stack order — Needs Decision still floats to the
    /// top, because `TaskRanking.stackOrder` forces it.
    static func assigned(
        tasks: [TaskItem], currentUserID: UUID?,
        status: TaskStatus? = nil, category: String? = nil
    ) -> [MyTasksSection] {
        let scoped = tasks.filter {
            $0.isMine(currentUserID: currentUserID) && applyFilters($0, status: status, category: category)
        }
        let entries = laneEntries(from: scoped, allTasks: tasks)
        let grouped = Dictionary(grouping: entries) { sectionKind(for: $0.anchor) }
        return sectionOrder.compactMap { kind in
            guard let items = grouped[kind], !items.isEmpty else { return nil }
            return MyTasksSection(kind: kind, entries: items)
        }
    }

    /// The Created tab: work the current user authored (`creatorID == me`), newest
    /// first, flat, across every status — a plain authorship record, not a pipeline.
    static func created(
        tasks: [TaskItem], currentUserID: UUID?,
        status: TaskStatus? = nil, category: String? = nil
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
        status: TaskStatus? = nil, category: String? = nil
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
