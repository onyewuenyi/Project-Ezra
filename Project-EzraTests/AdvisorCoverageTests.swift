//
//  AdvisorCoverageTests.swift
//  Project-EzraTests
//
//  The coverage sweep is the instrument the gate inversion will be judged on, so it has
//  to be trustworthy before the boundary moves. Pure — no model anywhere.
//
//  What these protect, in order of importance: the counts add up (a sweep that loses a
//  task would understate coverage and argue for widening the gate on a lie), silence is
//  attributed to the RIGHT reason (the whole value is knowing which kind of silence you
//  have), and an empty store reports "no tasks" rather than 0%.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct AdvisorCoverageTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func task(
        _ title: String, effort: Int? = nil, status: TaskStatus = .todo,
        in context: NSManagedObjectContext
    ) -> TaskItem {
        TaskItem(title: title, status: status, effortMinutes: effort, in: context)
    }

    @Test("Every task lands in exactly one reason, and the buckets sum to the total")
    func countsAreExhaustiveAndDisjoint() {
        let context = context()
        let tasks = [
            task("Call the dentist", effort: 15, in: context),
            task("Renew passport", effort: 120, in: context),
            task("Should we move to Lisbon", effort: 15, in: context),
            task("Buy milk", effort: 15, in: context),
        ]

        let report = AdvisorCoverage.measure(tasks)

        #expect(report.total == 4)
        #expect(report.byReason.values.reduce(0, +) == 4)
        #expect(report.worthy + report.silent == report.total)
    }

    @Test("Silence is attributed, not merely counted")
    func silenceCarriesItsReason() {
        let context = context()
        let plain = task("Call the dentist", effort: 15, in: context)
        let done = task("Pay the water bill", effort: 15, in: context)
        done.complete(now: Date())

        let report = AdvisorCoverage.measure([plain, done])

        #expect(report.count(.plain) == 1)
        #expect(report.count(.resolved) == 1)
        #expect(report.worthy == 0)
    }

    @Test("Worthy tasks are attributed to the rung that fired")
    func worthyCarriesItsReason() {
        let context = context()
        let big = task("Renew passport", effort: 120, in: context)
        let choice = task("Should we move to Lisbon", effort: 15, in: context)

        let report = AdvisorCoverage.measure([big, choice])

        #expect(report.count(.largeEffort) == 1)
        #expect(report.count(.decisionWording) == 1)
        #expect(report.worthy == 2)
    }

    @Test("An empty store reports no tasks, never 0% coverage")
    func emptyStoreIsNotZeroPercent() {
        let report = AdvisorCoverage.measure([])
        #expect(report.total == 0)
        #expect(report.worthyShare == nil)
        #expect(report.line == "advisor coverage: no tasks")
    }

    @Test("The one-line form names the share and the silent reasons")
    func lineIsReadable() {
        let context = context()
        let tasks = [
            task("Call the dentist", effort: 15, in: context),
            task("Renew passport", effort: 120, in: context),
        ]
        let line = AdvisorCoverage.measure(tasks).line
        #expect(line.contains("1/2 worthy (50%)"))
        #expect(line.contains("plain 1"))
    }

    @Test("The table lists every reason, including the ones that didn't occur")
    func tableIsStable() {
        let context = context()
        let table = AdvisorCoverage.measure([task("Call the dentist", effort: 15, in: context)]).table
        // A reason that stops occurring must read as a zero, not vanish — otherwise a
        // shifting boundary looks like a shrinking table.
        for reason in AdvisorGateReason.allCases {
            #expect(table.contains(reason.rawValue), "missing \(reason.rawValue)")
        }
    }
}
