//
//  FMPrimitives.swift
//  Project-Ezra
//
//  **Campaign 5 · WS4: the boundary pass on the GA runtime.** (`-FMPrimitives`)
//
//  `docs/capture.md` ▸ *Ramble economics* left one decision explicitly open and explicitly
//  empirical: Apple Foundation Models are a CANDIDATE for synchronous Ramble primitives,
//  the beta-8 numbers are baseline evidence only, and production routing reopens after the
//  GA evaluation — "by a human over the report, which may legitimately conclude any
//  coverage share". This is that report. It exists so that reopening the decision costs one
//  launch argument rather than a week of re-deriving what to measure.
//
//  It answers the two questions the decision rule actually turns on (P-A and P-D of WS4).
//  P-B (Extract) is `-QuickCaptureDiag` Q1 and is not re-implemented here; P-C (Match)
//  needs a pair fixture that does not exist yet, and printing a placeholder for it would be
//  the exact thing §11 warns about — an instrument that looks like it measured something.
//
//  **P-A · Segment.** `OnDeviceSegmenter` over the labeled corpora: does the model find the
//  boundaries the deterministic read missed, verbatim, inside the latency envelope?
//
//  **P-D · Artifact acceptance.** The artifact through the EXISTING validator, scored as a
//  2×2 with FALSE ACCEPT printed first — a cut the validator cleared whose count is still
//  wrong is a capture that reveals a confident misreading as final, and it is the only cell
//  that can hurt a person. It is the `falseKeep` cell of the routing quadrant, asked of
//  this arm.
//
//  **Two cohorts, and printing both is the point.** The arm is wired to fire on exactly one
//  escalation reason, so scoring it on every row the local read gets wrong would credit it
//  for captures production never hands it — the "ground truth asking the wrong question"
//  failure, in its most flattering direction. So:
//
//    • REACHABLE — what escalates as `.underSegmented` today. What the arm is worth as wired.
//    • POTENTIAL — every unstructured row whose local read has the wrong count. What the
//      arm could be worth if the gate were widened, which is a separate, named decision
//      and not one this report is allowed to make quietly.
//
//  A reachable cohort in the low single digits is a real finding, not a broken run: it says
//  the escalation signal, not the model, is what bounds the win.
//

#if DEBUG

import Foundation
import FoundationModels

enum FMPrimitives {

    // MARK: - The decision rule, stated before the numbers

    /// A cut the validator accepted whose count is still wrong. **Zero, always.** The
    /// asymmetry is the product's: a false reject costs one cloud call, a false accept
    /// costs the person a silently-merged errand revealed as final.
    static let falseAcceptCeiling = 0

    /// The renegotiated Private Capture envelope, which this arm inherits: it runs in the
    /// same place in the same beat, in front of a cloud call it is trying to avoid.
    static let latencyP50CeilingMs = 2000.0
    static let latencyP95CeilingMs = 2500.0

    /// Below this share of exact fragment counts on the reachable cohort, the pass is not
    /// buying the boundaries it exists for and the added latency is paid for nothing.
    /// Deliberately not a floor inherited from anywhere: it is stated here, once, so a
    /// later run cannot quietly move it (economics invariant 4 — quality floors are fixed
    /// for a campaign and move only by a separate named decision).
    static let exactFragmentFloor = 0.7

    // MARK: - Scoring

    /// What one artifact did. Ordered worst-first in the enum so a sort reads as a triage.
    enum Verdict: String {
        /// The validator accepted a cut whose count is wrong. THE cell that can hurt.
        case falseAccept = "FALSE-ACCEPT"
        /// Accepted, and the count matches the label.
        case trueAccept = "accept"
        /// Refused, and the cut was actually right — one cloud call spent needlessly.
        case falseReject = "false-reject"
        /// Refused, and the cut was wrong. The system working.
        case trueReject = "reject"
        /// The artifact never grounded, timed out, or the model was not reachable.
        case noArtifact = "no-artifact"
    }

    struct Row {
        var utterance: String
        var expected: Int
        var localCount: Int
        var fragments: Int
        var accepted: Bool
        var refusal: String
        var verdict: Verdict
        var ms: Double
        /// Whether the MODEL answered. A latency tail built from calls that never
        /// served describes the failure path, not the arm — the first run of this
        /// harness printed "p90 2479ms" from nine errors, which is the shape of a
        /// number that looks like a measurement and is not one.
        var served: Bool
        /// The model's cut points, printed only on a FALSE-ACCEPT row (see below).
        var anchors: [String] = []
    }

