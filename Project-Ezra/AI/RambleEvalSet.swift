//
//  RambleEvalSet.swift
//  Project-Ezra
//
//  The honest-risk instrument: a hand-labeled eval set for the ramble pipeline
//  (speech-ish text → intents → resolved drafts), scored per field — the SINGLE
//  source both consumers run: `RambleEvalTests` (heuristic + resolver, with
//  regression floors) and the `-RambleEval` launch seam (the ACTIVE engine, which
//  on real hardware means the on-device model — how "does on-device land >50%?"
//  gets answered with data instead of vibes).
//
//  The runner is parameterized on a resolve closure so both consumers score
//  IDENTICALLY — the scoring body cannot drift between the test and the device.
//
//  DEBUG-only: ~300 lines of labeled utterances have no business in a release
//  binary. The test target builds Debug, so `@testable import` sees everything.
//

#if DEBUG

import Foundation

enum RambleEval {

    // MARK: - Fixture shape

    struct ExpectedTask {
        var titleContains: [String]
        var category: String? = nil
        var judgment: Bool = false
        var owner: String? = nil
        var blocked: Bool = false
        /// The kind the pipeline should classify (axis 2, INTERNAL since 2026-08-11 —
        /// no user correction exists, so this floor is the field's whole trust story).
        /// Nil = unlabeled, unscored; label where the reading is unambiguous.
        var kind: WorkIntent? = nil
        /// True when the pipeline should land a date — either because the utterance says
        /// one, or because the task's own nature carries a real deadline the user rarely
        /// bothers to speak (rent, a renewal, a filing). The second kind is
        /// `IntentResolver.inferredDueDate`'s job; before it existed every one of these
        /// was labeled false, and the label meant "the user didn't say a date" rather than
        /// "this task shouldn't have one".
        var expectDue: Bool = false
    }

    struct EvalCase {
        var utterance: String
        var expected: [ExpectedTask]

        /// How many INTENTS the pipeline should emit, when that differs from the DRAFT
        /// count above.
        ///
        /// They differ in exactly one situation: `IntentResolver.expand` fans one intent
        /// out across named occasions, so "walk the dog monday and tuesday" is ONE intent
        /// and TWO drafts. Any reader judged on task COUNT has to be judged against this
        /// number, not the draft count — otherwise the product's own correctly-working
        /// expansion is recorded as a misread.
        ///
        /// Nil = same as `expected.count`, which is the overwhelming majority.
        var expectedIntents: Int? = nil

        /// One intended outcome, before expansion.
        var isAtomic: Bool { (expectedIntents ?? expected.count) == 1 }
    }

    // MARK: - The adversarial near-miss suite

    /// Decomposition near-misses, in matched pairs — the hardest corpus in the product.
    ///
    /// Written to break an on-device confidence gate, which was measured and deleted
    /// (2026-08-22). They outlived it because the question they ask did not change hands
    /// so much as move up a rung: *where does one intended outcome end?* That is now
    /// Gemini's whole job, and these are the cases that punish getting it wrong.
    ///
    /// **Why the golden corpus is not enough.** `evalSet` samples how people actually
    /// talk, so most of it is plainly one thing or plainly several, and the hard cases
    /// are rare enough for an average to swallow them. A clean score on a natural sample
    /// can simply mean the sample was not adversarial — the failure mode a finite corpus
    /// always has and never reports.
    ///
    /// **The pairing is the point.** Each "looks like one, is two" sits beside a "looks
    /// like two, is one", so nothing passes by becoming uniformly more suspicious of the
    /// word "and". A reader that splits everything and a reader that splits nothing both
    /// score well on half of this set and badly on the other.
    static let gateAdversarialSet: [EvalCase] = [

        // ── Looks atomic, is NOT. A SAFE verdict here loses the user work. ──

        // Two people, two errands, no second action verb to give it away.
        EvalCase(
            utterance: "text mom about sunday and the dentist about thursday",
            expected: [
                ExpectedTask(titleContains: ["mom"]),
                ExpectedTask(titleContains: ["dentist"]),
            ]),
        // No leading verb at all, so nothing lexical marks the boundary.
        EvalCase(
            utterance: "sarah needs the report and john needs the invoice",
            expected: [
                ExpectedTask(titleContains: ["report"]),
                ExpectedTask(titleContains: ["invoice"]),
            ]),
        // Two appointments with two different parties on two different days.
        EvalCase(
            utterance: "dentist on thursday and the vet on friday",
            expected: [
                ExpectedTask(titleContains: ["dentist"], expectDue: true),
                ExpectedTask(titleContains: ["vet"], expectDue: true),
            ]),
        // A trailing second outcome disguised as a modifier of the first.
        EvalCase(
            utterance: "post the parcel and a stamp for the birthday card",
            expected: [
                ExpectedTask(titleContains: ["parcel"]),
                ExpectedTask(titleContains: ["stamp"]),
            ]),

        // ── Looks compound, IS one. Splitting these is the mirror failure, and the
        //    reason the suite is paired rather than a list of hard splits. ──

        // Compound object, one email. (Deliberately NOT "call mom and dad about the
        // reunion" — the golden set already owns that utterance, and a duplicate across
        // the two corpora gives one text two different labels.)
        EvalCase(
            utterance: "email the landlord about the boiler and the leak",
            expected: [ExpectedTask(titleContains: ["landlord"])]),
        // Two verbs, one errand — the outcome rule read forwards.
        EvalCase(
            utterance: "pick up and drop off the kids",
            expected: [ExpectedTask(titleContains: ["kids"])]),
        // One subject, one call, two topics.
        EvalCase(
            utterance: "call the school about the trip and the uniform",
            expected: [ExpectedTask(titleContains: ["school"])]),
        // Three sentences' worth of context about ONE outcome, no punctuation.
        EvalCase(
            utterance: "sort out the passport it expires in march",
            expected: [ExpectedTask(titleContains: ["passport"], expectDue: true)]),
    ]

