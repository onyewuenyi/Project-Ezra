//
//  HouseholdEngineTests.swift
//  Project-EzraTests
//
//  The Household Engine is the coordination counterpart to the Attention Engine:
//  Tasks + change log + roster in, a derived HouseholdSnapshot out. The status
//  rules, the relative-overload heuristic, the bounded coordination feed, and the
//  all-owners timeline are product invariants — locked here over pure fixtures, no
//  NSManagedObjectContext. The honesty rule holds throughout: an empty household is quiet,
//  never a fabricated "perfectly balanced".
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Household engine")
struct HouseholdEngineTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// The current user's linked member id — "my" fixtures set `ownerID: me` so they
    /// land in the `.you` bucket (a nil owner now means shared/unassigned, not "you").
    private let me = UUID()
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 24 * 3600) }

    private func compute(
        _ tasks: [TaskItem], changes: [ChangeLogEntry] = [], members: [FamilyMember] = []
    ) -> HouseholdSnapshot {
        HouseholdEngine.compute(
            tasks: tasks, changes: changes, members: members, currentUserID: me, now: now)
    }

    private func you(_ snap: HouseholdSnapshot) -> MemberLoad? {
        snap.members.first { if case .you = $0.kind { return true } else { return false } }
    }

    private func shared(_ snap: HouseholdSnapshot) -> MemberLoad? {
        snap.members.first { if case .shared = $0.kind { return true } else { return false } }
    }

    private func loadFor(_ snap: HouseholdSnapshot, member: FamilyMember) -> MemberLoad? {
        snap.members.first { $0.kind == .member(member.uuid) }
    }

    // MARK: - Status

    @Test("Solo (no members) is quiet and hasHousehold is false, even with active work")
    func soloIsQuiet() {
        let mine = TaskItem(title: "mow the lawn", status: .active, ownerID: me, createdAt: now)
        let snap = compute([mine])
        #expect(snap.status == .quiet)
        #expect(snap.hasHousehold == false)
        // Honesty: no fabricated positive highlights for an empty household.
        #expect(snap.highlights.isEmpty)
    }

    @Test("Overdue work pushes the household to needs-attention")
    func overdueNeedsAttention() {
        let maya = FamilyMember(name: "Maya")
        let overdue = TaskItem(
            title: "pay the bill", status: .active, dueDate: days(-2), ownerID: me, createdAt: now)
        let snap = compute([overdue], members: [maya])
        #expect(snap.status == .needsAttention)
        #expect(snap.headline == "Needs attention")
    }

    @Test("An open decision pushes the household to needs-attention")
    func decisionNeedsAttention() {
        let maya = FamilyMember(name: "Maya")
        let call = TaskItem(
            title: "should we move", status: .active, isJudgmentCall: true, needsDecision: true,
            createdAt: now)
        let snap = compute([call], members: [maya])
        #expect(snap.status == .needsAttention)
    }

    @Test("Unowned household work pushes to needs-attention and adds a Shared bucket")
    func upForGrabsNeedsAttention() {
        let maya = FamilyMember(name: "Maya")
        let grab = TaskItem(title: "book the caterer", status: .active, ownerPending: true, createdAt: now)
        let snap = compute([grab], members: [maya])
        #expect(snap.status == .needsAttention)
        #expect(shared(snap) != nil)
        #expect(shared(snap)?.activeCount == 1)
    }

    @Test("Real work with no red flags reads as operating smoothly")
    func smoothWhenClean() {
        let maya = FamilyMember(name: "Maya")
        let mine = TaskItem(
            title: "prep dinner", status: .active, dueDate: days(3), ownerID: me, createdAt: now)
        let snap = compute([mine], members: [maya])
        #expect(snap.status == .operatingSmoothly)
    }

    @Test("No Shared bucket when there is no unowned work")
    func noSharedBucketWithoutUnowned() {
        let maya = FamilyMember(name: "Maya")
        let mine = TaskItem(title: "prep dinner", status: .active, ownerID: me, createdAt: now)
        let snap = compute([mine], members: [maya])
        #expect(shared(snap) == nil)
    }

    // MARK: - Overload heuristic (relative, floored)

    @Test("Overload needs a real plate AND clearly more than the household median")
    func overloadFiresAboveFloorAndMedian() {
        let maya = FamilyMember(name: "Maya")
        let ezra = FamilyMember(name: "Ezra")
        // you: 4 active, each member: 1 → median 1, floor 4 → you overloaded.
        var tasks = (0..<4).map {
            TaskItem(title: "mine \($0)", status: .active, ownerID: me, createdAt: now)
        }
        tasks.append(TaskItem(title: "maya", status: .active, ownerID: maya.uuid, createdAt: now))
        tasks.append(TaskItem(title: "ezra", status: .active, ownerID: ezra.uuid, createdAt: now))
        let snap = compute(tasks, members: [maya, ezra])
        #expect(you(snap)?.isOverloaded == true)
        #expect(loadFor(snap, member: maya)?.isOverloaded == false)
    }

    @Test("Below the floor of 4, a lopsided plate is not overload")
    func overloadRespectsFloor() {
        let maya = FamilyMember(name: "Maya")
        let ezra = FamilyMember(name: "Ezra")
        var tasks = (0..<3).map {
            TaskItem(title: "mine \($0)", status: .active, ownerID: me, createdAt: now)
        }
        tasks.append(TaskItem(title: "maya", status: .active, ownerID: maya.uuid, createdAt: now))
        tasks.append(TaskItem(title: "ezra", status: .active, ownerID: ezra.uuid, createdAt: now))
        let snap = compute(tasks, members: [maya, ezra])
        #expect(you(snap)?.isOverloaded == false)
    }

    @Test("A solo carrier is never overloaded relative to itself")
    func soloCarrierNeverOverloaded() {
        let maya = FamilyMember(name: "Maya")  // owns nothing
        let tasks = (0..<10).map {
            TaskItem(title: "mine \($0)", status: .active, ownerID: me, createdAt: now)
        }
        let snap = compute(tasks, members: [maya])
        #expect(you(snap)?.isOverloaded == false)
    }

    // MARK: - Per-member counts

    @Test("Per-member counts (active / due-today / blocked / overdue) match the tasks")
    func memberCountsAreExact() {
        let maya = FamilyMember(name: "Maya")
        let active = TaskItem(title: "venue", status: .active, ownerID: maya.uuid, createdAt: now)
        let dueToday = TaskItem(
            title: "school run", status: .active, dueDate: now, ownerID: maya.uuid, createdAt: now)
        let overdue = TaskItem(
            title: "insurance", status: .active, dueDate: days(-1), ownerID: maya.uuid, createdAt: now)
        let blocked = TaskItem(title: "remodel", status: .active, ownerID: maya.uuid, createdAt: now)
        blocked.addExternalBlocker("the plumber", among: [blocked])
        // An inbox item is not on the plate yet — it's an unconfirmed capture.
        let inbox = TaskItem(title: "someday", status: .inbox, ownerID: maya.uuid, createdAt: now)
        let snap = compute([active, dueToday, overdue, blocked, inbox], members: [maya])
        let load = loadFor(snap, member: maya)
        #expect(load?.activeCount == 4)
        #expect(load?.dueTodayCount == 1)
        #expect(load?.overdueCount == 1)
        #expect(load?.blockedCount == 1)
    }

    // MARK: - Coordination feed

    @Test("The coordination feed is bounded and every event has a non-empty reason")
    func feedIsBoundedAndExplainable() {
        let maya = FamilyMember(name: "Maya")
        let grabs = (0..<8).map {
            TaskItem(title: "grab \($0)", status: .active, ownerPending: true, createdAt: now)
        }
        let snap = compute(grabs, members: [maya])
        #expect(snap.coordination.count <= HouseholdEngine.Budget.feed)
        #expect(snap.coordination.allSatisfy { !$0.reasons.isEmpty })
    }

    @Test("Undone change-log entries never surface in the coordination feed")
    func feedSkipsUndone() {
        let maya = FamilyMember(name: "Maya")
        let mine = TaskItem(title: "prep dinner", status: .active, dueDate: days(2), createdAt: now)
        let live = ChangeLogEntry(
            summary: "Maya was assigned the venue", action: "assigned", initiatedBy: .human,
            timestamp: now)
        let reverted = ChangeLogEntry(
            summary: "Ezra was assigned the caterer", action: "assigned", initiatedBy: .human,
            timestamp: now)
        reverted.undone = true
        let snap = compute([mine], changes: [live, reverted], members: [maya])
        #expect(snap.coordination.contains { $0.sentence == "Maya was assigned the venue" })
        #expect(!snap.coordination.contains { $0.sentence == "Ezra was assigned the caterer" })
    }

    @Test("Plain AI filings are not coordination events")
    func feedSkipsFilings() {
        let maya = FamilyMember(name: "Maya")
        let mine = TaskItem(title: "prep dinner", status: .active, dueDate: days(2), createdAt: now)
        let filed = ChangeLogEntry(
            summary: "Filed 'prep dinner' under Home", action: "filed", initiatedBy: .ai,
            timestamp: now)
        let snap = compute([mine], changes: [filed], members: [maya])
        #expect(!snap.coordination.contains { $0.sentence.hasPrefix("Filed") })
    }

    // MARK: - Shared timeline

    @Test("The timeline spans every owner and excludes resolved / undated / overdue")
    func timelineSpansOwnersAndFilters() {
        let maya = FamilyMember(name: "Maya")
        let mine = TaskItem(
            title: "my thing", status: .active, dueDate: days(1), ownerID: me, createdAt: now)
        let hers = TaskItem(
            title: "her thing", status: .active, dueDate: days(2), ownerID: maya.uuid, createdAt: now)
        let resolved = TaskItem(title: "done thing", status: .active, dueDate: days(1), createdAt: now)
        resolved.complete(now: now)
        let undated = TaskItem(title: "someday thing", status: .active, createdAt: now)
        let overdue = TaskItem(title: "late thing", status: .active, dueDate: days(-1), createdAt: now)
        let farOff = TaskItem(title: "next month", status: .active, dueDate: days(30), createdAt: now)
        let snap = compute(
            [mine, hers, resolved, undated, overdue, farOff], members: [maya])
        let titles = snap.timeline.map(\.title)
        #expect(titles.contains("my thing"))
        #expect(titles.contains("her thing"))  // another owner's commitment shows up
        #expect(!titles.contains("done thing"))
        #expect(!titles.contains("someday thing"))
        #expect(!titles.contains("late thing"))
        #expect(!titles.contains("next month"))
        // Sorted by due date.
        #expect(snap.timeline.map(\.dueDate) == snap.timeline.map(\.dueDate).sorted())
    }

    // MARK: - Facts

    @Test("Facts round-trip the snapshot's numbers for the narrative layer")
    func factsMatchSnapshot() {
        let maya = FamilyMember(name: "Maya")
        let overdue = TaskItem(
            title: "insurance", status: .active, dueDate: days(-1), ownerID: maya.uuid, createdAt: now)
        let blocked = TaskItem(title: "remodel", status: .active, ownerID: maya.uuid, createdAt: now)
        blocked.addExternalBlocker("the plumber", among: [blocked])
        let grab = TaskItem(title: "caterer", status: .active, ownerPending: true, createdAt: now)
        let call = TaskItem(
            title: "should we move", status: .active, isJudgmentCall: true, needsDecision: true,
            createdAt: now)
        let snap = compute([overdue, blocked, grab, call], members: [maya])
        let facts = HouseholdEngine.facts(from: snap)
        #expect(facts.overdueCount == snap.members.reduce(0) { $0 + $1.overdueCount })
        #expect(facts.blockedCount == snap.members.reduce(0) { $0 + $1.blockedCount })
        #expect(facts.overdueCount == 1)
        #expect(facts.blockedCount == 1)
        #expect(facts.unownedCount >= 1)
        #expect(facts.needsDecisionCount >= 1)
    }
}
