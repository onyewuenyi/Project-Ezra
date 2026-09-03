//
//  CapturePerformanceContract.swift
//  Project-Ezra
//
//  The Ramble latency contract, as code. Two layers, deliberately separated (owner
//  feedback, 2026-08-29): **the PRODUCT metric is the one clock the targets bind —
//  capture-end (`submittedAt`) → trustworthy reveal (`revealedAt`), DWELL COUNTED**
//  (`CaptureRunTelemetry.confirmMs`); everything else (`parseMs`, `retrievalMs`, the
//  dwell constants, `sinceLastWordMs`) is a PIPELINE metric that exists to EXPLAIN the
//  product number, never to be optimized in its place. A 200ms model inside a 1.1s
//  experience is a product problem; an 800ms model inside an 800ms experience is not.
//  Optimize the product clock first; use pipeline metrics to diagnose it.
//
//  The owner's north star: "time from end-of-speech → trustworthy capture, because
//  that's the moment the user is actually waiting for." Two boundary decisions pinned:
//  the orb's dwell is INSIDE the metric (perceived latency is honest latency); the 5s
//  silence window is OUTSIDE it, recorded separately (`sinceLastWordMs`) as the UX
//  parameter it is — the user is deciding when they're done, not waiting on us.
//
//  **The routing matrix this contract measures** (production paths as of 2026-08-29):
//
//      capture                          route                    target (product clock)
//      1 item, read holds               local deterministic      <0.8s p50 / <1.5s p95
//      2–5 items, read holds            local deterministic      <1.2s p50 / <2.0s p95
//      complex / past depth floors      Gemini                   <2.0s p50 / <4.0s p95
//      read fell short (escalated)      Gemini                   <4.0s p95
//      on-device FM                     INTENDED PRIMARY, gates pending — not yet a production path (below)
//
//  **Today's production fast path is deterministic-local → Gemini; on-device FM is
//  the INTENDED PRIMARY Ramble engine, pending gates it has not yet passed** (owner
//  reframing, 2026-08-29 — deterministic = obvious cases + safety signals, Gemini =
//  escape hatch). FM earns production status only by passing, ON DEVICE: the
//  accuracy floors (`RambleEval.Floors`), the FM-path latency gates — **p50 <500ms ·
//  p95 <1.5s · p99 <3s** — and reliability (observed, not yet gated). Measured by
//  `-RambleEval on-device(direct)` and `-FMDiagnostics` (the attribution seam);
//  these explicit gates supersede the old "within ~2× of the cloud arm" tripwire.
//  Current evidence: deterministic read p90 2ms with every floor held; FM p90 21s
//  unattributed on the same phone. Production routing and every target above are
//  UNCHANGED until the gates pass.
//
//  **This type may describe a capture; it may never route one.** `Tier` buckets a
//  capture for MEASUREMENT — routing stays `CaptureRoute.route(for:localRead:)` +
//  `CaptureEscalation`, a function of structure and observed evidence, and neither file
//  imports this one. The tier thresholds are a COMPLEXITY HEURISTIC, not a definition
//  of complexity: length and item count are proxies (six groceries are easy; thirty
//  ambiguous words are not), kept because they are cheap, deterministic, and calibrated
//  against the corpus's real bimodal length distribution. The dimensions the heuristic
//  cannot see — semantic ambiguity, segmentation uncertainty — are exactly what
//  `CaptureEscalation`'s evidence checks catch AFTER the read exists, which is why the
//  escalated row is measured apart from the complex one. The complex thresholds are
//  `CaptureRoute`'s depth floors BY REFERENCE: `bigDump`'s escalation population and
//  the complex measurement population are the same set, and two copies of the number
//  would drift. (`tierNeverRoutes` pins the direction of that dependency.)
//
//  App target, not DEBUG-gated — the Floors precedent: an instrument two consumers must
//  agree on cannot live inside one of them. The live report (Settings footer,
//  `-CaptureDiagnostics`) and the DEBUG eval (`RambleEval`) read the SAME targets here.
//  Accuracy floors stay in `RambleEval.Floors` and sit beside every latency row in the
//  eval table — a latency pass with a broken floor is a FAIL, never a trade. The
//  router's optimization problem, stated once: **maximum local processing SUBJECT TO
//  the accuracy and latency constraints** — never "maximize local processing". The
//  false-local ceiling below is the accuracy side of that constraint made checkable.
//
//  **Explicitly NOT built, with tripwires** (owner decisions, 2026-08-29):
//  - A live transcript on the orb. The orb is reception-only by contract (its header),
//    so the "transcript trails speech by <300ms" line has nothing to measure and is
//    dropped from the contract entirely.
//  - Per-clause parallel FM fan-out. The deterministic read serves a multi-item capture
//    in ~2ms; parallelizing a model that measured p90 21s on device reaches no tier
//    target, and `SerialGate`'s one-session constraint makes it structurally expensive.
//  - An on-device FM rung between local and Gemini — see the matrix above.
//

