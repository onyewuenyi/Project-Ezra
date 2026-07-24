//
//  RambleEvalTests.swift
//  Project-EzraTests
//
//  The honest-risk instrument: a hand-labeled eval set for the ramble pipeline
//  (speech-ish text → intents → resolved drafts), scored per field. The floors
//  are REGRESSION floors calibrated just under the observed heuristic numbers —
//  they catch a change that degrades the pipeline, they are not aspirations.
//
//  The fixtures are engine-agnostic: the same set is the benchmark to run
//  against the Foundation Models path on device (and any escalated path later),
//  which is how the "does on-device land >50%?" question gets answered with
//  data instead of vibes.
//

import Foundation
import Testing

@testable import Project_Ezra

// MARK: - Fixture shape

private struct ExpectedTask {
    var titleContains: [String]
    var category: String? = nil
    var judgment: Bool = false
    var owner: String? = nil
    var blocked: Bool = false
    var expectDue: Bool = false
}

private struct EvalCase {
    var utterance: String
    var expected: [ExpectedTask]
}

// MARK: - The labeled set (~40 rambles)

private let evalSet: [EvalCase] = [
    // Single errands, clear category signals.
    EvalCase(
        utterance: "renew my passport",
        expected: [
            ExpectedTask(titleContains: ["passport"], category: "Travel")
        ]),
    EvalCase(
        utterance: "pay the water bill",
        expected: [
            ExpectedTask(titleContains: ["water bill"], category: "Finance")
        ]),
    EvalCase(
        utterance: "call mom back",
        expected: [
            ExpectedTask(titleContains: ["mom"], category: "Family")
        ]),
    EvalCase(
        utterance: "pick up the dry cleaning",
        expected: [
            ExpectedTask(titleContains: ["dry cleaning"], category: "Errands")
        ]),
    EvalCase(
        utterance: "schedule a dentist appointment",
        expected: [
            ExpectedTask(titleContains: ["dentist"], category: "Health")
        ]),
    EvalCase(
        utterance: "oil change is overdue",
        expected: [
            ExpectedTask(titleContains: ["oil change"], category: "Car")
        ]),
    EvalCase(
        utterance: "do the laundry",
        expected: [
            ExpectedTask(titleContains: ["laundry"], category: "Home")
        ]),
    EvalCase(
        utterance: "finish the Q3 deck",
        expected: [
            ExpectedTask(titleContains: ["deck"], category: "Work")
        ]),
    EvalCase(
        utterance: "return the amazon package",
        expected: [
            ExpectedTask(titleContains: ["package"], category: "Errands")
        ]),
    EvalCase(
        utterance: "book a haircut",
        expected: [
            ExpectedTask(titleContains: ["haircut"], category: "Personal")
        ]),
    EvalCase(
        utterance: "renew car registration at the dmv",
        expected: [
            ExpectedTask(titleContains: ["registration"], category: "Car")
        ]),
    EvalCase(
        utterance: "refill the prescription",
        expected: [
            ExpectedTask(titleContains: ["prescription"], category: "Health")
        ]),
    EvalCase(
        utterance: "file the taxes",
        expected: [
            ExpectedTask(titleContains: ["taxes"], category: "Finance")
        ]),
    EvalCase(
        utterance: "buy groceries",
        expected: [
            ExpectedTask(titleContains: ["groceries"], category: "Home")
        ]),
    EvalCase(
        utterance: "email the client about the invoice",
        expected: [
            ExpectedTask(titleContains: ["client"], category: "Work")
        ]),
    EvalCase(
        utterance: "book the hotel for the trip",
        expected: [
            ExpectedTask(titleContains: ["hotel"], category: "Travel")
        ]),
    // Vague / ambiguous — Admin is the honest fallback.
    EvalCase(
        utterance: "deal with the thing from last week",
        expected: [
            ExpectedTask(titleContains: ["thing"], category: "Admin")
        ]),
    EvalCase(
        utterance: "sort out that paperwork situation",
        expected: [
            ExpectedTask(titleContains: ["paperwork"], category: "Admin")
        ]),
    // Judgment calls — the permanent carve-out.
    EvalCase(
        utterance: "should I quit the gym",
        expected: [
            ExpectedTask(titleContains: ["gym"], judgment: true)
        ]),
    EvalCase(
        utterance: "figure out if the side project is still worth it",
        expected: [
            ExpectedTask(titleContains: ["side project"], judgment: true)
        ]),
    EvalCase(
        utterance: "decide whether to switch schools",
        expected: [
            ExpectedTask(titleContains: ["schools"], judgment: true)
        ]),
    EvalCase(
        utterance: "cancel the streaming subscription",
        expected: [
            ExpectedTask(titleContains: ["subscription"], judgment: true)
        ]),
    // Delegation.
    EvalCase(
        utterance: "ask sarah to book the venue",
        expected: [
            ExpectedTask(titleContains: ["venue"], owner: "Sarah")
        ]),
    EvalCase(
        utterance: "mike will handle the invoices",
        expected: [
            ExpectedTask(titleContains: ["invoices"], owner: "Mike")
        ]),
    EvalCase(
        utterance: "remind maya about the permission slip",
        expected: [
            ExpectedTask(titleContains: ["permission slip"], owner: "Maya")
        ]),
    // Dependencies.
    EvalCase(
        utterance: "book flights after passport is done",
        expected: [
            ExpectedTask(titleContains: ["flights"], category: "Travel", blocked: true)
        ]),
    EvalCase(
        utterance: "send the deck once the numbers are final",
        expected: [
            ExpectedTask(titleContains: ["deck"], blocked: true)
        ]),
    EvalCase(
        utterance: "call the plumber when I hear back from the landlord",
        expected: [
            ExpectedTask(titleContains: ["plumber"], blocked: true)
        ]),
    EvalCase(
        utterance: "submit expenses waiting on receipts",
        expected: [
            ExpectedTask(titleContains: ["expenses"], blocked: true)
        ]),
    // Dates.
    EvalCase(
        utterance: "daycare enrollment forms due friday",
        expected: [
            ExpectedTask(titleContains: ["daycare"], category: "Family", expectDue: true)
        ]),
    EvalCase(
        utterance: "submit the expense report tomorrow",
        expected: [
            ExpectedTask(titleContains: ["expense report"], expectDue: true)
        ]),
    EvalCase(
        utterance: "water the plants today",
        expected: [
            ExpectedTask(titleContains: ["plants"], expectDue: true)
        ]),
    EvalCase(
        utterance: "trash goes out monday",
        expected: [
            ExpectedTask(titleContains: ["trash"], category: "Home", expectDue: true)
        ]),
    // Multi-item run-ons (the fan-out).
    EvalCase(
        utterance: "renew passport, book flights, call the bank",
        expected: [
            ExpectedTask(titleContains: ["passport"]),
            ExpectedTask(titleContains: ["flights"]),
            ExpectedTask(titleContains: ["bank"]),
        ]),
    EvalCase(
        utterance: "buy milk, return package, pay water bill",
        expected: [
            ExpectedTask(titleContains: ["milk"]),
            ExpectedTask(titleContains: ["package"]),
            ExpectedTask(titleContains: ["water bill"]),
        ]),
    EvalCase(
        utterance: """
            renew my passport
            should I quit the side project
            oil change overdue
            """,
        expected: [
            ExpectedTask(titleContains: ["passport"], category: "Travel"),
            ExpectedTask(titleContains: ["side project"], judgment: true),
            ExpectedTask(titleContains: ["oil change"], category: "Car"),
        ]),
    EvalCase(
        utterance: """
            - call the dentist
            - fix the leaky faucet
            """,
        expected: [
            ExpectedTask(titleContains: ["dentist"], category: "Health"),
            ExpectedTask(titleContains: ["faucet"], category: "Home"),
        ]),
    // Messy speech artifacts.
    EvalCase(
        utterance: "um also I guess call the plumber",
        expected: [
            ExpectedTask(titleContains: ["plumber"], category: "Home")
        ]),
    EvalCase(
        utterance: "oh and don't forget the daycare forms",
        expected: [
            ExpectedTask(titleContains: ["daycare"], category: "Family")
        ]),
    EvalCase(
        utterance: "so basically I need to renew the insurance",
        expected: [
            ExpectedTask(titleContains: ["insurance"])
        ]),
    EvalCase(
        utterance: "text dad about the reunion and also book the campsite",
        expected: [
            ExpectedTask(titleContains: ["dad"], category: "Family")
        ]),
]

