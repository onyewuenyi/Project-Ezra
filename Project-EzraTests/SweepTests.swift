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
        let ancient = TaskItem(title: "Reorganize the garage", status: .active, createdAt: daysAgo(30))
        context.insert(ancient)

        let result = BrainSweeps.run(in: context, now: now)

        #expect(result.archived.count == 1)
        #expect(ancient.status == .killed)
        #expect(ancient.killedAt == now)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let entry = try #require(entries.first { $0.taskUUID == ancient.uuid })
        #expect(entry.initiatedBy == .ai)
        #expect(entry.isReversible)
        #expect(entry.action == "archived")
    }

    @Test("Retro-stale but not archive-stale is left alone — the retro gets it first")
    func retroStaleSurvives() throws {
        let context = try makeContext()
        let stale = TaskItem(title: "Fix the faucet", status: .active, createdAt: daysAgo(10))
        context.insert(stale)

        let result = BrainSweeps.run(in: context, now: now)

        #expect(result.archived.isEmpty)
        #expect(stale.status == .active)
    }

    @Test("A dated task is never auto-archived — it goes overdue instead")
    func datedTaskUntouchable() throws {
        let context = try makeContext()
        let dated = TaskItem(
            title: "File taxes", status: .active,
            dueDate: now.addingTimeInterval(90 * 24 * 3600), createdAt: daysAgo(60))
        context.insert(dated)

        #expect(BrainSweeps.run(in: context, now: now).archived.isEmpty)
        #expect(dated.status == .active)
    }

    @Test("Judgment calls and open decisions are never silently killed")
    func judgmentUntouchable() throws {
        let context = try makeContext()
        let judgment = TaskItem(
            title: "Should I quit the gym", status: .inbox, confidence: 0.9,
            isJudgmentCall: true, needsDecision: true, createdAt: daysAgo(60))
        let openDecision = TaskItem(
            title: "Vague thing", status: .active, confidence: 0.3, needsDecision: true,
            createdAt: daysAgo(60))
        context.insert(judgment)
        context.insert(openDecision)

        #expect(BrainSweeps.run(in: context, now: now).archived.isEmpty)
        #expect(judgment.status == .inbox)
        #expect(openDecision.status == .active)
    }

    @Test("Resolved tasks are never re-archived")
    func resolvedUntouchable() throws {
        let context = try makeContext()
        let done = TaskItem(title: "Old win", status: .active, createdAt: daysAgo(60))
        done.complete(now: daysAgo(50))
        context.insert(done)

        #expect(BrainSweeps.run(in: context, now: now).archived.isEmpty)
        #expect(done.status == .done)
    }

    @Test("An archived task's dependents resurface on the next read — blocked is derived")
    func archiveFreesDependents() throws {
        let context = try makeContext()
        let ancient = TaskItem(title: "Pick a contractor", status: .active, createdAt: daysAgo(30))
        context.insert(ancient)
        let dependent = TaskItem(
            title: "Start the renovation", status: .active,
            blockedBy: [ancient.uuid].compactMap { $0 }, createdAt: now)
        context.insert(dependent)
        #expect(dependent.hasActiveBlockers(among: [ancient, dependent]))

        BrainSweeps.run(in: context, now: now)

        // The blocker resolved (killed), so the dependent reads unblocked.
        #expect(!dependent.hasActiveBlockers(among: [ancient, dependent]))
    }

    @Test("The debounce runs at most hourly")
    func debounce() throws {
        let context = try makeContext()
        let defaults = UserDefaults(suiteName: "sweep-tests-\(UUID().uuidString)")!
        let ancient = TaskItem(title: "Old thing", status: .active, createdAt: daysAgo(30))
        context.insert(ancient)
        let brain = AppBrain()

        brain.runMaintenanceSweepsIfDue(in: context, now: now, defaults: defaults)
        #expect(ancient.status == .killed)

        // A second ancient task appearing 5 minutes later waits for the next window.
        let another = TaskItem(title: "Older thing", status: .active, createdAt: daysAgo(40))
        context.insert(another)
        brain.runMaintenanceSweepsIfDue(
            in: context, now: now.addingTimeInterval(300), defaults: defaults)
        #expect(another.status == .active)

        // Past the hour, the sweep runs again.
        brain.runMaintenanceSweepsIfDue(
            in: context, now: now.addingTimeInterval(3700), defaults: defaults)
        #expect(another.status == .killed)
    }
}
