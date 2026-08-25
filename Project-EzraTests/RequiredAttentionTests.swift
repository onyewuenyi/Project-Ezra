//
//  RequiredAttentionTests.swift
//  Project-EzraTests
//
//  The master metric. Every dimension here can be made WORSE by a feature that looks like
//  an improvement — a chattier Advisor raises execution attention, a hedging Brief raises
//  orientation attention, a guessier capture model raises capture attention — so what
//  these tests pin is mostly the DIRECTION each number moves. A scorecard whose rows can
//  drift silently is a scorecard nobody can use to stop a regression.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Required Attention (the master metric)")
struct RequiredAttentionTests {

    private func freshAdvisor() -> AdvisorMetrics {
        AdvisorMetrics(defaults: UserDefaults(suiteName: "attention.\(UUID().uuidString)")!)
    }

    private func measure(
        tasks: [TaskItem] = [], entries: [ChangeLogEntry] = [], corrections: [Correction] = [],
        planned: Set<UUID> = [], advisor: AdvisorMetrics? = nil, now: Date = Date()
    ) -> RequiredAttention {
        RequiredAttention.measure(
            tasks: tasks, entries: entries, corrections: corrections, plannedTaskIDs: planned,
            advisor: advisor ?? freshAdvisor(), now: now)
    }

    // MARK: - Empty is not zero

    @Test("With no data, every dimension reads 'not measurable' rather than 'perfect'")
    func emptyIsNotZero() {
        let scorecard = measure()
        // The distinction that keeps this honest: "no corrections needed" and "nothing
        // captured yet" are opposite findings, and a scorecard that printed 0.00 for both
        // would report a fresh install as a flawless one.
        #expect(scorecard.capture.rate == nil)
        #expect(scorecard.orientation.rate == nil)
        #expect(scorecard.execution.rate == nil)
        #expect(scorecard.maintenance.rate == nil)
        #expect(scorecard.progressionLift == nil)
        #expect(scorecard.footerLine.contains("cap —"))
    }

    // MARK: - Capture

    @Test("Capture attention is corrections per confirmed task, and falls as inference improves")
    func captureAttention() {
        let context = TestStore.makeContext()
        let a = TaskItem(title: "Renew passport", in: context)
        a.confirmedAt = Date()
        let b = TaskItem(title: "Pay the water bill", in: context)
        b.confirmedAt = Date()
        // An unconfirmed task is not a capture the user has been asked to review yet, so it
        // must not dilute the denominator.
        _ = TaskItem(title: "Never confirmed", in: context)

        let correction = Correction(
            taskUUID: a.uuid, fieldCorrected: "category", aiValue: "Home", userValue: "Finance",
            in: context)
        let scorecard = measure(tasks: [a, b], corrections: [correction])
        #expect(scorecard.capture == RequiredAttention.Reading(numerator: 1, denominator: 2))
        #expect(scorecard.capture.rate == 0.5)
    }

    // MARK: - Orientation

    @Test("Orientation attention counts work the Brief never surfaced")
    func orientationAttention() {
        let context = TestStore.makeContext()
        let now = Date()

        // Surfaced by the Brief and worked → the Brief did its job.
        let surfaced = TaskItem(title: "Renew the car insurance", status: .doing, in: context)
        surfaced.lastHumanTouchAt = now
        // Worked but never surfaced → the user found it themselves, which is exactly the
        // manual sorting the Brief exists to remove.
        let found = TaskItem(title: "Call the pharmacy", status: .doing, in: context)
        found.lastHumanTouchAt = now
        // Surfaced but untouched: not work, so it belongs in neither side of the ratio.
        let ignored = TaskItem(title: "Sort the garage", status: .todo, in: context)

        let scorecard = measure(
            tasks: [surfaced, found, ignored], planned: Set([surfaced.uuid!]), now: now)
        #expect(scorecard.orientation == RequiredAttention.Reading(numerator: 1, denominator: 2))
    }

    @Test("Merely opening a task is not work — orientation must not reward browsing")
    func orientationIgnoresUntouchedTasks() {
        let context = TestStore.makeContext()
        let now = Date()
        // Touched today but still `.todo`: looked at, not moved. Counting this would make a
        // Brief that sends people browsing look like a Brief that oriented them.
        let looked = TaskItem(title: "Decide on the school", status: .todo, in: context)
        looked.lastHumanTouchAt = now

        #expect(measure(tasks: [looked], now: now).orientation.rate == nil)
    }

    // MARK: - Execution

    @Test("Execution attention rises when the Advisor intervenes repeatedly on one task")
    func executionAttention() {
        let context = TestStore.makeContext()
        let advisor = freshAdvisor()
        let task = TaskItem(title: "Plan the birthday dinner", status: .todo, in: context)

        advisor.recordActed(.advise, taskID: task.uuid, status: .todo)
        let once = measure(tasks: [task], advisor: advisor).execution
        #expect(once.rate == 1.0)

        // advise → act → advise → act reads agentic and annoying; one intervention →
        // progress reads like an intelligent coworker. The number has to move the wrong way
        // when the Advisor gets chattier, or it isn't measuring anything.
        advisor.recordActed(.decide, taskID: task.uuid, status: .todo)
        #expect(measure(tasks: [task], advisor: advisor).execution.rate == 2.0)
    }

    // MARK: - Maintenance

    @Test("Maintenance attention is manual edits per live task; resolved work stops counting")
    func maintenanceAttention() {
        let context = TestStore.makeContext()
        let live = TaskItem(title: "Renew passport", status: .todo, in: context)
        let done = TaskItem(title: "Pay the water bill", status: .todo, in: context)
        done.complete()

        let edit = ChangeLogEntry(
            summary: "Changed due date", action: ChangeLogEntry.editedAction, in: context)
        let filed = ChangeLogEntry(
            summary: "Filed under Home", action: "filed", in: context)

        // Only `edited` counts: it is the user maintaining state the system should have
        // maintained. A filing is the system doing its job, not upkeep the user performed.
        let scorecard = measure(tasks: [live, done], entries: [edit, filed])
        #expect(scorecard.maintenance == RequiredAttention.Reading(numerator: 1, denominator: 1))
    }

    // MARK: - The shape of the whole thing

    @Test("The footer carries all five dimensions, and the lift is signed")
    func footerShape() {
        let context = TestStore.makeContext()
        let advisor = freshAdvisor()

        let advised = TaskItem(title: "Renew passport", status: .todo, in: context)
        advisor.recordActed(.advise, taskID: advised.uuid, status: .todo)
        advised.complete()
        let silent = TaskItem(title: "Sort the garage", status: .todo, in: context)
        advisor.recordJudgedSilence(taskID: silent.uuid, status: .todo)

        let line = measure(tasks: [advised, silent], advisor: advisor).footerLine
        for dimension in ["cap", "orient", "exec", "maint", "lift"] {
            #expect(line.contains(dimension), "footer dropped \(dimension)")
        }
        // A working Advisor here: advised work resolved, silent work didn't.
        #expect(line.contains("lift +100pt"))
    }
}
