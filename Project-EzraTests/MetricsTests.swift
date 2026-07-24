//
//  MetricsTests.swift
//  Project-EzraTests
//
//  The PRD's success instrumentation. Acceptance and rot are pure derivations over
//  model arrays; the recorder persists only opens and the first-payoff stamp. All
//  of it must be honest: no signal, no number (nil, never a fake 0% or 100%).
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Derived metrics")
struct MetricsDerivationTests {

    @Test("Acceptance rate is the fraction of AI actions left standing")
    func acceptanceRate() {
        let kept = ChangeLogEntry(summary: "Filed A", initiatedBy: .ai)
        let undone = ChangeLogEntry(summary: "Filed B", initiatedBy: .ai)
        undone.undone = true
        #expect(Metrics.acceptanceRate(entries: [kept, undone]) == 0.5)
        #expect(Metrics.acceptanceRate(entries: [kept]) == 1.0)
    }

    @Test("Human entries never count toward the AI acceptance number")
    func acceptanceRateIgnoresHumanEntries() {
        let ai = ChangeLogEntry(summary: "Filed A", initiatedBy: .ai)
        let human = ChangeLogEntry(summary: "Edited B", initiatedBy: .human)
        #expect(Metrics.acceptanceRate(entries: [ai, human]) == 1.0)
        // Only-human logs produce no number at all — there is no AI to rate.
        #expect(Metrics.acceptanceRate(entries: [human]) == nil)
    }

    @Test("No trail entries means no acceptance number, not a fake one")
    func acceptanceRateEmpty() {
        #expect(Metrics.acceptanceRate(entries: []) == nil)
    }

    @Test("\"planned\" entries never count toward acceptance — a plan isn't an accepted action")
    func acceptanceRateIgnoresPlannedEntries() {
        let filing = ChangeLogEntry(summary: "Filed A", action: "filed", initiatedBy: .ai)
        let planned = ChangeLogEntry(
            summary: "Planned 4 actions for today", action: "planned", initiatedBy: .ai)
        planned.undone = true  // an undone plan must not drag the trust number down
        #expect(Metrics.acceptanceRate(entries: [filing, planned]) == 1.0)
        // Only planned entries → no acceptance number at all.
        #expect(Metrics.acceptanceRate(entries: [planned]) == nil)
    }

    @Test("Rot rate counts resolutions that happened after the staleness threshold")
    func rotRate() {
        let fresh = TaskItem(title: "fresh", createdAt: Date().addingTimeInterval(-3600))
        fresh.complete()
        let rotted = TaskItem(title: "rotted", createdAt: Date().addingTimeInterval(-9 * 24 * 3600))
        rotted.complete()
        let open = TaskItem(title: "open")  // unresolved tasks don't count either way
        #expect(Metrics.rotRate(tasks: [fresh, rotted, open]) == 0.5)
    }

    @Test("No resolved tasks means no rot number")
    func rotRateEmpty() {
        #expect(Metrics.rotRate(tasks: [TaskItem(title: "open")]) == nil)
    }
}

@Suite("Metrics recorder")
struct MetricsRecorderTests {

    private func freshDefaults() -> UserDefaults {
        let name = "metrics-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Opens increment and persist across recorder instances")
    func opensPersist() {
        let defaults = freshDefaults()
        let recorder = MetricsRecorder(defaults: defaults)
        recorder.recordOpen()
        recorder.recordOpen()
        #expect(recorder.selfInitiatedOpens == 2)
        #expect(MetricsRecorder(defaults: defaults).selfInitiatedOpens == 2)
    }

    @Test("First payoff stamps once, measured from install")
    func firstPayoffStampsOnce() {
        let defaults = freshDefaults()
        let install = Date(timeIntervalSince1970: 1_000_000)
        let recorder = MetricsRecorder(defaults: defaults, now: install)
        #expect(recorder.timeToFirstPayoff == nil)

        recorder.recordFirstPayoffIfNeeded(now: install.addingTimeInterval(42))
        #expect(recorder.timeToFirstPayoff == 42)

        // A later commit never moves the stamp.
        recorder.recordFirstPayoffIfNeeded(now: install.addingTimeInterval(500))
        #expect(recorder.timeToFirstPayoff == 42)
    }

    @Test("Install date persists so payoff survives relaunch")
    func installPersists() {
        let defaults = freshDefaults()
        let install = Date(timeIntervalSince1970: 2_000_000)
        _ = MetricsRecorder(defaults: defaults, now: install)
        let relaunched = MetricsRecorder(defaults: defaults, now: install.addingTimeInterval(999))
        #expect(relaunched.installedAt == install)
    }
}
