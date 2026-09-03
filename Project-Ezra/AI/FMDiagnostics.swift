//
//  FMDiagnostics.swift
//  Project-Ezra
//
//  `-FMDiagnostics` — the on-device Foundation Models diagnosis seam.
//
//  **CAMPAIGN 2 (2026-08-29 evening): "can pre-first-token latency COLLAPSE?"**
//  Campaign 1 attributed the ~20s captures: session 0% · preFirstToken 38% (~7–8.5s
//  full instructions, ~3.4–4.1s minimal) · postFirstToken 62% (~1,200–1,900 output
//  tokens from the full guided schema), with `contextSizeExceeded` on the hard case
//  (instructions = 45% of the 4,096 window). The objective now, stated by the owner:
//  determine whether FM can realistically become Ramble's PRIMARY capture engine —
//  and the single number to watch is whether preFirstToken can be brought down
//  substantially from ~3.5s. Minimal output is the MECHANISM for testing that, not
//  the objective; guided-vs-unguided is the primary diagnostic (it isolates the
//  constraint machinery).
//
//  Six arms, one question:
//    A guided-full        production instructions + full TriageResult   (baseline)
//    B guided-minschema   production instructions + MinimalCapture      (schema effect)
//    C guided-min-both    ~300-tok instructions   + MinimalCapture      (the candidate)
//    D guided-ladder-800  ~800-tok instructions   + MinimalCapture      (curve point)
//    E unguided-full      production instructions + plain String        (constraint tax)
//    F unguided-floor     ~70-tok instructions    + plain String        (absolute floor)
//
//  **Verdict is GREEN / YELLOW / RED, never binary** (team decision):
//  GREEN  = candidate preFirstToken p50 < 1s AND candidate total near contract AND
//           accuracy held → FM-primary optimization continues.
//  YELLOW = substantial preFirstToken improvement but still ≥ 1s (e.g. 3.5→1.3s —
//           the floor is ENGINEERABLE; ask whether the gap can close).
//  RED    = the floor stays ~3s+ across minimal schema, minimal instructions, AND
//           unguided → strong evidence the current runtime/device cannot support
//           the FM-primary latency contract.
//  Either way Track B profits: smaller prompt/output/schema makes Gemini faster,
//  cheaper, and frees context — the work is not wasted if FM loses.
//
//  **Measurement honesty rules (carried from campaign 1, all still binding):**
//  - `preFirstToken`/`postFirstToken` are MEASURED INTERVALS, not runtime components;
//    KV prefill is hypothesis. Rep 1 = "post-reboot first invocation", not "cold".
//    Failed rows never enter percentiles and do count against reliability. Nil
//    renders `—`, never 0. Token counting outside every timed window. Zero cloud
//    calls prevented (EvalQuotaGuard) and receipted; nonzero delta = RUN INVALID.
//  - **Accuracy is a NUMBER per configuration, not a hope**: guided arms score their
//    drafts against the corpus labels (segmentation · title · due — the fields the
//    minimal schema carries); unguided arms print `accuracy: n/a (diagnostic)`.
//  - The minimal schema KEEPS the trust architecture: `sourceQuote` (grounding) and
//    `dateExpression` (raw-expression rule) are contract, not verbosity. What drops
//    is what `IntentResolver` already backfills deterministically.
//  - The measurement-only instruction tiers and schema live in this file ONLY
//    (grep-pinned): whether anything here ships is a separate, floors-gated,
//    cloud-revalidated decision.
//
//  **What this campaign cannot prove**: root causes behind the intervals; that any
//  trim ships; anything about other devices/OS/model revisions. Claim scope: this
//  device, this runtime, this configuration.
//

#if DEBUG

import Foundation
import FoundationModels

@MainActor
enum FMDiagnostics {

    // MARK: - Gates & pure vocabulary (campaign 1 — retained, tested)

    /// The FM-path product targets the contract axis judges against.
    struct Gates {
        var p50Ms = 500.0
        var p95Ms = 1500.0
        var p99Ms = 3000.0
        static let standard = Gates()
    }

