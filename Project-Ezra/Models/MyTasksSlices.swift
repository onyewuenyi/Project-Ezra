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

/// The ownership scopes under the title — each answers "whose tasks am I looking at?".
///
/// **Everyone is the household's shared space (2026-09-12).** Assigned is yours and
/// Created is what you authored, and between them a task another member captured for
/// themselves was invisible on the home surface — the one screen a family shares. It
/// sits between the two because it is the widest scope: Assigned narrows to you,
/// Created narrows to your authorship. Same sections, same order, same cap; the row's
/// trailing avatar is what says whose each one is.
///
/// The first scope is CALLED "Mine" and named `assigned`: the case is Linear's word and
/// every seam, test and doc reads it, but on the row "Assigned" spent 69pt where "Mine"
/// spends 38 — and with three scopes on a 402pt phone that was the difference between
/// the filter naming its state ("Family") and dropping to a bare glyph. In a household
/// "Mine" is also the plainer answer to the question the pills ask.
enum MyTasksTab: String, CaseIterable, Identifiable {
    case assigned
    case everyone
    case created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .assigned: return "Mine"
        case .everyone: return "Everyone"
        case .created: return "Created"
        }
    }
}

/// What the My Tasks header renders — the composition rules, in one pure place.
///
/// **The contract:**
/// 1. **Ownership navigation** appears only when more than one ownership scope exists.
///    It answers *whose* tasks am I looking at.
/// 2. **Filter** is ALWAYS available. It answers *what subset* of those tasks I want,
///    and it never depends on the ownership navigation being visible.
/// 3. **Search** is independent, and never silently inherits the filter — a hidden
///    filter suppressing the thing you just searched for is a trap.
/// 4. **Sort** is independent. (Not built; named so the dimension has a home.)
/// 5. **Header geometry is stable regardless of roster** — members coming and going may
///    change which controls appear, but must never make the list below jump.
///
/// This type exists because rule 2 was broken for three weeks. The filter menu was
/// nested inside the selected tab's pill, and when the tab bar became conditional on
/// the roster (`00df087`, reasoning only about tabs) the chain
/// `filter ⊂ selected tab ⊂ tab row ⊂ tab bar ⊂ roster` silently removed a whole
/// capability on every solo household — no warning, no failing test, because
/// "is the filter reachable?" was emergent from view nesting rather than a decision
/// anything could assert. Now the two decisions sit side by side and the asymmetry is
/// the point: **tabs are roster-dependent; the filter never is.**
enum MyTasksHeader {
    /// Assigned and Created answer the same question until somebody else is in the
    /// household: with a roster of one, every task you created is a task assigned to
    /// you, so the pill would be a two-tab control over two identical lists on the
    /// most-used screen. It appears the moment a second member exists.
    static func showsTabs(othersRoster: Int) -> Bool { othersRoster > 0 }

    /// True for every roster size, forever. Filtering is a query dimension, not a
    /// feature of multiplayer — and a solo user needs it MORE, since their list is the
    /// only one they have. If this ever gains a condition, rule 2 is being broken again.
    static func showsFilter(othersRoster: Int) -> Bool { true }

    /// What the screen calls itself: "Tasks" alone; once somebody else exists, "My
    /// Tasks" over your scopes and "Our Tasks" over Everyone's.
    ///
    /// It reads `showsTabs` rather than the roster count directly, and that is the
    /// point: the possessive and the ownership pills answer the SAME question ("whose
    /// tasks?"), so they must appear and disappear together or the title promises a
    /// distinction the header isn't making. With a roster of one there is nobody to be
    /// distinguished from and "My" is noise — the v2 lean collapse dropped it, and it
    /// comes back with the person who gives it meaning. And the possessive follows the
    /// SELECTED scope: "My Tasks" over the household's whole list would be the same lie
    /// in the other direction.
    ///
    /// This lives here, next to the other two, for the reason rule 2 exists: header
    /// composition decided inside the view is how the filter got silently deleted for
    /// three weeks. A rule that isn't in this file isn't tested.
    static func title(othersRoster: Int, tab: MyTasksTab = .assigned) -> String {
        guard showsTabs(othersRoster: othersRoster) else { return "Tasks" }
        return tab == .everyone ? "Our Tasks" : "My Tasks"
    }

    /// What the filter control calls itself. nil when nothing is filtered.
    ///
    /// The control names its own state because a bare glyph has one specific failure
    /// mode on a task list: **a filtered list is indistinguishable from a list with
    /// tasks missing.** That is a trust problem, not a discoverability one. One active
    /// axis shows its value; both show a bounded count rather than "Done · Work",
    /// which would turn the control into a miniature query builder and fight the tabs
    /// for width.
    static func filterSummary(status: TaskStatus?, category: String?) -> String? {
        switch (status, category) {
        case (nil, nil): return nil
        case (let status?, nil): return status.label
        case (nil, let category?): return category
        case (_?, _?): return "2 filters"
        }
    }