    /// The 2×2, from what the validator said and what the label says. Pure — the scorer is
    /// bracketed below, and a scorer worth bracketing has to be a function.
    static func verdict(accepted: Bool, hadArtifact: Bool, fragments: Int, expected: Int) -> Verdict {
        guard hadArtifact else { return .noArtifact }
        let right = fragments == expected
        switch (accepted, right) {
        case (true, false): return .falseAccept
        case (true, true): return .trueAccept
        case (false, true): return .falseReject
        case (false, false): return .trueReject
        }
    }

    // MARK: - The cohorts

    struct CohortCase {
        var utterance: String
        var expected: Int
        var localCount: Int
        var reason: CaptureEscalationReason?
    }

    /// Every unstructured labeled row, with the deterministic read already taken — the
    /// same read production routes on, so the cohorts are the production populations
    /// rather than a re-derivation of them.
    @MainActor
    static func unstructuredRows(_ cases: [RambleEval.EvalCase]) -> [CohortCase] {
        cases.compactMap { evalCase in
            guard !Segmentation.structure(of: evalCase.utterance).isExplicit else { return nil }
            let local = AppBrain.provisionalDrafts(evalCase.utterance)
            // INTENTS, not drafts. The boundary pass names where each OUTCOME begins,
            // and `IntentResolver.expand` may fan one outcome into several drafts
            // ("walk the dog monday and tuesday" is ONE anchor and TWO drafts). Scoring
            // fragments against the draft count marked that row a miss on the first
            // device run for doing exactly the right thing. Same rule `RambleEval`
            // states for `expectedIntents`: any reader judged on COUNT is judged against
            // the intent count.
            return CohortCase(
                utterance: evalCase.utterance,
                expected: evalCase.expectedIntents ?? evalCase.expected.count,
                localCount: local.count,
                reason: CaptureEscalation.reason(for: evalCase.utterance, drafts: local))
        }
    }

    /// What the arm actually sees in production.
    static func reachable(_ rows: [CohortCase]) -> [CohortCase] {
        rows.filter { OnDeviceSegmenter.handles($0.reason) }
    }

    /// What the arm sees on the ON-DEVICE POSTURE — `soundsLikeSeveralThings`, the same
    /// deterministic detector `CaptureFlow.plan` uses to pick between the private engine
    /// and the boundary pass, narrowed to rows whose label is a boundary problem.
    ///
    /// It has its own cohort because it is its own POPULATION: the posture arm fires on
    /// the detector, not on the escalation reason, so it is reachable on rows the open
    /// posture's arm never sees. An arm with a live call site that no report covers is
    /// exactly the "documented and untrue" shape this codebase keeps finding in itself.
    static func posture(_ rows: [CohortCase]) -> [CohortCase] {
        rows.filter { PrivateCaptureEngine.soundsLikeSeveralThings($0.utterance) && $0.expected >= 2 }
    }

    /// Every row whose local read has the wrong count AND whose label is a boundary
    /// problem at all. The `expected >= 2` clause is not tidying: a row labeled zero
    /// tasks (the real corpus's anti-invention rows) or one task cannot be fixed by
    /// finding boundaries, and counting them as reachable-if-widened would credit this
    /// arm with a population no segmenter can serve.
    static func potential(_ rows: [CohortCase]) -> [CohortCase] {
        rows.filter { $0.localCount != $0.expected && $0.expected >= 2 }
    }

    // MARK: - The run

    @MainActor
    static func runIfRequested(brain: AppBrain) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-FMPrimitives") else { return }
        let markers = Instrument.Markers(name: "FM PRIMITIVES")
        if args.contains("-RambleEval") || args.contains("-FMDiagnostics")
            || args.contains("-QuickCaptureDiag")
        {
            print("=== FM PRIMITIVES REFUSED — run alone (other seams warm what this measures) ===")
            return
        }
        if args.contains("-EvalToFile") { Instrument.teeStdoutToDocuments("fmprimitives-report.txt") }

        print(markers.begin)
        print("Campaign 5 · WS4 — the boundary pass (P-A segment · P-D artifact acceptance)")

        let model = SystemLanguageModel.default
        print(
            Instrument.runStamp(
                model: brain.status.description,
                configuration: OnDeviceSegmenter.instructions + "|"
                    + String(describing: OnDeviceSegmenter.BoundaryRead.self) + "|"
                    + "cap=\(OnDeviceSegmenter.generationCapSeconds)|max=\(OnDeviceSegmenter.maxAnchors)"))
        print("host engine: \(brain.status.description)")

