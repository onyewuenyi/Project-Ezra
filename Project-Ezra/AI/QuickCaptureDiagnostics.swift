//
//  QuickCaptureDiagnostics.swift
//  Project-Ezra
//
//  `-QuickCaptureDiag` — CAMPAIGN 3: the Quick Capture envelope (2026-08-30).
//
//  The product hypothesis under test (owner + team): a bounded, device-only
//  **Private Capture** — one thought in, one trustworthy capture out, raw text never
//  leaving the device — is the workload where FM can excel TODAY, because it removes
//  exactly what two campaigns measured as FM's weaknesses (multi-intent segmentation,
//  output volume) and keeps what it measured as strengths (interpretation, grounding,
//  judgment). This seam prices that hypothesis with real statistics: the corpus has
//  ~35 labeled atomic cases, so n stops being 5.
//
//  Four questions, four sections:
//    Q1 CAPTURE QUALITY — single-object `CaptureIntent` (no array: "one in, one out"
//       as a SCHEMA property) over every atomic case + the compound-is-one
//       adversarials → accuracy, grounding-validity rate, latency at n≈70.
//    Q2 THE DETECTOR — can FM say "sounds like several things" (a boolean, the
//       smallest possible decode) reliably enough for the "Capture separately?"
//       affordance? Scored as precision/recall vs `isAtomic` on all 60 labeled cases,
//       AGAINST the free deterministic signal detector on the same cases.
//    Q3 THE TRUE FIXED BASE — an instruction micro-ladder down to ZERO instructions:
//       the pre-first-token curve's intercept, measured instead of extrapolated.
//       This is also the standing "Apple's runtime improved?" tripwire.
//    Q4 SUSTAINED USE — back-to-back captures on one case: capture lives in bursts,
//       and campaign 2 hinted later reps run slower (thermal).
//
//  Targets the verdict lines print against (the owner's Private Capture north-star):
//  100% local (enforced: EvalQuotaGuard, RUN INVALID on any provider call) ·
//  p50 <500ms · p95 <1.5s · p99 <3s · accuracy/grounding as measured rates —
//  the report states plainly which targets this runtime meets and misses.
//
//  All campaign-1/2 honesty rules bind: measured intervals not runtime components;
//  nil renders `—` never 0; failed rows out of percentiles, in reliability; token
//  counting outside timed windows; rows conserved AND valid counted separately; the
//  schema and instruction text here are MEASUREMENT-ONLY (grep-pinned); claim scope
//  is this device / runtime / configuration.
//

#if DEBUG

import Foundation
import FoundationModels

@MainActor
enum QuickCaptureDiagnostics {

    // MARK: - The measurement-only single-capture schema

    /// One thought → one capture. No array: the schema itself encodes "one in, one
    /// out", so the model structurally cannot decompose. Trust fields kept
    /// (`sourceQuote` grounding, `dateExpression` raw-expression rule); everything
    /// the resolver backfills, dropped. MEASUREMENT-ONLY — referenced nowhere
    /// outside this file (grep-pinned in tests).
    @Generable
    struct CaptureIntent {
        @Guide(description: "Short verb-led action, max 8 words.")
        let title: String
        @Guide(
            description:
                "The user's own words this capture comes from, copied VERBATIM from the input.")
        let sourceQuote: String
        @Guide(
            description:
                "The user's time phrase copied verbatim, or null. Never a computed date.")
        let dateExpression: String?
        @Guide(description: "True only for a values-based judgment call.")
        let isJudgmentCall: Bool
        @Guide(
            description:
                "The task, person, or event this waits on — NEVER a time or date (those go in dateExpression). Null otherwise."
        )
        let blockerPhrase: String?
    }

    /// The detector probe: the smallest decode a guided call can produce. Its
    /// latency is also the purest end-to-end floor measurement a REAL workload
    /// can give (pre-first-token + one boolean of decode).
    @Generable
    struct MultiIntentCheck {
        @Guide(
            description:
                "True if the input describes SEVERAL distinct things to do, false if it is one."
        )
        let severalThings: Bool
    }

    /// ~55 tokens — Quick Capture's whole instruction set. MEASUREMENT-ONLY.
    static let quickCaptureInstructions = """
        Turn the user's single thought into one captured task. The capture must come \
        from what they actually said — never invent. Copy their own words verbatim \
        into sourceQuote. Copy any time phrase verbatim into dateExpression; never \
        compute dates. Title: short, verb-led, max 8 words.
        """

