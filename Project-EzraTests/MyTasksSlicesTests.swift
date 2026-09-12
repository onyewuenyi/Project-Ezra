//
//  MyTasksSlicesTests.swift
//  Project-EzraTests
//
//  The pure slicing behind "My Tasks": Assigned sections (owned by me, chain-grouped,
//  sectioned by the ANCHOR's display status in focus order) and Created (authored by
//  me, newest first, flat), plus the filter predicate that keeps the Done/Canceled
//  ledger reachable.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("My Tasks slices")
struct MyTasksSlicesTests {

    // MARK: - Assigned sectioning

    @Test("assigned groups my tasks into display-status sections, in focus order")
    func assignedSections() {
        let me = UUID()
        let ip = TaskItem(title: "ip", status: .doing, ownerID: me)
        let todo = TaskItem(title: "todo", status: .todo, ownerID: me)
        let backlog = TaskItem(title: "bl", status: .todo, ownerID: me)  // inbox → Backlog
        let notMine = TaskItem(title: "nm", status: .todo, ownerID: UUID())
        let tasks = [todo, backlog, ip, notMine]

        let sections = MyTasksSlices.assigned(tasks: tasks, currentUserID: me)
        #expect(sections.map(\.status) == [.doing, .todo])
        // The not-mine task never appears in any section.
        let allTitles = sections.flatMap { $0.entries }.compactMap { entry -> String? in
            if case .single(let t) = entry { return t.title }
            return nil
        }
        #expect(!allTitles.contains("nm"))
    }

    @Test("a dependency chain sections once, by its anchor's display status")
    func chainSectionsByAnchor() {
        let me = UUID()
        let root = TaskItem(title: "root", status: .doing, ownerID: me)
        let dep = TaskItem(
            title: "dep", status: .todo, blockedBy: [root.uuid!], ownerID: me)
        let sections = MyTasksSlices.assigned(tasks: [root, dep], currentUserID: me)

        // A single chain entry, sectioned under the anchor (root) — In Progress.
        #expect(sections.count == 1)
        #expect(sections[0].status == .doing)
        guard case .chain = sections[0].entries[0] else {
            Issue.record("expected a chain entry")
            return
        }
    }

    @Test("The ledger reads newest-resolved first, and the inline cap keeps the most recent")
    func ledgerOrdersByResolution() {
        let me = UUID()
        let now = Date()
        // Seven done tasks, resolved at distinct times, inserted in scrambled order.
        let tasks: [TaskItem] = (0..<7).map { i in
            let t = TaskItem(title: "done \(i)", status: .todo, ownerID: me)
            t.complete(now: now.addingTimeInterval(-Double(i) * 3600))
            return t
        }.shuffled()
        let sections = MyTasksSlices.assigned(tasks: tasks, currentUserID: me)
        #expect(sections.count == 1)
        let ledger = sections[0]
        #expect(ledger.status == .done)
        // Five inline, and they are the five MOST RECENT, newest first — a record of what
        // was just finished, never the five highest-scoring.
        #expect(ledger.entries.map(\.anchor.title) == ["done 0", "done 1", "done 2", "done 3", "done 4"])
        #expect(ledger.hiddenCount == 2)
    }

    @Test("Needs Decision floats to the top within its section")
    func needsDecisionFloatsInSection() {
        let me = UUID()
        let plain = TaskItem(title: "plain", status: .todo, ownerID: me)
        let decide = TaskItem(
            title: "decide", status: .todo, needsDecision: true, ownerID: me)
        let sections = MyTasksSlices.assigned(tasks: [plain, decide], currentUserID: me)
        let todoSection = try? #require(sections.first { $0.status == .todo })
        guard case .single(let first)? = todoSection?.entries.first else {
            Issue.record("expected a single row")
            return
        }
        #expect(first.title == "decide")
    }

    // MARK: - Created ordering

