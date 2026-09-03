//
//  CapturePerformanceContractTests.swift
//  Project-EzraTests
//
//  The Ramble performance contract's three load-bearing properties, pinned:
//  the tier classifier is measurement-only (it may describe a capture, never route
//  one), the complex tier shares its thresholds with `bigDump` by reference, and the
//  report's cohort rules cannot drift (an escalated multi is not a multi; "not
//  recorded" never reads as zero).
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CapturePerformanceContractTests {

    // MARK: - Tiers

    @Test("Tier boundaries: one item is simple, a short list is multi, the floors are complex")
    func tierBoundaries() {
        typealias Tier = CapturePerformanceContract.Tier
        #expect(Tier.tier(for: "renew my passport") == .simple)
        #expect(Tier.tier(for: "buy milk and call the dentist tomorrow") == .multi)
        // Five short items stay multi; the sixth crosses the item floor.
        #expect(Tier.tier(for: "a", itemCount: 5) == .multi)
        #expect(Tier.tier(for: "a", itemCount: CaptureRoute.depthItemFloor) == .complex)
        // The character floor alone is enough, whatever the item count says.
        let long = String(repeating: "x", count: CaptureRoute.depthCharacterFloor)
        #expect(Tier.tier(for: long, itemCount: 1) == .complex)
    }

    @Test("The complex tier's thresholds ARE the depth floors — one source of truth")
    func complexSharesTheDepthFloors() {
        // `bigDump`'s escalation population and the complex measurement population must
        // be the same set. If someone gives the tier its own numbers, the report starts
        // measuring a cohort routing never made, and this fails.
        typealias Tier = CapturePerformanceContract.Tier
        #expect(Tier.tier(for: "a", itemCount: CaptureRoute.depthItemFloor - 1) != .complex)
        #expect(Tier.tier(for: "a", itemCount: CaptureRoute.depthItemFloor) == .complex)
        let under = String(repeating: "x", count: CaptureRoute.depthCharacterFloor - 1)
        let at = String(repeating: "x", count: CaptureRoute.depthCharacterFloor)
        #expect(Tier.tier(for: under, itemCount: 1) != .complex)
        #expect(Tier.tier(for: at, itemCount: 1) == .complex)
    }

    @Test("The tier never routes: routing outcomes at tier boundaries are untouched")
    func tierNeverRoutes() {
        // The measurement-only pin. Routing stays a function of structure + escalation
        // evidence; the tier is a bucket. These are the same inputs the routing tests
        // pin — if introducing the tier changed any of them, the classifier has become
        // a second routing authority.
        let typedList = "renew my passport\nbook the flights\npay the water bill"
        #expect(CaptureRoute.route(for: typedList) == .local)

        // A one-draft read of a short capture with no unaccounted signals reveals
        // locally — whatever tier the text lands in.
        let simple = "renew my passport"
        let drafts = AppBrain.provisionalDrafts(simple, learned: [])
        let decision = CaptureRoute.route(for: simple, localRead: drafts)
        #expect(decision.route == .local)
        #expect(decision.escalation == nil)
    }

    // MARK: - Percentiles

    @Test("nearestRank matches the eval's math and survives its edges")
    func nearestRankEdges() {
        typealias C = CapturePerformanceContract
        #expect(C.nearestRank([], quantile: 0.5) == 0)  // callers render as "not measured"
        #expect(C.nearestRank([700], quantile: 0.95) == 700)
        // Unsorted input sorts before ranking.
        #expect(C.nearestRank([900, 100, 500], quantile: 0.5) == 500)
        // Ten samples: p50 → index round(9*0.5)=5 (0-based, sorted); p95 → index 9.
        let ten = Array(1...10).map { $0 * 100 }
        #expect(C.nearestRank(ten, quantile: 0.5) == 600)
        #expect(C.nearestRank(ten, quantile: 0.95) == 1000)
        // And it IS the eval's number: same samples, same p90.
        var report = RambleEval.Report()
        report.settledMs = ten
        #expect(report.settledP90Ms == C.nearestRank(ten, quantile: 0.9))
    }

    // MARK: - The report's cohort rules

    private func receipt(
        tier: CapturePerformanceContract.Tier?, confirmMs: Int?,
        route: CaptureRoute = .local, escalation: CaptureEscalationReason? = nil
    ) -> CaptureProvenance {
        var run = CaptureRunTelemetry()
        run.route = route.metricName
        run.escalationReason = escalation?.rawValue
        run.tier = tier?.rawValue
        run.confirmMs = confirmMs
        return CaptureProvenance(
            captureID: UUID(), rawText: "x", capturedAt: Date(), committedAt: Date(),
            run: run, drafts: [], createdTaskIDs: [], mergedTaskIDs: [])
    }

    @Test("An escalated multi is NOT a multi — it lands in the escalated row")
    func escalatedLeavesItsTier() {
        let report = CapturePerformanceReport.measure([
            receipt(tier: .multi, confirmMs: 900),
            receipt(tier: .multi, confirmMs: 3200, route: .cloud, escalation: .underSegmented),
        ])
        let multi = report.rows.first { $0.label == "multi" }!
        let escalated = report.rows.first { $0.label == "escalated" }!
        // The 3.2s escalated capture must not drag the local multi row past its
        // 2s ceiling — the row describes the ordinary local path, and folding the
        // cloud surprises in would fail the target the local path is actually holding.
        #expect(multi.samples == [900])
        #expect(escalated.samples == [3200])
        #expect(multi.passes)
        #expect(escalated.passes)  // 3200 < 4000 p95
    }

    @Test("A bigDump escalation lands in complex, not escalated — same thresholds, same row")
    func bigDumpIsComplex() {
        let report = CapturePerformanceReport.measure([
            receipt(tier: .complex, confirmMs: 2500, route: .cloud, escalation: .bigDump)
        ])
        #expect(report.rows.first { $0.label == "complex" }!.samples == [2500])
        #expect(report.rows.first { $0.label == "escalated" }!.samples.isEmpty)
    }

    @Test("Local share divides local by NON-COMPLEX, and its verdicts stay diagnostic")
    func localShareBand() {
        // 3 ordinary captures, 2 local: 67% — below the band.
        let low = CapturePerformanceReport.measure([
            receipt(tier: .simple, confirmMs: 500),
            receipt(tier: .simple, confirmMs: 500),
            receipt(tier: .multi, confirmMs: 3000, route: .cloud, escalation: .lowCoverage),
            // Complex is excluded from the denominator: it is SUPPOSED to go cloud.
            receipt(tier: .complex, confirmMs: 2500, route: .cloud, escalation: .bigDump),
        ])
        #expect(low.localShare != nil)
        #expect(abs(low.localShare! - 2.0 / 3.0) < 0.001)
        // Lower-case verdicts + the diagnostic label, deliberately NOT the FAIL
        // register: the share prompts a question, the false-local gate holds the line.
        #expect(low.footerLines().contains { $0.contains("local share") && $0.contains("low") })
        #expect(low.footerLines().contains { $0.contains("diagnostic") })
        #expect(!low.footerLines().contains { $0.contains("local share") && $0.contains("FAIL") })

        // 4 of 5 local: 80% — in band.
        let inBand = CapturePerformanceReport.measure(
            (0..<4).map { _ in receipt(tier: .simple, confirmMs: 500) }
                + [receipt(tier: .multi, confirmMs: 3000, route: .cloud, escalation: .lowCoverage)])
        #expect(inBand.footerLines().contains { $0.contains("in band") })

        // All local: 100% — above the band, flagged high (check false-keeps, not party).
        let high = CapturePerformanceReport.measure([receipt(tier: .simple, confirmMs: 500)])
        #expect(high.footerLines().contains { $0.contains("high") })
    }

    @Test("Receipts without contract fields are excluded and counted, never zeroed in")
    func unmeasuredNeverReadsAsZero() {
        let report = CapturePerformanceReport.measure([
            receipt(tier: nil, confirmMs: nil),  // pre-contract history
            receipt(tier: .simple, confirmMs: 700),
        ])
        #expect(report.unmeasuredCount == 1)
        #expect(report.rows.first { $0.label == "simple" }!.samples == [700])
        // No share from the unmeasured row either way, and the footer says so.
        #expect(report.footerLines().contains { $0.contains("unmeasured: 1") })
    }

    @Test("An empty tier reports n=0, not a passing zero percentile")
    func emptyTierIsNotMeasured() {
        let report = CapturePerformanceReport.measure([])
        #expect(report.rows.allSatisfy { $0.passes })  // "not measured" is not a FAIL…
        #expect(report.footerLines().contains { $0.contains("simple: n=0") })  // …and says so
        #expect(report.localShare == nil)
        #expect(report.footerLines().contains { $0.contains("local share: —") })
    }

    @Test("Escalation reasons are tallied even on receipts too old to carry a tier")
    func reasonCountsSurviveUnmeasured() {
        var old = receipt(tier: nil, confirmMs: nil, route: .cloud)
        old.run.escalationReason = CaptureEscalationReason.underSegmented.rawValue
        let report = CapturePerformanceReport.measure([old])
        #expect(report.escalationReasons["underSegmented"] == 1)
    }
}
