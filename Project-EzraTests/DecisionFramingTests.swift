//
//  DecisionFramingTests.swift
//  Project-EzraTests
//
//  The recommendation's grounding rule: it renders ONLY when it names one of the
//  framing's own options. Anything else — an invented option, padding, whitespace —
//  drops whole. This is the anti-hallucination half of the "Thinking Partner may
//  recommend" reversal (2026-08-08); the other half is that the human still resolves.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Decision framing — grounded recommendation")
struct DecisionFramingTests {

    private func framing(recommendation: String, why: String = "It fits.") -> DecisionFraming {
        DecisionFraming(
            options: [
                FramedOption(label: "Keep the current plan", tradeoff: "Costs more."),
                FramedOption(label: "Switch providers", tradeoff: "Paperwork now."),
            ],
            costOfWaiting: "",
            recommendation: recommendation,
            recommendationWhy: why
        )
    }

    @Test("A recommendation naming one of its own options renders, label canonicalized")
    func grounded() {
        let best = framing(recommendation: "switch providers").groundedRecommendation
        #expect(best?.label == "Switch providers")  // the option's own casing wins
        #expect(best?.why == "It fits.")
    }

    @Test("A recommendation naming an option that doesn't exist drops whole")
    func inventedOptionDrops() {
        #expect(framing(recommendation: "Move abroad").groundedRecommendation == nil)
    }

    @Test("An empty or whitespace recommendation is an honest abstention")
    func emptyAbstains() {
        #expect(framing(recommendation: "").groundedRecommendation == nil)
        #expect(framing(recommendation: "   ").groundedRecommendation == nil)
    }
}
