//
//  ReasoningBudgetTests.swift
//  Project-EzraTests
//
//  The Advisor's reasoning budget and the daily cap. Both are pure functions, pinned like
//  every other policy primitive.
//
//  The router's question is "how much cognition does this judgment deserve?" — never
//  "which model?" — so these tests are written in budgets, and the rung mapping is tested
//  separately as the *implementation* of a budget. That separation is the point: when a
//  cheaper rung starts matching the ceiling on deep cases, `rung(for:)` changes and every
//  budget assertion below stays true.
//
//  These reasons are HYPOTHESES, and `AdvisorBenchmark` is what falsifies them. A case the
//  shallow rung matches at the ceiling should lose its `.deep` claim — so a failing test
//  here after a benchmark run is potentially the benchmark being right.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Reasoning budget (how much thought a judgment deserves)")
struct ReasoningBudgetTests {

    /// Facts for a task with nothing hard about it — the common case, and the one that
    /// must never cost money.
    private func plainFacts() -> TaskAdvisorFacts {
        TaskAdvisorFacts(
            id: UUID(), title: "Return the package", notes: nil, category: "Errands",
            rawCapture: "return the package", reasoning: "", status: .todo,
            effortMinutes: 15, dueDate: nil, overdueDays: nil, isUrgent: false,
            needsDecision: false, isJudgmentCall: false, decisionShaped: false,
            deferralCount: 0, quietDays: 0, blockerTitles: [], blockerIDs: [],
            dependentTitles: [], childIDs: [], openStepTitles: [], stepLabel: nil,
            parentTitle: nil, diagnosis: nil, breakdownReason: nil, workIntent: .action)
    }

    // MARK: - The hard band

    @Test("A standing decision deserves deep thought, by any of its three carriers")
    func decisionsAreHard() {
        // Values-laden choices are the one thing the system may never resolve itself, so
        // the most it can offer is well-framed options — and framing options well is
        // exactly the reasoning the local model doesn't have.
        var flagged = plainFacts()
        flagged.needsDecision = true
        #expect(AdvisorRouting.depthReason(flagged) == .decision)

        var judgment = plainFacts()
        judgment.isJudgmentCall = true
        #expect(AdvisorRouting.depthReason(judgment) == .decision)

        var shaped = plainFacts()
        shaped.decisionShaped = true
        #expect(AdvisorRouting.depthReason(shaped) == .decision)
    }

    @Test("Multi-step means a graph to hold, not a single obstacle")
    func multiStepIsHard() {
        var one = plainFacts()
        one.blockerTitles = ["passport"]
        // ONE blocker is a fact, not a graph — the local model states it perfectly well.
        #expect(AdvisorRouting.depthReason(one) == nil)

        var two = plainFacts()
        two.blockerTitles = ["passport", "contractor callback"]
        #expect(AdvisorRouting.depthReason(two) == .multiStep)

        // Blockers and open steps are two different graphs, and the reading has to hold
        // both at once — so they count together.
        var mixed = plainFacts()
        mixed.blockerTitles = ["passport"]
        mixed.openStepTitles = ["book the appointment"]
        #expect(AdvisorRouting.depthReason(mixed) == .multiStep)
    }

    @Test("Repeat deferral is live evidence that the obvious advice already failed")
    func repeatDeferralIsHard() {
        var almost = plainFacts()
        almost.deferralCount = AdvisorRouting.repeatDeferralFloor - 1
        #expect(AdvisorRouting.depthReason(almost) == nil)

        var repeated = plainFacts()
        repeated.deferralCount = AdvisorRouting.repeatDeferralFloor
        #expect(AdvisorRouting.depthReason(repeated) == .repeatDeferred)
    }

