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

    @Test("The floor never restates the spine: a bare flag is the obligation block's to state")
    func flaggedAloneIsSilent() {
        let context = context()
        let task = TaskItem(title: "Pick a school for September", status: .todo, in: context)
        task.needsDecision = true
        task.isJudgmentCall = true
        // The obligation block renders whenever the flag is set — model or no model —
        // so a floor sentence saying "this is flagged" was the block repeated in
        // prose. Silence here is the correct reading.
        #expect(reading(task, among: [task]) == nil)
    }

    @Test("A flagged task with an ADDITIVE fact speaks to that fact, not the flag")
    func flaggedWithAdditiveFactSpeaks() {
        let context = context()
        let task = TaskItem(title: "Pick a school for September", status: .todo, in: context)
        task.needsDecision = true
        task.dueDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())

        let reading = reading(task, among: [task])
        #expect(reading?.move == .advise)
        #expect(reading?.observation.contains("due") == true)
        #expect(reading?.options.isEmpty == true)  // rung 0 must never fabricate options
    }

    @Test("A purely blocked task is silent — the waiting spine already names the wait")
    func blockedAloneIsSilent() {
        let context = context()
        let blocker = TaskItem(title: "Send Maya the numbers", status: .todo, in: context)
        let task = TaskItem(title: "Sign the vendor contract", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])
        #expect(reading(task, among: [task, blocker]) == nil)
    }

    @Test("A FLAGGED blocked task still names its blocker — the deciding spine does not")
    func blockedUnderAFlagSpeaks() {
        let context = context()
        let blocker = TaskItem(title: "Send Maya the numbers", status: .todo, in: context)
        let task = TaskItem(title: "Sign the vendor contract", status: .todo, in: context)
        task.addTaskBlocker(blocker.uuid!, among: [task, blocker])
        task.needsDecision = true

        // Shape is .deciding (the flag wins precedence), so the page's spine is the
        // obligation block and the blocker fact is ADDITIVE — the floor states it.
        let reading = reading(task, among: [task, blocker])
        #expect(reading?.move == .openBlocker)
        #expect(reading?.observation.contains("Send Maya the numbers") == true)
    }

    @Test("An external wait reaches the facts and the prompt; the WAITING page renders it as the spine")
    func externalWaitReachesTheFacts() {
        let context = context()
        let task = TaskItem(title: "Sign the lease", status: .todo, in: context)
        task.addExternalBlocker("the landlord to send the final copy", among: [task])

        // The fact travels — prompt and evidence — even though the floor stays
        // silent on the waiting page (the spine renders the wait, hourglass and all).
        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        #expect(facts.blockerTitles.isEmpty)
        #expect(facts.externalWaits == ["the landlord to send the final copy"])
        #expect(facts.promptBlock.contains("WAITING ON: the landlord to send the final copy"))
        #expect(DeterministicReading.make(from: facts) == nil)

        // Under a flag the wait is additive again — and NOT `.openBlocker`, because
        // there is no row to open.
        task.needsDecision = true
        let flagged = reading(task, among: [task])
        #expect(flagged?.move == .advise)
        #expect(flagged?.observation.contains("the landlord") == true)
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

    @Test("Axis 2 never becomes the floor's voice — planningIntent is silent, its peers speak")
    func planningIntentNeverSpeaks() {
        let context = context()
        // `.planningIntent` derives from the internal workIntent classifier; voicing
        // it would be axis 2 rendered as UI. Its peers are grounded in user-visible
        // facts and keep their sentences.
        let planning = TaskItem(title: "Sort the estate", status: .todo, in: context)
        planning.workIntent = .planning
        #expect(
            BreakdownEligibility.evaluate(planning, among: [planning]) == .planningIntent)
        #expect(reading(planning, among: [planning]) == nil)

        let big = TaskItem(
            title: "Repaint the hallway", status: .todo, effortMinutes: 120, in: context)
        #expect(reading(big, among: [big])?.observation.isEmpty == false)
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

    @Test("Only the arm that names a task cites it — and a citation is a declared edge")
    func citationsBelongToTheDependentsArm() {
        let context = context()
        // The dependents arm cites what it names, capped.
        let task = TaskItem(title: "Confirm the guest count", status: .todo, in: context)
        let dependent = TaskItem(title: "Book the venue", status: .todo, in: context)
        dependent.addTaskBlocker(task.uuid!, among: [task, dependent])
        let cited = reading(task, among: [task, dependent])
        #expect(cited?.citedTaskIDs == [dependent.uuid!])

        // An arm that speaks about something else cites nothing — a citation row
        // under an unrelated observation would be a non sequitur with a chevron.
        let overdue = TaskItem(title: "Renew the insurance", status: .todo, in: context)
        overdue.dueDate = Calendar.current.date(byAdding: .day, value: -3, to: Date())
        #expect(reading(overdue, among: [overdue])?.citedTaskIDs.isEmpty == true)
    }

    @Test("What bears on the choice never restates the flag — the block owns that line")
    func decisionContextExcludesTheFlag() {
        let context = context()
        let task = TaskItem(title: "Pick a school", status: .todo, in: context)
        task.needsDecision = true
        task.isUrgent = true
        task.dueDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())

        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        let lines = facts.decisionContextLines
        #expect(!lines.isEmpty)
        #expect(lines.count <= 3)
        #expect(!lines.contains(TaskAdvisorFacts.decisionFlagEvidence))
        // The full evidence still carries the flag line — "Why this?" elsewhere keeps it.
        #expect(facts.userVisibleEvidence.contains(TaskAdvisorFacts.decisionFlagEvidence))
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
        // Overdue: a fact no spine states, so the floor speaks on every shape.
        let task = TaskItem(title: "Renew the insurance", status: .todo, in: context)
        task.dueDate = Calendar.current.date(byAdding: .day, value: -3, to: Date())

        let store = store(.failed(ModelResult<ValidatedReading>.noUsableOutput))
        store.ensure(task: task, among: [task])
        await store.awaitPendingJudgment(for: task.uuid)

        guard case .fallback(let reading) = store.state(for: task) else {
            Issue.record("expected .fallback, got \(store.state(for: task))")
            return
        }
        #expect(reading?.observation.contains("due") == true)
    }

    @Test("A timeout degrades the same way — running out of time is not a verdict")
    func timeoutFallsToTheFloor() async {
        let context = context()
        // A dependent is a fact no spine states, so the floor speaks on every shape.
        let dependent = TaskItem(title: "Book the venue", status: .todo, in: context)
        let task = TaskItem(
            title: "Confirm the guest count", status: .todo, effortMinutes: 90, in: context)
        dependent.addTaskBlocker(task.uuid!, among: [task, dependent])

        let store = store(.timedOut)
        store.ensure(task: task, among: [task, dependent])
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
        // gate, but rung 0 has no fact to state — and, post spine-suppression, so is
        // a purely blocked task, whose fact the waiting spine renders instead.
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
