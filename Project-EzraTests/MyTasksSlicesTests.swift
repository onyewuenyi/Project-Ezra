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
        #expect(sections.map(\.kind) == [.status(.doing), .status(.todo)])
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
        #expect(sections[0].kind == .status(.doing))
        guard case .chain = sections[0].entries[0] else {
            Issue.record("expected a chain entry")
            return
        }
    }

    @Test("Needs Decision floats to the top within its section")
    func needsDecisionFloatsInSection() {
        let me = UUID()
        let plain = TaskItem(title: "plain", status: .todo, ownerID: me)
        let decide = TaskItem(
            title: "decide", status: .todo, needsDecision: true, ownerID: me)
        let sections = MyTasksSlices.assigned(tasks: [plain, decide], currentUserID: me)
        let todoSection = try? #require(sections.first { $0.kind == .status(.todo) })
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
        #expect(sections.map(\.kind) == [.status(.done)])
        #expect(sections[0].entries.count == 1)
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

    @Test("A LIVE reference item gets its own section, never Todo")
    func referenceSectionsSeparately() {
        let me = UUID()
        let todo = TaskItem(title: "todo", status: .todo, ownerID: me)
        let note = TaskItem(title: "wifi password", status: .todo, ownerID: me)
        note.workIntent = .reference

        let sections = MyTasksSlices.assigned(tasks: [todo, note], currentUserID: me)
        // Filing a saved password under "Todo" would claim it is queued work. It is
        // not — and the separate section is the seam a future knowledge/execution
        // split would cut along.
        #expect(sections.map(\.kind) == [.status(.todo), .reference])

        // Once RESOLVED it really is a resolution record, so it files normally.
        note.complete()
        let after = MyTasksSlices.assigned(tasks: [todo, note], currentUserID: me)
        #expect(after.map(\.kind) == [.status(.todo), .status(.done)])
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
}
