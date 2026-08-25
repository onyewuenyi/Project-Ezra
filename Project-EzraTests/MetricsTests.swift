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

    @Test("Gate skips are counted apart from judged silence — different questions")
    func gatedIsNotNothing() {
        let defaults = freshDefaults()
        let metrics = AdvisorMetrics(defaults: defaults)
        metrics.recordGated()
        metrics.recordGated()
        metrics.recordOffered(.nothing)

        // "We skipped this for free" and "the model looked and declined" must not share
        // a counter: gate skips accumulate on every fingerprint change of every trivial
        // task and would swamp the honesty denominator.
        #expect(metrics.gated == 2)
        #expect(metrics.stats[.nothing]?.offered == 1)
        #expect(metrics.footerLine == "advisor: gated 2 · zip 1")
        #expect(AdvisorMetrics(defaults: defaults).gated == 2)  // persists

        metrics.reset()
        #expect(metrics.gated == 0)
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
        // `lift n/a` is the important half. With no judged-silence cohort there is nothing
        // to compare against, and the footer says so rather than reporting the bare
        // advised rate as though it meant something — "no difference measured" and "no
        // measurement possible" are different claims.
        #expect(line == "moved 50% (2) · lift n/a · re-int 1.5")
    }

    @Test("Progression LIFT compares advised tasks against judged-silent ones")
    func progressionLift() {
        let context = TestStore.makeContext()
        let metrics = AdvisorMetrics(defaults: freshDefaults())

        // Treatment: two advised, one moved → 50%.
        let advisedMoved = TaskItem(title: "Renew passport", status: .todo, in: context)
        metrics.recordActed(.advise, taskID: advisedMoved.uuid, status: .todo)
        advisedMoved.complete()
        let advisedStuck = TaskItem(title: "Sort the garage", status: .todo, in: context)
        metrics.recordActed(.advise, taskID: advisedStuck.uuid, status: .todo)

        // Control: the Advisor looked at two worthy tasks and judged silence. Neither
        // moved → 0%. Lift is therefore +50 points.
        let silentA = TaskItem(title: "Book the dentist", status: .todo, in: context)
        let silentB = TaskItem(title: "Fix the gate", status: .todo, in: context)
        metrics.recordJudgedSilence(taskID: silentA.uuid, status: .todo)
        metrics.recordJudgedSilence(taskID: silentB.uuid, status: .todo)

        let all = [advisedMoved, advisedStuck, silentA, silentB]
        let (advised, silent, lift) = metrics.progression(among: all)
        #expect(advised == AdvisorMetrics.Cohort(moved: 1, total: 2))
        #expect(silent == AdvisorMetrics.Cohort(moved: 0, total: 2))
        #expect(lift == 0.5)
        #expect(metrics.progressionLine(among: all)?.contains("lift +50pt") == true)
    }

    @Test("A task that was advised never counts as its own control")
    func controlCohortIsUncontaminated() {
        let context = TestStore.makeContext()
        let metrics = AdvisorMetrics(defaults: freshDefaults())

        // Advised once, then judged silent later (the facts changed and the Advisor had
        // nothing to add). It belongs to the TREATMENT group — the intervention is the
        // thing whose effect is being measured. Counting it in both would dilute the
        // difference towards zero and make a working Advisor look ineffective.
        let task = TaskItem(title: "Decide on the school", status: .todo, in: context)
        metrics.recordActed(.decide, taskID: task.uuid, status: .todo)
        metrics.recordJudgedSilence(taskID: task.uuid, status: .todo)
        task.complete()

        let (advised, silent, lift) = metrics.progression(among: [task])
        #expect(advised == AdvisorMetrics.Cohort(moved: 1, total: 1))
        #expect(silent == AdvisorMetrics.Cohort(moved: 0, total: 0))
        // No usable control ⇒ no lift claim.
        #expect(lift == nil)
    }

    @Test("A negative lift is reported with its sign — it is the most important reading")
    func negativeLiftIsVisible() {
        let context = TestStore.makeContext()
        let metrics = AdvisorMetrics(defaults: freshDefaults())

        // The falsifying case: advised work sat still while silent work moved. If the
        // Advisor is not helping, this footer has to be able to say so — an unsigned
        // percentage would let the bad news hide in plain sight.
        let advised = TaskItem(title: "Plan the birthday", status: .todo, in: context)
        metrics.recordActed(.advise, taskID: advised.uuid, status: .todo)
        let silent = TaskItem(title: "Pay the water bill", status: .todo, in: context)
        metrics.recordJudgedSilence(taskID: silent.uuid, status: .todo)
        silent.complete()

        let all = [advised, silent]
        #expect(metrics.progression(among: all).lift == -1.0)
        #expect(metrics.progressionLine(among: all)?.contains("lift -100pt") == true)
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
