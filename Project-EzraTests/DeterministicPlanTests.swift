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