import Foundation

/// The per-tier latency targets and the report that folds real receipts against them.
struct CapturePerformanceContract {

    // MARK: - Tiers (measurement-only)

    /// A capture's complexity bucket, derived from the text alone. Measurement
    /// vocabulary — see the file header for why this must never become a router.
    enum Tier: String, CaseIterable {
        /// One distinct item — the "buy milk" population, the product's common case.
        case simple
        /// Two to five items below the depth floors — a short list spoken as one dump.
        case multi
        /// Past `CaptureRoute.depthCharacterFloor` or `depthItemFloor` — the population
        /// device evidence says deterministic segmentation fails on. Identical to
        /// `bigDump`'s escalation predicate by construction.
        case complex

        /// Bucket a capture. `itemCount` accepts a precomputed count the way
        /// `captureDepth` does, so a caller that already segmented doesn't pay twice.
        static func tier(for text: String, itemCount: Int? = nil) -> Tier {
            let items = itemCount ?? Segmentation.items(from: text).count
            if text.count >= CaptureRoute.depthCharacterFloor
                || items >= CaptureRoute.depthItemFloor
            {
                return .complex
            }
            return items <= 1 ? .simple : .multi
        }
    }

    // MARK: - Targets

    struct Targets: Equatable {
        var p50Ms: Double
        var p95Ms: Double
    }

    /// capture-end → reveal, dwell counted.
    var simple = Targets(p50Ms: 800, p95Ms: 1500)
    var multi = Targets(p50Ms: 1200, p95Ms: 2000)
    var complex = Targets(p50Ms: 2000, p95Ms: 4000)
    /// The local→cloud surprise population: a non-complex capture whose local read fell
    /// short. P95 only — its P50 is the cloud's business, already covered by `complex`.
    var escalatedP95Ms = 4000.0
    /// Share of ordinary (non-complex) commits the local read should serve.
    ///
    /// **A DIAGNOSTIC, never a hard gate** (owner decision): 90% local at 95% accuracy
    /// is worse than 75% local at 99.5%, so a share number can only ever prompt a
    /// question — below the band, are the escalation signals too eager? above it,
    /// check `falseLocalCeiling` and the policy report's false-keeps before
    /// celebrating. The report renders it low/high/in-band, never pass/FAIL, and no
    /// verdict anywhere folds it into a failure.
    var localShareBand: ClosedRange<Double> = 0.70...0.90

    /// The accuracy side of the routing constraint, made checkable: the share of
    /// kept-local unstructured captures the local read got WRONG (wrong task count on
    /// the eval corpus — the false-keeps the policy report names). This IS a hard
    /// gate where local share is not, because a false local silently loses user
    /// intent while an unnecessary escalation costs one cloud call. Measurable only
    /// where ground truth exists (the eval corpus); live usage has no oracle, so the
    /// live report carries no equivalent row rather than a fake one.
    var falseLocalCeiling = 0.05

    static let standard = CapturePerformanceContract()

    func targets(for tier: Tier) -> Targets {
        switch tier {
        case .simple: return simple
        case .multi: return multi
        case .complex: return complex
        }
    }

    // MARK: - Percentiles

    /// Nearest-rank percentile, the same math as `RambleEval.Report.settledP90Ms` —
    /// shared here so the live report and the eval cannot round differently.
    /// Returns 0 on an empty list; CALLERS must render that as "not measured", never
    /// as a zero (the sidecar's founding rule: absence is not instantaneousness).
    static func nearestRank(_ samples: [Int], quantile: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(
            sorted.count - 1, Int((Double(sorted.count - 1) * quantile).rounded()))
        return Double(sorted[index])
    }
}

// MARK: - The live report

/// The contract, checked against what actually shipped: a pure fold over the
/// provenance sidecar's receipts.
///
/// **Limitation, by construction: receipts exist only for COMMITTED captures**
/// (`AppBrain.recordProvenance` runs at commit), so a capture revealed and then
/// abandoned is invisible here. This measures the shipped experience of captures that
/// became tasks, over at most the sidecar's newest 200 — which is the population the
/// product's promise is actually made to.
///
/// Cohort rules, stated once so they cannot drift:
/// - `simple` / `multi` rows: that tier AND `escalationReason == nil` — the ordinary
///   local path the 0.8s/1.2s targets describe.
/// - `complex` row: that tier, any route (`bigDump` escalations land here because the
///   tier and the escalation share their thresholds).
/// - `escalated` row: `escalationReason != nil` AND tier != complex — the local→cloud
///   surprise population.
/// - local share: local-route commits ÷ non-complex commits.
/// - Receipts with no `confirmMs` or no `tier` (pre-contract history) are excluded
///   from percentiles and surface only in the `n=` counts.
struct CapturePerformanceReport {

