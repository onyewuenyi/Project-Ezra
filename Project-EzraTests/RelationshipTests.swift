//
//  RelationshipTests.swift
//  Project-EzraTests
//
//  The `Relationship` blob is the graph's most load-bearing type — it absorbed the old
//  `blockersData` + `parentTaskID`. These lock the four hardening measures: the derived
//  `blockers` view keeps the exact old Blocker semantics (durable list, external waits,
//  reopen re-blocks, cycle guard, unblock leaves `.parent`), tombstones carry no live
//  semantics, the versioned envelope round-trips, and — the real prize — an
//  operation-sequence property test runs the bridge against an independent oracle so a
//  reopen×tombstone interaction can never silently diverge.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Relationship graph bridge")
struct RelationshipTests {

    // MARK: - Blocker-bridge parity

    @Test("A tracked blocker is durable: it survives the target completing and re-blocks on reopen")
    func durableListReopen() {
        let target = TaskItem(title: "passport", status: .active)
        let task = TaskItem(title: "flights", status: .active)
        let all = [target, task]
        task.addTaskBlocker(target.uuid!, among: all)
        #expect(task.hasActiveBlockers(among: all))

        target.complete(now: Date())
        #expect(!task.hasActiveBlockers(among: all))  // no longer active…
        #expect(task.blockers.count == 1)  // …but still in the durable list

        target.reopen(among: all)
        #expect(task.hasActiveBlockers(among: all))  // re-blocks automatically
    }

    @Test("An external wait derives as an external Blocker with its note preserved")
    func externalWait() {
        let task = TaskItem(title: "kitchen", status: .active)
        task.addExternalBlocker("the plumber to confirm", among: [task])
        let blockers = task.blockers
        #expect(blockers.count == 1)
        #expect(blockers[0].kind == .external)
        #expect(blockers[0].taskID == nil)
        #expect(blockers[0].note == "the plumber to confirm")
        #expect(task.hasActiveBlockers(among: [task]))  // external is always active
    }

    @Test("The cycle guard still holds through the relationship bridge")
    func cycleGuard() {
        let a = TaskItem(title: "a", status: .active)
        let b = TaskItem(title: "b", status: .active)
        let all = [a, b]
        a.addTaskBlocker(b.uuid!, among: all)  // a waits on b
        b.addTaskBlocker(a.uuid!, among: all)  // would close a cycle → no-op
        #expect(b.taskBlockerIDs.isEmpty)
    }