        // Zero-cloud, PREVENTED rather than observed: the boundary pass is an on-device
        // claim, so a provider call anywhere beneath it invalidates the claim outright.
        let originalProvider = CloudModel.provider
        CloudModel.provider = LaunchSeams.EvalQuotaGuard.self
        defer { CloudModel.provider = originalProvider }
        let cloudBefore = IntelligenceLedger.shared.cloudCallsToday()

        // ── The bracket (rule 1), before any model runs ──
        // A known-clean artifact must score clean and a known-reckless one must be caught.
        // Without this, a scorer that returns `.trueAccept` unconditionally prints a
        // perfect campaign.
        let cleanFlags =
            verdict(accepted: true, hadArtifact: true, fragments: 3, expected: 3) == .falseAccept ? 1 : 0
        let recklessFlags =
            verdict(accepted: true, hadArtifact: true, fragments: 1, expected: 4) == .falseAccept ? 1 : 0
        let bracket = Instrument.bracketHolds(cleanFlags: cleanFlags, recklessFlags: recklessFlags)
        print("\n── bracket (rule 1) ──")
        print(
            bracket
                ? "scorer bracket HOLDS — a correct cut scores clean, a merged one is caught"
                : "SCORER BLIND — every verdict below is withdrawn")
        guard bracket else {
            print(markers.end)
            return
        }

        guard brain.status.isOnDevice else {
            print("\n(no on-device model on this host — P-A and P-D are device-only)")
            await printCohorts(args: args)
            print("\n── verdict ──")
            print("NOT MEASURED: no on-device model. Run on the GA phone; the cohorts above still hold.")
            print(markers.end)
            return
        }
        let instructionTokens =
            ((try? await model.tokenCount(for: OnDeviceSegmenter.instructions)).map(String.init)) ?? "—"
        print("instructions: segmenter \(instructionTokens) tok · contextSize \(model.contextSize)")

        let cohorts = await printCohorts(args: args)
        let before = ModelMetrics.shared.stats[.captureSegment] ?? .init()

        print("\n── P-A · Segment · REACHABLE cohort (what the arm sees in production) ──")
        let reachableRows = await score(cohorts.reachable)
        printRows(reachableRows)

        print("\n── P-A · Segment · POSTURE cohort (the arm's second live call site) ──")
        let postureRows = await score(cohorts.posture)
        printRows(postureRows)
        printPostureRegret(postureRows)

        print("\n── P-A · Segment · POTENTIAL cohort (every row the local read counts wrong) ──")
        let potentialRows = await score(cohorts.potential)
        printRows(potentialRows)

        let delta = Instrument.ArmDelta.between(before, ModelMetrics.shared.stats[.captureSegment] ?? .init())
        let allRows = reachableRows + postureRows + potentialRows
        // Served calls only — see `Row.served`.
        let latencies = allRows.filter(\.served).map(\.ms)
        print("\n" + Instrument.armLine("segment", delta: delta, latenciesMs: latencies))
        if let banner = Instrument.degradedBanner(delta, arm: "segment") { print(banner) }

        // ── P-D ──
        print("\n── P-D · Artifact acceptance, REACHABLE cohort (2×2, false accept first) ──")
        let falseAccepts = printQuadrant(reachableRows)

        print("\n── P-D · Artifact acceptance, POSTURE cohort (2×2, false accept first) ──")
        let postureFalseAccepts = printQuadrant(postureRows)
        if postureFalseAccepts > falseAcceptCeiling {
            print(
                "  NOTE: a false accept on the POSTURE path has no cloud behind it — the "
                    + "misread IS the capture. This cell gates the posture arm on its own.")
        }

        // ── Headline ──
        print("\n── headline · correct local resolution rate ──")
        printHeadline(all: cohorts.all, reachable: cohorts.reachable, rows: reachableRows)

        // ── Latency envelope ──
        let p50 = Instrument.percentile(latencies, 0.5)
        let p95 = Instrument.percentile(latencies, 0.95)
        let p99 = Instrument.percentile(latencies, 0.99)
        print("\n── latency envelope ──")
        // An empty latency list percentiles to zero, which prints as a triumph. Say the
        // truth instead — the credibility guard below refuses a decision either way, but
        // a report is read by people long after its verdict line scrolls past.
        print(
            latencies.isEmpty
                ? "segment pass: NOT MEASURED — no served call to time"
                : String(
                    format:
                        "segment pass: p50 %.0fms · p95 %.0fms · p99 %.0fms  (ceilings p50 %.0f · p95 %.0f)",
                    p50, p95, p99, latencyP50CeilingMs, latencyP95CeilingMs))