    // MARK: - The labeled set (count printed at runtime — never trust a comment)

    static let evalSet: [EvalCase] = [
        // Single errands, clear category signals.
        EvalCase(
            utterance: "renew my passport",
            expected: [
                ExpectedTask(titleContains: ["passport"], category: "Travel", kind: .action, expectDue: true)
            ]),
        EvalCase(
            utterance: "pay the water bill",
            expected: [
                ExpectedTask(
                    titleContains: ["water bill"], category: "Finance", kind: .action, expectDue: true)
            ]),
        EvalCase(
            utterance: "call mom back",
            expected: [
                ExpectedTask(titleContains: ["mom"], category: "Family", kind: .action)
            ]),
        EvalCase(
            utterance: "pick up the dry cleaning",
            expected: [
                ExpectedTask(titleContains: ["dry cleaning"], category: "Errands")
            ]),
        EvalCase(
            utterance: "schedule a dentist appointment",
            expected: [
                ExpectedTask(titleContains: ["dentist"], category: "Health", kind: .action)
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
                ExpectedTask(titleContains: ["deck"], category: "Work", kind: .action)
            ]),
        EvalCase(
            utterance: "return the amazon package",
            expected: [
                ExpectedTask(titleContains: ["package"], category: "Errands")
            ]),
        EvalCase(
            utterance: "book a haircut",
            expected: [
                ExpectedTask(titleContains: ["haircut"], category: "Personal", kind: .action)
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
                ExpectedTask(titleContains: ["groceries"], category: "Home", kind: .action)
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
                ExpectedTask(titleContains: ["gym"], judgment: true, kind: .planning)
            ]),
        EvalCase(
            utterance: "figure out if the side project is still worth it",
            expected: [
                ExpectedTask(titleContains: ["side project"], judgment: true, kind: .planning)
            ]),
        EvalCase(
            utterance: "decide whether to switch schools",
            expected: [
                ExpectedTask(titleContains: ["schools"], judgment: true, kind: .planning)
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
                ExpectedTask(titleContains: ["flights"], category: "Travel", blocked: true, kind: .action)
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

        // ── THE CASE THE ROUTING WAS REVERSED ON (device, 2026-08) ──
        //
        // Verbatim from the product-shape v2 write-up, and it is here because it was
        // NOT here: the eval set held ~100% floors while this exact utterance collapsed
        // into one task titled with its own transcript. That is the difference between
        // an eval set and a proof — the floors described the shapes we had already
        // taught the splitter, not the shape the product actually fails on.
        //
        // **It is expected to MISS on the deterministic and on-device arms, and that is
        // the point.** The connectives are gone entirely — no "and", no "then", no
        // commas — so there is nothing lexical to split on; it is pure stream
        // segmentation with modifier attachment ("tomorrow" belongs to the school run,
        // "for next week" to the cooking), which is Level 2–3 semantic parsing. The
        // floors stay green because a single miss across the set is still ~98%, and that
        // is deliberate too: this case is a TARGET for the cloud arm to clear, not a
        // regression bar for arms that were never going to clear it. When the cloud arm
        // runs and this case passes on it and fails on the others, the routing decision
        // has its evidence in the same table.
        //
        // **Extended 2026-08-20 to the utterance as actually spoken on device**, which
        // runs three items past where this fixture used to stop and carries the two
        // shapes the count argument turns on:
        //
        //   "cook a lunch for three days of the week for next week"  → ONE task
        //   "walk my dog monday and tuesday"                          → TWO tasks
        //
        // Both are the same rule read in opposite directions — one task per distinct
        // intended OUTCOME, not per verb and not per number. A quantity inside one
        // outcome (three lunches, cooked once) does not multiply it; two named occasions
        // of one outcome do. The second is `IntentResolver.expand`'s whole job, and it
        // is scored HERE rather than only in a unit test because expansion that works on
        // a hand-built intent and never survives a real parse is not a feature.
        //
        // Nine expected, in utterance order — the expanded pair sits where the user said
        // it, earliest date first.
        EvalCase(
            utterance:
                "take the kids to school tomorrow go to the park cook a lunch for three days of the week for next week figure out what to finish up with work plan birthday dinner with my wife walk my dog monday and tuesday plan the year of 2027 review the year of 2026",
            expected: [
                ExpectedTask(titleContains: ["school"], category: "Family", expectDue: true),
                ExpectedTask(titleContains: ["park"]),
                ExpectedTask(titleContains: ["lunch"], category: "Home"),
                ExpectedTask(titleContains: ["work"], kind: .planning),
                ExpectedTask(titleContains: ["birthday"], category: "Family", kind: .planning),
                ExpectedTask(titleContains: ["dog"], expectDue: true),
                ExpectedTask(titleContains: ["dog"], expectDue: true),
                ExpectedTask(titleContains: ["2027"], kind: .planning),
                ExpectedTask(titleContains: ["2026"], kind: .planning),
            ],
            // Nine drafts, EIGHT intents — the dog walk is one intent the resolver fans
            // out. Not a detail: without this a reader is marked wrong for being right
            // about the one case the expansion rule exists for.
            expectedIntents: 8),

        // The expansion isolated from the hard blob above, so a segmentation miss there
        // can't hide whether the fan-out itself works — and so the free arms are held to
        // it too. Both of these DO pass deterministically: the " and " boundary is
        // rejected by `Segmentation.acceptBoundary` (a weekday doesn't start an item),
        // and `HeuristicEngine.weekdayEnumeration` hands the whole phrase over.
        EvalCase(
            utterance: "walk the dog monday and tuesday",
            expected: [
                ExpectedTask(titleContains: ["dog"], expectDue: true),
                ExpectedTask(titleContains: ["dog"], expectDue: true),
            ],
            // TWO drafts from ONE intent. This is the single clearest case in the corpus
            // where "how many tasks?" and "how many things did the person mean?" have
            // different answers, and a decomposer is judged on the second.
            expectedIntents: 1),
        EvalCase(
            // The guard, and the more important half: a quantity is not an enumeration.
            // If this ever returns three, the expansion has started reading numbers.
            utterance: "cook lunch for three days of the week next week",
            expected: [
                ExpectedTask(titleContains: ["lunch"], category: "Home", expectDue: true)
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
        EvalCase(
            // "after that" is a connective; "after <noun>" is a blocker. One ramble
            // exercising both — the second item splits clean, the third stays blocked.
            utterance:
                "renew my passport and after that book flights for the trip, and book the hotel once the flights are booked",
            expected: [
                ExpectedTask(titleContains: ["passport"], expectDue: true),
                ExpectedTask(titleContains: ["flights"], category: "Travel"),
                ExpectedTask(titleContains: ["hotel"], blocked: true),
            ]),
        EvalCase(
            // Spoken enumeration — ordinal openers strip, items verify.
            utterance: "first call the dentist then i need to pay the water bill",
            expected: [
                ExpectedTask(titleContains: ["dentist"], category: "Health"),
                ExpectedTask(titleContains: ["water bill"], category: "Finance", expectDue: true),
            ]),
    ]

    // MARK: - Scoring

    struct Score {
        var hits = 0
        var total = 0
        var rate: Double { total == 0 ? 1 : Double(hits) / Double(total) }
        mutating func record(_ hit: Bool) {
            total += 1
            if hit { hits += 1 }
        }
        var display: String { "\(hits)/\(total) (\(Int((rate * 100).rounded()))%)" }
    }

    // MARK: - Floors

    /// The per-field regression floors — calibrated just under observed numbers. They
    /// catch a change that degrades the pipeline; they are not aspirations.
    ///
    /// **They live HERE, not in the test, and that is the point of this phase.** They
    /// used to be `#expect` literals inside `RambleEvalTests`, which meant only CI could
    /// fail them — and CI exercises the deterministic path, because the Foundation
    /// Models path only runs on real hardware. So the floors were held by the FALLBACK
    /// while the front door was never measured against them at all. A green suite proved
    /// the arm nobody ships as the primary, and an unstructured spoken blob failed to
    /// segment on device with every floor still reading 100%.
    ///
    /// Moving them next to the scoring body is the same argument that put the scoring
    /// body in the app target: an instrument that two consumers must agree on cannot
    /// live inside one of them. Every arm — heuristic, on-device, and the cloud arm when
    /// it lands — is now held to the same numbers by the same code.
    struct Floors {
        var segmentation = 0.95
        var title = 0.95
        var category = 0.90
        var judgment = 0.95
        /// Deliberately looser: three labeled samples is no basis for a tighter floor.
        var owner = 0.60
        var blocked = 0.95
        var due = 0.95
        /// Kind is INTERNAL (no user correction exists since 2026-08-11), so this floor
        /// is the field's whole trust story — an AI-owned field earns trust through
        /// evaluation, not invisibility.
        var kind = 0.90

        /// Re-baselined upward with the connective-aware splitter (`Segmentation`):
        /// observed segmentation/title/judgment/blocked/due all 100% and category 97%
        /// across the labeled set including the dictated run-on cases.
        static let standard = Floors()

        // The gate's ceilings lived here; deleted with the gate (2026-08-22).

        /// End-to-end time to a settled interpretation, p90, per arm.
        ///
        /// Generous on purpose: it is a REGRESSION guard, not a target. The target is
        /// "did local bypasses shorten this?", which is answered by comparing arms, and
        /// no single threshold can express that. What this catches is the pipeline
        /// quietly getting slower while every accuracy row stays green.
        var settledRevealP90Ms = 3000.0
    }

    /// One full run's per-field results plus the named misses.
    struct Report {
        var segmentation = Score()
        var title = Score()
        var category = Score()
        var judgment = Score()
        var owner = Score()
        var blocked = Score()
        var due = Score()
        var kind = Score()
        var caseCount = 0

        /// **Time to a settled interpretation**, per case: the whole decision — routing,
        /// routing, parse, resolver — from submit to drafts in hand.
        ///
        /// Accuracy is the hard constraint; this is the optimization target. It is also
        /// the number that retired the on-device confidence gate: that path measured a
        /// warm p50 of 2303ms on device against a cloud arm answering in about a second,
        /// so the "local-first" route was slower than the network it avoided.
        ///
        /// NOT `ModelMetrics.lastConfirmMs`: that is the SHIPPED number and includes
        /// `Motion.orbMinimumDwellSeconds`, so it can only be read through the composer.
        /// This is the pipeline's own cost with no presentation floor in it. When the two
        /// diverge on a local read, the difference is the dwell — by design.
        var settledMs: [Int] = []
        var settledP90Ms: Double {
            guard !settledMs.isEmpty else { return 0 }
            let sorted = settledMs.sorted()
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.9).rounded()))
            return Double(sorted[index])
        }

        /// Every field paired with its name and floor, so callers iterate rather than
        /// enumerate — the shape that stops the test and the device seam from checking
        /// different subsets.
        func fields(against floors: Floors = .standard) -> [(name: String, score: Score, floor: Double)] {
            [
                ("segmentation", segmentation, floors.segmentation),
                ("title", title, floors.title),
                ("category", category, floors.category),
                ("judgment", judgment, floors.judgment),
                ("owner", owner, floors.owner),
                ("blocked", blocked, floors.blocked),
                ("due", due, floors.due),
                ("kind", kind, floors.kind),
            ]
        }

        /// The fields that fell below their floor, named, with both numbers. Empty = pass.
        ///
        /// Latency is checked here too, as a CEILING rather than a floor — it is the one
        /// row that fails by being too big. Keeping it inside `failures` rather than
        /// beside it is deliberate: a number reported in the table and checked nowhere is
        /// the exact rot `everyFieldIsHeld` exists to prevent, and a timing row is no
        /// more exempt from that than an accuracy row.
        func failures(against floors: Floors = .standard) -> [String] {
            var broken = fields(against: floors).compactMap { field -> String? in
                guard field.score.rate < field.floor else { return nil }
                return "\(field.name) \(field.score.display) < floor \(Int(field.floor * 100))%"
            }
            if !settledMs.isEmpty, settledP90Ms > floors.settledRevealP90Ms {
                broken.append(
                    "settled p90 \(Int(settledP90Ms))ms > ceiling \(Int(floors.settledRevealP90Ms))ms")
            }
            return broken
        }

        var table: String { table(against: .standard) }

        /// The report as a table, each row carrying its own PASS/FAIL against the floor
        /// — so a device run answers "did this arm hold?" without anyone comparing
        /// printed percentages to numbers in a test file by eye.
        func table(against floors: Floors, arm: String? = nil) -> String {
            let title =
                arm.map { "Ramble eval — \($0) (\(caseCount) cases)" }
                ?? "Ramble eval (\(caseCount) cases)"
            let rows = fields(against: floors).map { field in
                let verdict = field.score.rate < field.floor ? "FAIL" : "pass"
                return field.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                    + field.score.display.padding(toLength: 16, withPad: " ", startingAt: 0)
                    + "floor \(Int(field.floor * 100))%  \(verdict)"
            }
            let verdict = failures(against: floors).isEmpty ? "ALL FLOORS HELD" : "FLOORS BROKEN"
            // The latency row is printed even with no samples, as "—" rather than 0.
            // "Not measured" and "instantaneous" are opposite findings, and a zero here
            // would read as the second while meaning the first.
            let latency =
                settledMs.isEmpty
                ? "settled p90     —           (not measured)"
                : "settled p90     "
                    + "\(Int(settledP90Ms))ms".padding(toLength: 12, withPad: " ", startingAt: 0)
                    + "ceiling \(Int(floors.settledRevealP90Ms))ms  "
                    + (settledP90Ms > floors.settledRevealP90Ms ? "FAIL" : "pass")
            return """

                ── \(title) ──
                \(rows.joined(separator: "\n"))
                \(latency)
                ── \(verdict) ──

                """
        }
    }

    /// Score `evalSet` through `resolve` — the whole pipeline behind one closure, so
    /// the test (heuristic + resolver) and the device seam (the ACTIVE engine) run
    /// the IDENTICAL scoring body. Misses are named through `log` as they happen —
    /// the aggregates say a floor moved; only the named case says why.
    static func score(
        resolve: (String) async throws -> [TaskDraft],
        log: (String) -> Void = { print($0) }
    ) async throws -> Report {
        var report = Report()
        report.caseCount = evalSet.count

        for evalCase in evalSet {
            let started = Date()
            let drafts = try await resolve(evalCase.utterance)
            report.settledMs.append(Int(Date().timeIntervalSince(started) * 1000))

            report.segmentation.record(drafts.count == evalCase.expected.count)
            // Field scoring pairs in order and only when segmentation matched —
            // misaligned pairs would corrupt the field numbers.
            guard drafts.count == evalCase.expected.count else {
                log(
                    "  miss[segmentation] \(drafts.count)≠\(evalCase.expected.count) ← \(evalCase.utterance.prefix(60))"
                )
                continue
            }

            for (draft, expected) in zip(drafts, evalCase.expected) {
                let lowerTitle = draft.title.lowercased()
                func score(_ field: inout Score, _ label: String, _ hit: Bool) {
                    field.record(hit)
                    if !hit {
                        log("  miss[\(label)] \"\(draft.title)\" ← \(evalCase.utterance.prefix(60))")
                    }
                }
                score(
                    &report.title, "title",
                    expected.titleContains.allSatisfy { lowerTitle.contains($0.lowercased()) })
                if let expectedCategory = expected.category {
                    score(&report.category, "category", draft.category == expectedCategory)
                }
                score(&report.judgment, "judgment", draft.isJudgmentCall == expected.judgment)
                if let expectedOwner = expected.owner {
                    score(&report.owner, "owner", draft.ownerName == expectedOwner)
                }
                score(&report.blocked, "blocked", (draft.blockedBy != nil) == expected.blocked)
                score(&report.due, "due", (draft.dueDate != nil) == expected.expectDue)
                if let expectedKind = expected.kind {
                    score(&report.kind, "kind", draft.workIntent == expectedKind)
                }
            }
        }
        return report
    }
}

// The gate scorer lived here until 2026-08-22. It was deleted with the gate it measured
// — see `CaptureRoute` for the numbers that killed it. The instrument did its job: it
// caught three bugs in itself before the gate ever ran, and then reported honestly that
// the thing it was built to calibrate could not be calibrated.
//
// `gateAdversarialSet` survives it. Those near-miss pairs were written to break a
// classifier and they break a DECOMPOSER just as well, which is now Gemini's problem.

#endif