    /// Minimum valid warm observations before a contract verdict may be issued.
    static let minValidForVerdict = 8
    /// p99 needs at least this many valid observations to be more than decoration.
    static let minValidForP99 = 20

    enum ContractVerdict: String {
        case pass, fail, inconclusive
    }

    enum Diagnosis: String {
        case preFirstTokenDominated = "preFirstToken-dominated"
        case postFirstTokenDominated = "postFirstToken-dominated"
        case sessionDominated = "session-dominated"
        case mixed
    }

    enum NextExperiment: String {
        case promptCache = "prompt/cache investigation"
        case outputSchema = "output/schema investigation"
        case runtime = "runtime investigation"
        case routingConversation = "gates met — open the routing conversation"
    }

    /// Contract axis: judged ONLY on the explicit population — the candidate arm's
    /// warm successful invocations. p99 binds only with enough samples.
    static func contractVerdict(
        validWarmMs: [Int], gates: Gates = .standard
    ) -> ContractVerdict {
        guard validWarmMs.count >= minValidForVerdict else { return .inconclusive }
        let p50 = CapturePerformanceContract.nearestRank(validWarmMs, quantile: 0.5)
        let p95 = CapturePerformanceContract.nearestRank(validWarmMs, quantile: 0.95)
        if p50 > gates.p50Ms || p95 > gates.p95Ms { return .fail }
        if validWarmMs.count >= minValidForP99,
            CapturePerformanceContract.nearestRank(validWarmMs, quantile: 0.99) > gates.p99Ms
        {
            return .fail
        }
        return .pass
    }

    /// Diagnosis axis — independent of the contract axis by design.
    static func diagnosis(
        sessionShare: Double, preFirstTokenShare: Double, postFirstTokenShare: Double
    ) -> Diagnosis {
        if sessionShare >= 0.6 { return .sessionDominated }
        if preFirstTokenShare >= 0.6 { return .preFirstTokenDominated }
        if postFirstTokenShare >= 0.6 { return .postFirstTokenDominated }
        return .mixed
    }

    static func nextExperiment(
        contract: ContractVerdict, diagnosis: Diagnosis
    ) -> NextExperiment {
        guard contract != .pass else { return .routingConversation }
        switch diagnosis {
        case .preFirstTokenDominated, .sessionDominated: return .promptCache
        case .postFirstTokenDominated: return .outputSchema
        case .mixed: return .runtime
        }
    }

    // MARK: - Campaign-2 verdict (GREEN/YELLOW/RED)

    enum CampaignVerdict: String {
        case green = "GREEN — FM-primary has a path; optimize on"
        case yellow =
            "YELLOW — the floor moved but the gap remains; decide whether to chase it"
        case red =
            "RED — the floor survives every attack; current runtime/device cannot support FM-primary at these gates"
        case inconclusive = "INCONCLUSIVE — too few valid observations"
    }

    /// The campaign's decision rule, pure and test-pinned.
    ///
    /// - `bestPreMs`: the LOWEST preFirstToken p50 across every arm (minimal schema,
    ///   minimal instructions, unguided included) — RED requires the floor to survive
    ///   ALL attacks, so the best arm is the honest witness.
    /// - `candidateTotalMs`: the candidate configuration's (arm C) total p50.
    /// - `accuracyHeld`: the candidate's scored accuracy did not drop below the
    ///   baseline arm's on the same cases (nil = not measurable → blocks GREEN).
    static func campaignVerdict(
        bestPreMs: Int?, candidateTotalMs: Int?, accuracyHeld: Bool?
    ) -> CampaignVerdict {
        guard let bestPreMs else { return .inconclusive }
        if bestPreMs >= 3000 { return .red }
        if bestPreMs < 1000, let candidateTotalMs, candidateTotalMs <= 2000,
            accuracyHeld == true
        {
            return .green
        }
        return .yellow
    }

    // MARK: - Case selection (campaign 1 — retained, tested)

