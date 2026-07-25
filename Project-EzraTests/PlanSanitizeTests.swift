//
//  PlanSanitizeTests.swift
//  Project-EzraTests
//
//  `GeneratedPlan.validated(against:)` is the anti-hallucination guard for the AI
//  advisor briefing. Unlike the old `sanitized` (which re-imposed a deterministic
//  order), it does NOT rank: it keeps the advisor's selection and order, but drops
//  ids that aren't real candidates, collapses duplicates, backfills an empty line
//  from the candidate's fact line, and caps at `maxActions`.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Plan validation")
struct PlanSanitizeTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 24 * 3600) }

    /// Three candidates; `gamma` is overdue so it carries a non-empty fact line.
    private func request() -> TodayPlanRequest {
        let alpha = TaskItem(title: "alpha", status: .todo)
        let beta = TaskItem(title: "beta", status: .todo)
        let gamma = TaskItem(title: "gamma", status: .todo, dueDate: days(-1))
        let all = [alpha, beta, gamma]
        return TodayPlanRequest.make(
            candidateItems: all, allTasks: all, recapCount: 0, typicalCompleted: nil, now: now)
    }

    @Test("Keeps the advisor's order and selection; drops invented ids and duplicates")
    func dropsAndDedupes() {
        let req = request()
        let ids = req.candidates.map(\.id)
        // Hostile output: candidate 3 first, an invented id, candidate 1 twice.
        let raw = GeneratedPlan(
            actions: [
                PlannedAction(taskID: ids[2], rationale: "line three"),
                PlannedAction(taskID: UUID(), rationale: "invented"),
                PlannedAction(taskID: ids[0], rationale: "line one"),
                PlannedAction(taskID: ids[0], rationale: "dup one"),
            ],
            headline: "  A calm day  ", tradeoffs: "  set aside beta  ", risks: "  gamma overdue  ",
            tier: .onDevice)

        let clean = raw.validated(against: req)
        // Advisor order preserved (NOT re-sorted): [three, one]; invented + dup gone.
        #expect(clean.actions.map(\.taskID) == [ids[2], ids[0]])
        #expect(clean.actions[0].rationale == "line three")
        #expect(clean.actions[1].rationale == "line one")
        // Narrative voice is trimmed and preserved.
        #expect(clean.headline == "A calm day")
        #expect(clean.tradeoffs == "set aside beta")
        #expect(clean.risks == "gamma overdue")
        #expect(clean.hasAdvisorVoice)
        #expect(clean.tier == .onDevice)
    }

    @Test("An empty line is backfilled from the candidate's fact line")
    func backfillsEmptyLine() {
        let req = request()
        let overdue = req.candidates.first { !$0.facts.isEmpty }!
        let raw = GeneratedPlan(
            actions: [PlannedAction(taskID: overdue.id, rationale: "   ")],
            headline: nil, tradeoffs: nil, risks: nil, tier: .deterministic)
        let clean = raw.validated(against: req)
        #expect(clean.actions.count == 1)
        #expect(clean.actions[0].rationale == overdue.factLine)
        #expect(!clean.hasAdvisorVoice)  // no headline/tradeoffs/risks
    }

    @Test("Caps at maxActions")
    func capsAtMax() {
        let tasks = (0..<9).map { TaskItem(title: "t\($0)", status: .todo) }
        let req = TodayPlanRequest.make(
            candidateItems: tasks, allTasks: tasks, recapCount: 0, typicalCompleted: nil, now: now)
        let raw = GeneratedPlan(
            actions: req.candidates.map { PlannedAction(taskID: $0.id, rationale: "r") },
            headline: nil, tradeoffs: nil, risks: nil, tier: .onDevice)
        #expect(raw.validated(against: req).actions.count == GeneratedPlan.maxActions)
    }
}
