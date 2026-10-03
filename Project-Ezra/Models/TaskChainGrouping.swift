//
//  TaskChainGrouping.swift
//  Project-Ezra
//
//  Groups active tasks into dependency chains for the Tasks screen's stacked-card
//  visualization. Built entirely on the real `blockedBy` reference graph (no fuzzy
//  text matching) — a chain is a connected component of 2+ tasks linked by active
//  blocker references, laid out root(s)-first via a topological sort so branching
//  (a task with 2 blockers, or a blocker with 2 dependents) renders correctly
//  instead of being flattened into a single line.
//

import CoreData
import Foundation

/// A dependency-linked group of active tasks, in execution order: root(s) first,
/// then the tasks waiting on them, layer by layer. Recomputed fresh every render —
/// nothing here is persisted, so there's no stale-chain state to manage.
struct TaskChain: Identifiable {
    let members: [TaskItem]
    /// The rank keys the LANE uses to position this chain — passed in so the front card
    /// (`root`) is chosen under the SAME population-dependent keys that place the whole
    /// chain in the lane. A member-only re-rank would compute different relevance/blocking
    /// terms (a `.parent` umbrella outside the chain, due-proximity, isBlocked all shift
    /// with the population), so the collapsed stack's front card and its lane position
    /// could be driven by different `effectiveAttention` values.
    let rankKeys: [UUID: RankKey]

    /// Stable enough for a single render pass: the sorted member uuids joined — and
    /// never EMPTY (2026-09-18). A chain whose members have all just been deleted
    /// `compactMap`s to nothing and joined to "", which is the same duplicate-id crash
    /// `TaskLaneEntry.id` carries the long note about; the object identities are the
    /// fallback that cannot collide.
    var id: String {
        let uuids = members.compactMap(\.uuid).map(\.uuidString).sorted()
        guard uuids.isEmpty else { return uuids.joined(separator: "-") }
        return members.map { $0.objectID.uriRepresentation().absoluteString }.sorted()
            .joined(separator: "-")
    }

    /// The member that decides this chain's lane and sort position: whichever root
    /// (a member with nothing inside the chain to come first — the "front" the
    /// collapsed stack shows) sorts first under the stack precedence.
    var root: TaskItem {
        let roots = members.filter { TaskChainGrouping.prerequisites(of: $0, within: members).isEmpty }
        return roots.min { TaskChainGrouping.precedes($0, $1, keys: rankKeys) } ?? members[0]
    }
}

// MARK: - The chain read as a GROUP with a current task (2026-09-12)

extension TaskChain {
    /// The member that NAMES the outcome: a container whose steps are in this chain and
    /// which is no chain member's own step (the top-most, when containers nest). Nil for a
    /// chain of bare blockers, which has no name of its own.
    ///
    /// The umbrella is the group's caption on the list, never one of its cards — it holds
    /// its steps as prerequisites, so it is always the LAST member in execution order and
    /// was the last card in the old pile. A group represents the remaining work toward
    /// an outcome, and the outcome is not a piece of that work. When the last step
    /// resolves the chain dissolves and the umbrella surfaces as an ordinary row, which is
    /// the one honest moment to ask whether the outcome itself is done.
    var umbrella: TaskItem? {
        let memberIDs = Set(members.compactMap(\.uuid))
        return members.first { candidate in
            guard let id = candidate.uuid else { return false }
            let hasStepsHere = members.contains { $0.parentTaskID == id }
            let isSomeonesStepHere = candidate.parentTaskID.map(memberIDs.contains) ?? false
            return hasStepsHere && !isSomeonesStepHere
        }
    }

    /// What the deck's caption calls the group. A named outcome is its umbrella's title. A
    /// chain of bare blockers has no name, so its caption is its STORY — the members in
    /// execution order, "Renew passport → Book flights → Request time off" — because the
    /// only thing that made these one group is that each unlocks the next, and saying so
    /// is more useful than the generic "Linked tasks" it replaced. One line; the caption
    /// truncates the tail.
    var groupTitle: String {
        umbrella?.title ?? deckMembers.map(\.title).joined(separator: " → ")
    }

    /// The cards the group pages through: every member but the umbrella, in execution
    /// order — the front card is `root`, the first member with nothing left to wait on, so
    /// a waiting member never leads while an actionable one exists.
    var deckMembers: [TaskItem] {
        guard let umbrella else { return members }
        return members.filter { $0 !== umbrella }
    }
}

/// One renderable row in a lane: either a standalone task, or a whole chain.
enum TaskLaneEntry: Identifiable {
    case single(TaskItem)
    case chain(TaskChain)