    @Test("The ordinary task stays shallow — the deep band is narrow on purpose")
    func plainTasksStayShallow() {
        #expect(AdvisorRouting.depthReason(plainFacts()) == nil)
        #expect(AdvisorRouting.budget(for: plainFacts()) == .shallow)
        #expect(
            AdvisorRouting.rung(for: plainFacts(), cloudAvailable: true, budgetAllows: true)
                == .onDevice)
    }

    // MARK: - Budgets vs. their implementation

    @Test("A budget is ordered, so 'more thought' is a comparison rather than a vibe")
    func budgetsAreOrdered() {
        #expect(ReasoningBudget.none < .shallow)
        #expect(ReasoningBudget.shallow < .deep)
        #expect(ReasoningBudget.allCases.count == 3)
    }

    @Test("Only a deep budget can reach the paid rung; everything else implements locally")
    func rungImplementsTheBudget() {
        for budget in ReasoningBudget.allCases {
            let rung = AdvisorRouting.rung(
                for: budget, cloudAvailable: true, budgetAllows: true)
            #expect(rung == (budget == .deep ? .cloud : .onDevice))
        }
        // And the router never answers with a free rung — silence is decided before a
        // judge is ever called, so two places must not be able to decide it.
        for budget in ReasoningBudget.allCases {
            for cloud in [true, false] {
                for allowed in [true, false] {
                    let rung = AdvisorRouting.rung(
                        for: budget, cloudAvailable: cloud, budgetAllows: allowed)
                    #expect(rung == .onDevice || rung == .cloud)
                }
            }
        }
    }

    // MARK: - The two gates above the band

    @Test("No provider means no cloud, however hard the task")
    func noProviderNeverRoutesCloud() {
        var hard = plainFacts()
        hard.needsDecision = true
        #expect(AdvisorRouting.budget(for: hard) == .deep)
        #expect(
            AdvisorRouting.rung(for: hard, cloudAvailable: false, budgetAllows: true) == .onDevice)
    }

    @Test("Routing never invents a rung the ladder's free half owns")
    func routerOnlyEverAnswersTwoRungs() {
        for hard in [true, false] {
            var facts = plainFacts()
            facts.needsDecision = hard
            let rung = AdvisorRouting.rung(
                for: facts, cloudAvailable: true, budgetAllows: true)
            #expect(rung == .onDevice || rung == .cloud)
        }
    }

    @Test("A spent budget degrades to on-device — a real reading, just a cheaper one")
    func spentBudgetDegrades() {
        var hard = plainFacts()
        hard.deferralCount = 9
        #expect(
            AdvisorRouting.rung(for: hard, cloudAvailable: true, budgetAllows: false) == .onDevice)
        // And the degrade is silent by construction: the router's whole vocabulary is
        // rungs. There is no "budget exhausted" state for a surface to render, because
        // converting an invisible cost control into a visible one would make it an
        // anxiety and an engagement hook in a single move.
    }

}

@MainActor
@Suite("Cloud budget (one dumb daily cap)")
struct CloudBudgetTests {

    private func ledger() -> IntelligenceLedger {
        IntelligenceLedger(defaults: UserDefaults(suiteName: "budget.test.\(UUID().uuidString)")!)
    }

    @Test("A fresh day allows spending; the cap stops it exactly at the ceiling")
    func capStopsAtTheCeiling() {
        let ledger = ledger()
        #expect(CloudBudget.allows(ledger: ledger))

        for _ in 0..<(CloudBudget.dailyCallCap - 1) {
            ledger.record(.cloud, for: .advisor)
        }
        // One short of the cap is still allowed — an off-by-one here silently costs the
        // user their last paid call of the day.
        #expect(CloudBudget.allows(ledger: ledger))

        ledger.record(.cloud, for: .advisor)
        #expect(!CloudBudget.allows(ledger: ledger))
    }

    @Test("Free rungs never consume the budget")
    func freeRungsAreFree() {
        let ledger = ledger()
        for _ in 0..<(CloudBudget.dailyCallCap * 2) {
            ledger.record(.facts, for: .advisor)
            ledger.record(.memory, for: .advisor)
            ledger.record(.onDevice, for: .advisor)
        }
        #expect(CloudBudget.allows(ledger: ledger))
    }

