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

    // MARK: - The routing quadrant

    /// One escalation-policy decision, scored against the labels.
    ///
    /// Three definitions are pinned here because each is a place the quadrant could
    /// otherwise overclaim:
    ///
    /// **Universe = UNSTRUCTURED cases only.** An explicit-structure capture never
    /// reaches `CaptureEscalation` — the user drew the boundaries, so there is no
    /// routing decision to score. `routingRows` filters accordingly, and the four
    /// verdict cells MUST sum to the unstructured count (test-pinned): a future
    /// special-case branch may not silently drop a case from the quadrant.
    ///
    /// **The oracle is `drafts.count` vs `expected.count` — POST-EXPANSION** — the same
    /// comparison the false-keep line has always used. Case 50 labels 9 drafts against
    /// 8 intents (`expand` fans the dog walk); swapping `expectedIntents` in here would
    /// silently shift every verdict, so the choice is stated rather than implied.
    ///
    /// **"justified", not "necessary".** With a count-only oracle and zero cloud calls,
    /// "escalated AND the local count was wrong" proves the LOCAL READ fell short — it
    /// cannot prove the cloud does better. The cell claims the escalation DECISION was
    /// justified by the read's failure, nothing more.
    enum RoutingVerdict: String, CaseIterable {
        case keptCorrect = "kept-correct"
        case falseKeep = "false-keep"
        case escalatedJustified = "escalated-justified"
        case escalatedUnnecessary = "escalated-unnecessary"
    }

    struct RoutingRow {
        var utterance: String
        var draftCount: Int
        var expectedCount: Int
        var reason: CaptureEscalationReason?
        var verdict: RoutingVerdict
    }

    /// The verdict for one decision — pure, so the quadrant math is testable without
    /// running a pipeline.
    static func routingVerdict(
        reason: CaptureEscalationReason?, draftCount: Int, expectedCount: Int
    ) -> RoutingVerdict {
        let countRight = draftCount == expectedCount
        switch (reason, countRight) {
        case (nil, true): return .keptCorrect
        case (nil, false): return .falseKeep
        case (.some, false): return .escalatedJustified
        case (.some, true): return .escalatedUnnecessary
        }
    }

    /// Score a corpus's UNSTRUCTURED cases through the escalation policy. The resolve
    /// closure is the deterministic pipeline (the read the verifier judges); a throw
    /// counts as an empty read, which is what production would see.
    static func routingRows(
        over cases: [EvalCase],
        resolve: (String) async throws -> [TaskDraft]
    ) async -> [RoutingRow] {
        var rows: [RoutingRow] = []
        for evalCase in cases
        where !Segmentation.structure(of: evalCase.utterance).isExplicit {
            let drafts = (try? await resolve(evalCase.utterance)) ?? []
            let reason = CaptureEscalation.reason(for: evalCase.utterance, drafts: drafts)
            rows.append(
                RoutingRow(
                    utterance: evalCase.utterance, draftCount: drafts.count,
                    expectedCount: evalCase.expected.count, reason: reason,
                    verdict: routingVerdict(
                        reason: reason, draftCount: drafts.count,
                        expectedCount: evalCase.expected.count)))
        }
        return rows
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

    // MARK: - The real-utterance corpus (quarantined)

    /// What people ACTUALLY said to the orb: every capture in the owner's device store
    /// from 2026-08-27 to 08-30, verbatim (ASR errors and all), labeled blind by one
    /// labeler and ruled row-by-row by the owner on 2026-09-02. Kept APART from
    /// `evalSet` — it is scored against `Floors.real`, never folded into the authored
    /// floors, because reality is messier than authored fixtures and a floor that
    /// moves to admit it has stopped measuring anything.
    ///
    /// What this corpus has that the authored one never did: bare clock times ("cook
    /// dinner at 3"), fragments cut by the silence window ("Have"), the mic catching a
    /// room ("You just ate sand. Cook dinner at 9 p.m. No. No, Bubba…"), retry
    /// siblings, and meta-narration ("Adding pickup shirt…"). The four policy rulings
    /// it forced, each a product decision rather than a label:
    ///
    ///  P1 · A bare clock time implies TODAY — `IntentResolver.resolveDate`'s last arm.
    ///  P2 · Ambient/conversation captures label the buried task when one exists and
    ///       ZERO tasks when none — the first labeled anti-invention rows (18, 24, 28).
    ///  P3 · A truncated capture with a verb and an object is ONE task, unresolved
    ///       details welcome ("Take something to my" keeps the words: a task you delete
    ///       costs a swipe, a thought the system dropped costs the thought); a bare
    ///       word is zero ("Have").
    ///  P4 · Meta-narration is stripped — the capture is the content, not the act of
    ///       capturing ("Adding pickup shirt at 3 PM" is a shirt pickup).
    ///
    /// Row-level rulings: #39's "action blindness" is an ASR error for "action plan"
    /// and the title carries the words as said (the product does not fix speech
    /// recognition); #41's "eat breakfast" is a task because the person enumerated it
    /// with "and then"; #43 "today as Sunday" is dated (which day is the resolver's
    /// today-wins arm, and `expectDue` asks only whether a date landed). A child's
    /// name is replaced by "Micah" consistently — same syllable shape, so
    /// segmentation and title behaviour are unchanged and no real name sits in a
    /// public repository.
    ///
    /// **Categories, owners and kinds are deliberately unlabeled** here: this corpus
    /// measures the three things the device evidence questioned — count, title and
    /// date — and a label nobody can rule on with confidence is noise wearing a
    /// floor.
    static let realSet: [EvalCase] = [
        // 18 · P2: pure conversation the mic caught. Zero tasks.
        EvalCase(
            utterance:
                "Hello, what are you doing? Just taking my time, talking, seeing different stuff. What are your thoughts? Turn up for a check. Yep, you still listening? This probably looks good and then that's it.",
            expected: []),
        // 19 · P1: bare clock time → today.
        EvalCase(
            utterance: "Clean up room at 3 PM.",
            expected: [ExpectedTask(titleContains: ["clean", "room"], expectDue: true)]),
        // 20 · day + time: the day wins, the clock never shadows it.
        EvalCase(
            utterance: "Clean up my room tomorrow at 3 PM.",
            expected: [ExpectedTask(titleContains: ["clean", "room"], expectDue: true)]),
        // 21 · "today" spoken, "3PM" glued.
        EvalCase(
            utterance: "Cook at 3PM today",
            expected: [ExpectedTask(titleContains: ["cook"], expectDue: true)]),
        // 22 · P3: a bare word. Zero tasks.
        EvalCase(utterance: "Have", expected: []),
        // 23 · "tonight".
        EvalCase(
            utterance: "Plan what to make for dinner tonight!",
            expected: [ExpectedTask(titleContains: ["dinner"], expectDue: true)]),
        // 24 · P2 flagship: ONE task buried in child-wrangling. The anti-invention row.
        EvalCase(
            utterance:
                "You just ate sand. Cook dinner at 9 p.m. No. No, Bubba. No, we boy. No! That's yuppie. Is he being too great? Tell Mr. Charles, what did you guys do today at school? Hey, I want all that sand back in the bucket. We've wasted all the sand. Put it back in the bucket. Oh, I hate God. It's not gonna come off for a while. You had to wash it to get it off. It's glitter stuff. No, you're still playing with it",
            expected: [ExpectedTask(titleContains: ["cook", "dinner"], expectDue: true)]),
        // 25/26 · retry siblings, kept both — real retry behaviour.
        EvalCase(
            utterance: "Cook some dinner for tomorrow",
            expected: [ExpectedTask(titleContains: ["cook", "dinner"], expectDue: true)]),
        EvalCase(
            utterance: "Cook dinner for tomorrow",
            expected: [ExpectedTask(titleContains: ["cook", "dinner"], expectDue: true)]),
        // 27 · vague but actionable.
        EvalCase(
            utterance: "I wanna take this back to the house",
            expected: [ExpectedTask(titleContains: ["house"])]),
        // 28 · P2: musing, no outcome. Zero tasks.
        EvalCase(
            utterance:
                "I thought people are like, you know what? I wanna go a few more house. You know what I mean? So",
            expected: []),
        // 29 · P1: a bare hour after "at".
        EvalCase(
            utterance: "Cook dinner at 5",
            expected: [ExpectedTask(titleContains: ["cook", "dinner"], expectDue: true)]),
        // 30 · P3 boundary, ruled ONE: verb + object, destination cut. The words stay.
        EvalCase(
            utterance: "Take something to my",
            expected: [ExpectedTask(titleContains: ["take"])]),
        // 31 · P3 + P4: narration stripped, cut at the time — "When?" is the right ask.
        EvalCase(
            utterance: "I want to add that I need to be ready to go to brunch at",
            expected: [ExpectedTask(titleContains: ["brunch"])]),
        // 32 · P1: "noon".
        EvalCase(
            utterance: "Make lunch at noon",
            expected: [ExpectedTask(titleContains: ["lunch"], expectDue: true)]),
        // 33 · trailing comma from ASR.
        EvalCase(
            utterance: "Clean my car tomorrow,",
            expected: [ExpectedTask(titleContains: ["clean", "car"], expectDue: true)]),
        // 34 · P1 + a person + an ASR tail ("be").
        EvalCase(
            utterance: "Get Micah ready to go to the gym at 10 AM. be",
            expected: [ExpectedTask(titleContains: ["micah", "gym"], expectDue: true)]),
        // 35 · the real multi-intent flagship; "next week on Friday" tests arm order.
        EvalCase(
            utterance:
                "Go to the car next week on Friday, make a plan for anniversary for this Wednesday. take Micah to daycare Monday at 8 AM",
            expected: [
                ExpectedTask(titleContains: ["car"], expectDue: true),
                ExpectedTask(titleContains: ["anniversary"], expectDue: true),
                ExpectedTask(titleContains: ["daycare"], expectDue: true),
            ]),
        // 36 · P1: bare hour.
        EvalCase(
            utterance: "Cook dinner at 3",
            expected: [ExpectedTask(titleContains: ["cook", "dinner"], expectDue: true)]),
        // 37 · "next week".
        EvalCase(
            utterance: "Take car to the shop next week",
            expected: [ExpectedTask(titleContains: ["car", "shop"], expectDue: true)]),
        // 38 · unpunctuated boundary — a segmentation test on real speech.
        EvalCase(
            utterance: "Pick up groceries at noon make an action plan this Sunday for the week",
            expected: [
                ExpectedTask(titleContains: ["groceries"], expectDue: true),
                ExpectedTask(titleContains: ["plan"], expectDue: true),
            ]),
        // 39 · ASR error kept as said ("action blindness" = "action plan").
        EvalCase(
            utterance: "Cook dinner at 3 PM, make a action blindness Sunday for the week.",
            expected: [
                ExpectedTask(titleContains: ["cook", "dinner"], expectDue: true),
                ExpectedTask(titleContains: ["action"], expectDue: true),
            ]),
        // 40 · P4: narration stripped.
        EvalCase(
            utterance: "Adding pickup shirt at 3 PM So this is where so this is where",
            expected: [ExpectedTask(titleContains: ["shirt"], expectDue: true)]),
        // 41 · "then" boundary; breakfast is a task because it was enumerated.
        EvalCase(
            utterance:
                "first So I need to go pick up my car at 3 PM, clean my clothes and then eat breakfast",
            expected: [
                ExpectedTask(titleContains: ["car"], expectDue: true),
                ExpectedTask(titleContains: ["clothes"]),
                ExpectedTask(titleContains: ["breakfast"]),
            ]),
        // 42 · P3: outcome discernible.
        EvalCase(
            utterance: "We go to the bank to pick up",
            expected: [ExpectedTask(titleContains: ["bank"])]),
        // 43 · ASR ambiguity ("today as Sunday"): dated; today wins in the resolver.
        EvalCase(
            utterance: "Plan meeting today as Sunday.",
            expected: [ExpectedTask(titleContains: ["meeting"], expectDue: true)]),
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
        // **A comma list whose last item does not open on a verb (added 2026-09-20).**
        // The deterministic read currently returns ONE draft for this — titled
        // "Renew my passport, book flights", with a wait chip holding the other two
        // outcomes verbatim — because `splitCommaList` requires EVERY part to be
        // item-like (a verb, or four words or fewer) and vetoes the whole split when one
        // is not. "daycare forms are due friday" opens on a noun, so it vetoes, and the
        // two parts that were unambiguous go down with it.
        //
        // The same veto explains "daycare forms are due friday and the oil change is
        // overdue", which also comes back as one draft: neither half opens on a verb.
        // Swap the last clause for one that does — "…, call mom back" — and all three
        // outcomes appear, dependency edge included. So the boundary is the veto, not
        // the sentence's complexity.
        //
        // It is in the corpus because it was found by eye, on a screenshot, and a defect
        // found by eye is a defect nobody is measuring. The router does notice — this
        // escalates as `underSegmented`, so a build with the cloud reachable reads it
        // correctly and the free tail is what under-reads. That is the documented
        // design, which is exactly why the gap belongs in the number rather than in an
        // argument about whether it matters.
        //
        // **FIXED the same day, and only because the eval said it was safe.** The veto
        // now has a third arm (`Segmentation.isItemLike`): a part carrying its own
        // DEADLINE counts as an outcome unless it opens on a pronoun, which is what
        // separates "and daycare forms are due friday" from "call mom, she's back from
        // the trip on friday" — the second carries a day too, and is one task with
        // context. Measured against the 2026-09-20 baseline (segmentation 51/52 golden ·
        // 23/26 real · false-keep 0 · adversarial false-keep 2 · coverage 96%): this
        // case now passes, and every other number is unchanged. **Any further loosening
        // needs the same evidence** — false-keep is the critical error, and
        // `email the landlord about the boiler and the leak` sits one heuristic away.
        EvalCase(
            utterance:
                "renew my passport, book flights after it comes through, and daycare forms are due friday",
            expected: [
                // The renewal's lead time is inferred, and the flights wait on it — both
                // were mislabeled when this case was added on 2026-09-20 and the eval
                // said so on the next run. The labels are the oracle; getting them wrong
                // is how a corpus quietly starts certifying the wrong answer.
                ExpectedTask(titleContains: ["passport"], expectDue: true),
                ExpectedTask(titleContains: ["flights"], blocked: true),
                ExpectedTask(titleContains: ["daycare"], expectDue: true),
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

        /// The floors for `realSet`, calibrated just under the DETERMINISTIC arm's
        /// observed numbers on 2026-09-02: segmentation 22/26 (85%), title 28/28, due
        /// 28/28, judgment 28/28, blocked 28/28 (category/owner/kind are unlabeled
        /// there, so those entries hold nothing). The four segmentation misses are
        /// the rows the deterministic arm CANNOT get by construction — the three
        /// anti-invention rows (it splits conversation into sentences; only the
        /// authority can say "nothing here") and the bare word "Have" (it cannot tell
        /// a fragment from a one-word task like "groceries"). Every other real row
        /// segments, including the three that needed new boundaries (a dictated
        /// period, a time expression before a verb, "cook"/"eat" in the lexicon).
        /// Re-calibrate only DOWNWARD from observed numbers, like every other floor.
        static let real = Floors(segmentation: 0.80, due: 0.95)

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
        /// The same samples bucketed by `CapturePerformanceContract.Tier`, so the
        /// contract's per-tier ceilings can be checked here against the SAME corpus
        /// that holds the accuracy floors — a latency pass with a broken floor is a
        /// FAIL, and putting both in one table is what makes that unmissable.
        var settledByTier: [String: [Int]] = [:]
        var settledP90Ms: Double {
            CapturePerformanceContract.nearestRank(settledMs, quantile: 0.9)
        }
        var settledP50Ms: Double {
            CapturePerformanceContract.nearestRank(settledMs, quantile: 0.5)
        }
        var settledP95Ms: Double {
            CapturePerformanceContract.nearestRank(settledMs, quantile: 0.95)
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
            // The performance contract's per-tier p95 ceilings, beside the accuracy
            // floors — the single 3000ms row above stays as the per-ARM regression
            // guard (it is what makes the retired on-device arm's 21s scream FAIL).
            // Eval samples are PIPELINE-ONLY (no dwell, by the settledMs design), so a
            // tier passing here and failing in the live report means the dwell is the
            // gap — the table's job is to make that comparison possible, not hide it.
            let contract = CapturePerformanceContract.standard
            for tier in CapturePerformanceContract.Tier.allCases {
                guard let samples = settledByTier[tier.rawValue], !samples.isEmpty
                else { continue }
                let p95 = CapturePerformanceContract.nearestRank(samples, quantile: 0.95)
                let ceiling = contract.targets(for: tier).p95Ms
                if p95 > ceiling {
                    broken.append(
                        "\(tier.rawValue) p95 \(Int(p95))ms > contract \(Int(ceiling))ms")
                }
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
            // The contract's tiers, with the informational "+dwell" column for the
            // local tiers: eval samples carry no presentation floor, so the shipped
            // number for a voice-local reveal is ≈ sample + orbLocalDwellSeconds —
            // printed so "is the dwell the gap?" is answerable from the table alone.
            let contract = CapturePerformanceContract.standard
            let tierRows = CapturePerformanceContract.Tier.allCases.compactMap {
                tier -> String? in
                guard let samples = settledByTier[tier.rawValue], !samples.isEmpty
                else { return nil }
                let p50 = CapturePerformanceContract.nearestRank(samples, quantile: 0.5)
                let p95 = CapturePerformanceContract.nearestRank(samples, quantile: 0.95)
                let targets = contract.targets(for: tier)
                let verdict = p95 > targets.p95Ms ? "FAIL" : "pass"
                let dwell =
                    tier == .complex
                    ? ""
                    : "  (+dwell → shipped ≈ \(Int(p50 + Motion.orbLocalDwellSeconds * 1000))ms)"
                return "\(tier.rawValue) (n=\(samples.count))"
                    .padding(toLength: 16, withPad: " ", startingAt: 0)
                    + "p50 \(Int(p50))ms · p95 \(Int(p95))ms  "
                    + "contract \(Int(targets.p50Ms))/\(Int(targets.p95Ms))ms  \(verdict)"
                    + dwell
            }
            return """

                ── \(title) ──
                \(rows.joined(separator: "\n"))
                \(latency)
                \(tierRows.joined(separator: "\n"))
                ── \(verdict) ──

                """
        }
    }

    /// Score `evalSet` through `resolve` — the whole pipeline behind one closure, so
    /// the test (heuristic + resolver) and the device seam (the ACTIVE engine) run
    /// the IDENTICAL scoring body. Misses are named through `log` as they happen —
    /// the aggregates say a floor moved; only the named case says why.
    static func score(
        over corpus: [EvalCase] = evalSet,
        resolve: (String) async throws -> [TaskDraft],
        repeats: Int = 1,
        reversed: Bool = false,
        limit: Int? = nil,
        heartbeat: Bool = false,
        log: (String) -> Void = { print($0) }
    ) async throws -> Report {
        var report = Report()

        // `reversed` is Session B's flake instrument: two device passes, forward then
        // reverse, and the DIFF of named misses is the per-case flake rate — a miss
        // that appears in one order and not the other is scheduling/thermal noise, not
        // a model finding, and must not spend a cloud call on revalidation.
        //
        // `limit` is the smoke-test dial (`-EvalCaseLimit N`): a 3–5 case pass that
        // answers "is the model arm ALIVE on this host?" in a couple of minutes before
        // anyone commits to a 52-case sitting.
        //
        // `heartbeat` is Session B's other lesson: the report used to print only
        // MISSES, so twenty-five consecutive clean cases and a suspended app produced
        // the same silence, and a human spent an hour telling them apart. On a model
        // arm every case now announces itself BEFORE the inference (line-buffered, so
        // a hang reads as "start" with no "done" — the liveness signal itself) and
        // reports its outcome and cost after.
        var cases = reversed ? Array(corpus.reversed()) : corpus
        if let limit { cases = Array(cases.prefix(limit)) }
        report.caseCount = cases.count
        for (index, evalCase) in cases.enumerated() {
            let tier = CapturePerformanceContract.Tier.tier(for: evalCase.utterance).rawValue
            if heartbeat {
                log("  case \(index + 1)/\(cases.count) → \(evalCase.utterance.prefix(44))")
            }
            let started = Date()
            let drafts = try await resolve(evalCase.utterance)
            let firstMs = Int(Date().timeIntervalSince(started) * 1000)
            if heartbeat {
                let verdict = drafts.count == evalCase.expected.count ? "ok" : "MISS"
                log(
                    "  case \(index + 1)/\(cases.count) \(verdict) · \(firstMs)ms · "
                        + "\(drafts.count) draft\(drafts.count == 1 ? "" : "s")")
            }
            report.settledMs.append(firstMs)
            report.settledByTier[tier, default: []].append(firstMs)
            // Extra timing-only repeats for stabler percentiles (`-CaptureRepeats`).
            // Accuracy is scored ONCE, on the first run: re-scoring identical inputs
            // would only multiply every hit and miss by N and change no rate.
            for _ in 1..<max(1, repeats) {
                let repeatStarted = Date()
                _ = try await resolve(evalCase.utterance)
                let ms = Int(Date().timeIntervalSince(repeatStarted) * 1000)
                report.settledMs.append(ms)
                report.settledByTier[tier, default: []].append(ms)
            }

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
