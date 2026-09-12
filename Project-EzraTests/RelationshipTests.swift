//
//  RelationshipTests.swift
//  Project-EzraTests
//
//  The `Relationship` blob is the graph's most load-bearing type — it absorbed the old
//  `blockersData` + `parentTaskID`. These lock the hardening measures: the derived
//  `blockers` view keeps the exact old Blocker semantics (durable list, external waits,
//  reopen re-blocks, cycle guard, unblock leaves `.parent`), the `Origin` invariants
//  hold, suppression keys are symmetric/directional by construction, the versioned
//  envelope round-trips, and — the real prize — an operation-sequence property test
//  runs the bridge against an independent oracle so a reopen×edge interaction can
//  never silently diverge.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Relationship graph bridge")
struct RelationshipTests {

    // MARK: - Blocker-bridge parity

    @Test("The decode cache never outlives the bytes: a blob written past the setter is re-read")
    func decodeCacheFollowsTheBytes() {
        // `relationships` decodes once per blob and serves the decode while the stored
        // bytes still equal the ones it came from. A CloudKit merge or a `refresh` writes
        // `relationshipsData` without touching the setter, so the cache must be keyed on
        // the BYTES, not on "has the setter run" — this simulates exactly that write.
        let target = TaskItem(title: "passport", status: .todo)
        let other = TaskItem(title: "visa", status: .todo)
        let task = TaskItem(title: "flights", status: .todo)
        let all = [target, other, task]
        task.addTaskBlocker(target.uuid!, among: all)
        #expect(task.taskBlockerIDs == [target.uuid!])

        let foreign = RelationshipStore.encode([.blocks(taskID: other.uuid!, origin: .human)])
        task.setValue(foreign, forKey: "relationshipsData")
        #expect(task.taskBlockerIDs == [other.uuid!])

        task.setValue(nil, forKey: "relationshipsData")
        #expect(task.relationships.isEmpty)
    }

    @Test("A tracked blocker is durable: it survives the target completing and re-blocks on reopen")
    func durableListReopen() {
        let target = TaskItem(title: "passport", status: .todo)
        let task = TaskItem(title: "flights", status: .todo)
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
        let task = TaskItem(title: "kitchen", status: .todo)
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
        let a = TaskItem(title: "a", status: .todo)
        let b = TaskItem(title: "b", status: .todo)
        let all = [a, b]
        a.addTaskBlocker(b.uuid!, among: all)  // a waits on b
        b.addTaskBlocker(a.uuid!, among: all)  // would close a cycle → no-op
        #expect(b.taskBlockerIDs.isEmpty)
    }

    @Test("unblock() drops the .blocks edges but leaves a .parent edge intact")
    func unblockLeavesParent() {
        let parent = TaskItem(title: "trip", status: .todo)
        let blocker = TaskItem(title: "passport", status: .todo)
        let task = TaskItem(title: "book hotel", status: .todo)
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
        let b1 = TaskItem(title: "b1", status: .todo)
        let b2 = TaskItem(title: "b2", status: .todo)
        let task = TaskItem(title: "x", status: .todo)
        let all = [task, b1, b2]
        task.addTaskBlocker(b1.uuid!, among: all)
        task.addTaskBlocker(b2.uuid!, among: all)
        let firstID = task.blockers.first { $0.taskID == b1.uuid! }!.id
        task.removeBlocker(firstID, among: all)
        #expect(task.taskBlockerIDs == [b2.uuid!])
    }

    // MARK: - Suppression keys (pair-owned, never edges)

    @Test("Duplicate suppression is symmetric by construction; parent stays directional")
    func suppressionKeySemantics() {
        let a = UUID()
        let b = UUID()
        let dup = RelationshipSuppression(
            kind: .duplicateMerge, pairKey: RelationshipSuppression.symmetricKey(a, b),
            targetID: nil, normalizedTitle: nil, createdAt: Date())
        // The same false pair can't come back from the other side.
        #expect(dup.suppressesPair(kind: .duplicateMerge, a, b))
        #expect(dup.suppressesPair(kind: .duplicateMerge, b, a))
        #expect(!dup.suppressesPair(kind: .parentLink, a, b))

        let parent = RelationshipSuppression(
            kind: .parentLink, pairKey: RelationshipSuppression.directionalKey(child: a, parent: b),
            targetID: nil, normalizedTitle: nil, createdAt: Date())
        // "A is not a child of B" implies nothing about the reverse.
        #expect(parent.suppressesPair(kind: .parentLink, a, b))
        #expect(!parent.suppressesPair(kind: .parentLink, b, a))
    }

