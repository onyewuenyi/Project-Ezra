//
//  TaskTimelineTests.swift
//  Project-EzraTests
//
//  The state timeline is instrumentation, so its whole value is that it never lies:
//  it records what actually happened, counts backward moves honestly, and reports
//  nothing rather than a fabricated number when it has no history. It tracks the
//  *status* axis only (Inbox/Active/Done/Killed) — "blocked" and "unowned" are
//  derived observations that don't move the status, so they never appear here.
//  @ModelManaged-object fixtures build in the shared in-memory scratch context; time is injected so the math is exact.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Task state timeline")
struct TaskTimelineTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// `t0` plus N minutes.
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: - Recording

    @Test("init opens a visit for the initial status at createdAt")
    func initSeedsOpenVisit() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        #expect(task.stateTimeline.count == 1)
        #expect(task.stateTimeline[0].state == TaskStatus.active.rawValue)
        #expect(task.stateTimeline[0].enteredAt == t0)
        #expect(task.stateTimeline[0].exitedAt == nil)
    }

    @Test("A transition closes the open visit and opens the next")
    func transitionClosesAndOpens() {
        let task = TaskItem(title: "x", status: .inbox, createdAt: t0)
        task.transition(to: .active, now: at(10))
        #expect(task.status == .active)
        #expect(task.stateTimeline.count == 2)
        #expect(task.stateTimeline[0].exitedAt == at(10))
        #expect(task.stateTimeline[0].duration == 600)
        #expect(task.stateTimeline[1].enteredAt == at(10))
        #expect(task.stateTimeline[1].exitedAt == nil)
    }

    @Test("Writing status directly (the activity-trail undo path) still records a visit")
    func directStateWriteIsInstrumented() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        task.status = .inbox  // ChangeLogUndo's default revert does exactly this
        #expect(task.stateTimeline.count == 2)
        #expect(task.stateTimeline[0].exitedAt != nil)
        #expect(task.stateTimeline[1].state == TaskStatus.inbox.rawValue)
    }

    @Test("Mutation helpers funnel through the timeline")
    func mutationHelpersRecord() {
        let task = TaskItem(title: "x", status: .inbox, confidence: 0.9, createdAt: t0)
        task.confirm(now: at(5))
        #expect(task.status == .active)
        task.complete(now: at(10))
        #expect(task.status == .done)
        #expect(task.stateTimeline.count == 3)
    }

    @Test("transition() bumps updatedAt with the authoritative timestamp")
    func transitionBumpsUpdatedAt() {
        let task = TaskItem(title: "x", status: .inbox, createdAt: t0)
        task.transition(to: .active, now: at(10))
        #expect(task.updatedAt == at(10))
    }

    // MARK: - Dwell math

    @Test("secondsIn sums closed visits exactly")
    func secondsInClosed() {
        let task = TaskItem(title: "x", status: .inbox, createdAt: t0)
        task.transition(to: .active, now: at(10))
        task.transition(to: .done, now: at(35))
        #expect(task.secondsIn(.inbox) == 600)  // 10m
        #expect(task.secondsIn(.active) == 1500)  // 25m
    }

    @Test("The open visit counts up to now")
    func openVisitIsLive() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        #expect(task.secondsIn(.active, now: at(5)) == 300)
    }

    @Test("A resolved task's dwell does not tick upward forever")
    func doneDoesNotGrow() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        task.complete(now: at(10))
        #expect(task.secondsIn(.done, now: at(10)) == 0)
        #expect(task.secondsIn(.done, now: at(9999)) == 0)

        let killed = TaskItem(title: "y", status: .active, createdAt: t0)
        killed.kill(now: at(10))
        #expect(killed.secondsIn(.killed, now: at(9999)) == 0)
    }

    @Test("A same-status transition records nothing and keeps the clock running")
    func noOpTransitionIsIgnored() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        task.transition(to: .active, now: at(10))  // a re-derive landing on the same status
        #expect(task.stateTimeline.count == 1)
        #expect(task.stateTimeline[0].enteredAt == t0)  // clock was NOT reset
        #expect(task.secondsIn(.active, now: at(20)) == 1200)  // one continuous 20m
    }

    @Test("Adding a blocker never touches the timeline — blocked is not a status")
    func blockingDoesNotRecordAVisit() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9, createdAt: t0)
        task.addExternalBlocker(nil, among: [])
        // The task reads as blocked, but its status — and thus its timeline — is
        // untouched: it's still one continuous Active visit.
        #expect(task.stateTimeline.count == 1)
        #expect(task.status == .active)
        #expect(task.secondsIn(.active, now: at(20)) == 1200)
    }

    // MARK: - Backward / repeated transitions (the edge cases)

    @Test("Reopen preserves the closed Done visit and re-sums Active dwell")
    func reopenPreservesHistory() {
        let task = TaskItem(title: "x", status: .active, confidence: 0.9, createdAt: t0)
        task.complete(now: at(20))
        task.reopen(among: [])
        #expect(task.completedAt == nil)
        // Reopen restored the prior status; its earlier stint still counts.
        #expect(task.status == .active)
        #expect(task.secondsIn(.active, now: at(20)) >= 1200)
        #expect(task.stateTimeline.contains { $0.state == TaskStatus.done.rawValue && $0.exitedAt != nil })
    }

    @Test("Legacy raw values in history fold forward on reopen")
    func legacyHistoryFoldsForward() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        // Simulate a pre-redirect history that somehow survived the store reset.
        task.stateTimeline = [
            StateVisit(state: "ready", enteredAt: t0, exitedAt: at(10)),
            StateVisit(state: "done", enteredAt: at(10), exitedAt: nil),
        ]
        task.reopen(among: [])
        #expect(task.status == .active)  // "ready" folds to .active
    }

    // MARK: - Migration honesty

    @Test("A row with no recorded history fabricates none on its next transition")
    func legacyRowFabricatesNoHistory() {
        // A task persisted before the timeline shipped: no visits at all.
        let task = TaskItem(
            title: "x", status: .inbox, createdAt: t0.addingTimeInterval(-30 * 24 * 3600))
        task.stateTimeline = []

        task.transition(to: .active, now: t0)

        // The 30 days it sat before we were watching are NOT invented.
        #expect(task.secondsIn(.inbox) == 0)
        #expect(task.stateTimeline.count == 1)
        #expect(task.stateTimeline[0].state == TaskStatus.active.rawValue)
        #expect(task.stateTimeline[0].enteredAt == t0)
    }
}