    @Test("created returns my authored tasks newest first, across all statuses")
    func createdOrdering() {
        let me = UUID()
        let old = TaskItem(
            title: "old", status: .todo, creatorID: me,
            createdAt: Date(timeIntervalSinceNow: -1000))
        let recent = TaskItem(title: "new", status: .done, creatorID: me, createdAt: Date())
        let notMine = TaskItem(title: "nm", status: .todo, creatorID: UUID(), createdAt: Date())
        let result = MyTasksSlices.created(tasks: [old, recent, notMine], currentUserID: me)
        #expect(result.map(\.title) == ["new", "old"])
    }

    @Test("createdEntries orders by anchor createdAt descending (flat, all statuses)")
    func createdEntriesOrdering() {
        let me = UUID()
        let old = TaskItem(
            title: "old", status: .todo, creatorID: me,
            createdAt: Date(timeIntervalSinceNow: -1000))
        let recent = TaskItem(title: "new", status: .done, creatorID: me, createdAt: Date())
        let notMine = TaskItem(title: "nm", status: .todo, creatorID: UUID(), createdAt: Date())
        let entries = MyTasksSlices.createdEntries(tasks: [old, recent, notMine], currentUserID: me)
        #expect(entries.map { $0.anchor.title } == ["new", "old"])
    }

    @Test("createdEntries stacks a dependency chain into a single entry")
    func createdEntriesChains() {
        let me = UUID()
        let root = TaskItem(title: "root", status: .todo, creatorID: me, createdAt: Date())
        let dep = TaskItem(
            title: "dep", status: .todo, creatorID: me, blockedBy: [root.uuid!], createdAt: Date())
        let entries = MyTasksSlices.createdEntries(tasks: [root, dep], currentUserID: me)
        #expect(entries.count == 1)
        guard case .chain = entries[0] else {
            Issue.record("expected a chain entry")
            return
        }
    }

    @Test("created ignores a task with no author (nil creatorID never matches)")
    func createdIgnoresUnauthored() {
        let me = UUID()
        let orphan = TaskItem(title: "orphan", status: .todo)  // creatorID nil
        #expect(MyTasksSlices.created(tasks: [orphan], currentUserID: me).isEmpty)
        // …and a nil current user never matches an authored task either.
        let mine = TaskItem(title: "mine", status: .todo, creatorID: me)
        #expect(MyTasksSlices.created(tasks: [mine], currentUserID: nil).isEmpty)
    }

    // MARK: - Filters

    @Test("applyFilters narrows by display status and category")
    func filters() {
        let work = TaskItem(title: "w", category: "Work", status: .todo)
        #expect(MyTasksSlices.applyFilters(work, status: .todo, category: "Work"))
        #expect(!MyTasksSlices.applyFilters(work, status: .done, category: nil))
        #expect(!MyTasksSlices.applyFilters(work, status: nil, category: "Home"))
        #expect(MyTasksSlices.applyFilters(work, status: nil, category: nil))
    }

    @Test("a Done filter surfaces the Done ledger (the retired Completed slice's job)")
    func assignedDoneFilter() {
        let me = UUID()
        let active = TaskItem(title: "a", status: .todo, ownerID: me)
        let done = TaskItem(title: "d", status: .todo, ownerID: me)
        done.complete()
        let sections = MyTasksSlices.assigned(tasks: [active, done], currentUserID: me, status: .done)
        #expect(sections.map(\.status) == [.done])
        #expect(sections[0].entries.count == 1)
    }

    // MARK: - Header contract (the two dimensions, and which one the roster may touch)

    @Test("The filter is reachable at EVERY roster size — it is not a multiplayer feature")
    func filterIsAlwaysReachable() {
        // The regression this pins: the filter menu used to be nested inside the
        // selected tab's pill, so when the tab bar became roster-conditional a solo
        // household silently lost filtering entirely. A solo user needs it MORE — it
        // is the only list they have.
        for roster in 0...5 {
            #expect(MyTasksHeader.showsFilter(othersRoster: roster))
        }
    }

    @Test("Ownership tabs are the roster-dependent half — and the ONLY one")
    func tabsFollowTheRoster() {
        // Stated next to the test above on purpose: the asymmetry is the contract.
        #expect(!MyTasksHeader.showsTabs(othersRoster: 0))
        #expect(MyTasksHeader.showsTabs(othersRoster: 1))
        #expect(MyTasksHeader.showsTabs(othersRoster: 4))
    }