    @Test("unblock() drops the .blocks edges but leaves a .parent edge intact")
    func unblockLeavesParent() {
        let parent = TaskItem(title: "trip", status: .active)
        let blocker = TaskItem(title: "passport", status: .active)
        let task = TaskItem(title: "book hotel", status: .active)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])
        // Seed a parent edge directly (Phase 2 adds the mutation helper).
        task.relationships =
            task.relationships + [.parent(taskID: parent.uuid!)]
        #expect(task.parentTaskID == parent.uuid!)

        task.unblock()
        #expect(task.blockers.isEmpty)
        #expect(task.parentTaskID == parent.uuid!)  // parent survives
    }

    @Test("removeBlocker drops one edge by id, leaving the rest")
    func removeOneBlocker() {
        let b1 = TaskItem(title: "b1", status: .active)
        let b2 = TaskItem(title: "b2", status: .active)
        let task = TaskItem(title: "x", status: .active)
        let all = [task, b1, b2]
        task.addTaskBlocker(b1.uuid!, among: all)
        task.addTaskBlocker(b2.uuid!, among: all)
        let firstID = task.blockers.first { $0.taskID == b1.uuid! }!.id
        task.removeBlocker(firstID, among: all)
        #expect(task.taskBlockerIDs == [b2.uuid!])
    }

    // MARK: - Tombstones

    @Test("A dismissed edge carries no live semantics — invisible to every derived view")
    func dismissedNoLiveSemantics() {
        let blocker = TaskItem(title: "b", status: .active)
        let parent = TaskItem(title: "p", status: .active)
        let task = TaskItem(title: "x", status: .active)
        task.relationships = [
            Relationship(
                kind: .blocks, targetID: blocker.uuid!, provenance: .human, confidence: 1.0,
                dismissed: true),
            Relationship(
                kind: .parent, targetID: parent.uuid!, provenance: .human, confidence: 1.0,
                dismissed: true),
        ]
        #expect(task.blockers.isEmpty)
        #expect(!task.hasActiveBlockers(among: [task, blocker]))
        #expect(task.parentTaskID == nil)
    }

    // MARK: - Invariant validation + envelope

    @Test("Invariant validation catches self-edges, dup lives, bad targets, and human confidence")
    func invariants() {
        let id = UUID()
        let other = UUID()
        // Self-edge.
        #expect(
            Relationship.firstViolation(
                in: [.blocks(taskID: id)], owner: id) != nil)
        // Duplicate live (kind, target).
        #expect(
            Relationship.firstViolation(
                in: [.blocks(taskID: other), .blocks(taskID: other)]) != nil)
        // nil target on a non-blocks edge.
        #expect(
            Relationship.firstViolation(in: [
                Relationship(kind: .parent, targetID: nil, provenance: .human, confidence: 1.0)
            ]) != nil)
        // Human edge with confidence ≠ 1.0.
        #expect(
            Relationship.firstViolation(in: [
                Relationship(kind: .blocks, targetID: other, provenance: .human, confidence: 0.5)
            ]) != nil)
        // A clean list is valid.
        #expect(Relationship.firstViolation(in: [.blocks(taskID: other)], owner: id) == nil)
    }

    @Test("The versioned envelope round-trips")
    func envelopeRoundTrip() throws {
        let rels = [Relationship.blocks(taskID: UUID()), Relationship.externalWait("later")]
        let data = try #require(RelationshipStore.encode(rels))
        #expect(RelationshipStore.decode(data) == rels)
    }

    // MARK: - Operation-sequence property test (the reopen×tombstone catcher)

    @Test("A seeded-random op sequence never diverges from the independent blocker oracle")
    func operationSequenceParity() {
        var rng = SeededRNG(seed: 0x5EED_1234)

        for _ in 0..<40 {
            let target = TaskItem(title: "target", status: .active)
            let pool = (0..<4).map { TaskItem(title: "b\($0)", status: .active) }
            let all = [target] + pool

            // Oracle: the durable set of blocker edges + which blocker tasks are open.
            var oracleEdges = Set<UUID>()
            var openTasks = Set(pool.compactMap(\.uuid))

            for _ in 0..<25 {
                switch rng.next() % 5 {
                case 0:  // add a random blocker
                    let b = pool[Int(rng.next() % UInt64(pool.count))]
                    target.addTaskBlocker(b.uuid!, among: all)
                    oracleEdges.insert(b.uuid!)
                case 1:  // remove a random current blocker
                    if let b = target.blockers.first(where: { $0.kind == .task }) {
                        target.removeBlocker(b.id, among: all)
                        oracleEdges.remove(b.taskID!)
                    }
                case 2:  // unblock everything
                    target.unblock()
                    oracleEdges.removeAll()
                case 3:  // complete a random open blocker task
                    let b = pool[Int(rng.next() % UInt64(pool.count))]
                    if openTasks.contains(b.uuid!) {
                        b.complete(now: Date())
                        openTasks.remove(b.uuid!)
                    }
                default:  // reopen a random resolved blocker task
                    let b = pool[Int(rng.next() % UInt64(pool.count))]
                    if !openTasks.contains(b.uuid!) {
                        b.reopen(among: all)
                        openTasks.insert(b.uuid!)
                    }
                }

                // The derived active-blocker set must equal edges ∩ open tasks, always.
                let derived = Set(target.activeBlockers(among: all).compactMap(\.taskID))
                #expect(derived == oracleEdges.intersection(openTasks))
            }
        }
    }
}

/// A tiny deterministic LCG so the property test is reproducible (no `Math.random`).
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 16
    }
}