        // ── Verdict ──
        print("\n── verdict ──")
        if let violation = Instrument.zeroCloudViolation(
            providerCallsBefore: cloudBefore, providerCallsAfter: IntelligenceLedger.shared.cloudCallsToday())
        {
            print(violation)
            print(markers.end)
            return
        }
        print("RUN INTEGRITY: clean · providerCalls 0 — the on-device claim held")
        guard delta.isCredible else {
            print("NOT MEASURED: the arm did not answer often enough. Fix the arm, re-run; decide nothing.")
            print(markers.end)
            return
        }
        let exact = share(reachableRows.filter { $0.fragments == $0.expected }.count, reachableRows.count)
        // ONE constant turns on BOTH call sites, so the gates must cover both cohorts. The
        // posture cell is listed separately and reads harder on purpose: a false accept on
        // the open posture is a misread the cloud never got a chance to fix, while on the
        // posture path there is no cloud at all — the misread IS the capture.
        let gates = [
            ("false accept (open posture) == \(falseAcceptCeiling)", falseAccepts <= falseAcceptCeiling),
            (
                "false accept (on-device posture) == \(falseAcceptCeiling)",
                postureFalseAccepts <= falseAcceptCeiling
            ),
            (
                String(format: "exact fragments ≥ %.0f%%", exactFragmentFloor * 100),
                exact >= exactFragmentFloor
            ),
            (String(format: "p50 ≤ %.0fms", latencyP50CeilingMs), p50 <= latencyP50CeilingMs),
            (String(format: "p95 ≤ %.0fms", latencyP95CeilingMs), p95 <= latencyP95CeilingMs),
        ]
        for (name, held) in gates { print("  \(held ? "HOLD" : "FAIL") · \(name)") }
        let allHold = gates.allSatisfy(\.1)
        print("")
        if reachableRows.isEmpty {
            print(
                "DECISION: hold. The reachable cohort is EMPTY — nothing escalates as under-segmented "
                    + "on this corpus, so the arm buys nothing as wired. The question this run raises is "
                    + "about the GATE, not the model: read the POTENTIAL cohort above and decide "
                    + "separately whether the escalation signal should widen.")
        } else if allHold {
            print(
                "DECISION: the gates hold. Flip `OnDeviceSegmenter.isRoutingEnabled` to true "
                    + "(one line), record this stamp in docs/capture.md's runtime table, and re-run "
                    + "-RambleEval to confirm the policy report's false-keep line did not move.")
        } else {
            print(
                "DECISION: hold. A failing gate above is the reason; nothing changes and the table says why.")
        }
        print("scope: this device, this runtime/model/configuration — quote no row without the stamp.")
        print(markers.end)
    }

    // MARK: - Pieces

    private struct Cohorts {
        var all: [CohortCase]
        var reachable: [CohortCase]
        var posture: [CohortCase]
        var potential: [CohortCase]
    }

    @MainActor
    @discardableResult
    private static func printCohorts(args: [String]) async -> Cohorts {
        let corpus = RambleEval.evalSet + RambleEval.gateAdversarialSet + RambleEval.realSet
        let rows = unstructuredRows(corpus)
        let reach = reachable(rows)
        let post = posture(rows)
        let pot = potential(rows)
        print("\n── cohorts ──")
        print("labeled rows \(corpus.count) · unstructured \(rows.count)")
        print(
            "REACHABLE (open posture — escalates as under-segmented today): \(reach.count)"
                + (reach.isEmpty ? "  ← the arm is unreachable on this corpus" : ""))
        print("POSTURE   (on-device posture — several things by the detector): \(post.count)")
        print("POTENTIAL (local read counts wrong): \(pot.count)")
        return Cohorts(all: rows, reachable: reach, posture: post, potential: pot)
    }

    @MainActor
    private static func score(_ cohort: [CohortCase]) async -> [Row] {
        var rows: [Row] = []
        for (index, item) in cohort.enumerated() {
            // Heartbeat — see `DuplicateSweepEval.runIfRequested` for why a silent
            // judging phase is an instrument defect on a device.
            print("  … \(index + 1)/\(cohort.count) \(String(item.utterance.prefix(48)))")
            let started = Date()
            let outcome = await OnDeviceSegmenter.segment(text: item.utterance)
            let ms = Date().timeIntervalSince(started) * 1000
            switch outcome {
            case .accepted(_, let fragments, let anchors):
                // The CUT count, never the draft count. The resolver fans one outcome into
                // several drafts by design ("walk my dog monday and tuesday" → two), and
                // this row scores against INTENTS; taking `max(fragments, drafts.count)`
                // marked the GA model's exactly-right 8-part cut of case 50 as a
                // FALSE-ACCEPT of 9 on 2026-09-17 — the anchors printed below are what
                // exposed it. The draft count is the resolver's, not the model's.
                rows.append(
                    Row(
                        utterance: item.utterance, expected: item.expected, localCount: item.localCount,
                        fragments: fragments, accepted: true, refusal: "—",
                        verdict: verdict(
                            accepted: true, hadArtifact: true, fragments: fragments,
                            expected: item.expected),
                        ms: ms, served: true, anchors: anchors))
            case .refused(let refusal):
                // A refusal that produced a CUT still has a countable artifact — that is
                // what makes the false-reject cell measurable. A refusal with no artifact
                // (unavailable, timed out, ungrounded) has nothing to score and says so.
                // The CUT's own count, never the deterministic one: substituting the read
                // the arm was trying to improve on would score the wrong artifact and make
                // the false-reject cell unreadable.
                let fragments: Int
                let hadArtifact: Bool
                if case .validator(_, let cutCount) = refusal {
                    fragments = cutCount
                    hadArtifact = true
                } else {
                    fragments = 0
                    hadArtifact = false
                }
                // A model that refused on its own terms (ungrounded, no-gain, validator)
                // still SERVED; only the three shortfall cases did not.
                let served: Bool
                switch refusal {
                case .unavailable, .timedOut, .failed: served = false
                case .ungrounded, .noGain, .validator: served = true
                }
                rows.append(
                    Row(
                        utterance: item.utterance, expected: item.expected, localCount: item.localCount,
                        fragments: fragments, accepted: false,
                        // One line, always. An unclamped `LanguageModelError` description is
                        // eight lines of nested NSError and it destroys the table it lands in
                        // — which is how the first run of this harness printed a report nobody
                        // could read.
                        refusal: Instrument.oneLine(refusal.label).prefix(26).description,
                        verdict: verdict(
                            accepted: false, hadArtifact: hadArtifact, fragments: fragments,
                            expected: item.expected),
                        ms: ms, served: served))
            }
        }
        return rows
    }

    private static func printRows(_ rows: [Row]) {
        guard !rows.isEmpty else {
            print("  (empty cohort — nothing measured)")
            return
        }
        // Padded by hand: `String(format:)` ignores a width specifier on `%@` here, so
        // every column ran together in the first run's output.
        print(
            "  " + pad("verdict", 13) + pad("exp", 5) + pad("local", 6) + pad("fm", 4)
                + pad("refusal", 28) + pad("ms", 7) + "utterance")
        for row in rows.sorted(by: { $0.verdict.rawValue < $1.verdict.rawValue }) {
            print(
                "  " + pad(row.verdict.rawValue, 13) + pad("\(row.expected)", 5)
                    + pad("\(row.localCount)", 6) + pad("\(row.fragments)", 4) + pad(row.refusal, 28)
                    + pad(String(format: "%.0f", row.ms), 7) + String(row.utterance.prefix(52)))
            // THE cell that can hurt, shown with the cut that produced it: a count says
            // the model was wrong, the anchors say how — the difference between "it split
            // a day-list" and "it invented a boundary", which need different fixes.
            if row.verdict == .falseAccept, !row.anchors.isEmpty {
                print("               cut at: " + row.anchors.map { "⟨\($0)⟩" }.joined(separator: " "))
            }
        }
        let exact = rows.filter { $0.fragments == $0.expected }.count
        let servedRows = rows.filter(\.served)
        let grounded = servedRows.filter { !$0.refusal.hasPrefix("ungrounded") }.count
        print(
            String(
                format:
                    "  summary: served %d/%d · fragments-exact %d/%d (%.0f%%) · grounded %d/%d served · accepted %d/%d",
                servedRows.count, rows.count, exact, rows.count, share(exact, rows.count) * 100, grounded,
                servedRows.count, rows.filter(\.accepted).count, rows.count))
    }

    @discardableResult
    private static func printQuadrant(_ rows: [Row]) -> Int {
        var counts: [Verdict: Int] = [:]
        for row in rows { counts[row.verdict, default: 0] += 1 }
        let order: [(Verdict, String)] = [
            (.falseAccept, "accepted by the validator, count still wrong — THE cell that can hurt"),
            (.trueAccept, "accepted, count right — a transmission avoided"),
            (.falseReject, "refused, cut was right — one cloud call spent needlessly"),
            (.trueReject, "refused, cut was wrong — the system working"),
            (.noArtifact, "no artifact to score"),
        ]
        for (verdict, gloss) in order {
            print("  " + pad(verdict.rawValue, 15) + pad("\(counts[verdict] ?? 0)", 5) + gloss)
        }
        let accepted = (counts[.trueAccept] ?? 0) + (counts[.falseAccept] ?? 0)
        print(
            accepted == 0
                ? "  acceptance precision: n/a (nothing accepted)"
                : String(
                    format: "  acceptance precision: %.0f%%", share(counts[.trueAccept] ?? 0, accepted) * 100)
        )
        return counts[.falseAccept] ?? 0
    }

    /// **Posture regret** — refused cuts that were nevertheless BETTER than the read the
    /// person got instead.
    ///
    /// It exists because the two call sites have different consequences for a refusal. On
    /// the open posture a refused cut costs nothing: Gemini runs and answers. On the
    /// on-device posture there is nothing behind the refusal but the deterministic read the
    /// cut was trying to improve on — so strict validator acceptance can throw away a cut
    /// that was closer to the truth in exchange for no gain at all.
    ///
    /// This does NOT argue for relaxing the validator, and the report must not read as if
    /// it does: "closer to the label" is knowable here and unknowable at runtime, where the
    /// validator is the only signal there is. It is printed so that a non-zero number
    /// becomes a named decision — find a runtime signal, or accept the regret — instead of
    /// a cost nobody measured.
    private static func printPostureRegret(_ rows: [Row]) {
        let refusedByValidator = rows.filter { !$0.accepted && $0.refusal.hasPrefix("validator") }
        let regret = refusedByValidator.filter {
            abs($0.fragments - $0.expected) < abs($0.localCount - $0.expected)
        }
        guard !refusedByValidator.isEmpty else {
            print("  posture regret: n/a (the validator refused nothing here)")
            return
        }
        print(
            "  posture regret: \(regret.count)/\(refusedByValidator.count) validator-refused cuts were "
                + "CLOSER to the label than the read the person got instead"
                + (regret.isEmpty
                    ? " — strict acceptance costs nothing on this corpus"
                    : " — a named decision, not a licence to relax the validator"))
    }

    /// **The strategic number** (economics, WS1): successful Rambles resolved correctly
    /// with no cloud call ÷ all labeled Rambles. Printed today and projected, because a
    /// projection with no baseline beside it is a number nobody can argue with.
    private static func printHeadline(all: [CohortCase], reachable: [CohortCase], rows: [Row]) {
        let today = all.filter { $0.reason == nil && $0.localCount == $0.expected }.count
        let newlyResolved = rows.filter { $0.verdict == .trueAccept }.count
        let denominator = all.count
        print(
            String(
                format: "  today      %.0f%% (%d/%d)  — unstructured rows resolved correctly, no cloud call",
                share(today, denominator) * 100, today, denominator))
        print(
            String(
                format: "  projected  %.0f%% (%d/%d)  — plus the rows the boundary pass newly resolves",
                share(today + newlyResolved, denominator) * 100, today + newlyResolved, denominator))
        print(
            String(
                format: "  delta      %+.0fpt · transmissions avoided %d of %d reachable escalations",
                (share(today + newlyResolved, denominator) - share(today, denominator)) * 100,
                newlyResolved, reachable.count))
        if newlyResolved == 0 {
            print("  (a zero delta is a finding: as wired, this arm changes nothing on this corpus)")
        }
    }

    /// Fixed-width column. `String(format:)` ignores a width specifier on `%@` here, which
    /// is why this is a function and not a format string.
    static func pad(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard text.count < width else { return String(text.prefix(width - 1)) + " " }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func share(_ hit: Int, _ total: Int) -> Double {
        total > 0 ? Double(hit) / Double(total) : 0
    }
}

#endif
