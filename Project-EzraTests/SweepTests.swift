//
//  SweepTests.swift
//  Project-EzraTests
//
//  The maintenance sweep's one power — the stale auto-archive — is silent-tier,
//  so its guards ARE the product: undated only, long-threshold only, never a
//  judgment call or open decision, and always reversible via the change log.
//

import Foundation
import CoreData
import Testing

@testable import Project_Ezra

@Suite("Maintenance sweeps")
@MainActor
struct SweepTests {

    private func makeContext() throws -> NSManagedObjectContext {
        return TestStore.makeContext()
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 24 * 3600) }

    @Test("An undated task untouched past the archive threshold is killed, reversibly")
    func archivesAncientUndated() throws {
        let context = try makeContext()
        let ancient = TaskItem(title: "Reorganize the garage", status: .todo, createdAt: daysAgo(30))
        context.insert(ancient)

        let result = BrainSweeps.run(in: context, now: now)

        #expect(result.archived.count == 1)
        #expect(ancient.status == .canceled)
        #expect(ancient.killedAt == now)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let entry = try #require(entries.first { $0.taskUUID == ancient.uuid })
        #expect(entry.initiatedBy == .ai)
        #expect(entry.isReversible)
        #expect(entry.action == "archived")
    }

    @Test("Long-abandoned in-flight work is still archived — Doing is not a hiding place")
    func archivesAbandonedInFlight() throws {
        let context = try makeContext()
        // Picked up a month ago and never touched since. `.doing` earns a relevance
        // boost, but deliberately NOT archive immunity: a boost plus immunity would
        // make a task that can never leave the system.
        let abandoned = TaskItem(title: "Rewire the shed", status: .todo, createdAt: daysAgo(40))
        abandoned.transition(to: .doing, now: daysAgo(30))
        context.insert(abandoned)

        #expect(BrainSweeps.run(in: context, now: now).archived.count == 1)
        #expect(abandoned.status == .canceled)
    }

    @Test("Retro-stale but not archive-stale is left alone — the retro gets it first")
    func retroStaleSurvives() throws {
        let context = try makeContext()
        let stale = TaskItem(title: "Fix the faucet", status: .todo, createdAt: daysAgo(10))
        context.insert(stale)

        let result = BrainSweeps.run(in: context, now: now)

        #expect(result.archived.isEmpty)
        #expect(stale.status.isLive)
    }

    @Test("A dated task is never auto-archived — it goes overdue instead")
    func datedTaskUntouchable() throws {
        let context = try makeContext()
        let dated = TaskItem(
            title: "File taxes", status: .todo,
            dueDate: now.addingTimeInterval(90 * 24 * 3600), createdAt: daysAgo(60))
        context.insert(dated)

        #expect(BrainSweeps.run(in: context, now: now).archived.isEmpty)
        #expect(dated.status.isLive)
    }

    @Test("Judgment calls and open decisions are never silently killed")
    func judgmentUntouchable() throws {
        let context = try makeContext()
        let judgment = TaskItem(
            title: "Should I quit the gym", status: .todo, confidence: 0.9,
            isJudgmentCall: true, needsDecision: true, createdAt: daysAgo(60))
        let openDecision = TaskItem(
            title: "Vague thing", status: .todo, confidence: 0.3, needsDecision: true,
            createdAt: daysAgo(60))
        context.insert(judgment)
        context.insert(openDecision)

        #expect(BrainSweeps.run(in: context, now: now).archived.isEmpty)
        #expect(judgment.status == .todo)
        #expect(openDecision.status.isLive)
    }

    @Test("Resolved tasks are never re-archived")
    func resolvedUntouchable() throws {
        let context = try makeContext()
        let done = TaskItem(title: "Old win", status: .todo, createdAt: daysAgo(60))
        done.complete(now: daysAgo(50))
        context.insert(done)

        #expect(BrainSweeps.run(in: context, now: now).archived.isEmpty)
        #expect(done.status == .done)
    }

    @Test("An archived task's dependents resurface on the next read — blocked is derived")
    func archiveFreesDependents() throws {
        let context = try makeContext()
        let ancient = TaskItem(title: "Pick a contractor", status: .todo, createdAt: daysAgo(30))
        context.insert(ancient)
        let dependent = TaskItem(
            title: "Start the renovation", status: .todo,
            blockedBy: [ancient.uuid].compactMap { $0 }, createdAt: now)
        context.insert(dependent)
        #expect(dependent.hasActiveBlockers(among: [ancient, dependent]))

        BrainSweeps.run(in: context, now: now)

        // The blocker resolved (killed), so the dependent reads unblocked.
        #expect(!dependent.hasActiveBlockers(among: [ancient, dependent]))
    }

    @Test("An undone auto-archive resets the human clock — the next sweep doesn't re-kill it")
    func undoneArchiveNotReArchived() throws {
        let context = try makeContext()
        let ancient = TaskItem(title: "Reorganize the garage", status: .todo, createdAt: daysAgo(30))
        context.insert(ancient)

        // First sweep archives the stale, undated task.
        #expect(BrainSweeps.run(in: context, now: now).archived.count == 1)
        #expect(ancient.status == .canceled)

        // Undo it from the change log, exactly as the Inbox feed's Undo does.
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let archived = try #require(
            entries.first { $0.taskUUID == ancient.uuid && $0.action == "archived" })
        ChangeLogUndo.revert(archived, in: context, now: now)
        archived.undone = true
        try context.save()
        #expect(!ancient.status.isResolved)  // back in the working set

        // The next hourly sweep must NOT re-archive it — the revival stamped the human
        // clock, so it no longer reads stale. (Regression: the hourly re-kill loop.)
        let second = BrainSweeps.run(in: context, now: now.addingTimeInterval(3600))
        #expect(second.archived.isEmpty)
        #expect(!ancient.status.isResolved)
    }

    @Test("The archive message reports days since the HUMAN clock, not a system updatedAt bump")
    func archiveMessageUsesHumanClock() throws {
        let context = try makeContext()
        let ancient = TaskItem(title: "Old thing", status: .todo, createdAt: daysAgo(30))
        // A SYSTEM edge-write bumps `updatedAt` to now — an idle-from-updatedAt message would
        // wrongly read "0 days". Staleness (human clock) is untouched, so it still archives.
        ancient.touch(now: now)
        context.insert(ancient)

        BrainSweeps.run(in: context, now: now)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let entry = try #require(entries.first { $0.taskUUID == ancient.uuid })
        #expect(entry.summary.contains("for 30 days"))
        #expect(!entry.summary.contains("for 0 days"))
    }

    @Test("The debounce runs at most hourly")
    func debounce() throws {
        let context = try makeContext()
        let defaults = UserDefaults(suiteName: "sweep-tests-\(UUID().uuidString)")!
        let ancient = TaskItem(title: "Old thing", status: .todo, createdAt: daysAgo(30))
        context.insert(ancient)
        let brain = AppBrain()

        brain.runMaintenanceSweepsIfDue(in: context, now: now, defaults: defaults)
        #expect(ancient.status == .canceled)

        // A second ancient task appearing 5 minutes later waits for the next window.
        let another = TaskItem(title: "Older thing", status: .todo, createdAt: daysAgo(40))
        context.insert(another)
        brain.runMaintenanceSweepsIfDue(
            in: context, now: now.addingTimeInterval(300), defaults: defaults)
        #expect(another.status.isLive)

        // Past the hour, the sweep runs again.
        brain.runMaintenanceSweepsIfDue(
            in: context, now: now.addingTimeInterval(3700), defaults: defaults)
        #expect(another.status == .canceled)
    }
}
