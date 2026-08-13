//
//  GroundingTests.swift
//  Project-EzraTests
//
//  Capture is the conservative stage: it understands what the user said and invents nothing.
//  The model names the evidence for each task it emits (`TaskIntent.sourceQuote`) and the
//  SYSTEM verifies that evidence against the raw capture — because model-authored evidence
//  for model-authored output proves nothing at all.
//
//  The motivating failure: "pick up food from the store later today" came back with a second
//  task, "buy new printer paper", which the user never said.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct GroundingTests {

    private func intent(_ title: String, quote: String? = nil) -> TaskIntent {
        TaskIntent(
            title: title, category: "Admin", confidence: 0.9, isJudgmentCall: false,
            reasoning: "", sourceQuote: quote)
    }

    private static let capture = "pick up food from the store later today"

    // MARK: - The reported failure

    @Test("An invented task is dropped — no quote, no shared words")
    func inventedTaskDropped() {
        #expect(!AppBrain.grounded(intent("Buy new printer paper"), in: Self.capture))
    }

    @Test("A quote the user never said does not launder an invented task")
    func fabricatedQuoteRejected() {
        // The circularity this whole mechanism exists to close: the model cannot make a
        // task legitimate by asserting evidence for it.
        let fabricated = intent("Buy new printer paper", quote: "buy new printer paper")
        #expect(!AppBrain.grounded(fabricated, in: Self.capture))
    }

    // MARK: - Rung 1 — the verified quote

    @Test("A verified quote grounds the task, whitespace and case notwithstanding")
    func verifiedQuoteGrounds() {
        #expect(
            AppBrain.grounded(
                intent("Pick up food", quote: "pick up food from the store"), in: Self.capture))
        #expect(
            AppBrain.grounded(
                intent("Pick up food", quote: "  Pick Up   Food  "), in: Self.capture))
    }

    @Test("A verified quote carries a heavy paraphrase the lexical rung would reject")
    func quoteRescuesLegitimateParaphrase() {
        // This is why the quote is the primary rung: a good reading can share no words at
        // all with its source, and a lexical-only rule would throw it away.
        let capture = "take care of the house before everyone arrives"
        let paraphrase = intent("Clean the living room", quote: "take care of the house")
        #expect(AppBrain.grounded(paraphrase, in: capture))
        // Same task WITHOUT evidence falls through to the anomaly detector and is refused.
        #expect(!AppBrain.grounded(intent("Clean the living room"), in: capture))
    }

    // MARK: - Rung 2 — the lexical anomaly detector

    @Test("Without a quote, one shared significant word is enough")
    func lexicalAnchorGrounds() {
        // "grab milk" → "Buy milk": the verb changed, the object anchors it.
        #expect(AppBrain.grounded(intent("Buy milk"), in: "grab milk on the way home"))
        #expect(AppBrain.grounded(intent("Renew passport"), in: "renew my passport"))
    }

    @Test("An empty title is let through — there is nothing to judge")
    func emptyTitlePasses() {
        #expect(AppBrain.grounded(intent(""), in: Self.capture))
    }

    // MARK: - The heuristic path is grounded by construction

    @Test("Heuristic intents carry no quote and still pass — they are cut from the text")
    func heuristicPathUnaffected() throws {
        let text = "renew my passport and call mom"
        let intents = Segmentation.items(from: text).map { HeuristicEngine.intent(from: $0) }
        #expect(!intents.isEmpty)
        for produced in intents {
            #expect(produced.sourceQuote == nil)
            #expect(AppBrain.grounded(produced, in: text), "\(produced.title)")
        }
    }
}
