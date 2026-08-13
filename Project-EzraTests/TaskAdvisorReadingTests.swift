//
//  TaskAdvisorReadingTests.swift
//  Project-EzraTests
//
//  The Advisor's trust boundary: model output is untrusted transport, and
//  `validated(against:)` is what turns it into the `ValidatedReading` contract.
//  Every rule is drop/degrade, never substitute — absorbed the retired
//  `DecisionFramingTests` grounding cases (the recommendation must name one of its
//  own options verbatim) and the breakdown sanitize rules, now per-move arms of one
//  validator.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Task Advisor — the reading's trust boundary")
struct TaskAdvisorReadingTests {

    private func facts(blockers: [String] = []) -> TaskAdvisorFacts {
        TaskAdvisorFacts(
            id: UUID(), title: "Renew passport", notes: nil, category: "Admin",
            rawCapture: "", reasoning: "", status: .todo, effortMinutes: 90,
            dueDate: nil, overdueDays: nil, isUrgent: false, needsDecision: false,
            isJudgmentCall: false, decisionShaped: false, deferralCount: 0, quietDays: 0,
            blockerTitles: blockers, blockerIDs: [], dependentTitles: [], childIDs: [],
            openStepTitles: [], stepLabel: nil, parentTitle: nil, diagnosis: nil,
            breakdownReason: nil, workIntent: nil)
    }

    private func reading(
        observation: String = "This has sat for a while.",
        guidance: String = "",
        nextMove: String = "Start with the form.",
        action: String,
        options: [AdvisorOption] = [],
        recommendation: String = "",
        recommendationWhy: String = "",
        steps: [AdvisorStep] = []
    ) -> TaskAdvisorReading {
        TaskAdvisorReading(
            observation: observation, guidance: guidance, nextMove: nextMove, action: action,
            options: options, recommendation: recommendation,
            recommendationWhy: recommendationWhy, steps: steps)
    }

    private var twoOptions: [AdvisorOption] {
        [
            AdvisorOption(label: "Keep the current plan", tradeoff: "Costs more."),
            AdvisorOption(label: "Switch providers", tradeoff: "Paperwork now."),
        ]
    }

    // MARK: - The move vocabulary

    @Test("nothing validates to silence, discarding everything else")
    func nothingIsSilence() {
        let validated = reading(action: "nothing", options: twoOptions).validated(against: facts())
        #expect(validated == .silence)
        #expect(validated?.move == .nothing)
    }

    @Test("An unknown action string degrades to advise — forward tolerance, not a crash")
    func unknownActionDegrades() {
        let validated = reading(action: "delegate").validated(against: facts())
        #expect(validated?.move == .advise)
        #expect(validated?.observation == "This has sat for a while.")
    }

    @Test("The lenient decode trims and case-folds")
    func lenientDecode() {
        #expect(AdvisorMove(lenient: " Decide ") == .decide)
        #expect(AdvisorMove(lenient: "CREATESTEPS") == .createSteps)
        #expect(AdvisorMove(lenient: "research") == nil)
    }

    @Test("An empty observation on a non-nothing move is nothing usable")
    func emptyObservationIsUnusable() {
        #expect(reading(observation: "  ", action: "advise").validated(against: facts()) == nil)
        // But silence needs no observation — it discards everything anyway.
        #expect(reading(observation: "", action: "nothing").validated(against: facts()) != nil)
    }

    // MARK: - decide (the absorbed grounding cases)

    @Test("A recommendation naming one of its own options renders, label canonicalized")
    func groundedRecommendation() {
        let validated = reading(
            action: "decide", options: twoOptions,
            recommendation: "switch providers", recommendationWhy: "It fits."
        ).validated(against: facts())
        #expect(validated?.move == .decide)
        #expect(validated?.recommendation?.label == "Switch providers")  // option casing wins
        #expect(validated?.recommendation?.why == "It fits.")
    }