    static func representativeCases(
        from corpus: [RambleEval.EvalCase], count: Int
    ) -> [(index: Int, evalCase: RambleEval.EvalCase)] {
        guard !corpus.isEmpty else { return [] }
        typealias Tier = CapturePerformanceContract.Tier
        func tier(_ c: RambleEval.EvalCase) -> Tier { Tier.tier(for: c.utterance) }

        var picks: [Int] = []
        if let idx = corpus.indices
            .filter({ tier(corpus[$0]) == .simple })
            .min(by: { corpus[$0].utterance.count < corpus[$1].utterance.count })
        {
            picks.append(idx)
        }
        if let idx = corpus.indices.first(where: {
            tier(corpus[$0]) == .multi && corpus[$0].expected.count == 2
        }) {
            picks.append(idx)
        }
        let multis = corpus.indices.filter { tier(corpus[$0]) == .multi }
            .sorted { corpus[$0].utterance.count < corpus[$1].utterance.count }
        if !multis.isEmpty { picks.append(multis[multis.count / 2]) }
        if let idx = corpus.indices.first(where: { corpus[$0].expected.count >= 8 }) {
            picks.append(idx)
        }
        if let idx = corpus.indices.max(by: {
            corpus[$0].utterance.count < corpus[$1].utterance.count
        }) {
            picks.append(idx)
        }

        var seen = Set<Int>()
        let unique = picks.filter { seen.insert($0).inserted }
        return unique.prefix(count).map { ($0, corpus[$0]) }
    }

    // MARK: - Rows (campaign 1 — retained, tested)

    struct Row {
        var caseNumber: Int  // 1-based, of K
        var caseCount: Int
        var rep: Int  // 1-based, of R
        var repCount: Int
        /// "post-reboot first invocation" · "poolHit" · "poolMiss" · "fresh"
        var sessionLabel: String
        var acquisitionMs: Int?
        var preparedAheadMs: Int?
        var preFirstTokenMs: Int?
        var totalMs: Int?
        /// nil = success; otherwise the labeled failure ("TIMEOUT", an errorLabel).
        var failure: String?
        var promptTok: Int?
        var outTok: Int?

        var postFirstTokenMs: Int? {
            guard let totalMs, let preFirstTokenMs else { return nil }
            return totalMs - preFirstTokenMs
        }
        var isValid: Bool { failure == nil && totalMs != nil }
    }

    /// The row format pull-scripts grep — pinned by a test so it cannot drift.
    /// Nil measurements render `—`, never 0: absence is not instantaneousness.
    static func formatRow(_ row: Row) -> String {
        func ms(_ value: Int?) -> String { value.map { "\($0)ms" } ?? "—" }
        var session = row.sessionLabel
        if let acq = row.acquisitionMs, let prep = row.preparedAheadMs {
            session += "(acquisition \(acq)ms · prepared-ahead \(prep)ms)"
        }
        var parts = [
            "fm case \(row.caseNumber)/\(row.caseCount) rep \(row.rep)/\(row.repCount) \(session)",
            "preFirstToken \(ms(row.preFirstTokenMs))",
            "postFirstToken \(ms(row.postFirstTokenMs))",
            "total \(ms(row.totalMs))",
        ]
        if let failure = row.failure { parts.append("FAILED(\(failure))") }
        if let promptTok = row.promptTok { parts.append("promptTok \(promptTok)") }
        if let outTok = row.outTok { parts.append("outTok ~\(outTok)") }
        if let post = row.postFirstTokenMs, post > 0, let outTok = row.outTok {
            parts.append(String(format: "~%.0f tok/s", Double(outTok) / Double(post) * 1000))
        }
        return "  " + parts.joined(separator: " · ")
    }

    // MARK: - Accuracy tally

    /// Per-arm accuracy over the fields the minimal schema carries — segmentation
    /// (draft count vs labels, post-expansion), title substrings, and due presence.
    /// A NUMBER per configuration; "accuracy must hold" is meaningless without one.
    struct AccuracyTally: Equatable {
        var segHits = 0
        var segTotal = 0
        var titleHits = 0
        var titleTotal = 0
        var dueHits = 0
        var dueTotal = 0

        var line: String {
            segTotal == 0
                ? "accuracy: n/a (diagnostic)"
                : "accuracy: seg \(segHits)/\(segTotal) · title \(titleHits)/\(titleTotal) · due \(dueHits)/\(dueTotal)"
        }
        var segRate: Double { segTotal == 0 ? 0 : Double(segHits) / Double(segTotal) }
    }