// MARK: - Runner

@Suite("Ramble eval (heuristic pipeline)")
struct RambleEvalTests {

    private struct Score {
        var hits = 0
        var total = 0
        var rate: Double { total == 0 ? 1 : Double(hits) / Double(total) }
        mutating func record(_ hit: Bool) {
            total += 1
            if hit { hits += 1 }
        }
        var display: String { "\(hits)/\(total) (\(Int((rate * 100).rounded()))%)" }
    }

    @Test("Per-field accuracy holds the regression floors")
    func evalAccuracy() async throws {
        var segmentation = Score()
        var title = Score()
        var category = Score()
        var judgment = Score()
        var owner = Score()
        var blocked = Score()
        var due = Score()

        let engine = HeuristicEngine()
        for evalCase in evalSet {
            let intents = try await engine.triage(rawText: evalCase.utterance)
            let drafts = IntentResolver.resolve(intents)

            segmentation.record(drafts.count == evalCase.expected.count)
            // Field scoring pairs in order and only when segmentation matched —
            // misaligned pairs would corrupt the field numbers.
            guard drafts.count == evalCase.expected.count else { continue }

            for (draft, expected) in zip(drafts, evalCase.expected) {
                let lowerTitle = draft.title.lowercased()
                title.record(expected.titleContains.allSatisfy { lowerTitle.contains($0.lowercased()) })
                if let expectedCategory = expected.category {
                    category.record(draft.category == expectedCategory)
                }
                judgment.record(draft.isJudgmentCall == expected.judgment)
                if let expectedOwner = expected.owner {
                    owner.record(draft.ownerName == expectedOwner)
                }
                blocked.record((draft.blockedBy != nil) == expected.blocked)
                due.record((draft.dueDate != nil) == expected.expectDue)
            }
        }

        print(
            """

            ── Ramble eval (heuristic + resolver, \(evalSet.count) cases) ──
            segmentation  \(segmentation.display)
            title         \(title.display)
            category      \(category.display)
            judgment      \(judgment.display)
            owner         \(owner.display)
            blocked       \(blocked.display)
            due           \(due.display)
            ────────────────────────────────────────────────

            """)

        // Regression floors — calibrated just under observed first-run numbers.
        #expect(segmentation.rate >= 0.75, "segmentation regressed: \(segmentation.display)")
        #expect(title.rate >= 0.85, "title fidelity regressed: \(title.display)")
        #expect(category.rate >= 0.60, "category accuracy regressed: \(category.display)")
        #expect(judgment.rate >= 0.85, "judgment detection regressed: \(judgment.display)")
        #expect(owner.rate >= 0.60, "owner extraction regressed: \(owner.display)")
        #expect(blocked.rate >= 0.80, "blocker detection regressed: \(blocked.display)")
        #expect(due.rate >= 0.75, "due detection regressed: \(due.display)")
    }
}