    @Test("Capture-form suppression matches on normalized draft title, not raw text")
    func captureFormNormalization() {
        let target = UUID()
        let suppression = RelationshipSuppression(
            kind: .duplicateMerge, pairKey: nil, targetID: target,
            normalizedTitle: RelationshipSuppression.normalizeTitle("Renew — the Passport!"),
            createdAt: Date())
        #expect(
            suppression.suppresses(
                kind: .duplicateMerge, targetID: target,
                normalizedTitle: RelationshipSuppression.normalizeTitle("renew the passport")))
        #expect(
            !suppression.suppresses(
                kind: .duplicateMerge, targetID: target,
                normalizedTitle: RelationshipSuppression.normalizeTitle("book the flights")))
    }

    // MARK: - Invariant validation + envelope

    @Test("Invariant validation catches self-edges, dup pairs, bad targets, and bad confidence")
    func invariants() {
        let id = UUID()
        let other = UUID()
        // Self-edge.
        #expect(
            Relationship.firstViolation(
                in: [.blocks(taskID: id)], owner: id) != nil)
        // Duplicate (kind, target) pair.
        #expect(
            Relationship.firstViolation(
                in: [.blocks(taskID: other), .blocks(taskID: other)]) != nil)
        // nil target on a non-blocks edge.
        #expect(
            Relationship.firstViolation(in: [
                Relationship(kind: .parent, targetID: nil, origin: .human)
            ]) != nil)
        // Inferred confidence outside 0…1. (A human edge with a confidence is now
        // unrepresentable — `Origin.human` has no confidence to get wrong.)
        #expect(
            Relationship.firstViolation(in: [
                Relationship(kind: .blocks, targetID: other, origin: .inferred(confidence: 1.4))
            ]) != nil)
        // A clean list is valid.
        #expect(Relationship.firstViolation(in: [.blocks(taskID: other)], owner: id) == nil)
    }

    @Test("The static derivations match the instance accessors on arbitrary edge lists")
    func staticDerivationsMatchInstanceAccessors() {
        // The statics exist so a bulk pass can decode once and derive many views;
        // they must stay behaviorally identical to the accessors they back.
        var rng = SystemRandomNumberGenerator()
        let open = TaskItem(title: "open", status: .todo)
        let resolved = TaskItem(title: "done", status: .done)
        let parent = TaskItem(title: "umbrella", status: .todo)
        let all = [open, resolved, parent]

        for _ in 0..<20 {
            let task = TaskItem(title: "subject", status: .todo)
            if Bool.random(using: &rng) { task.addTaskBlocker(open.uuid!, among: all + [task]) }
            if Bool.random(using: &rng) { task.addTaskBlocker(resolved.uuid!, among: all + [task]) }
            if Bool.random(using: &rng) { task.addExternalBlocker("a wait", among: [task]) }
            if Bool.random(using: &rng) { task.linkParent(parent.uuid!) }

            let rels = task.relationships
            let openIDs = Set((all + [task]).filter { !$0.status.isResolved }.compactMap(\.uuid))
            #expect(TaskItem.blockers(from: rels) == task.blockers)
            #expect(TaskItem.parentTaskID(from: rels) == task.parentTaskID)
            #expect(
                TaskItem.activeBlockers(from: rels, openIDs: openIDs)
                    == task.activeBlockers(among: all + [task]))
        }
    }

    @Test("The versioned envelope round-trips")
    func envelopeRoundTrip() throws {
        let rels = [Relationship.blocks(taskID: UUID()), Relationship.externalWait("later")]
        let data = try #require(RelationshipStore.encode(rels))
        #expect(RelationshipStore.decode(data) == rels)
    }

    // MARK: - Operation-sequence property test (the reopen×edge catcher)

    @Test("A seeded-random op sequence never diverges from the independent blocker oracle")
    func operationSequenceParity() {
        var rng = SeededRNG(seed: 0x5EED_1234)

        for _ in 0..<40 {
            let target = TaskItem(title: "target", status: .todo)
            let pool = (0..<4).map { TaskItem(title: "b\($0)", status: .todo) }
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
