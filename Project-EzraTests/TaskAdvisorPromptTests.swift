//
//  TaskAdvisorPromptTests.swift
//  Project-EzraTests
//
//  The Advisor's instructions, pinned (the `UnstickNarrationTests` pattern): the five
//  questions are the prompt structure, the move vocabulary is closed, and the honesty
//  rules — silence is good, recommendation requires evidence, the CTA owns the
//  lifecycle — are load-bearing product behavior, not phrasing. A drive-by edit should
//  change loudly, in a diff that says why.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Task Advisor — pinned instructions")
struct TaskAdvisorPromptTests {

    @Test("The five questions structure the reasoning, in order")
    func fiveQuestions() {
        let instructions = TaskAdvisorService.instructions
        let questions = [
            "What is the person trying to accomplish?",
            "What is preventing progress?",
            "What do they need right now?",
            "What is the best intervention?",
            "What should happen next?",
        ]
        var searchFrom = instructions.startIndex
        for question in questions {
            guard let range = instructions.range(of: question, range: searchFrom..<instructions.endIndex)
            else {
                Issue.record("Missing or out of order: \(question)")
                return
            }
            searchFrom = range.upperBound
        }
    }

    @Test("The move vocabulary is closed, and every case is named")
    func moveVocabulary() {
        let instructions = TaskAdvisorService.instructions
        for move in AdvisorMove.allCases {
            #expect(instructions.contains(move.rawValue))
        }
    }

    @Test("The honesty rules are stated: silence is good, evidence gates advice")
    func honestyRules() {
        let instructions = TaskAdvisorService.instructions
        #expect(instructions.contains("Silence beats noise"))
        #expect(instructions.contains("Recommendation requires evidence"))
        #expect(instructions.contains("honest abstention beats a coin flip"))
        #expect(instructions.contains("never contradict them"))  // sensors are fixed
        #expect(instructions.contains("A Start button already exists"))
        #expect(instructions.contains("You never decide, start, or change anything"))
    }

    @Test("The per-task prompt IS the facts block — nothing else rides along")
    func promptIsTheFactsBlock() {
        let facts = TaskAdvisorFacts(
            id: UUID(), title: "Fix the boiler", notes: nil, category: "Home",
            rawCapture: "", reasoning: "", status: .todo, effortMinutes: nil,
            dueDate: nil, overdueDays: nil, isUrgent: false, needsDecision: false,
            isJudgmentCall: false, decisionShaped: false, deferralCount: 0, quietDays: 0,
            blockerTitles: ["Get the part"], blockerIDs: [], dependentTitles: [],
            childIDs: [], openStepTitles: [], stepLabel: nil, parentTitle: nil,
            diagnosis: nil, breakdownReason: nil, workIntent: nil)
        #expect(TaskAdvisorService.prompt(for: facts) == facts.promptBlock)
        #expect(TaskAdvisorService.prompt(for: facts).contains("WAITING ON: Get the part"))
    }
}
