//
//  ReasoningBudget.swift
//  Project-Ezra
//
//  **How much cognition does this judgment deserve?** — and nothing about which model
//  answers it.
//
//  This replaces a router that asked the wrong question. The first version decided
//  "is this task hard enough to pay for", which is a *procurement* question dressed as a
//  product one: it starts from the price list and works backwards, so the answer is
//  always a percentage somebody chose. The v5 correction is that **routing percentages
//  are an output, not a decision** — never "cloud should be 10%", always "these cases
//  measurably need deep reasoning; those don't."
//
//  So the router now answers in units of THOUGHT, and rung selection merely implements
//  the answer. Two things fall out of that, and both matter:
//
//  1. **Ezra decides, never the model.** A budget is set by the system from deterministic
//     facts before any generation happens. A model asked to decide how hard to think
//     about itself is a model with an unbounded appetite.
//  2. **The mapping is swappable without touching policy.** When a cheaper rung starts
//     matching the ceiling on `.deep` cases (which is what the benchmark exists to
//     discover), `rung(for:)` changes and the budget assignments don't. The judgment
//     "this deserves real thought" stays true even when real thought gets cheaper.
//
//  **Depth is not length.** A bigger budget buys a better diagnosis and sharper silence,
//  never more words — the visible contract is one judgment and at most one move at every
//  rung. `ValidatedReading` enforces that identically regardless of what was spent, so
//  models can be swapped without the product changing shape.
//

import Foundation

/// How much cognition a judgment deserves.
enum ReasoningBudget: String, CaseIterable, Sendable, Comparable {
    /// Not worth thinking about. The deterministic gate already answered.
    case none
    /// One observation over a handful of facts — a state most tasks are in, and one the
    /// local model handles well.
    case shallow
    /// Several things held at once: competing options, a chain of prerequisites, a
    /// history of the user bouncing off. This is the band where the local model is
    /// measurably weak and where the differentiating sentence — "I was stuck, and Ezra
    /// knew the move" — is won or lost.
    case deep

    private var order: Int {
        switch self {
        case .none: return 0
        case .shallow: return 1
        case .deep: return 2
        }
    }

    static func < (lhs: ReasoningBudget, rhs: ReasoningBudget) -> Bool { lhs.order < rhs.order }
}

enum AdvisorRouting {

    /// The budget this judgment deserves, from facts alone.
    ///
    /// Called only AFTER the deterministic gate opened and the fingerprint cache missed,
    /// so `.none` never appears here in practice — it exists so the enum is total and so
    /// a future gate change has somewhere to say "nothing".
    static func budget(for facts: TaskAdvisorFacts) -> ReasoningBudget {
        depthReason(facts) == nil ? .shallow : .deep
    }

    /// Why this judgment deserves real thought — or nil for shallow.
    ///
    /// A reason rather than a Bool, for the same argument that inverted
    /// `AdvisorGateReason`: "31 of 58 went deep" is not actionable, "28 were
    /// repeat-deferred" says which way the boundary should move. Ordered — first match
    /// wins — and the order is a REPORTING choice, not a claim about which matters more.
    ///
    /// **These are hypotheses the benchmark is meant to falsify.** They are where deep
    /// reasoning is *expected* to earn its keep; `AdvisorBenchmark` is what turns that
    /// expectation into a measurement, and a case that the shallow rung matches at the
    /// ceiling should lose its `.deep` claim rather than keep it out of habit.
    static func depthReason(_ facts: TaskAdvisorFacts) -> DepthReason? {
        // 1. A standing human obligation to choose. Values-laden decisions are the one
        //    thing the system may never resolve itself, so the most it can offer is a
        //    well-framed set of options — and framing options well is the reasoning the
        //    local model does not have.
        if facts.needsDecision || facts.isJudgmentCall || facts.decisionShaped {
            return .decision
        }
        // 2. Multi-step: prerequisites and open steps at the same time. The reading has
        //    to hold a graph, not a fact. ONE blocker is deliberately not enough — that
        //    is a fact the local model states perfectly well.
        if facts.blockerTitles.count + facts.openStepTitles.count >= 2 { return .multiStep }
        // 3. The user has bounced off this repeatedly. `deferralCount` is CONSECUTIVE,
        //    cleared the moment they engage, so a high number is live evidence that the
        //    obvious advice already failed — the strongest single signal that a better
        //    reading is worth the thought.
        if facts.deferralCount >= repeatDeferralFloor { return .repeatDeferred }
        return nil
    }

    /// Consecutive deferrals before a task counts as repeat-deferred. The first number to
    /// move when the benchmark has data — a magic 3 in a condition is not a thing anyone
    /// tunes.
    static let repeatDeferralFloor = 3