    struct Row {
        var label: String
        var samples: [Int]
        var p50: Double
        var p95: Double
        /// Nil target = informational row (no verdict).
        var p50TargetMs: Double?
        var p95TargetMs: Double?

        var passes: Bool {
            guard !samples.isEmpty else { return true }  // "not measured" is not a FAIL
            if let target = p50TargetMs, p50 > target { return false }
            if let target = p95TargetMs, p95 > target { return false }
            return true
        }
    }

    var rows: [Row] = []
    /// local-route commits ÷ non-complex commits; nil when there are no non-complex
    /// commits to divide by — "no share measurable" is not 0%.
    var localShare: Double?
    var localShareBand: ClosedRange<Double>
    var escalationReasons: [String: Int] = [:]
    /// Receipts that predate the contract fields, counted so the denominator is honest.
    var unmeasuredCount = 0

    static func measure(
        _ records: [CaptureProvenance],
        against contract: CapturePerformanceContract = .standard
    ) -> CapturePerformanceReport {
        var report = CapturePerformanceReport(localShareBand: contract.localShareBand)

        var byTier: [CapturePerformanceContract.Tier: [Int]] = [:]
        var escalatedSamples: [Int] = []
        var localCount = 0
        var ordinaryCount = 0

        for record in records {
            let run = record.run
            if let reason = run.escalationReason {
                report.escalationReasons[reason, default: 0] += 1
            }
            guard let tierRaw = run.tier,
                let tier = CapturePerformanceContract.Tier(rawValue: tierRaw),
                let confirmMs = run.confirmMs
            else {
                report.unmeasuredCount += 1
                continue
            }
            if tier != .complex {
                ordinaryCount += 1
                if run.route == CaptureRoute.local.metricName { localCount += 1 }
            }
            switch (tier, run.escalationReason) {
            case (.complex, _):
                byTier[.complex, default: []].append(confirmMs)
            case (_, nil):
                byTier[tier, default: []].append(confirmMs)
            case (_, .some):
                escalatedSamples.append(confirmMs)
            }
        }

        for tier in CapturePerformanceContract.Tier.allCases {
            let samples = byTier[tier] ?? []
            let targets = contract.targets(for: tier)
            report.rows.append(
                Row(
                    label: tier.rawValue, samples: samples,
                    p50: CapturePerformanceContract.nearestRank(samples, quantile: 0.5),
                    p95: CapturePerformanceContract.nearestRank(samples, quantile: 0.95),
                    p50TargetMs: targets.p50Ms, p95TargetMs: targets.p95Ms))
        }
        report.rows.append(
            Row(
                label: "escalated", samples: escalatedSamples,
                p50: CapturePerformanceContract.nearestRank(escalatedSamples, quantile: 0.5),
                p95: CapturePerformanceContract.nearestRank(escalatedSamples, quantile: 0.95),
                p50TargetMs: nil, p95TargetMs: contract.escalatedP95Ms))

        report.localShare = ordinaryCount > 0 ? Double(localCount) / Double(ordinaryCount) : nil
        return report
    }

    /// The contract table as footer lines — the same `pass`/`FAIL` vocabulary the eval
    /// table uses, one line per row, empty rows saying `n=0` rather than showing a
    /// zero percentile.
    func footerLines() -> [String] {
        var lines = rows.map { row -> String in
            guard !row.samples.isEmpty else { return "ramble \(row.label): n=0" }
            var parts = ["p50 \(Int(row.p50))ms", "p95 \(Int(row.p95))ms"]
            if let target = row.p50TargetMs, let p95Target = row.p95TargetMs {
                parts.append("target \(Int(target))/\(Int(p95Target))ms")
            } else if let p95Target = row.p95TargetMs {
                parts.append("target p95 \(Int(p95Target))ms")
            }
            parts.append(row.passes ? "pass" : "FAIL")
            return "ramble \(row.label) (n=\(row.samples.count)): " + parts.joined(separator: " · ")
        }
        if let localShare {
            let pct = Int((localShare * 100).rounded())
            let verdict =
                localShareBand.contains(localShare)
                ? "in band" : (localShare < localShareBand.lowerBound ? "low" : "high")
            let band =
                "\(Int(localShareBand.lowerBound * 100))–\(Int(localShareBand.upperBound * 100))%"
            // Lower-case verdicts on purpose: this row is a diagnostic, and giving it
            // the FAIL register would teach the reader to maximize local share — the
            // exact optimization target the contract's header refuses.
            lines.append("ramble local share: \(pct)% (band \(band)) \(verdict) · diagnostic")
        } else {
            lines.append("ramble local share: —")
        }
        if !escalationReasons.isEmpty {
            let reasons = escalationReasons.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            lines.append("ramble escalations: \(reasons)")
        }
        if unmeasuredCount > 0 {
            lines.append("ramble unmeasured: \(unmeasuredCount) pre-contract receipts")
        }
        return lines
    }
}
