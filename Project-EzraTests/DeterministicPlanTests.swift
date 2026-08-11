//
//  DeterministicPlanTests.swift
//  Project-EzraTests
//
//  The deterministic generator is the fallback the simulator exercises and the tier
//  chain ends on. With no model it can't be an advisor — it takes the top
//  `fallbackCount` candidates (TaskRanking order) with fact-line reasoning and no
//  headline/tradeoffs/risks, and never fails.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Deterministic plan generator")
struct DeterministicPlanTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 24 * 3600) }

    private func request(typical: Int?) -> TodayPlanRequest {
        let decision = TaskItem(title: "decide", status: .todo, needsDecision: true)
        let urgent = TaskItem(title: "urgent", status: .todo, dueDate: days(-1), isUrgent: true)
        let medium = TaskItem(title: "medium", status: .todo, dueDate: now)
        let all = TaskRanking.sorted([medium, urgent, decision], now: now)
        return TodayPlanRequest.make(
            candidateItems: all, allTasks: all, recapCount: 0, typicalCompleted: typical, now: now)
    }

    @Test("An in-progress task carries that fact to both the advisor and the fallback")
    func inProgressIsAnObservableFact() throws {
        let task = TaskItem(title: "Rewire the shed", status: .todo)
        task.transition(to: .doing, now: now)
        let snapshot = try #require(PlanTaskSnapshot.from(task, among: [task], now: now))

        #expect(snapshot.facts.contains("in progress"))
        // One array, two consumers: the model's prompt row and the voiceless
        // fallback's per-action line.
        #expect(snapshot.promptLine(index: 1).contains("in progress"))
        #expect(snapshot.factLine.contains("in progress"))
    }

    @Test("A todo task claims no such fact")
    func todoIsNotInProgress() throws {
        let task = TaskItem(title: "Rewire the shed", status: .todo)
        let snapshot = try #require(PlanTaskSnapshot.from(task, among: [task], now: now))
        #expect(!snapshot.facts.contains("in progress"))
    }

    @Test("Top fallbackCount candidates, fact-line lines, no advisor voice")
    func fallbackShape() async throws {
        let req = request(typical: 2)
        #expect(req.fallbackCount == 2)
        let plan = try await DeterministicPlanGenerator().generate(req, onPartial: nil)
        #expect(plan.tier == .deterministic)
        #expect(!plan.hasAdvisorVoice)
        #expect(plan.actions.map(\.taskID) == req.candidates.prefix(2).map(\.id))
    }

    @Test("fallbackCount clamps to the candidate count")
    func clampsToCandidates() async throws {
        let req = request(typical: 7)
        #expect(req.fallbackCount == 3)  // only three candidates exist
        let plan = try await DeterministicPlanGenerator().generate(req, onPartial: nil)
        #expect(plan.actions.count == 3)
    }

    @Test("Cold start (no throughput) uses a sane default, clamped to candidates")
    func coldStartDefault() async throws {
        let req = request(typical: nil)
        #expect(req.fallbackCount == 3)  // default 5, clamped to 3 candidates
    }
}

@MainActor
@Suite("Advisor-only facts — internal signals never become UI")
struct PromptOnlyFactsTests {

    private func snapshot(
        intent: WorkIntent? = nil, deferrals: Int32 = 0
    ) -> PlanTaskSnapshot {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Sort the garage", status: .todo, in: context)
        task.workIntent = intent
        task.deferralCount = deferrals
        return PlanTaskSnapshot.from(task, among: [task], now: Date())!
    }

    @Test("Planning classification reaches the advisor prompt, never the display line")
    func planningIsPromptOnly() {
        let snap = snapshot(intent: .planning)
        #expect(snap.promptOnlyFacts == ["planning work"])
        #expect(!snap.factLine.contains("planning"))
        #expect(snap.promptLine(index: 1).contains("planning work"))
    }

    @Test("Deferral is a bounded band: 2 and 3 speak, 1 and 4+ stay silent")
    func deferralBandIsBounded() {
        #expect(snapshot(deferrals: 1).promptOnlyFacts == nil)
        #expect(snapshot(deferrals: 2).promptOnlyFacts == ["set aside 2×"])
        #expect(snapshot(deferrals: 3).promptOnlyFacts == ["set aside 3×"])
        // 4+ is StallDiagnosis/Unstick territory — the advisor never sees escalating
        // pressure, so defer → re-plan → defer can't become a loop.
        #expect(snapshot(deferrals: 4).promptOnlyFacts == nil)
        #expect(!snapshot(deferrals: 4).promptLine(index: 1).contains("set aside"))
    }

    @Test("An action task with no deferrals carries no internal signals at all")
    func cleanTaskHasNone() {
        let snap = snapshot(intent: .action)
        #expect(snap.promptOnlyFacts == nil)
        #expect(snap.promptLine(index: 1) == "1. [\(snap.id.uuidString)] Sort the garage")
    }
}