    enum DepthReason: String, CaseIterable, Sendable {
        case decision
        case multiStep
        case repeatDeferred
    }

    /// Which rung IMPLEMENTS a budget, given what is reachable and affordable.
    ///
    /// This is the whole of the model-selection logic, and it is deliberately dull: the
    /// interesting decision happened in `budget(for:)`. A `.deep` judgment with no cloud
    /// provider, or a spent daily budget, still gets thought — just the best thought
    /// available locally, silently. The user is never told their advice was rationed.
    static func rung(
        for budget: ReasoningBudget, cloudAvailable: Bool, budgetAllows: Bool
    ) -> IntelligenceRung {
        guard budget == .deep, cloudAvailable, budgetAllows else { return .onDevice }
        return .cloud
    }

    /// Convenience for call sites that have facts rather than a budget.
    static func rung(
        for facts: TaskAdvisorFacts, cloudAvailable: Bool, budgetAllows: Bool
    ) -> IntelligenceRung {
        rung(for: budget(for: facts), cloudAvailable: cloudAvailable, budgetAllows: budgetAllows)
    }
}

// MARK: - The cap

/// One dumb daily cloud-call cap that degrades to Rung 2, silently.
///
/// **Deliberately not a governor.** The proposed eligibility → recency → rate machinery
/// solves a problem nobody has measured, and this codebase has a named precedent against
/// that: the capture deadline was tuned on device evidence, not argument. The fingerprint
/// cache and the plays-once Brief already remove the two biggest cost drivers
/// structurally, so the honest sequence is **meter first** (`IntelligenceLedger`), **cap
/// second** (this), **govern on evidence** — and only if the counters show a real
/// distribution problem.
///
/// **Nothing here is ever user-visible.** No credits, no tokens, no generation counters,
/// no "deep thinking allowance". The user experiences "Ezra helps when help is
/// warranted", never "Ezra is rationed" — a budget shown to a user is a budget they start
/// managing, and making the user manage Ezra is the one thing the product refuses
/// outright. The cap's only surface is the DEBUG diagnostics line.
enum CloudBudget {
    /// Calls per day across ALL workloads.
    ///
    /// A single shared number rather than per-workload quotas: the whole point of the
    /// ladder is that workloads climb it at different rates, and pre-allocating between
    /// them would be exactly the speculative governor this refuses to build. Sized well
    /// above a projected heavy day so it never shapes normal use — a runaway backstop,
    /// not a ration.
    /// **A runaway backstop, not a ration — and sized for a research build.**
    ///
    /// It was 40, chosen as "well above a projected heavy day" for a shipping user. That
    /// number is wrong for the way this build is actually used: a manual evaluation
    /// session drives far more cloud traffic than a day of real use, and hitting the cap
    /// mid-session degrades to Rung 2 *silently*, which turns an eval into a measurement
    /// of the cap rather than of the model. The backstop still exists — an unattended
    /// loop against a paid API is a real way to lose money — it just sits above where
    /// exploration lives instead of inside it.
    static let dailyCallCap = 500

    /// Precompute gets a smaller share of the same ceiling.
    ///
    /// Speculative work must never be able to starve work a user is actually waiting on.
    /// Precompute is a bet that a task will be opened; a presence-time judgment is a
    /// certainty that one already was. So the cheaper-in-expectation call yields.
    static let precomputeShare = 0.5

    static func allows(ledger: IntelligenceLedger = .shared, now: Date = Date()) -> Bool {
        let allowed = ledger.cloudCallsToday(now: now) < dailyCallCap
        #if DEBUG
        // Silence is the right PRODUCT behaviour — a user told "you have used your AI
        // budget" gains an anxiety and an engagement hook and loses nothing else. It
        // is the wrong DEVELOPMENT behaviour: an eval that silently stops exercising
        // the rung it is evaluating reports the cap's opinion as the model's. Loud
        // here, silent in the shipping build.
        if !allowed {
            print(
                "⚠️ cloud budget exhausted — degrading to on-device. "
                    + statusLine(ledger: ledger, now: now))
        }
        #endif
        return allowed
    }

    /// Whether a SPECULATIVE deep judgment may run. Strictly tighter than `allows`.
    static func allowsPrecompute(ledger: IntelligenceLedger = .shared, now: Date = Date()) -> Bool {
        Double(ledger.cloudCallsToday(now: now)) < Double(dailyCallCap) * precomputeShare
    }

    /// The DEBUG line — and the number that says whether the cap is doing anything at
    /// all. If it is never approached, the cap is correctly inert and the smart governor
    /// stays unbuilt, which is the answer we want.
    static func statusLine(ledger: IntelligenceLedger = .shared, now: Date = Date()) -> String {
        "cloud budget: \(ledger.cloudCallsToday(now: now))/\(dailyCallCap)"
    }
}