    /// ~25 tokens — the detector's instruction set. MEASUREMENT-ONLY.
    static let detectorInstructions = """
        Decide whether the user's note describes one thing to do or several distinct \
        things. Answer the single boolean only.
        """

    // MARK: - The deterministic detector baseline (free, instant)

    /// The zero-cost competitor Q2 measures FM against: the escalation verifier's
    /// own signals, asked the detector's question. A capture with 2+ boundary
    /// signals reads as "several things".
    static func deterministicSeveralThings(_ text: String) -> Bool {
        CaptureEscalation.connectiveSignals(in: text) + CaptureEscalation.timeSignals(in: text)
            >= 2
    }

    // MARK: - Detector metrics (pure, test-pinned)

    /// Precision/recall for "several things" against the corpus's `isAtomic` labels.
    /// Positive class = MULTI (severalThings true), because the affordance this
    /// feeds ("Capture separately?") fires on positives — a false positive nags a
    /// single thought, a false negative silently under-captures.
    struct DetectorScore: Equatable {
        var truePositives = 0
        var falsePositives = 0
        var trueNegatives = 0
        var falseNegatives = 0

        var precision: Double? {
            let denom = truePositives + falsePositives
            return denom == 0 ? nil : Double(truePositives) / Double(denom)
        }
        var recall: Double? {
            let denom = truePositives + falseNegatives
            return denom == 0 ? nil : Double(truePositives) / Double(denom)
        }
        var accuracy: Double? {
            let total = truePositives + falsePositives + trueNegatives + falseNegatives
            return total == 0
                ? nil : Double(truePositives + trueNegatives) / Double(total)
        }

        mutating func record(predictedMulti: Bool, actuallyMulti: Bool) {
            switch (predictedMulti, actuallyMulti) {
            case (true, true): truePositives += 1
            case (true, false): falsePositives += 1
            case (false, false): trueNegatives += 1
            case (false, true): falseNegatives += 1
            }
        }

        var line: String {
            func pct(_ value: Double?) -> String {
                value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            }
            return
                "precision \(pct(precision)) · recall \(pct(recall)) · accuracy \(pct(accuracy))"
                + " (TP \(truePositives) FP \(falsePositives) TN \(trueNegatives) FN \(falseNegatives))"
        }
    }

    // MARK: - Q1 case selection (pure, test-pinned)

    /// The bounded workload's population: every labeled ATOMIC case from the main
    /// corpus, plus the adversarial "looks compound, IS one" half — the exact traps
    /// a single-capture feature must not fall into. Multi cases are deliberately
    /// EXCLUDED from Q1 (the detector owns them in Q2).
    static func atomicCases(
        corpus: [RambleEval.EvalCase], adversarial: [RambleEval.EvalCase]
    ) -> [RambleEval.EvalCase] {
        corpus.filter(\.isAtomic) + adversarial.filter { $0.expected.count == 1 }
    }

    // MARK: - The run

    static func runIfRequested(brain: AppBrain) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-QuickCaptureDiag") else { return }
        if args.contains("-RambleEval") || args.contains("-FMDiagnostics") {
            print("=== QUICK CAPTURE DIAG REFUSED — run alone (other seams warm what this measures) ===")
            return
        }
        if args.contains("-EvalToFile") {
            Instrument.teeStdoutToDocuments("quickcapture-report.txt")
        }

        print("=== QUICK CAPTURE DIAG · CAMPAIGN 3: the Private Capture envelope ===")
        print(
            Instrument.runStamp(
                model: brain.status.description, configuration: PrivateCaptureEngine.instructions))
        guard brain.status.isOnDevice else {
            print("(skipped — no on-device model on this host; these numbers are device-only)")
            print("=== END QUICK CAPTURE DIAG ===")
            return
        }

        // The Private Capture guarantee, enforced the way the product would enforce
        // it: no reachable cloud, and any leaked call invalidates the run.
        let originalProvider = CloudModel.provider
        CloudModel.provider = LaunchSeams.EvalQuotaGuard.self
        defer { CloudModel.provider = originalProvider }
        let cloudBefore = IntelligenceLedger.shared.cloudCallsToday()