// MARK: - Formatting

@Suite("Task timeline formatting")
struct TaskTimelineFormatTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    @Test("Sub-minute durations report nothing rather than a rounded zero")
    func subMinuteIsNoSignal() {
        #expect(TaskTimeline.compactDuration(0) == nil)
        #expect(TaskTimeline.compactDuration(59) == nil)
    }

    @Test("Compact duration scales through minutes, hours, days")
    func compactDurationScales() {
        #expect(TaskTimeline.compactDuration(60) == "1m")
        #expect(TaskTimeline.compactDuration(25 * 60) == "25m")
        #expect(TaskTimeline.compactDuration(3600) == "1h")
        #expect(TaskTimeline.compactDuration(90 * 60) == "1h 30m")
        #expect(TaskTimeline.compactDuration(3 * 24 * 3600) == "3d")
    }

    @Test("A task with no recorded history says nothing")
    func noHistoryNoSummary() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        task.stateTimeline = []
        #expect(TaskTimeline.summary(for: task, now: at(500)) == nil)
    }

    @Test("A brand-new task says nothing until there's something to report")
    func subMinuteTaskSaysNothing() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        #expect(TaskTimeline.summary(for: task, now: t0.addingTimeInterval(5)) == nil)
    }

    @Test("An unresolved task reports its current dwell, phrased per status")
    func unresolvedReportsDwell() {
        let active = TaskItem(title: "x", status: .active, createdAt: t0)
        #expect(TaskTimeline.summary(for: active, now: at(180)) == "Active for 3h")

        let inbox = TaskItem(title: "z", status: .inbox, createdAt: t0)
        #expect(TaskTimeline.summary(for: inbox, now: at(120)) == "Awaiting your confirm for 2h")
    }

    @Test("A resolved task reports total time end-to-end")
    func resolvedReportsTotals() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        task.complete(now: at(120))
        #expect(TaskTimeline.summary(for: task, now: at(200)) == "Done · took 2h")
    }

    @Test("A killed task is named honestly")
    func killedIsNamedHonestly() {
        let task = TaskItem(title: "x", status: .active, createdAt: t0)
        task.kill(now: at(120))
        #expect(TaskTimeline.summary(for: task, now: at(200)) == "Killed · took 2h")
    }
}
