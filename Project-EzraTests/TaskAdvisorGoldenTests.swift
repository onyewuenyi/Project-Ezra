//
//  TaskAdvisorGoldenTests.swift
//  Project-EzraTests
//
//  The Advisor's product acceptance tests: whole scenarios, not individual services.
//  Each one exercises THE LOOP —
//
//      task state → judgment → next move → human action → task state changes → re-judge
//
//  — which is the product thesis, and which shipped broken (the store only judged at
//  mount and on `isActive` flips, so a reading survived the action that invalidated
//  it). These are the tests that would have caught it.
//
//  The judge is injected (`ModelRun` is inert under XCTest), and every canned judge
//  here READS THE FACTS rather than replaying a script — so "the reading changed"
//  can only pass if the facts genuinely changed, which is the thing under test.
//
//  Each scenario asserts the same three things: the previous reading is gone, a NEW
//  fingerprint was evaluated, and no intermediate reading was shown.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Task Advisor — golden scenarios (the loop)")
struct TaskAdvisorGoldenTests {

    // MARK: - Harness

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func freshMetrics() -> AdvisorMetrics {
        let name = "advisor-golden-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AdvisorMetrics(defaults: defaults)
    }

    /// Counts judgments so a scenario can assert that a NEW evaluation happened (or,
    /// for the silent case, that none ever did).
    private final class JudgeSpy {
        var calls = 0
        var lastFacts: TaskAdvisorFacts?
        /// Which rung the router sent this judgment to. Recorded so a scenario can assert
        /// on routing without a second store — and so the golden scenarios stay honest
        /// about the fact that they run with no cloud provider installed.
        var lastRung: IntelligenceRung?
    }

    private func reading(
        _ move: AdvisorMove, _ observation: String, options: [AdvisorChoice] = [],
        recommendation: AdvisorRecommendation? = nil, steps: [BreakdownStep] = []
    ) -> ValidatedReading {
        ValidatedReading(
            move: move, observation: observation, guidance: nil, nextMove: nil,
            options: options, recommendation: recommendation, steps: steps)
    }

    /// Build a store whose judge derives its reading from the facts it is handed.
    /// `isModelAvailable` is forced true: `AppBrain.onDeviceModelAvailable()` is
    /// hard-false under XCTest, which would route every worthy task to `.fallback`
    /// and never reach the judge.
    private func store(
        _ spy: JudgeSpy, _ judge: @escaping @MainActor (TaskAdvisorFacts) -> ValidatedReading
    ) -> TaskAdvisorStore {
        TaskAdvisorStore(
            judge: { facts, rung, _ in
                spy.calls += 1
                spy.lastFacts = facts
                spy.lastRung = rung
                return .success(judge(facts))
            },
            isModelAvailable: { true },
            metrics: freshMetrics())
    }

    private func revealed(_ state: AdvisorState) -> ValidatedReading? {
        if case .revealed(let reading) = state { return reading }
        return nil
    }

    // MARK: - blocked → unblocked

    @Test("Resolving the blocker retires the blocker reading and judges the new state")
    func blockedBecomesReady() async {
        let context = context()
        let spy = JudgeSpy()
        // The canned judge reads the FACTS: with a blocker it says openBlocker, without
        // one it says you're ready. So the transition can only be observed if the
        // Advisor actually re-judged against changed facts.
        let store = store(spy) { facts in
            facts.blockerTitles.isEmpty
                ? self.reading(.advise, "You're ready to continue.")
                : self.reading(.openBlocker, "Waiting on \(facts.blockerTitles[0]).")
        }

        // `.doing`: you were working on it when you hit the blocker. Work in flight is
        // always advisor-worthy, so this exercises the loop all the way back through
        // the JUDGE — the case where there is still something worth saying.
        let task = TaskItem(title: "Fix the boiler", status: .doing, in: context)
        let blocker = TaskItem(title: "Get the replacement part quote", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])

        store.ensure(task: task, among: [task, blocker])
        await store.awaitPendingJudgment(for: task.uuid)
        let first = revealed(store.state(for: task))
        #expect(first?.move == .openBlocker)
        #expect(spy.calls == 1)

        // The human acts: opens the blocker, resolves it, comes back. The blocker's
        // status changed — this task's `updatedAt` did not — which is why the detail
        // needs its own re-ensure on sheet dismissal.
        blocker.complete()
        store.ensure(task: task, among: [task, blocker])
        await store.awaitPendingJudgment(for: task.uuid)