    /// What the list says when the filter matched nothing — it NAMES the filter, because
    /// the failure mode `filterSummary` guards against is worse here: an empty list under
    /// an active filter is exactly what "all my tasks are gone" would look like. Nil when
    /// no filter is active (that emptiness is real, and gets the capture invitation).
    static func filteredEmptyMessage(status: TaskStatus?, category: String?) -> String? {
        switch (status, category) {
        case (nil, nil): return nil
        case (let status?, nil): return "No tasks match “\(status.label)”."
        case (nil, let category?): return "No tasks match “\(category)”."
        case (_?, _?): return "No tasks match both filters."
        }
    }
}

/// One section on the Assigned tab: a header and the chain-grouped entries under it,
/// already stack-ordered.
struct MyTasksSection: Identifiable {
    let status: TaskStatus
    let entries: [TaskLaneEntry]
    /// Resolved rows held back by the inline cap — the ledger stays reachable (a
    /// "Show all N" row flips the status filter, the documented isolation path)
    /// without the graveyard outgrowing the pipeline it sits under.
    var hiddenCount: Int = 0

    var id: String { status.rawValue }
}

enum MyTasksSlices {
    /// The canonical section order — live pipeline first (In Progress → Todo), then
    /// the resolution ledger (Done → Canceled).
    static let sectionOrder: [TaskStatus] = [.doing, .todo, .done, .canceled]

    /// How many resolved rows a LEDGER section shows inline before deferring to the
    /// status filter. The live pipeline is never capped — this exists because Done
    /// grows monotonically on a daily-use store, and a list that is mostly graveyard
    /// under a short pipeline is the exact "437 things" failure the product exists
    /// to prevent. Five keeps "what did I just finish?" answerable at a glance;
    /// everything older is one tap away, not gone.
    static let resolvedInlineCap = 5

    /// The filter-menu predicate: an optional status filter and an optional category
    /// filter. `nil` means "All" for either axis. It is also how the Done/Canceled
    /// ledger gets ISOLATED — `sectionOrder` always renders those sections, so
    /// resolved work is reachable by scrolling; picking the Done (or Canceled) filter
    /// is what makes it the only thing on screen.
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
        status statusFilter: TaskStatus? = nil, category: String? = nil
    ) -> [MyTasksSection] {
        let scoped = tasks.filter {
            $0.isMine(currentUserID: currentUserID)
                && applyFilters($0, status: statusFilter, category: category)
        }
        return sections(scoped: scoped, allTasks: tasks, statusFilter: statusFilter)
    }

    /// The Everyone tab: the household's whole list — every owner, and the unowned —
    /// sectioned exactly as Assigned is. The scope is the only thing that differs, which
    /// is why the sectioning is one function: two copies would let the ledger cap or the
    /// resolution order drift between "mine" and "ours".
    static func everyone(
        tasks: [TaskItem], status statusFilter: TaskStatus? = nil, category: String? = nil
    ) -> [MyTasksSection] {
        let scoped = tasks.filter { applyFilters($0, status: statusFilter, category: category) }
        return sections(scoped: scoped, allTasks: tasks, statusFilter: statusFilter)
    }

    /// The status sectioning both scoped tabs share — see `assigned`.
    private static func sections(
        scoped: [TaskItem], allTasks tasks: [TaskItem], statusFilter: TaskStatus?
    ) -> [MyTasksSection] {
        let entries = laneEntries(from: scoped, allTasks: tasks)
        let grouped = Dictionary(grouping: entries) { $0.anchor.status }
        return sectionOrder.compactMap { status in
            guard var items = grouped[status], !items.isEmpty else { return nil }
            // The LEDGER is a record, so it reads in the order things happened: most
            // recently resolved first. Stack precedence is an attention order and means
            // nothing for finished work — under it the inline five were the five
            // highest-scoring resolved tasks, which is not "what did I just finish?", the
            // one question the cap exists to keep answerable. Stable, so two tasks
            // resolved in the same second keep their stack order.
            if status.isResolved {
                items = items.enumerated().sorted { a, b in
                    let (ta, tb) = (a.element.anchor.completedAt, b.element.anchor.completedAt)
                    if ta != tb { return (ta ?? .distantPast) > (tb ?? .distantPast) }
                    return a.offset < b.offset
                }.map(\.element)
            }
            // The ledger caps INLINE only, and only when no status filter is narrowing
            // the view — picking Done from the filter is precisely "show me the
            // ledger", and capping there would fight the user's explicit ask.
            if status.isResolved, statusFilter == nil, items.count > resolvedInlineCap {
                return MyTasksSection(
                    status: status,
                    entries: Array(items.prefix(resolvedInlineCap)),
                    hiddenCount: items.count - resolvedInlineCap)
            }
            return MyTasksSection(status: status, entries: items)
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