    /// Score one case's drafts against its labels — the same comparisons
    /// `RambleEval.score` makes for these fields, extracted so every arm shares them.
    static func score(
        drafts: [TaskDraft], against expected: [RambleEval.ExpectedTask],
        into tally: inout AccuracyTally
    ) {
        tally.segTotal += 1
        guard drafts.count == expected.count else { return }
        tally.segHits += 1
        for (draft, expectedTask) in zip(drafts, expected) {
            let lowerTitle = draft.title.lowercased()
            tally.titleTotal += 1
            if expectedTask.titleContains.allSatisfy({ lowerTitle.contains($0.lowercased()) }) {
                tally.titleHits += 1
            }
            tally.dueTotal += 1
            if (draft.dueDate != nil) == expectedTask.expectDue { tally.dueHits += 1 }
        }
    }

    // MARK: - Dials (campaign 1 — retained, tested)

    static func dial(_ flag: String, in arguments: [String], default def: Int) -> Int {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1),
            let value = Int(arguments[i + 1]), value > 0
        else { return def }
        return value
    }

    /// The seam refuses to share a launch with `-RambleEval`: the eval warms the
    /// model and the pool, contaminating exactly the state this seam measures.
    static func refusesLaunch(arguments: [String]) -> Bool {
        arguments.contains("-FMDiagnostics") && arguments.contains("-RambleEval")
    }

    // MARK: - The minimal capture schema (measurement-only)

    /// The smallest structure that supports Ramble's actual product behavior — the
    /// TRUST fields kept (`sourceQuote` is the grounding contract, `dateExpression`
    /// the raw-expression rule, judgment/blocker the routing inputs), everything
    /// `IntentResolver` deterministically backfills dropped (reasoning, importance,
    /// effort, workIntent, edge IDs). **MEASUREMENT-ONLY**: nothing outside this file
    /// may reference it; whether it ever ships is a separate, floors-gated decision.
    @Generable
    struct MinimalCapture {
        @Guide(description: "One entry per distinct intended outcome the user actually said.")
        let tasks: [MinimalTask]
    }

    @Generable
    struct MinimalTask {
        @Guide(description: "Short verb-led action, max 8 words.")
        let title: String
        @Guide(
            description:
                "The user's own words this task comes from, copied VERBATIM from the input.")
        let sourceQuote: String
        @Guide(
            description:
                "The user's time phrase copied verbatim (all named days), or null. Never a computed date."
        )
        let dateExpression: String?
        @Guide(description: "True only for a values-based judgment call.")
        let isJudgmentCall: Bool
        @Guide(description: "The phrase naming what this waits on, or null.")
        let blockerPhrase: String?
    }

    /// Minimal-schema output → the pipeline's own vocabulary, so the SAME resolver
    /// backfill and expansion run and accuracy is comparable across arms.
    static func intents(fromMinimal result: MinimalCapture) -> [TaskIntent] {
        result.tasks.map { task in
            TaskIntent(
                title: task.title, category: "Admin", dateExpression: task.dateExpression,
                personReference: nil, blockerPhrase: task.blockerPhrase, confidence: 0.7,
                isJudgmentCall: task.isJudgmentCall, reasoning: "", effortMinutes: nil,
                sourceQuote: task.sourceQuote)
        }
    }

    // MARK: - Measurement-only instruction tiers

    /// ~70 tokens — the absolute floor probe (arm F pairs it with unguided output).
    /// **MEASUREMENT-ONLY: referenced nowhere outside this file (grep-pinned).**
    static let measurementOnlyInstructions = """
        You turn a person's informal to-do note into structured task intents. One task \
        per distinct intended outcome. Every task must come from something the user \
        actually said — never invent one. Copy the user's own words verbatim into \
        sourceQuote. Copy any time phrase verbatim into dateExpression; never compute \
        dates. Keep titles under 8 words.
        """

    /// ~300 tokens — the CANDIDATE tier: every load-bearing capture rule kept, all
    /// elaboration and examples cut. Whether this (or anything like it) ships is a
    /// floors-gated, cloud-revalidated decision — this constant only prices it.
    static let tier300Instructions = """
        You are a careful personal assistant. Turn the user's informal, messy note into \
        structured task intents. Be precise, not proactive: understand what they said; \
        never think of more work for them.

        Hard rules:
        - Every task must come from something the user actually said. Never invent one.
        - sourceQuote: the user's own words for this task, copied VERBATIM. If you \
        cannot quote them, the task does not belong.
        - One task per distinct intended OUTCOME — never one per verb, sentence, or \
        number. "wash and fold the laundry" is one task. A quantity inside one outcome \
        does not multiply it. Several NAMED occasions of one outcome ("walk the dog \
        Monday and Tuesday") are still ONE task from you: copy ALL the days into \
        dateExpression; the app splits them.
        - dateExpression: the user's time phrase copied verbatim ("tomorrow", "friday"), \
        or null. NEVER a computed date.
        - title: short, verb-led, max 8 words. Never "it", "that", or "them" — bind \
        pronouns to what they refer to.
        - isJudgmentCall: true only for values or life-priority decisions.
        - blockerPhrase: what this task waits on, as the user's phrase, or null.
        - Self-corrections REPLACE what they correct. Skip filler and greetings.
        """

    /// ~800 tokens — the curve's midpoint: tier300's rules plus the field guidance
    /// and disambiguation the full block spends most of its length on, condensed.
    static let tier800Instructions =
        tier300Instructions + """


            Field guidance:
            - category: one of the app's known categories when obvious, else Admin.
            - confidence: your certainty in THIS task's reading, 0 to 1. Under 0.5 means \
            you are guessing.
            - isUrgent: true only when the wording itself carries urgency ("asap", \
            "urgent", "right now") — never inferred from importance.
            - effortMinutes: rough minutes when clearly implied (a phone call ~5-15, an \
            errand ~30, a project session 60+), else null. Cap 480.
            - personReference: another person's name exactly as spoken, or null. Never \
            resolve or normalize it.
            - importance: 0 to 1 when the stakes are clear from the words (~0.8 real \
            consequences, ~0.4 routine), else null.

            Disambiguation:
            - "pick up and drop off the kids" is one outcome with two verbs. "call mom and \
            dad" is one call. An errand plus its reason ("return the package before the \
            window closes") is one task carrying its deadline.
            - A leading time or place applies to every item it introduces until a new one \
            appears.
            - When unsure whether two things are one outcome or two, prefer the split — \
            but only if you can quote the user's own words for BOTH.
            - If splitting one outcome in two is a bad answer, inventing a third is worse.
            """

    // MARK: - The run

    static func runIfRequested(brain: AppBrain) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-FMDiagnostics") else { return }
        if refusesLaunch(arguments: args) {
            print(
                "=== FM DIAGNOSTICS REFUSED — do not combine with -RambleEval (it prewarms what this measures) ==="
            )
            return
        }
        if args.contains("-EvalToFile") {
            Instrument.teeStdoutToDocuments("fmdiagnostics-report.txt")
        }

        print("=== FM DIAGNOSTICS · CAMPAIGN 2: can preFirstToken collapse? ===")
        guard brain.status.isOnDevice else {
            print("(skipped — no on-device model on this host; these numbers are device-only)")
            print("=== END FM DIAGNOSTICS ===")
            return
        }

        // HARD integrity invariant: zero cloud calls, prevented AND checked.
        let originalProvider = CloudModel.provider
        CloudModel.provider = LaunchSeams.EvalQuotaGuard.self
        defer { CloudModel.provider = originalProvider }
        let cloudBefore = IntelligenceLedger.shared.cloudCallsToday()

        let caseCount = dial("-FMDiagCases", in: args, default: 5)
        let cases = representativeCases(from: RambleEval.evalSet, count: caseCount)
        let model = SystemLanguageModel.default
        let productionInstructions = FoundationModelsEngine.instructionText(for: TriageContext())

        func tok(_ text: String) async -> String {
            ((try? await model.tokenCount(for: text)).map(String.init)) ?? "—"
        }
        print("host engine: \(brain.status.description)")
        let productionTok = await tok(productionInstructions)
        let tier800Tok = await tok(tier800Instructions)
        let tier300Tok = await tok(tier300Instructions)
        let floorTok = await tok(measurementOnlyInstructions)
        print(
            "instruction tiers: production \(productionTok) tok · tier800 \(tier800Tok) tok · "
                + "tier300 \(tier300Tok) tok · floor \(floorTok) tok · contextSize \(model.contextSize)"
        )
        let caseLine = cases.map {
            "idx \($0.index) \(CapturePerformanceContract.Tier.tier(for: $0.evalCase.utterance).rawValue) \($0.evalCase.utterance.count)ch"
        }.joined(separator: " · ")
        print("cases: \(cases.count) of \(RambleEval.evalSet.count) — \(caseLine)")
        print(
            "arms: A guided-full(2) · B guided-minschema(2) · C guided-min-both(3, CANDIDATE) · "
                + "D guided-ladder-800(1) · E unguided-full(2) · F unguided-floor(2) — "
                + "\(cases.count * 12) invocations × ≤\(Int(LaunchSeams.evalCaseTimeoutSeconds))s")
        print("providerCalls guarded (EvalQuotaGuard installed) · experiment FROZEN at six arms")

        // Generation closures per output mode. Each returns (preMs, totalMs, drafts?).
        func guidedFull(
            _ session: LanguageModelSession, _ prompt: String
        ) async throws -> (
            Int?, Int, [TaskDraft]?
        ) {
            let started = Date()
            var firstMs: Int? = nil
            let stream = session.streamResponse(to: prompt, generating: TriageResult.self)
            for try await _ in stream {
                if firstMs == nil { firstMs = Int(Date().timeIntervalSince(started) * 1000) }
            }
            let result = try await stream.collect().content
            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            let intents = result.tasks.map { $0.toIntent() }
            return (firstMs, totalMs, IntentResolver.resolve(intents))
        }
        func guidedMinimal(
            _ session: LanguageModelSession, _ prompt: String
        ) async throws -> (
            Int?, Int, [TaskDraft]?
        ) {
            let started = Date()
            var firstMs: Int? = nil
            let stream = session.streamResponse(to: prompt, generating: MinimalCapture.self)
            for try await _ in stream {
                if firstMs == nil { firstMs = Int(Date().timeIntervalSince(started) * 1000) }
            }
            let result = try await stream.collect().content
            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            return (firstMs, totalMs, IntentResolver.resolve(intents(fromMinimal: result)))
        }
        func unguided(
            _ session: LanguageModelSession, _ prompt: String
        ) async throws -> (
            Int?, Int, [TaskDraft]?
        ) {
            let started = Date()
            var firstMs: Int? = nil
            let stream = session.streamResponse(to: prompt)
            for try await _ in stream {
                if firstMs == nil { firstMs = Int(Date().timeIntervalSince(started) * 1000) }
            }
            _ = try await stream.collect()
            return (firstMs, Int(Date().timeIntervalSince(started) * 1000), nil)
        }

        struct ArmResult {
            var name: String
            var rows: [Row]
            var accuracy: AccuracyTally
            var preP50: Int? {
                let pre = rows.filter(\.isValid).compactMap(\.preFirstTokenMs)
                return pre.isEmpty
                    ? nil : Int(CapturePerformanceContract.nearestRank(pre, quantile: 0.5))
            }
            var totalP50: Int? {
                let totals = rows.filter(\.isValid).compactMap(\.totalMs)
                return totals.isEmpty
                    ? nil : Int(CapturePerformanceContract.nearestRank(totals, quantile: 0.5))
            }
        }

        typealias Generate = (LanguageModelSession, String) async throws -> (
            Int?, Int, [TaskDraft]?
        )
        let arms: [(String, String, Int, Generate)] = [
            (
                "A guided-full (production instructions + TriageResult)",
                productionInstructions, 2, guidedFull
            ),
            (
                "B guided-minschema (production instructions + MinimalCapture)",
                productionInstructions, 2, guidedMinimal
            ),
            (
                "C guided-min-both (tier300 + MinimalCapture) — CANDIDATE",
                tier300Instructions, 3, guidedMinimal
            ),
            (
                "D guided-ladder-800 (tier800 + MinimalCapture)",
                tier800Instructions, 1, guidedMinimal
            ),
            (
                "E unguided-full (production instructions, plain String)",
                productionInstructions, 2, unguided
            ),
            (
                "F unguided-floor (floor instructions, plain String)",
                measurementOnlyInstructions, 2, unguided
            ),
        ]
        var results: [ArmResult] = []
        for (name, instructions, repeats, generate) in arms {
            let (rows, tally) = await runArm(
                name: name, cases: cases, repeats: repeats, instructions: instructions,
                model: model, generate: generate)
            results.append(ArmResult(name: name, rows: rows, accuracy: tally))
        }

        // The verdict hierarchy: integrity → THE number → the campaign verdict.
        let providerCalls = IntelligenceLedger.shared.cloudCallsToday() - cloudBefore
        print("\n── verdict ──")
        guard providerCalls == 0 else {
            print("RUN INVALID — cloud contamination (\(providerCalls) calls); verdicts withheld")
            print("=== END FM DIAGNOSTICS ===")
            return
        }
        print("RUN INTEGRITY: clean · providerCalls 0 (receipt)")

        print("preFirstToken p50 by arm (THE number):")
        for result in results {
            let pre = result.preP50.map { "\($0)ms" } ?? "—"
            let total = result.totalP50.map { "\($0)ms" } ?? "—"
            print("  \(result.name): pre \(pre) · total \(total) · \(result.accuracy.line)")
        }

        let baseline = results.first
        let candidate = results.first { $0.name.hasPrefix("C ") }
        let bestPre = results.compactMap(\.preP50).min()
        // Accuracy held = the candidate's segmentation is no worse than the baseline's
        // on the same cases. Nil when either side scored nothing.
        let accuracyHeld: Bool? = {
            guard let base = baseline, let cand = candidate, base.accuracy.segTotal > 0,
                cand.accuracy.segTotal > 0
            else { return nil }
            return cand.accuracy.segRate >= base.accuracy.segRate
        }()
        let verdict = campaignVerdict(
            bestPreMs: bestPre, candidateTotalMs: candidate?.totalP50, accuracyHeld: accuracyHeld)
        print(
            "CAMPAIGN: \(verdict.rawValue)"
                + (bestPre.map { " · best preFirstToken p50 \($0)ms (from the ~3500ms floor)" }
                    ?? ""))
        if let accuracyHeld, let base = baseline, let cand = candidate {
            print(
                String(
                    format: "accuracy: candidate seg %.0f%% vs baseline %.0f%% → %@",
                    cand.accuracy.segRate * 100, base.accuracy.segRate * 100,
                    accuracyHeld ? "HELD" : "DROPPED"))
        } else {
            print("accuracy: not comparable this run (a side scored nothing)")
        }
        print(
            "track B note: minimal schema/instructions improve Gemini cost, latency and context "
                + "headroom regardless of this verdict")
        print("scope: this device, this runtime/model/configuration — not universal FM viability")
        print("=== END FM DIAGNOSTICS ===")
    }

    // MARK: - Arm runner

    private static func runArm(
        name: String,
        cases: [(index: Int, evalCase: RambleEval.EvalCase)],
        repeats: Int,
        instructions: String,
        model: SystemLanguageModel,
        generate: @escaping (LanguageModelSession, String) async throws -> (
            Int?, Int, [TaskDraft]?
        )
    ) async -> ([Row], AccuracyTally) {
        print("\n── arm \(name) ──")
        var rows: [Row] = []
        var tally = AccuracyTally()
        var consecutiveFailures = 0
        armLoop: for (caseOffset, item) in cases.enumerated() {
            for rep in 1...repeats {
                let sessionStarted = Date()
                let session = LanguageModelSession(instructions: instructions)
                let sessionMs = Int(Date().timeIntervalSince(sessionStarted) * 1000)
                let label =
                    rows.isEmpty && caseOffset == 0 && rep == 1
                    ? "post-reboot first invocation " : "fresh"
                let prompt = FoundationModelsEngine.prompt(
                    for: item.evalCase.utterance, context: TriageContext())
                var row = Row(
                    caseNumber: caseOffset + 1, caseCount: cases.count, rep: rep,
                    repCount: repeats, sessionLabel: label, acquisitionMs: sessionMs,
                    preparedAheadMs: nil, preFirstTokenMs: nil, totalMs: nil, failure: nil,
                    promptTok: nil, outTok: nil)
                do {
                    let (preMs, totalMs, drafts) = try await ModelDeadline.race(
                        timeout: LaunchSeams.evalCaseTimeoutSeconds
                    ) {
                        try await generate(session, prompt)
                    }
                    row.preFirstTokenMs = preMs
                    row.totalMs = totalMs
                    consecutiveFailures = 0
                    // Accuracy: score each case ONCE (rep 1), like the eval —
                    // re-scoring identical inputs multiplies rates by nothing.
                    if let drafts, rep == 1 {
                        score(drafts: drafts, against: item.evalCase.expected, into: &tally)
                    }
                    // Token accounting OUTSIDE the timed window, always — and against
                    // THIS arm's instructions (the campaign-1 outTok bug's lesson).
                    row.promptTok = try? await model.tokenCount(for: prompt)
                    if let transcriptTok = try? await model.tokenCount(for: session.transcript),
                        let promptTok = row.promptTok
                    {
                        let instrTok = (try? await model.tokenCount(for: instructions)) ?? 0
                        row.outTok = max(0, transcriptTok - promptTok - instrTok)
                    }
                } catch is ModelDeadline.Exceeded {
                    row.failure = "TIMEOUT \(Int(LaunchSeams.evalCaseTimeoutSeconds))s"
                    consecutiveFailures += 1
                } catch {
                    row.failure = AppBrain.errorLabel(error)
                    consecutiveFailures += 1
                }
                rows.append(row)
                print(formatRow(row))
                if consecutiveFailures >= LaunchSeams.evalConsecutiveFailureLimit {
                    print(
                        "  arm aborted after \(consecutiveFailures) consecutive failures — "
                            + "the model is wedged; remaining rows would measure only the wall")
                    break armLoop
                }
            }
        }
        let planned = cases.count * repeats
        let valid = rows.filter(\.isValid).count
        let timeouts = rows.filter { $0.failure?.hasPrefix("TIMEOUT") == true }.count
        let failures = rows.count - valid - timeouts
        let conserved = rows.count == planned ? "conserved" : "NOT CONSERVED (arm aborted)"
        let validPre = rows.filter(\.isValid).compactMap(\.preFirstTokenMs)
        let validTotals = rows.filter(\.isValid).compactMap(\.totalMs)
        let latency =
            validTotals.isEmpty
            ? "latency —"
            : "pre p50 \(Int(CapturePerformanceContract.nearestRank(validPre, quantile: 0.5)))ms"
                + " · total p50/p95 \(Int(CapturePerformanceContract.nearestRank(validTotals, quantile: 0.5)))"
                + "/\(Int(CapturePerformanceContract.nearestRank(validTotals, quantile: 0.95)))ms"
        print(
            "arm summary: rows \(rows.count)/\(planned) \(conserved) · valid \(valid) · "
                + "timeouts \(timeouts) · failures \(failures) · \(latency) · \(tally.line)")
        return (rows, tally)
    }

    // MARK: - Attribution shares (campaign 1 — retained, tested)

    /// Median attribution shares over valid rows. Session share uses acquisition only
    /// (prepared-ahead is the NEXT invocation's cost — directional, never summed).
    static func attributionShares(rows: [Row]) -> (session: Double, pre: Double, post: Double) {
        let triples = rows.compactMap { row -> (Double, Double, Double)? in
            guard let total = row.totalMs, total > 0, let pre = row.preFirstTokenMs else {
                return nil
            }
            let session = Double(row.acquisitionMs ?? 0)
            let t = Double(total) + session
            return (session / t, Double(pre) / t, Double(total - pre) / t)
        }
        guard !triples.isEmpty else { return (0, 0, 0) }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return (
            median(triples.map(\.0)), median(triples.map(\.1)), median(triples.map(\.2))
        )
    }
}

#endif