        let model = SystemLanguageModel.default
        func tok(_ text: String) async -> String {
            ((try? await model.tokenCount(for: text)).map(String.init)) ?? "—"
        }
        print("host engine: \(brain.status.description)")
        print(
            "instructions: quickCapture \(await tok(quickCaptureInstructions)) tok · "
                + "detector \(await tok(detectorInstructions)) tok · contextSize \(model.contextSize)"
        )

        // `-QuickRealOnly`: the rested-phone sitting. Only the real-utterance corpus
        // (Q5) runs — the four campaign questions are answered and frozen; what a
        // short sitting needs is the accuracy-against-real-life number and honest
        // cool-device latency on the path that ships.
        if args.contains("-QuickRealOnly") {
            await scoreRealUtterances()
            let providerCalls = IntelligenceLedger.shared.cloudCallsToday() - cloudBefore
            print("\n── verdict ──")
            print(
                providerCalls == 0
                    ? "RUN INTEGRITY: clean · providerCalls 0 — the Private Capture guarantee held"
                    : "RUN INVALID — cloud contamination (\(providerCalls) calls); verdicts withheld")
            print("scope: this device, this runtime/model/configuration")
            print("=== END QUICK CAPTURE DIAG ===")
            return
        }

        let atomic = atomicCases(
            corpus: RambleEval.evalSet, adversarial: RambleEval.gateAdversarialSet)
        let detectorCases = RambleEval.evalSet + RambleEval.gateAdversarialSet
        let q1Repeats = FMDiagnostics.dial("-QuickRepeats", in: args, default: 2)
        print(
            "populations: Q1 atomic \(atomic.count) cases × \(q1Repeats) · "
                + "Q2 detector \(detectorCases.count) cases · Q3 ladder 3×5 · Q4 sustained 10")