    @Test("The title's possessive follows the roster in lockstep with the ownership tabs")
    func titleFollowsTheSameRosterRuleAsTabs() {
        // "My" and the Assigned/Created pair answer the same question ("whose tasks?"),
        // so they must appear together. A title that says "My Tasks" over a header
        // making no ownership distinction promises a filter that isn't there — the
        // v2 lean collapse dropped the possessive for exactly that reason.
        for roster in 0...5 {
            let showsTabs = MyTasksHeader.showsTabs(othersRoster: roster)
            let title = MyTasksHeader.title(othersRoster: roster)
            #expect(title == (showsTabs ? "My Tasks" : "Tasks"))
        }
        #expect(MyTasksHeader.title(othersRoster: 0) == "Tasks")
        #expect(MyTasksHeader.title(othersRoster: 1) == "My Tasks")
        // The possessive follows the SELECTED scope too: "My Tasks" over the household's
        // whole list is the same lie in the other direction. Solo, there is no scope.
        #expect(MyTasksHeader.title(othersRoster: 1, tab: .everyone) == "Our Tasks")
        #expect(MyTasksHeader.title(othersRoster: 1, tab: .created) == "My Tasks")
        #expect(MyTasksHeader.title(othersRoster: 0, tab: .everyone) == "Tasks")
    }

    @Test("Everyone is the household's whole list — every owner and the unowned, sectioned like Assigned")
    func everyoneIsTheSharedScope() {
        let me = UUID()
        let partner = UUID()
        let mine = TaskItem(title: "mine", status: .doing, ownerID: me)
        let theirs = TaskItem(title: "theirs", status: .todo, ownerID: partner)
        let nobodys = TaskItem(title: "nobodys", status: .todo, ownerID: nil)
        let tasks = [nobodys, theirs, mine]

        let assigned = MyTasksSlices.assigned(tasks: tasks, currentUserID: me)
        #expect(assigned.flatMap(\.entries).map(\.anchor.title) == ["mine"])

        let everyone = MyTasksSlices.everyone(tasks: tasks)
        #expect(everyone.map(\.status) == [.doing, .todo])
        #expect(Set(everyone.flatMap(\.entries).map(\.anchor.title)) == ["mine", "theirs", "nobodys"])
        // The same predicate narrows both scopes.
        let done = MyTasksSlices.everyone(tasks: tasks, status: .done)
        #expect(done.isEmpty)
    }

    @Test("Everyone sits between Assigned and Created — widest scope in the middle")
    func everyoneTabOrder() {
        #expect(MyTasksTab.allCases == [.assigned, .everyone, .created])
    }

    @Test("The filter control names its own state, and stays bounded when both axes are set")
    func filterSummaryNamesItsState() {
        #expect(MyTasksHeader.filterSummary(status: nil, category: nil) == nil)
        #expect(MyTasksHeader.filterSummary(status: .done, category: nil) == "Done")
        #expect(MyTasksHeader.filterSummary(status: .doing, category: nil) == "In Progress")
        #expect(MyTasksHeader.filterSummary(status: nil, category: "Work") == "Work")
        // Both axes collapse to a count rather than concatenating — "Done · Work" would
        // grow the control without bound and fight the tabs for width.
        #expect(MyTasksHeader.filterSummary(status: .done, category: "Work") == "2 filters")
    }

