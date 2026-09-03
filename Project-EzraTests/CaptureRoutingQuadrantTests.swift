//
//  CaptureRoutingQuadrantTests.swift
//  Project-EzraTests
//
//  The eval campaign's measurement-integrity tests (Session A, 2026-08-29). These
//  protect the EXPERIMENT, not the product: a quadrant a case can silently vanish
//  from, an adversarial suite whose pairing quietly breaks, or a complex fixture that
//  stops routing to the cloud would each corrupt every conclusion drawn downstream —
//  while looking exactly like a clean report.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CaptureRoutingQuadrantTests {

    /// The deterministic pipeline, exactly as the policy report runs it.
    private func resolve(_ utterance: String) async throws -> [TaskDraft] {
        let intents = try await HeuristicEngine().triage(rawText: utterance)
        return IntentResolver.resolve(intents)
    }

    // MARK: - Quadrant math

    @Test("Each (reason, count) combination lands in its named cell — and only there")
    func verdictPerCell() {
        typealias V = RambleEval.RoutingVerdict
        #expect(RambleEval.routingVerdict(reason: nil, draftCount: 2, expectedCount: 2) == .keptCorrect)
        #expect(RambleEval.routingVerdict(reason: nil, draftCount: 1, expectedCount: 3) == .falseKeep)
        #expect(
            RambleEval.routingVerdict(
                reason: .underSegmented, draftCount: 2, expectedCount: 9) == .escalatedJustified)
        #expect(
            RambleEval.routingVerdict(
                reason: .underSegmented, draftCount: 1, expectedCount: 1) == .escalatedUnnecessary)
    }

    @Test("Measurement integrity: the four cells sum to the unstructured case count")
    func cellsSumToEligible() async throws {
        // No case may vanish from the quadrant: a future special-case branch that
        // drops one would corrupt every rate built on the denominator, invisibly.
        let unstructured = RambleEval.evalSet.filter {
            !Segmentation.structure(of: $0.utterance).isExplicit
        }.count
        let rows = await RambleEval.routingRows(over: RambleEval.evalSet, resolve: resolve)
        #expect(rows.count == unstructured)
        // Every row carries exactly one verdict, so cell sums equal row count by
        // construction — asserted anyway, because "by construction" is what the last
        // three silent eval bugs also were.
        let cellSum = RambleEval.RoutingVerdict.allCases
            .map { verdict in rows.filter { $0.verdict == verdict }.count }
            .reduce(0, +)
        #expect(cellSum == unstructured)
    }

    // MARK: - The adversarial suite

    @Test("The policy keeps no wrong read on the authored corpus — false-keeps are zero")
    func authoredFalseKeepsAreZero() async {
        // The one number that can kill device-first routing, pinned at the value the
        // policy landed with. A false-keep is a capture the labels call wrong that
        // never reached the authority — the user's intent silently lost. Case 50 is
        // why this exists as a test and not a report line: the time-expression
        // boundary (2026-09-02) improved its deterministic read from two drafts to
        // five, and with only connective + time signals the verifier stopped seeing
        // the four still missing — the founding case became a false-keep with every
        // floor green. `interiorVerbSignals` restored the escalation; this pins it.
        let resolve: (String) async throws -> [TaskDraft] = { utterance in
            IntentResolver.resolve(try await HeuristicEngine().triage(rawText: utterance))
        }
        for (name, corpus) in [
            ("authored", RambleEval.evalSet), ("adversarial", RambleEval.gateAdversarialSet),
            ("real", RambleEval.realSet),
        ] {
            let rows = await RambleEval.routingRows(over: corpus, resolve: resolve)
            var cells: [RambleEval.RoutingVerdict: Int] = [:]
            for row in rows { cells[row.verdict, default: 0] += 1 }
            let line = RambleEval.RoutingVerdict.allCases.map { "\($0.rawValue) \(cells[$0] ?? 0)" }
                .joined(separator: " · ")
            print("quadrant[\(name)] (\(rows.count) unstructured): \(line)")
            for row in rows where row.verdict != .keptCorrect {
                print(
                    "  \(row.verdict.rawValue) \(row.reason.map { "[\($0)]" } ?? "") "
                        + "\(row.draftCount)≠\(row.expectedCount) ← \(row.utterance.prefix(60))")
            }
            if name == "authored" {
                #expect(cells[.falseKeep, default: 0] == 0, "authored false-keeps: \(line)")
            }
        }
    }

    @Test("The adversarial suite scores exactly 8 rows and its pairing is intact")
    func adversarialPairingHolds() async throws {
        // 4 "looks compound, IS one" (expected.count == 1) against 4 "looks atomic,
        // is NOT" — the directional structure is what makes the suite tuning data for
        // `boundarySignalFloor` rather than noise. A corpus edit could keep "8 cases"
        // while destroying the pairing; this is what notices.
        let rows = await RambleEval.routingRows(
            over: RambleEval.gateAdversarialSet, resolve: resolve)
        #expect(rows.count == 8)
        let compoundIsOne = rows.filter { $0.expectedCount == 1 }.count
        #expect(compoundIsOne == 4)
        #expect(rows.count - compoundIsOne == 4)
    }

    // MARK: - The complex population (contamination unrepresentable by construction)

    /// Unstructured utterances past the depth floors — the population device-first
    /// routing deliberately sends to the cloud. They live HERE, as routing fixtures, and
    /// nowhere near `evalSet`: a corpus that exists only inside a test cannot enter a
    /// floor denominator, which beats any number of assertions promising it won't.
    ///
    /// The first is the `-CaptureDiagnostics` device ramble MINUS its trailing
    /// ", and renew my passport" — that clause exists for the seeded-duplicate merge
    /// test, and intra-capture it makes any count reading ambiguous.
    static let complexFixtures: [String] = [
        // The 13→12-item device blob (~620 chars): the founding failure population.
        "ok brain dump time — renew my passport before the trip, and book flights "
            + "for that trip but only after the passport comes through, oil change is "
            + "overdue by like two weeks now, should I keep paying for the gym I honestly "
            + "never use, call mom back she left three voicemails, daycare enrollment "
            + "forms are due Friday, finish the Q3 deck for the board thing, return the "
            + "amazon package before the window closes, figure out if the side project is "
            + "still worth it or if I should let it go, pay the water bill it's the second "
            + "notice, ask Maya to sort out the insurance renewal, schedule the kitchen "
            + "plumber once the contractor calls back",
        // ≥400 chars, ~3 outcomes: isolates the character floor on meandering prose.
        "so I've been going back and forth on this for weeks now and I think what it "
            + "comes down to is I really do need to sit down and figure out whether we "
            + "should refinance the house this year because the rates keep moving and "
            + "everyone has an opinion, and somewhere in there I promised I would finally "
            + "sort through the garage which has become a disaster since the move, and "
            + "honestly the only other thing hanging over me is getting the tax documents "
            + "together before the accountant starts asking again",
        // ~500-char dictated run-on, 7-8 outcomes: the population the depth floors claim.
        "alright let me just get this all out I need to schedule the HVAC guy the "
            + "furnace is making that noise again and pick up Leo's prescription before "
            + "the pharmacy closes Saturday also the car registration renewal is sitting "
            + "on the counter and I keep ignoring it there's the parent teacher conference "
            + "signup that closes Friday I should probably start looking at summer camps "
            + "already everyone says they fill up by March and the gutter guy never called "
            + "back so I need to chase him and at some point this week I have to do the "
            + "expense report before finance locks the quarter",
    ]

    @Test("Every UNSTRUCTURED complex fixture routes .cloud — the contract, not the mechanism")
    func complexPopulationRoutesToCloud() async throws {
        // Deliberately NOT asserted: which escalation reason fires. "This population
        // requires the cloud" is the architectural claim; `bigDump` is today's
        // mechanism and free to evolve (a future complexity estimator must pass this
        // test unchanged).
        for utterance in Self.complexFixtures {
            #expect(
                CapturePerformanceContract.Tier.tier(for: utterance) == .complex,
                "not complex-tier: \(utterance.prefix(50))")
            #expect(
                !Segmentation.structure(of: utterance).isExplicit,
                "fixture must be unstructured: \(utterance.prefix(50))")
            let drafts = try await resolve(utterance)
            let decision = CaptureRoute.route(for: utterance, localRead: drafts)
            #expect(decision.route == .cloud, "kept local: \(utterance.prefix(50))")
        }
    }

    @Test("An EXPLICIT complex-tier list stays local — the privacy rule outranks the size heuristic")
    func explicitStructureOutranksComplexity() async throws {
        // Found by this campaign's first run (the fixture below was written asserting
        // `.cloud` and the router said no): `route(for:localRead:)` returns `.local`
        // for user-drawn structure BEFORE any escalation check, so a clean six-item
        // comma list is `.complex` to the MEASUREMENT tier and `.local` to ROUTING —
        // "structure the user typed never touches the network" wins, by design and by
        // the privacy test that pins it. Complex-tier and cloud-routed are therefore
        // overlapping populations, not the same one, and the live report's complex
        // row must be read with that in mind.
        let explicitList =
            "buy milk, book the dentist, call the plumber, renew the parking permit, "
            + "pick up the dry cleaning, email the accountant about the return"
        #expect(CapturePerformanceContract.Tier.tier(for: explicitList) == .complex)
        #expect(Segmentation.structure(of: explicitList).isExplicit)
        let drafts = try await resolve(explicitList)
        let decision = CaptureRoute.route(for: explicitList, localRead: drafts)
        #expect(decision.route == .local)
        #expect(decision.escalation == nil)
    }

    // MARK: - The quota gate

    @Test("Configured is not authorized: the cloud arm needs the flag AND the provider")
    func cloudArmGating() {
        typealias D = LaunchSeams.CloudArmDecision
        #expect(
            LaunchSeams.cloudArmDecision(arguments: ["-RambleEval"], providerAvailable: true)
                == .skippedNoFlag)
        #expect(
            LaunchSeams.cloudArmDecision(
                arguments: ["-RambleEval", "-WithCloud"], providerAvailable: true) == .run)
        #expect(
            LaunchSeams.cloudArmDecision(
                arguments: ["-RambleEval", "-WithCloud"], providerAvailable: false)
                == .skippedNoProvider)
    }

    @Test("The quota guard cannot bill: unavailable, and its session throws")
    func quotaGuardIsInert() {
        #expect(LaunchSeams.EvalQuotaGuard.isAvailable == false)
        #expect(throws: (any Error).self) {
            _ = try LaunchSeams.EvalQuotaGuard.session(
                instructions: "x", config: CapabilityProfiles.capture)
        }
    }

    // MARK: - The eval arm's hang protection

    @Test("A failure streak aborts the arm at the limit — and a success resets it")
    func failureStreakAbortsAtLimit() throws {
        // Session B's lesson, pinned: one hung case must score and continue (the
        // forward pass lost ~37 cases' numbers to a single error's rethrow), while a
        // RUN of failures must abort fast with a reason (the reverse pass burned 30
        // silent minutes on a wedged model with no deadline anywhere).
        let streak = LaunchSeams.EvalFailureStreak()
        try streak.recordOrAbort("timeout")
        try streak.recordOrAbort("timeout")
        #expect(streak.streak == 2)
        #expect(throws: LaunchSeams.EvalFailureStreak.ArmWedged.self) {
            try streak.recordOrAbort("timeout")
        }
        // A served case in between means the model is alive: the streak resets and
        // the same total failure count no longer aborts.
        let recovered = LaunchSeams.EvalFailureStreak()
        try recovered.recordOrAbort("timeout")
        try recovered.recordOrAbort("timeout")
        recovered.streak = 0  // what the arm does on success
        try recovered.recordOrAbort("timeout")
        #expect(recovered.streak == 1)
    }

    // MARK: - Prompt honesty

    @Test("The tool clause appears only when the session actually attaches the tool")
    func instructionsNeverPromiseAMissingTool() {
        let withRoster = TriageContext(roster: [RosterPerson(name: "Maya", relationship: "wife")])
        // On-device (tool attached): the clause belongs.
        #expect(
            FoundationModelsEngine.instructionText(for: withRoster)
                .contains("resolve_person"))
        // Cloud (no tools on the session): the text must not promise one.
        #expect(
            !FoundationModelsEngine.instructionText(
                for: withRoster, attachesResolvePersonTool: false
            ).contains("resolve_person"))
        // No roster: no clause either way.
        #expect(!FoundationModelsEngine.instructionText(for: TriageContext()).contains("resolve_person"))
    }
}