    @Test("A recommendation naming an option that doesn't exist drops whole")
    func inventedRecommendationDrops() {
        let validated = reading(
            action: "decide", options: twoOptions, recommendation: "Move abroad"
        ).validated(against: facts())
        #expect(validated?.move == .decide)
        #expect(validated?.recommendation == nil)
    }

    @Test("An empty or whitespace recommendation is an honest abstention")
    func emptyRecommendationAbstains() {
        for rec in ["", "   "] {
            let validated = reading(action: "decide", options: twoOptions, recommendation: rec)
                .validated(against: facts())
            #expect(validated?.recommendation == nil)
        }
    }

    @Test("Fewer than two usable options degrades decide to advise")
    func thinDecisionDegrades() {
        let one = [AdvisorOption(label: "Only choice", tradeoff: "")]
        let validated = reading(action: "decide", options: one).validated(against: facts())
        #expect(validated?.move == .advise)
        #expect(validated?.options.isEmpty == true)
    }

    @Test("Options de-duplicate case-insensitively and clamp to four")
    func optionSanitize() {
        let noisy = [
            AdvisorOption(label: "Plan A", tradeoff: ""),
            AdvisorOption(label: "plan a", tradeoff: "dupe"),
            AdvisorOption(label: "Plan B", tradeoff: ""),
            AdvisorOption(label: "Plan C", tradeoff: ""),
            AdvisorOption(label: "Plan D", tradeoff: ""),
            AdvisorOption(label: "Plan E", tradeoff: ""),
        ]
        let validated = reading(action: "decide", options: noisy).validated(against: facts())
        #expect(validated?.options.count == 4)
        #expect(validated?.options.first?.label == "Plan A")
    }

    // MARK: - createSteps (the absorbed sanitize rules)

    @Test("Steps sanitize: trimmed, de-duplicated, efforts clamped to the bands, capped at five")
    func stepSanitize() {
        let steps = [
            AdvisorStep(title: "  Gather documents  ", effortMinutes: 20),
            AdvisorStep(title: "gather documents", effortMinutes: 15),
            AdvisorStep(title: "Fill the form", effortMinutes: 45),
            AdvisorStep(title: "ok", effortMinutes: 15),  // too short, dropped
            AdvisorStep(title: "Book the appointment", effortMinutes: 500),
        ]
        let validated = reading(action: "createSteps", steps: steps).validated(against: facts())
        #expect(validated?.move == .createSteps)
        #expect(
            validated?.steps == [
                BreakdownStep(title: "Gather documents", effortMinutes: 15),
                BreakdownStep(title: "Fill the form", effortMinutes: 30),
                BreakdownStep(title: "Book the appointment", effortMinutes: 120),
            ])
    }

    @Test("One step is not a breakdown — it degrades to advise")
    func oneStepDegrades() {
        let one = [AdvisorStep(title: "Just do it", effortMinutes: 15)]
        let validated = reading(action: "createSteps", steps: one).validated(against: facts())
        #expect(validated?.move == .advise)
        #expect(validated?.steps.isEmpty == true)
    }

    // MARK: - openBlocker

    @Test("openBlocker requires a real blocker in the facts, else degrades to advise")
    func blockerRequiresBlocker() {
        let without = reading(action: "openBlocker").validated(against: facts())
        #expect(without?.move == .advise)

        let with = reading(action: "openBlocker")
            .validated(against: facts(blockers: ["Get the quote"]))
        #expect(with?.move == .openBlocker)
    }

    // MARK: - Payloads never leak across moves

    @Test("advise strips any stray options or steps the model attached")
    func adviseCarriesNoPayload() {
        let validated = reading(
            action: "advise", options: twoOptions,
            steps: [
                AdvisorStep(title: "Step one", effortMinutes: 15),
                AdvisorStep(title: "Step two", effortMinutes: 15),
            ]
        ).validated(against: facts())
        #expect(validated?.move == .advise)
        #expect(validated?.options.isEmpty == true)
        #expect(validated?.steps.isEmpty == true)
    }
}
