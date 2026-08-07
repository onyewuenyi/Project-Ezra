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
    /// True when the pipeline should land a date — either because the utterance says
    /// one, or because the task's own nature carries a real deadline the user rarely
    /// bothers to speak (rent, a renewal, a filing). The second kind is
    /// `IntentResolver.inferredDueDate`'s job; before it existed every one of these
    /// was labeled false, and the label meant "the user didn't say a date" rather than
    /// "this task shouldn't have one".
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
            ExpectedTask(titleContains: ["passport"], category: "Travel", expectDue: true)
        ]),
    EvalCase(
        utterance: "pay the water bill",
        expected: [
            ExpectedTask(titleContains: ["water bill"], category: "Finance", expectDue: true)
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
            ExpectedTask(titleContains: ["registration"], category: "Car", expectDue: true)
        ]),
    EvalCase(
        utterance: "refill the prescription",
        expected: [
            ExpectedTask(titleContains: ["prescription"], category: "Health", expectDue: true)
        ]),
    EvalCase(
        utterance: "file the taxes",
        expected: [
            ExpectedTask(titleContains: ["taxes"], category: "Finance", expectDue: true)
        ]),
    EvalCase(
        utterance: "buy groceries",
        expected: [
            ExpectedTask(titleContains: ["groceries"], category: "Home")
        ]),
    EvalCase(
        utterance: "email the client about the invoice",
        expected: [
            ExpectedTask(titleContains: ["client"], category: "Work", expectDue: true)
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
            ExpectedTask(titleContains: ["subscription"], judgment: true, expectDue: true)
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
            ExpectedTask(titleContains: ["passport"], expectDue: true),
            ExpectedTask(titleContains: ["flights"]),
            ExpectedTask(titleContains: ["bank"]),
        ]),
    EvalCase(
        utterance: "buy milk, return package, pay water bill",
        expected: [
            ExpectedTask(titleContains: ["milk"]),
            ExpectedTask(titleContains: ["package"]),
            ExpectedTask(titleContains: ["water bill"], expectDue: true),
        ]),
    EvalCase(
        utterance: """
            renew my passport
            should I quit the side project
            oil change overdue
            """,
        expected: [
            ExpectedTask(titleContains: ["passport"], category: "Travel", expectDue: true),
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
            ExpectedTask(titleContains: ["insurance"], expectDue: true)
        ]),
    EvalCase(
        // Label corrected with the connective-aware splitter: this utterance always
        // contained two actions — the single-task expectation was calibrated to the
        // old splitter's inability to see "and also", not to the ramble itself.
        utterance: "text dad about the reunion and also book the campsite",
        expected: [
            ExpectedTask(titleContains: ["dad"], category: "Family"),
            ExpectedTask(titleContains: ["campsite"]),
        ]),

    // Dictated run-ons — the flagship spoken shape: no newlines, no short comma
    // lists, items joined by breath-connectives. The old splitter returned ONE
    // mega-task for every one of these.
    EvalCase(
        utterance:
            "i need to renew my passport and then i need to book flights for the trip and also call mom about thanksgiving",
        expected: [
            ExpectedTask(titleContains: ["passport"], expectDue: true),
            ExpectedTask(titleContains: ["flights"], category: "Travel"),
            ExpectedTask(titleContains: ["mom"], category: "Family"),
        ]),
    EvalCase(
        utterance: "pay rent and figure out if we should switch insurance",
        expected: [
            ExpectedTask(titleContains: ["rent"], category: "Finance", expectDue: true),
            ExpectedTask(titleContains: ["insurance"], judgment: true),
        ]),
    EvalCase(
        // Compound object and compound verb — the guard cases: neither may split.
        utterance: "call mom and dad about the reunion",
        expected: [
            ExpectedTask(titleContains: ["mom", "dad"], category: "Family")
        ]),
    EvalCase(
        utterance: "wash and fold the laundry",
        expected: [
            ExpectedTask(titleContains: ["laundry"], category: "Home")
        ]),
    EvalCase(
        // Past the old 120-char comma cliff: this list is ~150 chars and must split
        // exactly like a short one.
        utterance:
            "renew my passport before the trip, book the dentist appointment for both kids, pay the water bill before the late fee, return the amazon package to the ups store",
        expected: [
            ExpectedTask(titleContains: ["passport"], expectDue: true),
            ExpectedTask(titleContains: ["dentist"]),
            ExpectedTask(titleContains: ["water bill"], category: "Finance", expectDue: true),
            ExpectedTask(titleContains: ["amazon"]),
        ]),
    EvalCase(
        utterance:
            "i need to schedule the oil change and then call the vet about rex's shots and i should probably email the landlord about the leak in the bathroom and also figure out whether we keep the storage unit because it's four hundred a month and we never go there",
        expected: [
            ExpectedTask(titleContains: ["oil change"], category: "Car"),
            ExpectedTask(titleContains: ["vet"]),
            ExpectedTask(titleContains: ["landlord"]),
            ExpectedTask(titleContains: ["storage"], judgment: true),
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
                // Name every miss — the aggregates say a floor moved; only the named
                // case says WHY, and recalibration is supposed to be evidence-based.
                func score(_ field: inout Score, _ label: String, _ hit: Bool) {
                    field.record(hit)
                    if !hit {
                        print("  miss[\(label)] \"\(draft.title)\" ← \(evalCase.utterance.prefix(60))")
                    }
                }
                score(
                    &title, "title",
                    expected.titleContains.allSatisfy { lowerTitle.contains($0.lowercased()) })
                if let expectedCategory = expected.category {
                    score(&category, "category", draft.category == expectedCategory)
                }
                score(&judgment, "judgment", draft.isJudgmentCall == expected.judgment)
                if let expectedOwner = expected.owner {
                    score(&owner, "owner", draft.ownerName == expectedOwner)
                }
                score(&blocked, "blocked", (draft.blockedBy != nil) == expected.blocked)
                score(&due, "due", (draft.dueDate != nil) == expected.expectDue)
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

        // Regression floors — calibrated just under observed numbers. Re-baselined
        // upward with the connective-aware splitter (Segmentation.swift): observed
        // segmentation/title/judgment/blocked/due all 100% and category 97% across 47
        // cases including the dictated run-on set. Owner keeps its old floor — three
        // samples is no basis for a tighter one.
        #expect(segmentation.rate >= 0.95, "segmentation regressed: \(segmentation.display)")
        #expect(title.rate >= 0.95, "title fidelity regressed: \(title.display)")
        #expect(category.rate >= 0.90, "category accuracy regressed: \(category.display)")
        #expect(judgment.rate >= 0.95, "judgment detection regressed: \(judgment.display)")
        #expect(owner.rate >= 0.60, "owner extraction regressed: \(owner.display)")
        #expect(blocked.rate >= 0.95, "blocker detection regressed: \(blocked.display)")
        #expect(due.rate >= 0.95, "due detection regressed: \(due.display)")
    }
}
