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

    // MARK: - ModelMetrics parse shape

    @Test("Parse-shape trio records in memory and renders in the footer line")
    func parseShapeRecordsAndRenders() {
        let metrics = ModelMetrics(defaults: freshDefaults())
        metrics.record(
            .captureTriage, .salvaged, latencyMs: 30_150, retrievalMs: 85, firstPartialMs: 1_900,
            partialCount: 7)

        let stats = metrics.stats[.captureTriage]
        #expect(stats?.lastRetrievalMs == 85)
        #expect(stats?.lastFirstPartialMs == 1_900)
        #expect(stats?.lastPartialCount == 7)

        let line = metrics.footerLines().first { $0.contains("capture") }
        #expect(line?.contains("first 1.9s") == true)
        #expect(line?.contains("retr 85ms") == true)
        #expect(line?.contains("7 partials") == true)
    }

    @Test("Token accounting records separately and renders as used/context")
    func tokenAccountingRenders() {
        let metrics = ModelMetrics(defaults: freshDefaults())
        metrics.record(.captureTriage, .success, latencyMs: 900)
        metrics.recordTokens(.captureTriage, promptTokens: 812, contextSize: 4096)

        let line = metrics.footerLines().first { $0.contains("capture") }
        #expect(line?.contains("812/4096 tok") == true)
    }

    @Test("A capability that reports no parse shape keeps its footer line unchanged")
    func parseShapeOmittedWhenUnreported() {
        let metrics = ModelMetrics(defaults: freshDefaults())
        metrics.record(.captureTriage, .success, latencyMs: 800)

        let line = metrics.footerLines().first { $0.contains("capture") }
        #expect(line?.contains("first") == false)
        #expect(line?.contains("retr") == false)
        #expect(line?.contains("partials") == false)
    }
}

@MainActor
@Suite("Advisor outcomes")
struct AdvisorMetricsTests {

    private func freshDefaults() -> UserDefaults {
        let name = "advisor-metrics-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Offered, acted and dismissed count independently and persist across instances")
    func countersPersist() {
        let defaults = freshDefaults()
        let metrics = AdvisorMetrics(defaults: defaults)
        metrics.recordOffered(.advise)
        metrics.recordOffered(.advise)
        metrics.recordActed(.advise, taskID: UUID(), status: .todo)
        metrics.recordDismissed(.advise)
        metrics.recordOffered(.decide)

        let reloaded = AdvisorMetrics(defaults: defaults)
        #expect(reloaded.stats[.advise] == .init(offered: 2, acted: 1, dismissed: 1))
        #expect(reloaded.stats[.decide] == .init(offered: 1, acted: 0, dismissed: 0))
        #expect(reloaded.actedEvents.count == 1)
    }

    @Test("The footer reads acted/offered, silence shows alone, fresh installs stay silent")
    func footerLine() {
        let metrics = AdvisorMetrics(defaults: freshDefaults())
        #expect(metrics.footerLine == nil)  // no line beats a row of zeros
        metrics.recordOffered(.nothing)
        metrics.recordOffered(.decide)
        metrics.recordActed(.decide, taskID: nil, status: .todo)
        #expect(metrics.footerLine == "advisor: zip 1 · dec 1/1")
    }

    @Test("Progression judges moved work, not AI activity")
    func progression() {
        let context = TestStore.makeContext()
        let metrics = AdvisorMetrics(defaults: freshDefaults())

        // Advised and finished → progressed.
        let done = TaskItem(title: "Renew passport", status: .todo, in: context)
        metrics.recordActed(.advise, taskID: done.uuid, status: .todo)
        done.complete()

        // Advised twice and still sitting where the advice found it → not progressed,
        // and the repeat intervention shows in the re-intervention rate.
        let stuck = TaskItem(title: "Sort the garage", status: .todo, in: context)
        metrics.recordActed(.advise, taskID: stuck.uuid, status: .todo)
        metrics.recordActed(.decide, taskID: stuck.uuid, status: .todo)

        let line = metrics.progressionLine(among: [done, stuck])
        #expect(line == "moved 50% · re-int 1.5")
    }

    @Test("An action that itself moved the task still needs FURTHER movement to count")
    func progressionBaseline() {
        let context = TestStore.makeContext()
        // "Do it now" acted from `.todo` and the task now sits `.doing`: that IS
        // progress past the baseline. But an intervention that found it already
        // `.doing` needs resolution to count.
        let task = TaskItem(title: "Write the report", status: .doing, in: context)
        #expect(AdvisorMetrics.hasProgressed(task, since: TaskStatus.todo.rawValue))
        #expect(!AdvisorMetrics.hasProgressed(task, since: TaskStatus.doing.rawValue))
        task.complete()
        #expect(AdvisorMetrics.hasProgressed(task, since: TaskStatus.doing.rawValue))
    }

    @Test("The acted-event list is evidence, not history — it stays capped")
    func actedEventsCap() {
        let metrics = AdvisorMetrics(defaults: freshDefaults())
        for _ in 0..<(AdvisorMetrics.maxActedEvents + 25) {
            metrics.recordActed(.advise, taskID: UUID(), status: .todo)
        }
        #expect(metrics.actedEvents.count == AdvisorMetrics.maxActedEvents)
    }
}
