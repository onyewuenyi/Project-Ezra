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

    @Test("The honesty rules are stated: evidence gates advice")
    func honestyRules() {
        let instructions = TaskAdvisorService.instructions
        // "Silence beats noise" was DELETED (2026-08-17). It made silence the posture
        // rather than one honest answer among five, and the first device eval showed the
        // cost: the model reached for `advise` or said nothing on tasks that plainly
        // warranted `decide` or `createSteps`. See `silenceIsTheExceptionNotTheDefault`.
        #expect(!instructions.contains("Silence beats noise"))
        #expect(instructions.contains("Recommendation requires evidence"))
        #expect(instructions.contains("honest abstention beats a coin flip"))
        #expect(instructions.contains("never contradict them"))  // sensors are fixed
        #expect(instructions.contains("A Start button already exists"))
        #expect(instructions.contains("You never decide, start, or change anything"))
    }

    @Test("The move is commitment-sized, not the whole task")
    func commitmentSized() {
        let instructions = TaskAdvisorService.instructions
        #expect(instructions.contains("SMALLEST USEFUL COMMITMENT"))
        #expect(instructions.contains("not trying to finish the"))
    }

    @Test("Every sentence earns its space — depth is layered, not omitted")
    func earnsItsSpace() {
        let instructions = TaskAdvisorService.instructions
        #expect(instructions.contains("Every sentence must earn its space"))
        // Was "leave guidance empty". Guidance is no longer expensive: it sits behind the
        // disclosure, so the instruction is to LAYER depth rather than drop it.
        #expect(instructions.contains("Guidance is the second layer"))
        // Matched short of the line wrap — the prompt breaks between "20" and "words".
        #expect(instructions.contains("ONE sentence, at most 20"))
    }

    // MARK: - The posture inversion (2026-08-17)

    @Test("Silence is the exception, not the default — position is the gradient")
    func silenceIsTheExceptionNotTheDefault() {
        let instructions = TaskAdvisorService.instructions
        // Order in the move list IS the instruction. `nothing` led it; a small model reads
        // the first option as the preferred one, and the eval showed exactly that bias.
        let advise = instructions.range(of: "- advise")
        let nothing = instructions.range(of: "- nothing")
        #expect(advise != nil && nothing != nil)
        if let a = advise, let n = nothing { #expect(a.lowerBound < n.lowerBound) }
        #expect(instructions.contains("A short useful line beats both"))
        #expect(instructions.contains("fallback, not the default"))
    }

    @Test("Every emission must name what got better")
    func emissionMustNameAGain() {
        let instructions = TaskAdvisorService.instructions
        #expect(instructions.contains("what became better for the person"))
        // The enumeration is load-bearing: an unqualified "justify yourself" bar makes a
        // small model resolve uncertainty toward silence, recreating the problem.
        #expect(instructions.contains("named the real obstacle"))
        #expect(instructions.contains("said what a fact MEANS"))
    }

    @Test("The design law is stated AND demonstrated")
    func neverRestateTheScreen() {
        let instructions = TaskAdvisorService.instructions
        #expect(instructions.contains("Never restate what the screen already shows"))
        // Worked contrast pairs, because an abstract rule is a hope: a small model at
        // temperature 0.5 follows examples far more reliably than principles. The first
        // device eval produced a textbook restatement on the kitchen fixture, which is
        // the pair now written into the prompt.
        #expect(instructions.contains("BAD:"))
        #expect(instructions.contains("GOOD:"))
        #expect(instructions.contains("Policy #88102"))
    }

    @Test("Certainty lives in the grammar, and urgency is never invented")
    func certaintyLadder() {
        let instructions = TaskAdvisorService.instructions
        // The four rungs — the product's substitute for a confidence score, which it
        // refuses to render.
        #expect(instructions.contains("Certainty lives in your grammar, never in a number"))
        #expect(instructions.contains("appears to be"))
        #expect(instructions.contains("It may be worth"))
        #expect(instructions.contains("not enough information"))
        #expect(instructions.contains("Never invent urgency"))
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