    @Test("An empty filtered list names the filter — and says nothing when no filter is on")
    func filteredEmptyMessageNamesTheFilter() {
        // A filtered list that matched nothing is indistinguishable from a list with
        // tasks missing; the message is where the distinction is made.
        #expect(MyTasksHeader.filteredEmptyMessage(status: nil, category: nil) == nil)
        #expect(MyTasksHeader.filteredEmptyMessage(status: .done, category: nil) == "No tasks match “Done”.")
        #expect(MyTasksHeader.filteredEmptyMessage(status: nil, category: "Home") == "No tasks match “Home”.")
        #expect(
            MyTasksHeader.filteredEmptyMessage(status: .done, category: "Home")
                == "No tasks match both filters.")
    }

    // MARK: - Detail-pager peers (what a swipe in the full-screen detail lands on)

    @Test("flatten walks sections top-to-bottom, entries in place")
    func peersFollowSectionOrder() {
        let me = UUID()
        let ip = TaskItem(title: "ip", status: .doing, ownerID: me)
        let todo = TaskItem(title: "todo", status: .todo, ownerID: me)
        let done = TaskItem(title: "done", status: .doing, ownerID: me)
        done.complete()
        let sections = MyTasksSlices.assigned(tasks: [done, todo, ip], currentUserID: me)

        // Same order the eye reads: In Progress → Todo → Done.
        #expect(TaskDetailPeers.flatten(sections).map(\.title) == ["ip", "todo", "done"])
    }

    @Test("flatten unrolls a chain stack root-first, where the stack sits")
    func peersUnrollChains() {
        let me = UUID()
        let root = TaskItem(title: "root", status: .todo, ownerID: me)
        let dep = TaskItem(
            title: "dep", status: .todo, blockedBy: [root.uuid!], ownerID: me)
        let loose = TaskItem(title: "loose", status: .todo, ownerID: me)
        let sections = MyTasksSlices.assigned(tasks: [root, dep, loose], currentUserID: me)
        let peers = TaskDetailPeers.flatten(sections)

        // Both chain members are reachable, blocker before what waits on it, and the
        // loose task is still in the list exactly once.
        #expect(Set(peers.map(\.title)) == ["root", "dep", "loose"])
        let rootIndex = try? #require(peers.firstIndex { $0.title == "root" })
        let depIndex = try? #require(peers.firstIndex { $0.title == "dep" })
        #expect(rootIndex! < depIndex!)
    }

    @Test("flatten preserves the Created tab's newest-first order")
    func peersFollowCreatedOrder() {
        let me = UUID()
        let old = TaskItem(
            title: "old", status: .todo, creatorID: me, createdAt: Date(timeIntervalSinceNow: -1000))
        let recent = TaskItem(title: "new", status: .todo, creatorID: me, createdAt: Date())
        let entries = MyTasksSlices.createdEntries(tasks: [old, recent], currentUserID: me)
        #expect(TaskDetailPeers.flatten(entries).map(\.title) == ["new", "old"])
    }

    @Test("flatten of an empty surface yields no peers (the detail stays a single page)")
    func peersEmpty() {
        #expect(TaskDetailPeers.flatten([MyTasksSection]()).isEmpty)
        #expect(TaskDetailPeers.flatten([TaskLaneEntry]()).isEmpty)
    }
    @Test("The ledger caps inline; the filter — its documented isolation path — uncaps it")
    func resolvedSectionsCapInline() {
        let context = TestStore.makeContext()
        let me = UserProfile.currentMemberID(in: context)
        for n in 0..<8 {
            let task = TaskItem(title: "Done \(n)", status: .todo, ownerID: me, in: context)
            task.complete()
        }
        for n in 0..<7 {
            _ = TaskItem(title: "Open \(n)", status: .todo, ownerID: me, in: context)
        }
        let tasks = TaskItem.fetchAll(in: context)

        let sections = MyTasksSlices.assigned(tasks: tasks, currentUserID: me)
        let done = sections.first { $0.status == .done }
        let todo = sections.first { $0.status == .todo }
        #expect(done?.entries.count == MyTasksSlices.resolvedInlineCap)
        #expect(done?.hiddenCount == 8 - MyTasksSlices.resolvedInlineCap)
        // The live pipeline is NEVER capped — the cap exists for the graveyard, and a
        // capped pipeline would hide work the ranking put there on purpose.
        #expect(todo?.entries.count == 7)
        #expect(todo?.hiddenCount == 0)

        // Picking Done from the filter is precisely "show me the ledger".
        let filtered = MyTasksSlices.assigned(tasks: tasks, currentUserID: me, status: .done)
        #expect(filtered.first { $0.status == .done }?.entries.count == 8)
        #expect(filtered.first { $0.status == .done }?.hiddenCount == 0)
    }

}