    @Test("The cap is daily — tomorrow starts with a full budget")
    func capIsDaily() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let suite = UserDefaults(suiteName: "budget.test.\(UUID().uuidString)")!
        let monday = Date(timeIntervalSince1970: 1_755_000_000)
        let ledger = IntelligenceLedger(defaults: suite, calendar: utc, now: monday)

        for _ in 0..<CloudBudget.dailyCallCap { ledger.record(.cloud, for: .brief, now: monday) }
        #expect(!CloudBudget.allows(ledger: ledger, now: monday))

        let tuesday = monday.addingTimeInterval(24 * 3600)
        #expect(CloudBudget.allows(ledger: ledger, now: tuesday))
    }

    @Test("The cap is a runaway backstop, not a ration")
    func capIsWellAboveATypicalDay() {
        // A typical day the architecture projects: a handful of rambles at one call
        // each, a couple of Advisor escalations, one Brief. If the cap ever sits near
        // that, it has stopped being a backstop and started being a product decision
        // nobody made.
        let typicalHeavyDay = 10 + 5 + 1
        #expect(CloudBudget.dailyCallCap > typicalHeavyDay * 2)
    }
}

@MainActor
@Suite("Precompute budget share")
struct PrecomputeBudgetTests {

    private func ledger() -> IntelligenceLedger {
        IntelligenceLedger(defaults: UserDefaults(suiteName: "precompute.\(UUID().uuidString)")!)
    }

    @Test("Speculative work yields to work a user is waiting on")
    func precomputeYieldsFirst() {
        let ledger = ledger()
        let share = Int(Double(CloudBudget.dailyCallCap) * CloudBudget.precomputeShare)
        for _ in 0..<share { ledger.record(.cloud, for: .advisor) }

        // Precompute is a BET that a task will be opened; a presence-time judgment is a
        // certainty that one already was. So the cheaper-in-expectation call runs out of
        // room first — a speculative pass must never be able to starve the real thing.
        #expect(!CloudBudget.allowsPrecompute(ledger: ledger))
        #expect(CloudBudget.allows(ledger: ledger))
    }

    @Test("The precompute share is strictly tighter than the daily cap")
    func shareIsTighter() {
        #expect(CloudBudget.precomputeShare > 0)
        #expect(CloudBudget.precomputeShare < 1)
    }
}

@Suite("Data boundary (what leaves this device)")
struct DataBoundaryTests {

    @Test("Three sentences in both configurations — no more, no fewer")
    func alwaysThreeSentences() {
        // The shape is the promise: one idea per line, readable in a glance. A fourth
        // sentence is where hedging starts; a second paragraph is where nobody reads it.
        #expect(DataBoundary.current(cloudReachable: true).sentences.count == 3)
        #expect(DataBoundary.current(cloudReachable: false).sentences.count == 3)
    }

    @Test("With no provider, nothing is claimed to leave")
    func offlineClaimsNothingLeaves() {
        let boundary = DataBoundary.current(cloudReachable: false)
        // Warning someone about transmission that is not happening is the mirror image of
        // hiding transmission that is.
        #expect(boundary.capture.contains("on this device"))
        #expect(!boundary.judgment.lowercased().contains("cloud"))
    }

    @Test("Corrections never leave, in every configuration")
    func correctionsNeverLeave() {
        for reachable in [true, false] {
            let boundary = DataBoundary.current(cloudReachable: reachable)
            #expect(boundary.never.contains("never leave"))
        }
    }