        // ── Q1: capture quality at scale ─────────────────────────────────────
        print("\n━━ Q1 · CAPTURE QUALITY (single-object schema, atomic population) ━━")
        var q1Rows: [FMDiagnostics.Row] = []
        var q1Tally = FMDiagnostics.AccuracyTally()
        var grounded = 0
        var groundedTotal = 0
        var consecutiveFailures = 0
        q1Loop: for (index, evalCase) in atomic.enumerated() {
            for rep in 1...q1Repeats {
                let session = LanguageModelSession(instructions: quickCaptureInstructions)
                var row = FMDiagnostics.Row(
                    caseNumber: index + 1, caseCount: atomic.count, rep: rep,
                    repCount: q1Repeats,
                    sessionLabel: q1Rows.isEmpty ? "post-reboot first invocation " : "fresh",
                    acquisitionMs: nil, preparedAheadMs: nil, preFirstTokenMs: nil,
                    totalMs: nil, failure: nil, promptTok: nil, outTok: nil,
                    utterance: evalCase.utterance)
                do {
                    let (preMs, totalMs, capture) = try await ModelDeadline.race(
                        timeout: LaunchSeams.evalCaseTimeoutSeconds
                    ) {
                        try await generateCapture(session: session, text: evalCase.utterance)
                    }
                    row.preFirstTokenMs = preMs
                    row.totalMs = totalMs
                    consecutiveFailures = 0
                    if rep == 1 {
                        // Accuracy through the SAME pipeline the product would use —
                        // including the null-string normalization the engine ships.
                        let (dateExpression, blockerPhrase) =
                            PrivateCaptureEngine.classifiedTimePhrase(
                                dateExpression: capture.dateExpression,
                                blockerPhrase: capture.blockerPhrase)
                        let intent = TaskIntent(
                            title: capture.title, category: "Admin",
                            dateExpression: dateExpression,
                            personReference: nil,
                            blockerPhrase: blockerPhrase,
                            confidence: 0.7,
                            isJudgmentCall: capture.isJudgmentCall, reasoning: "",
                            effortMinutes: nil, sourceQuote: capture.sourceQuote)
                        let drafts = IntentResolver.resolve([intent])
                        FMDiagnostics.score(
                            drafts: drafts, against: evalCase.expected, into: &q1Tally)
                        // A due miss names its WHY — the model emissions that steered
                        // `resolveDate`/suppression are invisible in an aggregate rate,
                        // and the 76% regression could not be diagnosed without them.
                        if let expected = evalCase.expected.first, let draft = drafts.first,
                            (draft.dueDate != nil) != expected.expectDue
                        {
                            print(
                                "  miss[due] \"\(capture.title)\" expectDue=\(expected.expectDue)"
                                    + " got=\(draft.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "nil")"
                                    + " dateExpr=\(capture.dateExpression.map { "\"\($0)\"" } ?? "nil")"
                                    + " blocker=\(capture.blockerPhrase.map { "\"\($0)\"" } ?? "nil")"
                                    + " judgment=\(capture.isJudgmentCall)"
                                    + " reason=\(draft.dueReason ?? "—")")
                        }
                        // The grounding-validity rate: the trust architecture's own
                        // check, measured as a rate rather than assumed.
                        groundedTotal += 1
                        if AppBrain.grounded(intent, in: evalCase.utterance) { grounded += 1 }
                    }
                } catch is ModelDeadline.Exceeded {
                    row.failure = "TIMEOUT \(Int(LaunchSeams.evalCaseTimeoutSeconds))s"
                    consecutiveFailures += 1
                } catch {
                    row.failure = AppBrain.errorLine(error)
                    consecutiveFailures += 1
                }
                q1Rows.append(row)
                print(FMDiagnostics.formatRow(row))
                if consecutiveFailures >= LaunchSeams.evalConsecutiveFailureLimit {
                    print("  Q1 aborted after \(consecutiveFailures) consecutive failures")
                    break q1Loop
                }
            }
        }
        summarize("Q1", rows: q1Rows, planned: atomic.count * q1Repeats, extra: q1Tally.line)
        if groundedTotal > 0 {
            print(
                "Q1 grounding validity: \(grounded)/\(groundedTotal) sourceQuotes verified against the raw text"
            )
        }

        // ── Q2: the multi-intent detector, FM vs deterministic ───────────────
        print("\n━━ Q2 · DETECTOR (\"sounds like several things?\") — FM vs deterministic ━━")
        var fmScore = DetectorScore()
        var detRows: [FMDiagnostics.Row] = []
        var deterministicScore = DetectorScore()
        consecutiveFailures = 0
        q2Loop: for (index, evalCase) in detectorCases.enumerated() {
            let actuallyMulti = !evalCase.isAtomic
            deterministicScore.record(
                predictedMulti: deterministicSeveralThings(evalCase.utterance),
                actuallyMulti: actuallyMulti)
            let session = LanguageModelSession(instructions: detectorInstructions)
            var row = FMDiagnostics.Row(
                caseNumber: index + 1, caseCount: detectorCases.count, rep: 1, repCount: 1,
                sessionLabel: "fresh", acquisitionMs: nil, preparedAheadMs: nil,
                preFirstTokenMs: nil, totalMs: nil, failure: nil, promptTok: nil, outTok: nil,
                utterance: evalCase.utterance)
            do {
                let (preMs, totalMs, verdict) = try await ModelDeadline.race(
                    timeout: LaunchSeams.evalCaseTimeoutSeconds
                ) {
                    try await generateDetector(session: session, text: evalCase.utterance)
                }
                row.preFirstTokenMs = preMs
                row.totalMs = totalMs
                consecutiveFailures = 0
                fmScore.record(predictedMulti: verdict, actuallyMulti: actuallyMulti)
            } catch is ModelDeadline.Exceeded {
                row.failure = "TIMEOUT \(Int(LaunchSeams.evalCaseTimeoutSeconds))s"
                consecutiveFailures += 1
            } catch {
                row.failure = AppBrain.errorLine(error)
                consecutiveFailures += 1
            }
            detRows.append(row)
            // The detector's rows are many and small — print failures only; the
            // summary carries the latency percentiles.
            if row.failure != nil { print(FMDiagnostics.formatRow(row)) }
            if consecutiveFailures >= LaunchSeams.evalConsecutiveFailureLimit {
                print("  Q2 aborted after \(consecutiveFailures) consecutive failures")
                break q2Loop
            }
        }
        summarize(
            "Q2 FM detector", rows: detRows, planned: detectorCases.count,
            extra: fmScore.line)
        print("Q2 deterministic detector (free, ~0ms): \(deterministicScore.line)")

        // ── Q3: the true fixed base — instruction ladder to ZERO ─────────────
        print("\n━━ Q3 · THE TRUE FIXED BASE (instruction ladder to zero) ━━")
        let ladderCases = Array(atomic.prefix(5))
        for (tierName, instructions) in [
            ("zero-instructions", ""), ("quick(~55tok)", quickCaptureInstructions),
            ("tier300(~285tok)", FMDiagnostics.tier300Instructions),
        ] {
            var pres: [Int] = []
            var totals: [Int] = []
            for evalCase in ladderCases {
                let session =
                    instructions.isEmpty
                    ? LanguageModelSession()
                    : LanguageModelSession(instructions: instructions)
                if let (preMs, totalMs, _) = try? await ModelDeadline.race(
                    timeout: LaunchSeams.evalCaseTimeoutSeconds,
                    { try await generateCapture(session: session, text: evalCase.utterance) })
                {
                    if let preMs { pres.append(preMs) }
                    totals.append(totalMs)
                }
            }
            let pre =
                pres.isEmpty
                ? "—"
                : "\(Int(CapturePerformanceContract.nearestRank(pres, quantile: 0.5)))ms"
            let total =
                totals.isEmpty
                ? "—"
                : "\(Int(CapturePerformanceContract.nearestRank(totals, quantile: 0.5)))ms"
            print(
                "  \(tierName): pre p50 \(pre) · total p50 \(total) · n \(totals.count)/\(ladderCases.count)"
            )
        }
        print(
            "  (zero-instructions row = the runtime's intercept: Apple's cost of asking, with our prompt only)"
        )

        // ── Q4: sustained use (thermal drift) ────────────────────────────────
        print("\n━━ Q4 · SUSTAINED USE (10 back-to-back captures, one case) ━━")
        if let burstCase = atomic.first {
            var series: [Int] = []
            for i in 1...10 {
                let session = LanguageModelSession(instructions: quickCaptureInstructions)
                if let (_, totalMs, _) = try? await ModelDeadline.race(
                    timeout: LaunchSeams.evalCaseTimeoutSeconds,
                    { try await generateCapture(session: session, text: burstCase.utterance) })
                {
                    series.append(totalMs)
                } else {
                    print("  burst \(i)/10: failed")
                }
            }
            let seriesLine = series.map(String.init).joined(separator: " → ")
            print("  totals (ms): \(seriesLine)")
            if let first = series.first, let last = series.last, series.count >= 5 {
                print(
                    "  drift: first \(first)ms → last \(last)ms "
                        + "(\(last >= first ? "+" : "")\(last - first)ms across the burst)")
            }
        }

        // ── Q5: what ships, against what was actually said ───────────────────
        await scoreRealUtterances()

        // ── Verdict ──────────────────────────────────────────────────────────
        let providerCalls = IntelligenceLedger.shared.cloudCallsToday() - cloudBefore
        print("\n── verdict ──")
        guard providerCalls == 0 else {
            print("RUN INVALID — cloud contamination (\(providerCalls) calls); verdicts withheld")
            print("=== END QUICK CAPTURE DIAG ===")
            return
        }
        print("RUN INTEGRITY: clean · providerCalls 0 — the Private Capture guarantee held")
        let q1Valid = q1Rows.filter(\.isValid).compactMap(\.totalMs)
        if q1Valid.count >= 8 {
            let p50 = Int(CapturePerformanceContract.nearestRank(q1Valid, quantile: 0.5))
            let p95 = Int(CapturePerformanceContract.nearestRank(q1Valid, quantile: 0.95))
            let p99 = Int(CapturePerformanceContract.nearestRank(q1Valid, quantile: 0.99))
            func gate(_ v: Int, _ target: Int) -> String { v <= target ? "meets" : "MISSES" }
            print(
                "PRIVATE CAPTURE vs its north-star (n=\(q1Valid.count)): "
                    + "p50 \(p50)ms \(gate(p50, 500)) 500 · p95 \(p95)ms \(gate(p95, 1500)) 1500 · "
                    + "p99 \(p99)ms \(gate(p99, 3000)) 3000")
        } else {
            print("PRIVATE CAPTURE latency: inconclusive (n=\(q1Valid.count) < 8)")
        }
        print(
            "capture quality: \(q1Tally.line)"
                + (groundedTotal > 0 ? " · grounded \(grounded)/\(groundedTotal)" : ""))
        print("detector: FM \(fmScore.line)")
        print("detector: deterministic \(deterministicScore.line)")
        print("scope: this device, this runtime/model/configuration")
        print("=== END QUICK CAPTURE DIAG ===")
    }

    // MARK: - Q5: the real-utterance corpus (2026-09-02)

    /// Score what SHIPS against what was actually said (`RambleEval.realSet`). Each
    /// population is read by the arm built for it — an arm scored on rows it cannot
    /// represent measures the label, not the arm:
    ///
    ///  · **single thoughts** → the production `PrivateCaptureEngine` on the sheet's
    ///    own path (prewarm → finish: grounding, time-phrase classification,
    ///    deterministic backfill, fallback), scored on title + due, with
    ///    captured-vs-FALLBACK and the perceived latency per row;
    ///  · **zero-task rows** (conversation the mic caught) → PRINTED, not scored: the
    ///    single-object schema always captures, by design, so the anti-invention
    ///    question is answered by reading the receipt, never by a rate that cannot
    ///    fail;
    ///  · **several-outcome rows** → the deterministic detector, whose "Ramble instead"
    ///    hand-off is the product's whole answer to a multi-thought long-press —
    ///    precision on the single rows, recall on the multi rows.
    ///
    /// Then the Ramble side of the same words: the deterministic arm's table against
    /// `Floors.real`, and the escalation policy's verdict per row (kept vs escalated,
    /// and the false-keeps the labels call wrong).
    static func scoreRealUtterances() async {
        let real = RambleEval.realSet
        print(
            "\n━━ Q5 · REAL UTTERANCES (\(real.count) captures from the device store, 2026-08-27→30) ━━"
        )

        // (a) Private Capture, the production engine, on every single-thought row.
        print("  private capture (production engine) on single thoughts:")
        var tally = FMDiagnostics.AccuracyTally()
        var latencies: [Int] = []
        var captured = 0
        var fallbacks = 0
        var asks = 0
        for evalCase in real where evalCase.expected.count == 1 {
            let engine = PrivateCaptureEngine()
            engine.prewarm()
            let started = Date()
            let outcome = await engine.finish(text: evalCase.utterance)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            latencies.append(ms)
            let draft = outcome.draft
            let arm: String
            switch outcome {
            case .captured:
                arm = "captured"
                captured += 1
            case .fallback:
                arm = "FALLBACK"
                fallbacks += 1
            }
            let before = tally
            FMDiagnostics.score(drafts: [draft], against: evalCase.expected, into: &tally)
            let titleHit = tally.titleHits > before.titleHits
            let dueHit = tally.dueHits > before.dueHits
            if !draft.unresolved.isEmpty { asks += 1 }
            let due = draft.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
            print(
                "  \(String(format: "%5d", ms))ms \(arm) \"\(draft.title)\" · \(draft.category)"
                    + " · due \(due)" + (titleHit ? "" : "  miss[title]")
                    + (dueHit ? "" : "  miss[due]")
                    + (draft.unresolved.isEmpty ? "" : "  ask[when?]")
                    + "  ← \(evalCase.utterance.prefix(48))")
        }
        if !latencies.isEmpty {
            let p50 = Int(CapturePerformanceContract.nearestRank(latencies, quantile: 0.5))
            let p95 = Int(CapturePerformanceContract.nearestRank(latencies, quantile: 0.95))
            print(
                "  private capture summary: n \(latencies.count) · captured \(captured) · fallback \(fallbacks)"
                    + " · perceived p50/p95 \(p50)/\(p95)ms · \(tally.line) · asks[when?] \(asks)")
        }

        // (b) The anti-invention rows: what a long-press on pure chatter produces.
        print("  anti-invention rows (schema always captures — read, don't rate):")
        for evalCase in real where evalCase.expected.isEmpty {
            let engine = PrivateCaptureEngine()
            engine.prewarm()
            let outcome = await engine.finish(text: evalCase.utterance)
            let draft = outcome.draft
            let arm: String
            switch outcome {
            case .captured: arm = "captured"
            case .fallback: arm = "FALLBACK"
            }
            print(
                "  \(arm) \"\(draft.title)\" ← \(evalCase.utterance.prefix(60))"
                    + "  (would a person keep this, or delete it?)")
        }

        // (c) The detector on real rows — precision on single thoughts, recall on
        // the several-outcome rows, every miss named.
        var detector = DetectorScore()
        for evalCase in real where !evalCase.expected.isEmpty {
            let predicted = PrivateCaptureEngine.soundsLikeSeveralThings(evalCase.utterance)
            let actual = !evalCase.isAtomic
            detector.record(predictedMulti: predicted, actuallyMulti: actual)
            if predicted != actual {
                print(
                    "  detector \(predicted ? "false nag" : "missed multi") ← \(evalCase.utterance.prefix(60))"
                )
            }
        }
        print("  detector (deterministic, real rows): \(detector.line)")

        // (d) The Ramble side: the deterministic arm and the escalation policy.
        let heuristic: (String) async throws -> [TaskDraft] = { utterance in
            let intents = try await HeuristicEngine().triage(rawText: utterance)
            return IntentResolver.resolve(intents)
        }
        if let report = try? await RambleEval.score(over: real, resolve: heuristic) {
            print(report.table(against: .real, arm: "heuristic · real utterances"))
        }
        let rows = await RambleEval.routingRows(over: real, resolve: heuristic)
        var cells: [RambleEval.RoutingVerdict: Int] = [:]
        for row in rows { cells[row.verdict, default: 0] += 1 }
        let summary = RambleEval.RoutingVerdict.allCases.map {
            "\($0.rawValue) \(cells[$0] ?? 0)"
        }.joined(separator: " · ")
        print("  escalation policy on real rows (\(rows.count) unstructured): \(summary)")
        for row in rows where row.verdict != .keptCorrect {
            print(
                "    \(row.verdict.rawValue) \(row.reason.map { "[\($0)]" } ?? "")"
                    + " \(row.draftCount)≠\(row.expectedCount) ← \(row.utterance.prefix(60))")
        }
    }

    // MARK: - Generation (first RAW snapshot stamps preFirstToken, always)

    private static func generateCapture(
        session: LanguageModelSession, text: String
    ) async throws -> (Int?, Int, CaptureIntent) {
        let started = Date()
        var firstMs: Int? = nil
        let prompt = "Here is the user's thought. Capture it:\n\n\(text)"
        let stream = session.streamResponse(to: prompt, generating: CaptureIntent.self)
        for try await _ in stream {
            if firstMs == nil { firstMs = Int(Date().timeIntervalSince(started) * 1000) }
        }
        let result = try await stream.collect().content
        return (firstMs, Int(Date().timeIntervalSince(started) * 1000), result)
    }

    private static func generateDetector(
        session: LanguageModelSession, text: String
    ) async throws -> (Int?, Int, Bool) {
        let started = Date()
        var firstMs: Int? = nil
        let prompt = "The user's note:\n\n\(text)"
        let stream = session.streamResponse(to: prompt, generating: MultiIntentCheck.self)
        for try await _ in stream {
            if firstMs == nil { firstMs = Int(Date().timeIntervalSince(started) * 1000) }
        }
        let result = try await stream.collect().content
        return (firstMs, Int(Date().timeIntervalSince(started) * 1000), result.severalThings)
    }

    // MARK: - Summary line

    private static func summarize(
        _ label: String, rows: [FMDiagnostics.Row], planned: Int, extra: String
    ) {
        let valid = rows.filter(\.isValid)
        let timeouts = rows.filter { $0.failure?.hasPrefix("TIMEOUT") == true }.count
        let failures = rows.count - valid.count - timeouts
        let conserved = rows.count == planned ? "conserved" : "NOT CONSERVED (aborted)"
        let pres = valid.compactMap(\.preFirstTokenMs)
        let totals = valid.compactMap(\.totalMs)
        let latency =
            totals.isEmpty
            ? "latency —"
            : "pre p50 \(Int(CapturePerformanceContract.nearestRank(pres, quantile: 0.5)))ms"
                + " · total p50/p95 \(Int(CapturePerformanceContract.nearestRank(totals, quantile: 0.5)))"
                + "/\(Int(CapturePerformanceContract.nearestRank(totals, quantile: 0.95)))ms"
        print(
            "\(label) summary: rows \(rows.count)/\(planned) \(conserved) · valid \(valid.count) · "
                + "timeouts \(timeouts) · failures \(failures) · \(latency) · \(extra)")
    }
}

#endif
