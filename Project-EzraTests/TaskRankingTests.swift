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
            TaskItem(title: "decide", status: .todo, confidence: 0.3, needsDecision: true), 10)
        let urgentOverdue = score(
            TaskItem(title: "urgent late", status: .todo, dueDate: days(-2), isUrgent: true), 100)
        let all = [decision, urgentOverdue]
        #expect(precedes(decision, urgentOverdue, among: all))
        #expect(!precedes(urgentOverdue, decision, among: all))
    }

    @Test("1a. A task both Blocked and Needs Decision still renders top — rule 1 wins")
    func needsDecisionOverridesBlocked() {
        let blocker = TaskItem(title: "blocker", status: .todo)
        let blockedDecision = TaskItem(
            title: "blocked decision", status: .todo, needsDecision: true, blockedBy: [blocker.uuid!])
        let plain = score(TaskItem(title: "plain", status: .todo, isUrgent: true), 100)
        let all = [blocker, blockedDecision, plain]
        #expect(precedes(blockedDecision, plain, among: all))
    }

    @Test("2. Blocked sinks below everything unblocked, regardless of score")
    func blockedSinks() {
        let blocker = TaskItem(title: "blocker", status: .todo)
        let blockedHot = score(
            TaskItem(title: "blocked hot", status: .todo, blockedBy: [blocker.uuid!]), 95)
        let routine = score(TaskItem(title: "routine", status: .todo), 10)
        let all = [blocker, blockedHot, routine]
        #expect(precedes(routine, blockedHot, among: all))
        #expect(!precedes(blockedHot, routine, among: all))
    }

    @Test("3. Attention score is the primary sort among unblocked, undecided tasks")
    func attentionScorePrimary() {
        let a = score(TaskItem(title: "a", status: .todo), 90)
        let b = score(TaskItem(title: "b", status: .todo), 60)
        let c = score(TaskItem(title: "c", status: .todo), 40)
        let d = score(TaskItem(title: "d", status: .todo), 35)
        let all = [d, c, b, a]
        let sorted = TaskRanking.sorted(all, now: now)
        #expect(sorted.map(\.title) == ["a", "b", "c", "d"])
    }

    @Test("4. Blocking boosts within equal score — but never overrides score")
    func blockingBoostsWithinScore() {
        let dependent = TaskItem(title: "dependent", status: .todo)
        let blocking = TaskItem(title: "blocking", status: .todo)
        dependent.addTaskBlocker(blocking.uuid!, among: [dependent, blocking])
        let peer = TaskItem(title: "peer", status: .todo)
        let higher = TaskItem(title: "higher", status: .todo)
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
            TaskItem(title: "overdue", status: .todo, dueDate: days(-1)), 50)
        let peer = score(TaskItem(title: "peer", status: .todo), 50)
        let higher = score(TaskItem(title: "higher", status: .todo), 70)
        let all = [overdue, peer, higher]
        #expect(precedes(overdue, peer, among: all))
        #expect(precedes(higher, overdue, among: all))
    }

    @Test("Then the calendar: soonest due first, undated last (equal score, no flags)")
    func dueDateFallback() {
        let soon = score(TaskItem(title: "soon", status: .todo, dueDate: days(1)), 50)
        let later = score(TaskItem(title: "later", status: .todo, dueDate: days(3)), 50)
        let undated = score(TaskItem(title: "undated", status: .todo), 50)
        let all = [undated, later, soon]
        let sorted = TaskRanking.sorted(all, now: now)
        #expect(sorted.map(\.title) == ["soon", "later", "undated"])
    }

    // MARK: - currentRelevance (the live layer inside the attention component)

    @Test("The live down-pull orders a neglected task below its peer within the band")
    func stalenessPullsDown() {
        // This was `deferralPullsDown` until 2026-09-12. It set `deferralCount = 5` — a
        // field the app has been unable to write since the Brief was cut — so it proved
        // the comparator reacts to a number nothing produces. The term it tested is gone;
        // the PROPERTY it was really protecting is that a down-pull exists and orders
        // correctly inside a band, and staleness is the live one.
        let neglected = score(
            TaskItem(title: "neglected", status: .todo, createdAt: days(-30)), 50)
        let peer = score(TaskItem(title: "peer", status: .todo, createdAt: now), 50)
        let all = [neglected, peer]
        #expect(precedes(peer, neglected, among: all))
        #expect(!precedes(neglected, peer, among: all))
    }

    @Test("Staleness reads the human clock — a system touch doesn't reset the decay")
    func stalenessHumanClock() {
        let dormant = score(TaskItem(title: "dormant", status: .todo, createdAt: days(-30)), 50)
        dormant.touch(now: days(-1))  // a system path bumped updatedAt; no human ever touched it
        let fresh = score(TaskItem(title: "fresh", status: .todo, createdAt: days(-30)), 50)
        fresh.touchHuman(now: now)
        let all = [dormant, fresh]
        #expect(precedes(fresh, dormant, among: all))  // dormant decayed ~30d despite the touch
    }

    @Test("A recent unblock boosts within the window; an old one doesn't")
    func recentUnblock() {
        let justFreed = score(TaskItem(title: "freed", status: .todo, createdAt: now), 50)
        justFreed.lastUnblockedAt = days(-1)  // inside the 48h window
        let longAgo = score(TaskItem(title: "old", status: .todo, createdAt: now), 50)
        longAgo.lastUnblockedAt = days(-5)  // outside — no boost
        let peer = score(TaskItem(title: "peer", status: .todo, createdAt: now), 50)
        let all = [justFreed, longAgo, peer]
        #expect(precedes(justFreed, peer, among: all))
        #expect(precedes(justFreed, longAgo, among: all))
    }

    // MARK: - The start commitment (`.doing` as a live signal, not a glyph color)

    /// Build a task that entered `.doing` at a specific moment, through the real
    /// transition path so the `StateVisit` the boost reads is genuine.
    private func started(_ title: String, at when: Date, createdAt: Date? = nil) -> TaskItem {
        let task = TaskItem(title: title, status: .todo, createdAt: createdAt ?? when)
        task.transition(to: .doing, now: when)
        return task
    }

    private func relevance(_ task: TaskItem) -> Double {
        TaskRanking.currentRelevance(
            for: task, now: now, recentlyGainedDependent: false, neighborDueDates: [])
    }

    @Test("Picking a task up boosts it — finishing beats starting")
    func startedWorkRises() {
        let inFlight = score(started("in flight", at: now.addingTimeInterval(-3600)), 50)
        let peer = score(TaskItem(title: "peer", status: .todo, createdAt: now), 50)
        let all = [inFlight, peer]
        #expect(precedes(inFlight, peer, among: all))
        #expect(!precedes(peer, inFlight, among: all))
    }

    @Test("The boost expires with the window — abandoned in-flight work stops floating")
    func startedBoostExpires() {
        // Same creation date, so staleness is identical and only the boost differs.
        let born = days(-30)
        let fresh = started("fresh", at: now.addingTimeInterval(-3600), createdAt: born)
        let abandoned = started("abandoned", at: days(-14), createdAt: born)
        #expect(relevance(fresh) - relevance(abandoned) == TaskRanking.startedBoost)
    }

    @Test("The boost reads the CURRENT visit, not summed dwell across every visit")
    func startedBoostReadsOpenVisit() {
        // Worked on for days a fortnight ago, dropped, and only just picked back up.
        // `secondsIn(.doing)` is enormous here; the live commitment is an hour old.
        let task = TaskItem(title: "resumed", status: .todo, createdAt: days(-30))
        task.transition(to: .doing, now: days(-14))
        task.transition(to: .todo, now: days(-11))
        task.transition(to: .doing, now: now.addingTimeInterval(-3600))
        #expect(task.secondsIn(.doing, now: now) > TaskRanking.recentWindow)

        let peer = TaskItem(title: "peer", status: .todo, createdAt: days(-30))
        #expect(relevance(task) - relevance(peer) == TaskRanking.startedBoost)
    }

    @Test("A todo task gets no start boost — the signal is the commitment, not the age")
    func todoGetsNoStartBoost() {
        let todo = TaskItem(title: "todo", status: .todo, createdAt: now)
        #expect(relevance(todo) == 0)
    }

    @Test("The start boost lives in the live layer, never in the persisted score")
    func startBoostNeverTouchesAttention() {
        // The band must stay fact-fed: `.doing` is the fastest fact in the system, so
        // it must not reach `AttentionMetadata`, only `currentRelevance`.
        let task = started("in flight", at: now)
        AttentionEngine.recompute([task], among: [task])
        let inFlightScore = task.attention.score

        let peer = TaskItem(title: "peer", status: .todo, createdAt: now)
        AttentionEngine.recompute([peer], among: [peer])
        #expect(inFlightScore == peer.attention.score)
    }

    @Test("currentRelevance clamps to ±25 in both directions")
    func relevanceClamp() {
        // A year untouched: staleness alone saturates the clamp several times over.
        let buried = TaskItem(title: "buried", status: .todo, createdAt: days(-365))
        let down = TaskRanking.currentRelevance(
            for: buried, now: now, recentlyGainedDependent: false, neighborDueDates: [])
        #expect(down == -TaskRanking.relevanceClamp)

        let hot = TaskItem(title: "hot", status: .todo, createdAt: now)
        hot.lastUnblockedAt = now
        let up = TaskRanking.currentRelevance(
            for: hot, now: now, recentlyGainedDependent: true, neighborDueDates: [now])
        #expect(up == TaskRanking.relevanceClamp)  // 12 + 8 + 15 = 35, clamped
    }

    @Test("Passport scenario: dormant high-importance sinks, then rises when flights get booked")
    func passportScenario() {
        // Dormant 20 days: intrinsic importance stays high, relevance is deeply negative.
        let passport = score(
            TaskItem(title: "Renew passport", status: .todo, createdAt: days(-20)), 70)
        let errand = score(TaskItem(title: "errand", status: .todo, createdAt: now), 60)
        // While dormant, the lower-importance errand outranks it (70 − 12 < 60).
        #expect(precedes(errand, passport, among: [passport, errand]))

        // Flights get booked: a near-due task now waits on the passport — a fresh
        // reverse edge (recently-gained dependent) plus a related deadline approaching.
        let flights = score(
            TaskItem(title: "Book flights", status: .todo, dueDate: days(2), createdAt: now), 40)
        flights.relationships = [
            Relationship(
                kind: .blocks, targetID: passport.uuid!, note: nil, origin: .human, createdAt: days(-1))
        ]
        let all = [passport, errand, flights]
        // −12 (stale) + 8 (new dependent) + 13 (due in 2d) = +9 → 79 beats 60.
        #expect(precedes(passport, errand, among: all))
    }

    // MARK: - Strict weak ordering (the crash guard)

    @Test("The comparator is a strict weak ordering over a shuffled adversarial set")
    func strictWeakOrdering() {
        let blocker = score(TaskItem(title: "blocker", status: .todo), 70)
        var tasks: [TaskItem] = [blocker]
        // Build a set exercising every component: decisions, blocked, DUPLICATE
        // scores (the tie path), blocking, overdue, dated/undated.
        let scores: [Double] = [100, 70, 70, 40, 35, 35, 10]
        for (i, value) in scores.enumerated() {
            tasks.append(
                score(
                    TaskItem(
                        title: "p\(i)", status: .todo,
                        dueDate: i.isMultiple(of: 2) ? days(Double(i - 2)) : nil,
                        isUrgent: i.isMultiple(of: 4),
                        createdAt: now), value))
            tasks.append(
                score(
                    TaskItem(
                        title: "d\(i)", status: .todo, needsDecision: i.isMultiple(of: 2),
                        createdAt: now), value))
        }
        let blocked = score(
            TaskItem(title: "blocked", status: .todo, blockedBy: [blocker.uuid!], isUrgent: true), 90)
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
        let decision = TaskItem(title: "d", status: .todo, needsDecision: true)
        #expect(TaskRanking.band(for: decision, isBlocked: false, now: now) == .critical)

        let overdue = TaskItem(title: "o", status: .todo, dueDate: days(-1))
        #expect(TaskRanking.band(for: overdue, isBlocked: false, now: now) == .critical)

        let dueTomorrow = TaskItem(title: "t", status: .todo, dueDate: days(1))
        #expect(TaskRanking.band(for: dueTomorrow, isBlocked: false, now: now) == .important)

        let urgentUndated = TaskItem(title: "u", status: .todo, isUrgent: true)
        #expect(TaskRanking.band(for: urgentUndated, isBlocked: false, now: now) == .important)

        let routine = TaskItem(title: "r", status: .todo)
        #expect(TaskRanking.band(for: routine, isBlocked: false, now: now) == .routine)

        // Blocked work can't demand today's attention (unless it needs a decision).
        let blockedUrgent = TaskItem(title: "b", status: .todo, isUrgent: true)
        #expect(TaskRanking.band(for: blockedUrgent, isBlocked: true, now: now) == .routine)

        // Resolved tasks are always routine.
        let resolved = TaskItem(title: "x", status: .todo, dueDate: days(-3))
        resolved.complete(now: now)
        #expect(TaskRanking.band(for: resolved, isBlocked: false, now: now) == .routine)
    }

    // MARK: - Quick wins

    @Test("Quick win: small effort, live, unblocked, owned, no decision pending")
    func quickWinPredicate() {
        let me = UUID()
        let quick = TaskItem(title: "call mom", status: .todo, ownerID: me, effortMinutes: 15)
        #expect(TaskRanking.isQuickWin(quick, isBlocked: false))

        let big = TaskItem(title: "renovate", status: .todo, ownerID: me, effortMinutes: 120)
        #expect(!TaskRanking.isQuickWin(big, isBlocked: false))

        let unestimated = TaskItem(title: "vague", status: .todo, ownerID: me)
        #expect(!TaskRanking.isQuickWin(unestimated, isBlocked: false))

        #expect(!TaskRanking.isQuickWin(quick, isBlocked: true))

        // Resolved work is a record, never a quick win.
        let done = TaskItem(title: "old", status: .done, ownerID: me, effortMinutes: 10)
        #expect(!TaskRanking.isQuickWin(done, isBlocked: false))

        // Handed back to the household: it is nobody's quick win until someone takes it.
        let unowned = TaskItem(title: "up for grabs", status: .todo, effortMinutes: 10)
        #expect(!TaskRanking.isQuickWin(unowned, isBlocked: false))

        let decision = TaskItem(
            title: "decide", status: .todo, needsDecision: true, ownerID: me, effortMinutes: 10)
        #expect(!TaskRanking.isQuickWin(decision, isBlocked: false))
    }
}
