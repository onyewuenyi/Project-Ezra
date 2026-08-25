//
//  DeterministicReadingTests.swift
//  Project-EzraTests
//
//  The rung-0 floor: a task the gate judged worthy must never reach a surface that
//  labels itself and then says nothing.
//
//  The four cases pinned below are the ones that were structurally impossible before,
//  and the reason is worth keeping in the test rather than only in the fix. The
//  no-model path rendered `StallDiagnosis.headline`, and `StallDetector.diagnose`
//  answers for exactly one of the gate's nine worthy reasons:
//
//    · `.decisionFlag` — excluded by an explicit guard inside `diagnose`
//    · `.blocked` / `.doing` / `.overdue` — checked AFTER `.stalled` in a
//      first-match-wins gate, so reaching them means the diagnosis is nil by construction
//
//  So these four could not produce fallback content no matter what the user did.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Advisor — the deterministic floor")
struct DeterministicReadingTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func reading(_ task: TaskItem, among tasks: [TaskItem]) -> ValidatedReading? {
        DeterministicReading.make(from: TaskAdvisorFacts.make(task: task, among: tasks))
    }

    @Test("A flagged decision speaks — the largest cohort the diagnosis could never reach")
    func flaggedDecisionSpeaks() {
        let context = context()
        let task = TaskItem(title: "Pick a school for September", status: .todo, in: context)
        task.needsDecision = true
        task.isJudgmentCall = true

        let reading = reading(task, among: [task])
        #expect(reading?.observation.isEmpty == false)
        #expect(reading?.move == .advise)  // rung 0 must never fabricate options
        #expect(reading?.options.isEmpty == true)
    }

    @Test("A blocked task names its blocker, and the move carries a real edge")
    func blockedNamesTheBlocker() {
        let context = context()
        let blocker = TaskItem(title: "Send Maya the numbers", status: .todo, in: context)
        let task = TaskItem(title: "Sign the vendor contract", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])

        let reading = reading(task, among: [task, blocker])
        #expect(reading?.move == .openBlocker)
        #expect(reading?.observation.contains("Send Maya the numbers") == true)
    }

    @Test("An external wait speaks — the blocker with no task to open")
    func externalWaitSpeaks() {
        let context = context()
        let task = TaskItem(title: "Sign the lease", status: .todo, in: context)
        task.addExternalBlocker("the landlord to send the final copy", among: [task])

        // `activeBlockerTasks` resolves `taskID`, so this blocker is invisible to
        // `blockerTitles`. Before `externalWaits` the task read as blocked to the gate
        // and as unblocked to every rung — including the prompt.
        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        #expect(facts.blockerTitles.isEmpty)
        #expect(facts.externalWaits == ["the landlord to send the final copy"])
        #expect(facts.promptBlock.contains("WAITING ON: the landlord to send the final copy"))

        let reading = DeterministicReading.make(from: facts)
        #expect(reading?.observation.contains("the landlord") == true)
        // NOT `.openBlocker`: there is no row to open, and the trust boundary would
        // degrade the move anyway.
        #expect(reading?.move == .advise)
    }

    @Test("Adding or clearing an external wait re-judges — it has no id to ride on")
    func externalWaitIsInTheFingerprint() {
        let context = context()
        let task = TaskItem(title: "Sign the lease", status: .todo, in: context)
        let before = TaskAdvisorFacts.make(task: task, among: [task]).fingerprint
        task.addExternalBlocker("the landlord", among: [task])
        let after = TaskAdvisorFacts.make(task: task, among: [task]).fingerprint
        #expect(before != after)
    }

    @Test("An overdue task states the fact, without inventing a reason for it")
    func overdueStatesTheFact() {
        let context = context()
        let task = TaskItem(title: "Renew the insurance", status: .todo, in: context)
        task.dueDate = Calendar.current.date(byAdding: .day, value: -3, to: Date())

        let reading = reading(task, among: [task])
        #expect(reading?.observation.isEmpty == false)
        #expect(reading?.move == .advise)
    }

    @Test("Rung 0 stays silent where it has nothing factual to say")
    func silenceWhereThereIsNothingToSay() {
        let context = context()
        // Plain, live, unflagged, unblocked, undated, small — the gate would not even
        // open here, and rung 0 must agree rather than manufacture a sentence.
        let task = TaskItem(title: "Call the dentist", status: .todo, effortMinutes: 15, in: context)
        #expect(reading(task, among: [task]) == nil)
    }

    @Test("A resolved task is never advised")
    func resolvedIsSilent() {
        let context = context()
        let task = TaskItem(title: "Pick a school", status: .todo, in: context)
        task.needsDecision = true
        task.complete()
        #expect(reading(task, among: [task]) == nil)
    }

    @Test("The diagnosed stall defers to the richer template that owns its action links")
    func diagnosedStallDefers() {
        let context = context()
        let task = TaskItem(title: "Plan the birthday dinner", status: .todo, in: context)
        task.deferralCount = 4  // past StallDetector.deferralThreshold

        // The view renders `fallbackContent` here — headline PLUS "Do it now" / "Defer
        // it" / "Let it go". Duplicating it as a bare `.advise` would drop those buttons.
        #expect(TaskAdvisorFacts.make(task: task, among: [task]).diagnosis != nil)
        #expect(reading(task, among: [task]) == nil)
    }

    @Test("Every reading carries its evidence, bound to the facts it was built from")
    func evidenceTravelsWithTheReading() {
        let context = context()
        let task = TaskItem(title: "Renew the insurance", status: .todo, in: context)
        task.dueDate = Calendar.current.date(byAdding: .day, value: -3, to: Date())
        task.isUrgent = true

        let reading = reading(task, among: [task])
        #expect(reading?.evidence.isEmpty == false)
    }
}

