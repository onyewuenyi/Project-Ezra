//
//  TaskRankingTests.swift
//  Project-EzraTests
//
//  The stack precedence is the Policy layer — how the hard bands + the AI-computed
//  attention SCORE manifest as position. Its ordering rules are product invariants:
//  Needs Decision forced top, then Blocked sunk, then attention score (desc) as the
//  primary sort, with Blocking and Overdue as boosts within equal score. The
//  comparator must also be a strict weak ordering, or `sorted(by:)` produces
//  undefined output.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Stack precedence ranking")
struct TaskRankingTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 24 * 3600) }

    /// Force a task's persisted attention score, isolating whichever component a test
    /// exercises from the score (the comparator reads `attention.score` directly).
    private func score(_ task: TaskItem, _ value: Double) -> TaskItem {
        task.attention = AttentionMetadata(score: value, contributors: [], computedAt: now)
        return task
    }

    private func precedes(_ a: TaskItem, _ b: TaskItem, among tasks: [TaskItem]) -> Bool {
        let keys = TaskRanking.rankKeys(for: tasks, now: now)
        return TaskRanking.stackOrder(keys[a.uuid!]!, keys[b.uuid!]!)
    }

    // MARK: - Precedence table

    @Test("1. Needs Decision beats everything — even an urgent, overdue, top-score task")
    func needsDecisionForcedTop() {
        let decision = score(
            TaskItem(title: "decide", status: .inbox, confidence: 0.3, needsDecision: true), 10)
        let urgentOverdue = score(
            TaskItem(title: "urgent late", status: .active, dueDate: days(-2), isUrgent: true), 100)
        let all = [decision, urgentOverdue]
        #expect(precedes(decision, urgentOverdue, among: all))
        #expect(!precedes(urgentOverdue, decision, among: all))
    }

    @Test("1a. A task both Blocked and Needs Decision still renders top — rule 1 wins")
    func needsDecisionOverridesBlocked() {
        let blocker = TaskItem(title: "blocker", status: .active)
        let blockedDecision = TaskItem(
            title: "blocked decision", status: .inbox, needsDecision: true, blockedBy: [blocker.uuid!])
        let plain = score(TaskItem(title: "plain", status: .active, isUrgent: true), 100)
        let all = [blocker, blockedDecision, plain]
        #expect(precedes(blockedDecision, plain, among: all))
    }

    @Test("2. Blocked sinks below everything unblocked, regardless of score")
    func blockedSinks() {
        let blocker = TaskItem(title: "blocker", status: .active)
        let blockedHot = score(
            TaskItem(title: "blocked hot", status: .active, blockedBy: [blocker.uuid!]), 95)
        let routine = score(TaskItem(title: "routine", status: .active), 10)
        let all = [blocker, blockedHot, routine]
        #expect(precedes(routine, blockedHot, among: all))
        #expect(!precedes(blockedHot, routine, among: all))
    }

    @Test("3. Attention score is the primary sort among unblocked, undecided tasks")
    func attentionScorePrimary() {
        let a = score(TaskItem(title: "a", status: .active), 90)
        let b = score(TaskItem(title: "b", status: .active), 60)
        let c = score(TaskItem(title: "c", status: .active), 40)
        let d = score(TaskItem(title: "d", status: .active), 35)
        let all = [d, c, b, a]
        let sorted = TaskRanking.sorted(all, now: now)
        #expect(sorted.map(\.title) == ["a", "b", "c", "d"])
    }

    @Test("4. Blocking boosts within equal score — but never overrides score")
    func blockingBoostsWithinScore() {
        let dependent = TaskItem(title: "dependent", status: .active)
        let blocking = TaskItem(title: "blocking", status: .active)
        dependent.addTaskBlocker(blocking.uuid!, among: [dependent, blocking])
        let peer = TaskItem(title: "peer", status: .active)
        let higher = TaskItem(title: "higher", status: .active)
        // Set scores AFTER wiring the blocker — addTaskBlocker recomputes the target's
        // attention (it gained a dependent), which would otherwise clobber these.
        _ = score(blocking, 50)
        _ = score(peer, 50)
        _ = score(higher, 70)
        let all = [dependent, blocking, peer, higher]
        #expect(precedes(blocking, peer, among: all))  // boost within equal score
        #expect(precedes(higher, blocking, among: all))  // score still wins
    }

    @Test("5. Overdue boosts within equal score — but never overrides score")
    func overdueBoostsWithinScore() {
        let overdue = score(
            TaskItem(title: "overdue", status: .active, dueDate: days(-1)), 50)
        let peer = score(TaskItem(title: "peer", status: .active), 50)
        let higher = score(TaskItem(title: "higher", status: .active), 70)
        let all = [overdue, peer, higher]
        #expect(precedes(overdue, peer, among: all))
        #expect(precedes(higher, overdue, among: all))
    }

    @Test("Then the calendar: soonest due first, undated last (equal score, no flags)")
    func dueDateFallback() {
        let soon = score(TaskItem(title: "soon", status: .active, dueDate: days(1)), 50)
        let later = score(TaskItem(title: "later", status: .active, dueDate: days(3)), 50)
        let undated = score(TaskItem(title: "undated", status: .active), 50)
        let all = [undated, later, soon]
        let sorted = TaskRanking.sorted(all, now: now)
        #expect(sorted.map(\.title) == ["soon", "later", "undated"])
    }

    // MARK: - Strict weak ordering (the crash guard)

    @Test("The comparator is a strict weak ordering over a shuffled adversarial set")
    func strictWeakOrdering() {
        let blocker = score(TaskItem(title: "blocker", status: .active), 70)
        var tasks: [TaskItem] = [blocker]
        // Build a set exercising every component: decisions, blocked, DUPLICATE
        // scores (the tie path), blocking, overdue, dated/undated.
        let scores: [Double] = [100, 70, 70, 40, 35, 35, 10]
        for (i, value) in scores.enumerated() {
            tasks.append(
                score(
                    TaskItem(
                        title: "p\(i)", status: .active,
                        dueDate: i.isMultiple(of: 2) ? days(Double(i - 2)) : nil,
                        isUrgent: i.isMultiple(of: 4),
                        createdAt: now), value))
            tasks.append(
                score(
                    TaskItem(
                        title: "d\(i)", status: .inbox, needsDecision: i.isMultiple(of: 2),
                        createdAt: now), value))
        }
        let blocked = score(
            TaskItem(title: "blocked", status: .active, blockedBy: [blocker.uuid!], isUrgent: true), 90)
        tasks.append(blocked)

        let keys = TaskRanking.rankKeys(for: tasks, now: now)
        let ranked = tasks.compactMap { $0.uuid.flatMap { keys[$0] } }
        #expect(ranked.count == tasks.count)

        // Irreflexivity + asymmetry + totality-of-equivalence over every pair.
        for a in ranked {
            #expect(!TaskRanking.stackOrder(a, a))
            for b in ranked {
                let ab = TaskRanking.stackOrder(a, b)
                let ba = TaskRanking.stackOrder(b, a)
                #expect(!(ab && ba))  // asymmetric
                if a.id != b.id {
                    #expect(ab || ba)  // the uuid tiebreak makes it total
                }
            }
        }
        // Transitivity over every triple.
        for a in ranked {
            for b in ranked where TaskRanking.stackOrder(a, b) {
                for c in ranked where TaskRanking.stackOrder(b, c) {
                    #expect(TaskRanking.stackOrder(a, c))
                }
            }
        }
    }

    // MARK: - Rank bands (internal)

    @Test(
        "Band: needsDecision and overdue are critical; due today/tomorrow + urgent important; rest routine"
    )
    func bandAssignment() {
        let decision = TaskItem(title: "d", status: .inbox, needsDecision: true)
        #expect(TaskRanking.band(for: decision, isBlocked: false, now: now) == .critical)

        let overdue = TaskItem(title: "o", status: .active, dueDate: days(-1))
        #expect(TaskRanking.band(for: overdue, isBlocked: false, now: now) == .critical)

        let dueTomorrow = TaskItem(title: "t", status: .active, dueDate: days(1))
        #expect(TaskRanking.band(for: dueTomorrow, isBlocked: false, now: now) == .important)

        let urgentUndated = TaskItem(title: "u", status: .active, isUrgent: true)
        #expect(TaskRanking.band(for: urgentUndated, isBlocked: false, now: now) == .important)

        let routine = TaskItem(title: "r", status: .active)
        #expect(TaskRanking.band(for: routine, isBlocked: false, now: now) == .routine)

        // Blocked work can't demand today's attention (unless it needs a decision).
        let blockedUrgent = TaskItem(title: "b", status: .active, isUrgent: true)
        #expect(TaskRanking.band(for: blockedUrgent, isBlocked: true, now: now) == .routine)

        // Resolved tasks are always routine.
        let resolved = TaskItem(title: "x", status: .active, dueDate: days(-3))
        resolved.complete(now: now)
        #expect(TaskRanking.band(for: resolved, isBlocked: false, now: now) == .routine)
    }

    // MARK: - Quick wins

    @Test("Quick win: small effort, active, unblocked, unowned-clear, no decision pending")
    func quickWinPredicate() {
        let quick = TaskItem(title: "call mom", status: .active, effortMinutes: 15)
        #expect(TaskRanking.isQuickWin(quick, isBlocked: false))

        let big = TaskItem(title: "renovate", status: .active, effortMinutes: 120)
        #expect(!TaskRanking.isQuickWin(big, isBlocked: false))

        let unestimated = TaskItem(title: "vague", status: .active)
        #expect(!TaskRanking.isQuickWin(unestimated, isBlocked: false))

        #expect(!TaskRanking.isQuickWin(quick, isBlocked: true))

        let inbox = TaskItem(title: "new", status: .inbox, effortMinutes: 10)
        #expect(!TaskRanking.isQuickWin(inbox, isBlocked: false))

        let decision = TaskItem(
            title: "decide", status: .active, needsDecision: true, effortMinutes: 10)
        #expect(!TaskRanking.isQuickWin(decision, isBlocked: false))
    }
}
