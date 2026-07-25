//
//  TodayQueriesTests.swift
//  Project-EzraTests
//
//  The pure membership behind the Today sequence. Recap counts only genuine
//  completions in-window; the docket is the deduped union of due-today / overdue /
//  needs-decision in stack order; chain detection powers routing. All under a fixed
//  clock — the same idiom as TaskRankingTests.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Today queries")
struct TodayQueriesTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func hours(_ n: Double) -> Date { now.addingTimeInterval(n * 3600) }
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 24 * 3600) }

    // MARK: - Recap

    @Test("Recap counts only tasks completed inside the window, newest first")
    func recapWindow() {
        let recent = TaskItem(title: "recent", status: .todo)
        recent.complete(now: hours(-1))
        let older = TaskItem(title: "older", status: .todo)
        older.complete(now: hours(-2))
        let stale = TaskItem(title: "stale", status: .todo)
        stale.complete(now: hours(-30))  // before the 24h window
        let killed = TaskItem(title: "killed", status: .todo)
        killed.kill(now: hours(-1))  // killed is not a celebration
        let open = TaskItem(title: "open", status: .todo)

        let recap = TodayQueries.recap(
            tasks: [older, recent, stale, killed, open], since: hours(-24), now: now)
        #expect(recap.count == 2)
        #expect(recap.completedTasks.map(\.title) == ["recent", "older"])
        #expect(!recap.isEmpty)
    }

    @Test("Empty recap is honest — no completions, no celebration")
    func recapEmpty() {
        let open = TaskItem(title: "open", status: .todo)
        let recap = TodayQueries.recap(tasks: [open], since: hours(-24), now: now)
        #expect(recap.isEmpty)
        #expect(recap.count == 0)
    }

    @Test("Cold-start window (start of today) counts today's completions, excludes yesterday's")
    func recapStartOfToday() {
        // A brand-new user has no `recapCutoff`, so the sequence uses start-of-today.
        let since = Calendar.current.startOfDay(for: now)
        let today = TaskItem(title: "today", status: .todo)
        today.complete(now: now)  // finished today → counts
        let yesterday = TaskItem(title: "yesterday", status: .todo)
        yesterday.complete(now: since.addingTimeInterval(-3600))  // before midnight → excluded
        let killedToday = TaskItem(title: "killed", status: .todo)
        killedToday.kill(now: since.addingTimeInterval(60))  // killed is never a celebration

        let recap = TodayQueries.recap(
            tasks: [today, yesterday, killedToday], since: since, now: now)
        #expect(recap.completedTasks.map(\.title) == ["today"])
        #expect(recap.count == 1)
    }

    // MARK: - Docket buckets

    @Test("Docket buckets: due today, overdue, needs-decision — resolved excluded")
    func docketBuckets() {
        let dueToday = TaskItem(title: "due today", status: .todo, dueDate: now)
        let overdue = TaskItem(title: "overdue", status: .todo, dueDate: days(-2))
        let decision = TaskItem(title: "decide", status: .todo, needsDecision: true)
        let future = TaskItem(title: "future", status: .todo, dueDate: days(3))
        let resolvedToday = TaskItem(title: "done today", status: .todo, dueDate: now)
        resolvedToday.complete(now: now)

        let docket = TodayQueries.docket(
            tasks: [dueToday, overdue, decision, future, resolvedToday], now: now)
        #expect(docket.dueToday.map(\.title) == ["due today"])
        #expect(docket.overdue.map(\.title) == ["overdue"])
        #expect(docket.needsDecision.map(\.title) == ["decide"])
        #expect(Set(docket.items.map(\.title)) == ["due today", "overdue", "decide"])
    }

    @Test("A task both overdue and needs-decision appears once, forced to the top")
    func docketDedupAndOrder() {
        let both = TaskItem(
            title: "both", status: .todo, needsDecision: true, dueDate: days(-1))
        let plainDue = TaskItem(title: "plain", status: .todo, dueDate: now, isUrgent: true)

        let docket = TodayQueries.docket(tasks: [plainDue, both], now: now)
        // Deduped: "both" is in overdue AND needsDecision but appears once.
        #expect(docket.items.filter { $0.title == "both" }.count == 1)
        // Needs Decision is forced top by the stack precedence.
        #expect(docket.items.first?.title == "both")
        #expect(docket.items.count == 2)
    }

    @Test("Empty docket when nothing is due, overdue, or awaiting a decision")
    func docketEmpty() {
        let calm = TaskItem(title: "someday", status: .todo)
        let docket = TodayQueries.docket(tasks: [calm], now: now)
        #expect(docket.isEmpty)
    }

    // MARK: - Chain detection

    @Test("A task both blocked and blocking is a chain; a single edge is not")
    func chainDetection() {
        // C waits on B waits on A → B is both blocked (by A) and blocking (C).
        let a = TaskItem(title: "a", status: .todo)
        let b = TaskItem(title: "b", status: .todo)
        let c = TaskItem(title: "c", status: .todo)
        let all = [a, b, c]
        b.addTaskBlocker(a.uuid!, among: all)
        c.addTaskBlocker(b.uuid!, among: all)
        #expect(TodayQueries.hasBlockedBlockingChain(all))

        // A single edge (B waits on A): nobody is both blocked and blocking.
        let x = TaskItem(title: "x", status: .todo)
        let y = TaskItem(title: "y", status: .todo)
        let pair = [x, y]
        y.addTaskBlocker(x.uuid!, among: pair)
        #expect(!TodayQueries.hasBlockedBlockingChain(pair))
    }
}