@MainActor
@Suite("Advisor — a failed generation falls to the floor, not to an error")
struct AdvisorFailureFloorTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func store(_ outcome: ModelResult<ValidatedReading>) -> TaskAdvisorStore {
        let name = "advisor-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return TaskAdvisorStore(
            judge: { _, _, _ in outcome },
            isModelAvailable: { true },
            metrics: AdvisorMetrics(defaults: defaults))
    }

    /// The case a device run caught: the model reports `.available`, the call fails
    /// anyway (an empty model catalog, a 429), and the surface used to read
    /// "That didn't finish. Try again." — an error string where §07 promises facts,
    /// offering a retry that cannot succeed.
    @Test("A thrown generation degrades to rung 0, not to a retry line")
    func failureFallsToTheFloor() async {
        let context = context()
        let blocker = TaskItem(title: "Send Maya the numbers", status: .todo, in: context)
        let task = TaskItem(title: "Sign the vendor contract", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])

        let store = store(.failed(ModelResult<ValidatedReading>.noUsableOutput))
        store.ensure(task: task, among: [task, blocker])
        await store.awaitPendingJudgment(for: task.uuid)

        guard case .fallback(let reading) = store.state(for: task) else {
            Issue.record("expected .fallback, got \(store.state(for: task))")
            return
        }
        #expect(reading?.observation.contains("Send Maya the numbers") == true)
    }

    @Test("A timeout degrades the same way — running out of time is not a verdict")
    func timeoutFallsToTheFloor() async {
        let context = context()
        let task = TaskItem(title: "Pick a school", status: .todo, in: context)
        task.needsDecision = true

        let store = store(.timedOut)
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)

        if case .fallback = store.state(for: task) {
        } else {
            Issue.record("expected .fallback, got \(store.state(for: task))")
        }
    }

    /// The retry seam still exists where rung 0 genuinely has nothing — silence is not
    /// the same as a floor, and collapsing the two would delete a real affordance.
    @Test("With no floor to fall to, the failure stays a failure")
    func failureWithoutAFloorStaysFailed() async {
        let context = context()
        // `.doing` with no steps, no blockers, no dependents, no flag: worthy by the
        // gate, but rung 0 has no fact to state.
        let task = TaskItem(title: "Tidy the garage", status: .todo, effortMinutes: 15, in: context)
        task.status = .doing

        let store = store(.failed("boom"))
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)

        if case .failed = store.state(for: task) {
        } else {
            Issue.record("expected .failed, got \(store.state(for: task))")
        }
    }
}