    @Test("The online sentence states BOTH halves — what stays and what goes")
    func onlineCopyNamesTheTransmission() {
        // The failure this guards is drift toward comfort, not toward falsehood. The
        // previous wording ("long, unstructured thoughts, mostly") was written when a
        // lexicon kept short sentences local; routing changed underneath it and "mostly"
        // silently became a soft word for "usually not". Copy that describes only the
        // reassuring half is how a privacy claim rots without anyone editing it.
        let capture = DataBoundary.current(cloudReachable: true).capture.lowercased()
        #expect(capture.contains("device"), "the local case must be named")
        #expect(capture.contains("cloud"), "the transmission must be named, not implied")
    }

    @Test("The copy matches what routing actually does")
    func copyAgreesWithRouting() {
        // Ties the sentence to the behaviour rather than to a reviewer's memory of it.
        // A typed list stays; a lone sentence does not — which is exactly what the
        // online copy now claims, and what it must keep claiming or be rewritten.
        #expect(CaptureRoute.route(for: "buy milk\ncall mom", cloudAvailable: true) == .local)
        #expect(CaptureRoute.route(for: "buy some milk on the way home", cloudAvailable: true) == .cloud)
    }

    @Test("No sentence names a provider, a model, or a budget")
    func noVendorOrMechanics() {
        // v5 cuts provider names and usage mechanics from customer-facing language
        // entirely: the user experiences "Ezra thought", never a vendor or a quota.
        let banned = ["gemini", "apple intelligence", "pcc", "openai", "token", "credit", "quota"]
        for reachable in [true, false] {
            let text = DataBoundary.current(cloudReachable: reachable).sentences
                .joined(separator: " ").lowercased()
            for word in banned {
                #expect(!text.contains(word), "customer-facing copy names \(word)")
            }
        }
    }
}

@Suite("Advisor latency budget (per rung, per presence)")
struct AdvisorDeadlineTests {

    @Test("Deep reasoning gets more time than a local read — the bug this replaced")
    func deepGetsMoreTimeThanLocal() {
        // One number for every rung shipped as a silent bug: 20s is right for a local read
        // and far too short for deep reasoning, so the paid rung would have timed out
        // routinely while the code, the tests and the docs all said it worked.
        let local = ModelDeadline.advisorSeconds(rung: .onDevice, presenceTime: true)
        let deep = ModelDeadline.advisorSeconds(rung: .cloud, presenceTime: true)
        #expect(local == ModelDeadline.cardSeconds)
        #expect(deep > local)
    }

    @Test("A precomputed deep read gets longer than one the user is watching")
    func precomputeGetsTheGenerousBudget() {
        let watched = ModelDeadline.advisorSeconds(rung: .cloud, presenceTime: true)
        let unwatched = ModelDeadline.advisorSeconds(rung: .cloud, presenceTime: false)
        // Nobody is waiting on a precompute, so correctness beats speed. A wait the user
        // IS watching should end in a cheaper answer rather than a longer wait.
        #expect(unwatched > watched)
    }

    @Test("Presence has no effect on a local read — there is nothing cheaper to fall to")
    func presenceOnlyMattersForDeep() {
        #expect(
            ModelDeadline.advisorSeconds(rung: .onDevice, presenceTime: true)
                == ModelDeadline.advisorSeconds(rung: .onDevice, presenceTime: false))
        // The free rungs never reach a judge, so they take the local budget by totality
        // rather than by meaning anything.
        for rung in [IntelligenceRung.facts, .memory] {
            #expect(
                ModelDeadline.advisorSeconds(rung: rung, presenceTime: true)
                    == ModelDeadline.cardSeconds)
        }
    }

    @Test("Every budget is bounded — no rung may wait forever")
    func everyBudgetIsBounded() {
        for rung in IntelligenceRung.allCases {
            for presence in [true, false] {
                let seconds = ModelDeadline.advisorSeconds(rung: rung, presenceTime: presence)
                #expect(seconds > 0)
                // The unbounded call is the bug `ModelRun` was built to delete, and a
                // deadline policy is exactly where one would sneak back in.
                #expect(seconds <= 120)
            }
        }
    }
}
