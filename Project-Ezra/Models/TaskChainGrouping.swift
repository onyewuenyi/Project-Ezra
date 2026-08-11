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

    /// Stable enough for a single render pass: the sorted member uuids joined.
    var id: String {
        members.compactMap(\.uuid).map(\.uuidString).sorted().joined(separator: "-")
    }

    /// The member that decides this chain's lane and sort position: whichever root
    /// (a member with nothing inside the chain to come first — the "front" the
    /// collapsed stack shows) sorts first under the stack precedence.
    var root: TaskItem {
        let roots = members.filter { TaskChainGrouping.prerequisites(of: $0, within: members).isEmpty }
        return roots.min { a, b in
            guard let ka = a.uuid.flatMap({ rankKeys[$0] }), let kb = b.uuid.flatMap({ rankKeys[$0] })
            else { return false }
            return TaskRanking.stackOrder(ka, kb)
        } ?? members[0]
    }
}

/// One renderable row in a lane: either a standalone task, or a whole chain.
enum TaskLaneEntry: Identifiable {
    case single(TaskItem)
    case chain(TaskChain)

    var id: String {
        switch self {
        case .single(let task): return task.uuid?.uuidString ?? task.title
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
        var adjacency: [UUID: Set<UUID>] = [:]
        for task in tasks {
            guard let id = task.uuid else { continue }
            for earlier in prerequisites(of: task, within: tasks) {
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
        task.activeBlockerTasks(among: set) + task.openSteps(among: set)
    }

    /// Kahn's algorithm: each layer is every not-yet-placed member whose prerequisites
    /// (within this chain) are all already placed, ties broken by the
    /// stack precedence for deterministic output. Falls back to a stable sort of
    /// whatever's left if nothing is ever ready (shouldn't happen — `addBlocker`
    /// already prevents cycles at write time, and containment can't cycle — but this
    /// keeps grouping from infinite-looping if one somehow existed).
    private static func topologicallyLayer(
        _ members: [TaskItem], keys: [UUID: RankKey]
    ) -> [TaskItem] {
        func precedes(_ a: TaskItem, _ b: TaskItem) -> Bool {
            guard let ka = a.uuid.flatMap({ keys[$0] }), let kb = b.uuid.flatMap({ keys[$0] })
            else { return false }
            return TaskRanking.stackOrder(ka, kb)
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