        let second = revealed(store.state(for: task))
        #expect(spy.calls == 2)  // a new fingerprint reached the judge
        #expect(second?.move == .advise)  // the previous reading is gone
        #expect(second?.observation == "You're ready to continue.")
    }

    @Test("When nothing is left to say, the loop closes to silence — not to a new sentence")
    func clearingTheLastSignalGoesQuiet() async {
        let context = context()
        let spy = JudgeSpy()
        let store = store(spy) { facts in
            self.reading(.openBlocker, "Waiting on \(facts.blockerTitles.first ?? "").")
        }

        let task = TaskItem(title: "Fix the boiler", status: .todo, in: context)
        let blocker = TaskItem(title: "Get the part quote", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])

        store.ensure(task: task, among: [task, blocker])
        await store.awaitPendingJudgment(for: task.uuid)
        #expect(revealed(store.state(for: task))?.move == .openBlocker)

        // Blocker cleared, and this `.todo` task now carries no signal at all. The
        // stale reading MUST go — that is the bug this suite exists for — but what it
        // gives way to is silence, not a closing remark: the user just cleared the
        // blocker themselves, so "you're unblocked" is the Advisor narrating the
        // user's own action back at them. Silence is the answer, and it costs nothing.
        blocker.complete()
        store.ensure(task: task, among: [task, blocker])
        await store.awaitPendingJudgment(for: task.uuid)

        #expect(store.state(for: task) == .quiet(.gate))
        #expect(spy.calls == 1)  // re-judged by the gate, for free
    }

    // MARK: - broad → decomposed

    @Test("Creating the steps retires the broad-outcome reading")
    func broadBecomesDecomposed() async {
        let context = context()
        let spy = JudgeSpy()
        let store = store(spy) { facts in
            facts.stepLabel == nil
                ? self.reading(
                    .createSteps, "This is still a broad outcome.",
                    steps: [
                        BreakdownStep(title: "Pick a provider", effortMinutes: 30),
                        BreakdownStep(title: "Book the appointment", effortMinutes: 15),
                    ])
                : self.reading(.advise, "The first step is ready to start.")
        }

        let task = TaskItem(
            title: "Sort out the pediatrician", status: .todo, effortMinutes: 120, in: context)
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)
        let proposed = revealed(store.state(for: task))
        #expect(proposed?.move == .createSteps)
        #expect(proposed?.steps.count == 2)

        // The human accepts — the one capability that commits.
        task.splitInto(proposed!.steps, in: context)
        let all = allTasks(in: context)
        #expect(task.children(among: all).count == 2)

        store.ensure(task: task, among: all)
        await store.awaitPendingJudgment(for: task.uuid)

        // The broad-outcome reading is gone: the umbrella has been decomposed, so it
        // is no longer breakdown-eligible and carries no other signal. The container
        // going quiet is consistent with `containerRecede` — a task you have usefully
        // decomposed should get out of its own steps' way, not keep talking. The
        // steps are where the work (and any future reading) now lives.
        #expect(revealed(store.state(for: task)) == nil)
        #expect(store.state(for: task) == .quiet(.gate))
    }

    // MARK: - ambiguous → decided

    @Test("Deciding clears the flag and retires the decision reading")
    func ambiguousBecomesDecided() async {
        let context = context()
        let spy = JudgeSpy()
        let store = store(spy) { facts in
            guard facts.needsDecision else {
                return self.reading(.advise, "The call is made; the rest is booking.")
            }
            // Ambiguous by construction — a judgment call with no clear winner, so the
            // canned judge abstains exactly as the product rule requires.
            return self.reading(
                .decide, "You need to choose between the two providers.",
                options: [
                    AdvisorChoice(label: "Dell Children's", tradeoff: "Higher cost, shorter drive."),
                    AdvisorChoice(label: "ARC", tradeoff: "Lower cost, longer drive."),
                ])
        }

        let task = TaskItem(title: "Choose a pediatrician", status: .todo, in: context)
        task.needsDecision = true
        task.isJudgmentCall = true

        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)
        let first = revealed(store.state(for: task))
        #expect(first?.move == .decide)
        #expect(first?.options.count == 2)
        #expect(first?.recommendation == nil)  // abstention: the facts favour neither

        // The human decides ON an option — the only thing that clears the flag.
        task.resolveDecisionAndLog(in: context, choice: "ARC")
        #expect(!task.needsDecision)
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)

        let after = revealed(store.state(for: task))
        #expect(spy.calls == 2)
        #expect(after?.move == .advise)
        #expect(after?.options.isEmpty == true)
    }

    // MARK: - clean → silent

    @Test("A clean task is silent for free — the model is never asked")
    func cleanStaysSilent() async {
        let context = context()
        let spy = JudgeSpy()
        let store = store(spy) { _ in self.reading(.advise, "should never be produced") }

        let task = TaskItem(title: "Call the dentist", status: .todo, effortMinutes: 15, in: context)
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)

        #expect(store.state(for: task) == .quiet(.gate))
        #expect(spy.calls == 0)  // zero model cost, by the gate
    }

    // MARK: - The one-interpretation contract

    @Test("A fingerprint produces at most one visible interpretation")
    func oneInterpretationPerFingerprint() async {
        let context = context()
        let spy = JudgeSpy()
        // A judge that would happily say something different every call — the contract
        // must hold in spite of it, not because the judge is stable.
        let store = store(spy) { facts in
            self.reading(.advise, "Reading number \(spy.calls) for \(facts.title).")
        }

        let task = TaskItem(title: "Sort the garage", status: .todo, in: context)
        task.deferralCount = 4

        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)
        let first = revealed(store.state(for: task))
        #expect(first != nil)

        // Re-render, re-activate, re-ensure: nothing changed about the task, so the
        // user must never see the Advisor appear to change its mind.
        for _ in 0..<3 {
            store.ensure(task: task, among: [task])
            await store.awaitPendingJudgment(for: task.uuid)
        }
        #expect(revealed(store.state(for: task)) == first)
        #expect(spy.calls == 1)  // and it was never even re-asked

        // A swipe away and back (the pager keeps neighbours mounted) also holds: the
        // revealed entry survives cancellation, which only drops in-flight work.
        store.cancel(taskID: task.uuid)
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)
        #expect(revealed(store.state(for: task)) == first)

        // Only a genuine fact change reopens it.
        task.deferralCount = 9
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)
        #expect(revealed(store.state(for: task)) != first)
        #expect(spy.calls == 2)
    }

    // MARK: -

    private func allTasks(in context: NSManagedObjectContext) -> [TaskItem] {
        let request = NSFetchRequest<TaskItem>(entityName: "TaskItem")
        return (try? context.fetch(request)) ?? []
    }
}