    /// **The fallback must be UNIQUE, not merely present (2026-09-18).** It used to be
    /// `task.title`, and a DELETED managed object answers "" for every attribute — so
    /// the instant "Clear all tasks" deleted the store's rows, every entry still on
    /// screen collapsed to the same empty id, SwiftUI logged
    /// *"the ID  occurs multiple times within the collection"* at fatal level, and the
    /// app died before the fetch could refresh. `objectID` is the identity Core Data
    /// guarantees for the object itself: unique, never empty, and still answerable
    /// after a delete. The uuid stays the primary id, because it is stable across a
    /// temporary objectID becoming permanent at save.
    var id: String {
        switch self {
        case .single(let task):
            return task.uuid?.uuidString ?? task.objectID.uriRepresentation().absoluteString
        case .chain(let chain): return chain.id
        }
    }

    /// The task that decides this entry's lane + sort position.
    var anchor: TaskItem {
        switch self {
        case .single(let task): return task
        case .chain(let chain): return chain.root
        }
    }
}

enum TaskChainGrouping {
    /// Partitions `tasks` into connected dependency chains (2+ members, linked by
    /// active blocker references) and loose standalones (no active connection to
    /// anything else in the set).
    /// `rankKeys` are the keys the caller positions lanes with (over the FULL working set);
    /// chain roots and layering use the same keys so selection and placement agree. A caller
    /// that omits them (tests) falls back to a member-scoped ranking.
    static func computeChains(
        in tasks: [TaskItem], rankKeys: [UUID: RankKey]? = nil
    ) -> (chains: [TaskChain], loose: [TaskItem]) {
        guard !tasks.isEmpty else { return ([], []) }
        let keys = rankKeys ?? TaskRanking.rankKeys(for: tasks)

        var byID: [UUID: TaskItem] = [:]
        for task in tasks { if let id = task.uuid { byID[id] = task } }

        // Undirected adjacency: an edge between a task and everything inside this set
        // that has to come before it — its active blockers AND its own open steps.
        // ONE index over the set, then one lookup per task: asking `prerequisites(of:
        // within:)` per task rebuilt that index per task, which made grouping O(n²) over
        // the whole working set on every render of My Tasks.
        let index = PrerequisiteIndex(tasks)
        var adjacency: [UUID: Set<UUID>] = [:]
        for task in tasks {
            guard let id = task.uuid else { continue }
            for earlier in index.prerequisites(of: task) {
                guard let earlierID = earlier.uuid else { continue }
                adjacency[id, default: []].insert(earlierID)
                adjacency[earlierID, default: []].insert(id)
            }
        }

        // Connected components via BFS.
        var visited: Set<UUID> = []
        var components: [[TaskItem]] = []
        for task in tasks {
            guard let id = task.uuid, !visited.contains(id) else { continue }
            var componentIDs: [UUID] = []
            var queue = [id]
            visited.insert(id)
            while !queue.isEmpty {
                let node = queue.removeFirst()
                componentIDs.append(node)
                for neighbor in adjacency[node] ?? [] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
            components.append(componentIDs.compactMap { byID[$0] })
        }

        var chains: [TaskChain] = []
        var loose: [TaskItem] = []
        for members in components {
            if members.count <= 1 {
                loose.append(contentsOf: members)
            } else {
                chains.append(
                    TaskChain(members: topologicallyLayer(members, keys: keys), rankKeys: keys))
            }
        }
        return (chains, loose)
    }

    /// Everything inside `set` that has to come before `task`: the tasks it is waiting
    /// on, plus its own still-open steps.
    ///
    /// **Two graphs, one ordering.** `.blocks` is sequencing and `.parent` is containment
    /// — different questions, deliberately not fused in storage (see `TaskItem.openSteps`)
    /// — but for the purpose of laying a stack out they answer the same one: what does the
    /// user have to get through first? Joining them HERE, in the one place that orders
    /// tasks for display, is what lets a breakdown render as a single stack with its steps
    /// in front, without the umbrella having to pretend it is blocked.
    static func prerequisites(of task: TaskItem, within set: [TaskItem]) -> [TaskItem] {
        PrerequisiteIndex(set).prerequisites(of: task)
    }

    /// The set, indexed once, so `prerequisites(of:)` is a lookup rather than a scan.
    ///
    /// This is `prerequisites(of:within:)`'s implementation — the join of the two graphs
    /// still happens in exactly one place, it is just built once per set instead of once
    /// per question. Answers are identical to `activeBlockerTasks(among:)` +
    /// `openSteps(among:)` over the same set, in the same order (blockers in set order,
    /// then steps in breakdown order), which `TaskChainGroupingTests` holds it to.
    struct PrerequisiteIndex {
        private let openIDs: Set<UUID>
        /// Every open task keyed by uuid, with its position in the set — blockers are
        /// returned in SET order, as the filter they replace did.
        private let open: [UUID: (task: TaskItem, position: Int)]
        /// Each parent's still-open steps, in breakdown order (`children(among:)`'s
        /// ordering — `sortIndex`, then `createdAt`, then uuid).
        private let openStepsByParent: [UUID: [TaskItem]]

        init(_ set: [TaskItem]) {
            var open: [UUID: (task: TaskItem, position: Int)] = [:]
            var steps: [UUID: [TaskItem]] = [:]
            for (position, task) in set.enumerated() where !task.status.isResolved {
                guard let id = task.uuid else { continue }
                open[id] = (task, position)
                if let parentID = task.parentTaskID {
                    steps[parentID, default: []].append(task)
                }
            }
            self.open = open
            self.openIDs = Set(open.keys)
            self.openStepsByParent = steps.mapValues { siblings in
                siblings.sorted {
                    ($0.sortIndex, $0.createdAt, $0.uuid?.uuidString ?? "")
                        < ($1.sortIndex, $1.createdAt, $1.uuid?.uuidString ?? "")
                }
            }
        }

        func prerequisites(of task: TaskItem) -> [TaskItem] {
            let edges = task.relationships
            var blockers: [TaskItem] = []
            if edges.contains(where: { $0.kind == .blocks }) {
                let blockerIDs = Set(
                    TaskItem.activeBlockers(from: edges, openIDs: openIDs).compactMap(\.taskID))
                blockers = blockerIDs.compactMap { open[$0] }
                    .sorted { $0.position < $1.position }
                    .map(\.task)
            }
            let steps = task.uuid.flatMap { openStepsByParent[$0] } ?? []
            return blockers + steps
        }
    }

    /// Kahn's algorithm: each layer is every not-yet-placed member whose prerequisites
    /// (within this chain) are all already placed, ties broken by the
    /// stack precedence for deterministic output. Falls back to a stable sort of
    /// whatever's left if nothing is ever ready (shouldn't happen — `addBlocker`
    /// already prevents cycles at write time, and containment can't cycle — but this
    /// keeps grouping from infinite-looping if one somehow existed).
    /// The tiebreak between two members that are both ready: **siblings under one umbrella
    /// keep their BREAKDOWN order** (`sortIndex`, then `createdAt`, then uuid — the same
    /// ordering `children(among:)` is), everything else takes the stack precedence.
    ///
    /// This is what makes the deck's front card, the container spine's next-step pointer
    /// and the kickoff line agree: all three now read the model's proposed sequence for
    /// steps. Before it the deck picked its front by attention among the roots, so
    /// "Order the cake" led the deck while the page called it "2 of 3 left".
    static func precedes(_ a: TaskItem, _ b: TaskItem, keys: [UUID: RankKey]) -> Bool {
        if let parent = a.parentTaskID, parent == b.parentTaskID {
            return (a.sortIndex, a.createdAt, a.uuid?.uuidString ?? "")
                < (b.sortIndex, b.createdAt, b.uuid?.uuidString ?? "")
        }
        guard let ka = a.uuid.flatMap({ keys[$0] }), let kb = b.uuid.flatMap({ keys[$0] })
        else { return false }
        return TaskRanking.stackOrder(ka, kb)
    }

    private static func topologicallyLayer(
        _ members: [TaskItem], keys: [UUID: RankKey]
    ) -> [TaskItem] {
        func precedes(_ a: TaskItem, _ b: TaskItem) -> Bool {
            TaskChainGrouping.precedes(a, b, keys: keys)
        }
        var remaining = members
        var ordered: [TaskItem] = []
        while !remaining.isEmpty {
            let orderedIDs = Set(ordered.compactMap(\.uuid))
            let ready =
                remaining
                .filter { member in
                    prerequisites(of: member, within: members).allSatisfy {
                        orderedIDs.contains($0.uuid ?? UUID())
                    }
                }
                .sorted(by: precedes)
            guard !ready.isEmpty else {
                ordered.append(contentsOf: remaining.sorted(by: precedes))
                break
            }
            ordered.append(contentsOf: ready)
            let readyIDs = Set(ready.compactMap(\.uuid))
            remaining.removeAll { readyIDs.contains($0.uuid ?? UUID()) }
        }
        return ordered
    }
}
