//
//  DuplicateSweepEval.swift
//  Project-Ezra
//
//  **The one model judgment that destroys user data, measured.** (`-DuplicateSweepEval`)
//
//  Everything the app infers is auto-accepted — the confirm card is the human boundary, and
//  a wrong guess costs an edit. The duplicate merge is the single named exception: it takes
//  an existing task off the person's list, it runs in the BACKGROUND where nobody is
//  watching, and it is gated on a number the MODEL reports about itself
//  (`confidence >= 0.85`).
//
//  `DuplicateSweepTests` covers the plumbing thoroughly — both prefilter floors, suppression,
//  the caps, best-first ordering, the kill/undo round trip, the judgment-call carve-out, the
//  off-device no-op. Every one of those tests runs with no model, because the test host has
//  none. **So the judge itself — the part that decides whether two of the person's tasks
//  become one — has never been scored, on device or in CI.**
//
//  That was tolerable while the runtime was frozen. It stops being tolerable the week the
//  model changes: a self-reported confidence is exactly the kind of value whose CALIBRATION
//  moves between runtimes, and 0.85 is a number somebody chose against a model that is being
//  replaced. A judge that becomes slightly more confident under GA merges tasks that a beta
//  build left alone, silently, hourly, with an Activity row as the only trace.
//
//  So this report answers three questions, in the order they matter:
//
//  1. **How often does the judge merge two tasks that are not the same?** FALSE MERGE, the
//     only cell that destroys anything, printed first, ceiling zero.
//  2. **Is 0.85 the right line?** The threshold is SWEPT rather than asserted — the report
//     prints the confidence distribution for true and false pairs separately and the
//     false/true merge counts at each candidate threshold. The routing-percentage doctrine
//     applied to a destructive gate: the number is an output, not a preference.
//  3. **Does the prefilter even let the duplicates through?** A judge with perfect precision
//     behind a filter that drops half the real duplicates is a feature that does not work,
//     and measuring only the judge would report it as flawless. Same lesson as
//     `FMPrimitives`' two cohorts: score the population production actually produces.
//
//  **The corpus is PAIRED**, the `gateAdversarialSet` shape: every "looks different, IS the
//  same" sits beside a "looks the same, IS different". A judge that says yes to everything
//  and a judge that says no to everything each score well on half of it, which is the only
//  way a single number can catch both failure directions at once.
//

#if DEBUG

import CoreData
import Foundation
import FoundationModels
import NaturalLanguage

enum DuplicateSweepEval {

    // MARK: - The labeled corpus

    struct LabeledPair {
        let a: String
        let b: String
        /// The truth: are these the same underlying task?
        let isDuplicate: Bool
        let category: String
        let note: String

        init(_ a: String, _ b: String, isDuplicate: Bool, category: String = "Admin", note: String = "") {
            self.a = a
            self.b = b
            self.isDuplicate = isDuplicate
            self.category = category
            self.note = note
        }
    }

    /// Twenty pairs, matched. The duplicates are the shapes this sweep exists to catch —
    /// the same errand re-said days apart — and each is answered by a near-miss built from
    /// the same words, so vocabulary overlap alone cannot carry a good score.
    static let corpus: [LabeledPair] = [

        // ── The same task, said differently. A miss here leaves the clutter in place. ──
        LabeledPair(
            "Renew passport", "passport renewal", isDuplicate: true,
            note: "the flagship shape — the sweep's whole reason to exist"),
        LabeledPair(
            "Book the dentist", "make a dentist appointment", isDuplicate: true),
        LabeledPair(
            "Pay the water bill", "water bill needs paying", isDuplicate: true, category: "Home"),
        LabeledPair(
            "Call the plumber about the leak", "ring the plumber re: leaking pipe",
            isDuplicate: true, category: "Home"),
        LabeledPair(
            "Order Mum's birthday present", "buy a birthday gift for mum", isDuplicate: true,
            category: "Family"),
        LabeledPair(
            "Sort out car insurance renewal", "renew the car insurance", isDuplicate: true),
        LabeledPair(
            "Send Sarah the Q3 numbers", "email sarah the q3 figures", isDuplicate: true,
            category: "Work"),
        LabeledPair(
            "Fix the leaking tap in the bathroom", "bathroom tap is dripping, needs fixing",
            isDuplicate: true, category: "Home"),
        LabeledPair(
            "Book flights to Lisbon", "get the Lisbon flights booked", isDuplicate: true),
        LabeledPair(
            "Cancel the gym membership", "cancel gym", isDuplicate: true),

        // ── NOT the same task, and each one is built from its partner's words. A false
        //    merge here takes a real errand off the person's list. ──
        LabeledPair(
            "Renew passport", "get new passport photos taken", isDuplicate: false,
            note:
                "the hardest near-miss in the set: a PREREQUISITE of the other, sharing the "
                + "word that makes them look identical to a prefilter"),
        LabeledPair(
            "Book the dentist", "book the vet", isDuplicate: false,
            note: "one word apart, two different appointments"),
        LabeledPair(
            "Pay the water bill", "pay the electricity bill", isDuplicate: false, category: "Home",
            note: "same verb, same noun-shape, different obligation"),
        LabeledPair(
            "Call the plumber about the leak", "call the landlord about the leak",
            isDuplicate: false, category: "Home",
            note: "same subject, different person — both calls still have to happen"),
        LabeledPair(
            "Order Mum's birthday present", "order Dad's birthday present", isDuplicate: false,
            category: "Family", note: "one word apart and emphatically not the same task"),
        LabeledPair(
            "Renew the car insurance", "renew the home insurance", isDuplicate: false),
        LabeledPair(
            "Send Sarah the Q3 numbers", "send Sarah the Q4 forecast", isDuplicate: false,
            category: "Work", note: "same recipient, different document"),
        LabeledPair(
            "Fix the leaking tap in the bathroom", "fix the leaking tap in the kitchen",
            isDuplicate: false, category: "Home", note: "the two-word difference that matters"),
        LabeledPair(
            "Book flights to Lisbon", "book the hotel in Lisbon", isDuplicate: false,
            note: "the sweep's own header names this sibling as the prefilter's hard case"),
        LabeledPair(
            "Cancel the gym membership", "cancel the newspaper subscription", isDuplicate: false),
    ]

    // MARK: - Scoring

    /// The 2×2, worst first. Pure, and bracketed before the report will print anything.
    enum Verdict: String {
        /// Merged two tasks that are NOT the same. The only cell that destroys anything.
        case falseMerge = "FALSE-MERGE"
        case trueMerge = "merge"
        /// Left a real duplicate in place. Clutter, not damage.
        case missedDuplicate = "missed"
        case correctlyLeft = "left"
        case noArtifact = "no-artifact"
    }

    static func verdict(merged: Bool, hadArtifact: Bool, isDuplicate: Bool) -> Verdict {
        guard hadArtifact else { return .noArtifact }
        switch (merged, isDuplicate) {
        case (true, false): return .falseMerge
        case (true, true): return .trueMerge
        case (false, true): return .missedDuplicate
        case (false, false): return .correctlyLeft
        }
    }

    struct Row {
        var pair: LabeledPair
        var judgedDuplicate: Bool
        var confidence: Double
        var reason: String
        var served: Bool
        var ms: Double
        var verdict: Verdict
        /// Whether the deterministic prefilter would have handed this pair to the judge at
        /// all. A pair the floors drop never reaches a model in production.
        var survivesPrefilter: Bool
        /// What the two floors saw — the numbers a floor can be re-tuned on.
        var similarity: Double?
        var overlap: Double = 0
    }

    /// **Can this host run the prefilter at all?**
    ///
    /// `candidatePairs` SKIPS any pair it has no vector for — correctly, since it "only
    /// reasons over evidence it has". On a host with no sentence embedding that means it
    /// skips EVERYTHING, and the first run of this report duly printed
    /// `real duplicates reaching the judge: 0/10 ← the floors, not the model, are the
    /// ceiling on this feature`. That reads as a devastating product finding and it was an
    /// artifact of the simulator. Exactly the §11 failure: a scorer whose clean-looking
    /// output is indistinguishable from a blind one.
    ///
    /// So the report now distinguishes "the floors rejected this pair" from "there was
    /// nothing here to judge with", and refuses a verdict in the second case.
    static var embeddingAvailable: Bool {
        EmbeddingStore.sentenceEmbedding?.vector(for: "renew passport") != nil
    }

    /// Would the production prefilter show this pair to the judge — and what did each floor
    /// actually see?
    ///
    /// The scores are returned, not just the verdict, because the first MEASURED run of
    /// this report (device, 2026-09-12, after the embedding fix) showed the floors dropping
    /// every real duplicate in the corpus — including "Renew passport / passport renewal",
    /// the pair the sweep's header names as its reason to exist. `embeddingFloor` (0.82 on
    /// the store's distance-derived similarity) was calibrated in `DuplicateSweepTests`
    /// against SYNTHETIC unit vectors (cos 0.99 → 0.86; cos 0.98 → 0.80), i.e. it demands
    /// cos ≈ 0.985, which no real sentence-embedding paraphrase reaches. A floor can only
    /// be moved on the numbers real vectors produce, and this is where they are printed.
    struct PrefilterRead {
        let survives: Bool
        let similarity: Double?
        let overlap: Double
    }

    @MainActor
    static func prefilterRead(_ pair: LabeledPair) -> PrefilterRead {
        let a = OpenTaskSnapshot(id: UUID(), title: pair.a, category: pair.category)
        let b = OpenTaskSnapshot(id: UUID(), title: pair.b, category: pair.category)
        let vector: (String) -> [Double]? = { EmbeddingStore.computeVector(for: $0) }
        let survivors = DuplicateSweep.candidatePairs(among: [a, b], suppressions: [], vector: vector)
        let wa = CorrectionProfile.significantWords(pair.a)
        let wb = CorrectionProfile.significantWords(pair.b)
        let union = Double(wa.union(wb).count)
        let overlap = union > 0 ? Double(wa.intersection(wb).count) / union : 0
        // Reuse the score candidatePairs already computed; only call similarity() for pairs that
        // survived the words guard but failed a floor (empty words means the floor was never
        // reached — showing a similarity value there would misattribute the rejection cause).
        let similarity: Double? = {
            if let candidate = survivors.first { return candidate.score }
            guard !wa.isEmpty, !wb.isEmpty else { return nil }
            guard let va = vector(pair.a), let vb = vector(pair.b) else { return nil }
            return EmbeddingStore.similarity(va, vb)
        }()
        return PrefilterRead(survives: !survivors.isEmpty, similarity: similarity, overlap: overlap)
    }

    @MainActor
    static func survivesPrefilter(_ pair: LabeledPair) -> Bool { prefilterRead(pair).survives }

    // MARK: - The run

    @MainActor
    static func runIfRequested(brain: AppBrain) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-DuplicateSweepEval") else { return }
        let markers = Instrument.Markers(name: "DUPLICATE SWEEP EVAL")
        for conflicting in ["-RambleEval", "-FMDiagnostics", "-QuickCaptureDiag", "-FMPrimitives"]
        where args.contains(conflicting) {
            print(
                "=== DUPLICATE SWEEP EVAL REFUSED — run alone (\(conflicting) warms what this measures) ===")
            return
        }
        if args.contains("-EvalToFile") { Instrument.teeStdoutToDocuments("dupsweep-report.txt") }

        print(markers.begin)
        print("the one model judgment that destroys user data — false merge is the cell that matters")
        print(
            Instrument.runStamp(
                model: brain.status.description,
                configuration: DuplicateSweep.judgeInstructions
                    + "|threshold=\(DuplicateSweep.acceptThreshold)"
                    + "|floors=\(DuplicateSweep.embeddingFloor)/\(DuplicateSweep.lexicalFloor)"))
        print("host engine: \(brain.status.description)")

        // Sweeps are on-device ONLY by invariant — background work nobody is waiting on has
        // no business costing money — so a provider call here invalidates the run twice
        // over: as a campaign integrity failure and as a product-invariant breach.
        let originalProvider = CloudModel.provider
        CloudModel.provider = LaunchSeams.EvalQuotaGuard.self
        defer { CloudModel.provider = originalProvider }
        let cloudBefore = IntelligenceLedger.shared.cloudCallsToday()

        // ── Bracket (rule 1) ──
        let cleanFlags = verdict(merged: true, hadArtifact: true, isDuplicate: true) == .falseMerge ? 1 : 0
        let recklessFlags =
            verdict(merged: true, hadArtifact: true, isDuplicate: false) == .falseMerge ? 1 : 0
        let bracket = Instrument.bracketHolds(cleanFlags: cleanFlags, recklessFlags: recklessFlags)
        print("\n── bracket (rule 1) ──")
        print(
            bracket
                ? "scorer bracket HOLDS — a correct merge scores clean, a wrong one is caught"
                : "SCORER BLIND — every verdict below is withdrawn")
        guard bracket else {
            print(markers.end)
            return
        }

        // ── The corpus's own balance, before anything runs ──
        let duplicates = corpus.filter(\.isDuplicate).count
        print("\n── corpus ──")
        print(
            "\(corpus.count) labeled pairs · \(duplicates) duplicates · \(corpus.count - duplicates) near-misses"
                + " — paired, so a yes-to-everything judge scores 50%")

        guard brain.status.isOnDevice else {
            print("\n(no on-device model on this host — the judge is device-only)")
            printPrefilterRecall(corpus.map { ($0, prefilterRead($0)) })
            print("\n── verdict ──")
            print("NOT MEASURED: no on-device model. The prefilter row above still holds.")
            print(markers.end)
            return
        }

        let before = ModelMetrics.shared.stats[.duplicateSweep] ?? .init()
        var rows: [Row] = []
        // One line per judgment, BEFORE the model is asked. The judging phase is up to
        // 20 × 10s of silence otherwise, and on a device that reads identically whether
        // the run is progressing, wedged, or suspended by auto-lock — the first device
        // run of this report sat at the corpus line for twelve minutes and nothing in
        // the file could say which. A poller needs a heartbeat to tell those apart.
        print("\n── judging (\(corpus.count) pairs) ──")
        for (index, pair) in corpus.enumerated() {
            print("  \(index + 1)/\(corpus.count) \(pair.a) / \(pair.b)")
            let read = prefilterRead(pair)
            let survives = read.survives
            let candidate = DuplicateSweep.CandidatePair(
                a: OpenTaskSnapshot(id: UUID(), title: pair.a, category: pair.category),
                b: OpenTaskSnapshot(id: UUID(), title: pair.b, category: pair.category),
                score: 1)
            let started = Date()
            // The PRODUCTION judge, not a copy of it.
            let result = await DuplicateSweep.judge(candidate)
            let ms = Date().timeIntervalSince(started) * 1000
            switch result {
            case .success(let judgment):
                // Production requires BOTH gates: the prefilter shows the pair, and the
                // judgment clears the threshold. Scoring the judgment alone would credit a
                // merge that production would never have reached.
                let merged = survives && DuplicateSweep.accepts(judgment)
                rows.append(
                    Row(
                        pair: pair, judgedDuplicate: judgment.isDuplicate,
                        confidence: judgment.confidence,
                        reason: Instrument.oneLine(judgment.reason), served: true, ms: ms,
                        verdict: verdict(
                            merged: merged, hadArtifact: true, isDuplicate: pair.isDuplicate),
                        survivesPrefilter: survives, similarity: read.similarity, overlap: read.overlap))
            case .unavailable, .timedOut, .cancelled, .failed:
                rows.append(
                    Row(
                        pair: pair, judgedDuplicate: false, confidence: 0,
                        reason: "the judge did not answer", served: false,
                        ms: ms,
                        verdict: .noArtifact, survivesPrefilter: survives, similarity: read.similarity,
                        overlap: read.overlap))
            }
        }
        let delta = Instrument.ArmDelta.between(
            before, ModelMetrics.shared.stats[.duplicateSweep] ?? .init())

        printRows(rows)
        printPrefilterRecall(
            corpus.map { pair in
                let row = rows.first { $0.pair.a == pair.a && $0.pair.b == pair.b }
                let read = PrefilterRead(
                    survives: row?.survivesPrefilter ?? false,
                    similarity: row?.similarity ?? nil,
                    overlap: row?.overlap ?? 0)
                return (pair, read)
            })

        let latencies = rows.filter(\.served).map(\.ms)
        print("\n" + Instrument.armLine("judge", delta: delta, latenciesMs: latencies))
        if let banner = Instrument.degradedBanner(delta, arm: "judge") { print(banner) }

        // TWO quadrants, for the same reason `FMPrimitives` prints two cohorts: one
        // measures the MODEL (what it decided), the other measures the FEATURE (what would
        // actually have merged, prefilter included). Collapsing them lets a host that
        // cannot run the prefilter print a spotless destructive gate.
        print("\n── the 2×2 · JUDGE (the model's answer at the threshold, prefilter ignored) ──")
        let judgeFalseMerges = printQuadrant(
            rows.map { row in
                var scored = row
                scored.verdict = verdict(
                    merged: row.served && row.judgedDuplicate
                        && row.confidence >= DuplicateSweep.acceptThreshold,
                    hadArtifact: row.served, isDuplicate: row.pair.isDuplicate)
                return scored
            })
        print("\n── the 2×2 · PRODUCTION (prefilter AND threshold — what would really merge) ──")
        let falseMerges = printQuadrant(rows)
        printConfidence(rows)
        printThresholdSweep(rows)

        print("\n── verdict ──")
        if let violation = Instrument.zeroCloudViolation(
            providerCallsBefore: cloudBefore,
            providerCallsAfter: IntelligenceLedger.shared.cloudCallsToday())
        {
            print(violation)
            print("(and a cloud call from a SWEEP is a product-invariant breach, not just a run defect)")
            print(markers.end)
            return
        }
        print("RUN INTEGRITY: clean · providerCalls 0 — sweeps stayed on device")
        guard delta.isCredible else {
            print("NOT MEASURED: the judge did not answer often enough. Decide nothing.")
            print(markers.end)
            return
        }
        // The vacuous-pass guard. This exact guard was WRITTEN on 2026-09-12 and never
        // landed — an unasserted string replace silently no-op'd — and the first device
        // run duly printed "HOLD · false merge == 0" over a prefilter that had skipped
        // every pair. The judge's own answers are still real and are reported above;
        // the FEATURE's verdict is not, because the production gate could never have
        // merged anything.
        guard embeddingAvailable else {
            print(
                "NOT MEASURED: no sentence embedding on this host, so the production gate could"
                    + " never merge anything and its zero false merges is VACUOUS. The JUDGE"
                    + " quadrant above is real (\(judgeFalseMerges) false merge"
                    + "\(judgeFalseMerges == 1 ? "" : "s") on the model's own answers); the"
                    + " feature's verdict needs a host with the embedding.")
            print(markers.end)
            return
        }
        print(
            falseMerges == 0
                ? "  HOLD · false merge == 0 — the destructive gate held on this corpus"
                : "  FAIL · \(falseMerges) FALSE MERGE\(falseMerges == 1 ? "" : "S") — a person would have lost a real task"
        )
        if judgeFalseMerges > falseMerges {
            print(
                "  NOTE · the JUDGE would have merged \(judgeFalseMerges) wrongly; the prefilter"
                    + " caught \(judgeFalseMerges - falseMerges). The gate is holding on the"
                    + " deterministic half — do not loosen the floors without re-running this.")
        }
        if falseMerges > 0 {
            print(
                "\nDECISION: raise `DuplicateSweep.acceptThreshold` to the lowest swept value above "
                    + "that gives zero false merges, or leave the sweep off on this runtime. A merge "
                    + "the person did not ask for is the worst outcome this product can produce.")
        } else {
            print(
                "\nDECISION: the gate holds. Record the stamp; re-run before ANY change to the "
                    + "judge's instructions, the schema, the threshold or the runtime.")
        }
        print("scope: this device, this runtime/model/configuration — quote no row without the stamp.")
        print(markers.end)
    }

    // MARK: - Report pieces

    private static func printRows(_ rows: [Row]) {
        print("\n── judgments ──")
        print(
            "  " + pad("verdict", 14) + pad("truth", 7) + pad("conf", 6) + pad("pre", 5)
                + pad("sim", 6) + pad("lex", 6) + pad("ms", 7) + "pair")
        for row in rows.sorted(by: { $0.verdict.rawValue < $1.verdict.rawValue }) {
            print(
                "  " + pad(row.verdict.rawValue, 14) + pad(row.pair.isDuplicate ? "dup" : "not", 7)
                    + pad(String(format: "%.2f", row.confidence), 6)
                    + pad(embeddingAvailable ? (row.survivesPrefilter ? "yes" : "NO") : "n/a", 5)
                    + pad(row.similarity.map { String(format: "%.2f", $0) } ?? "—", 6)
                    + pad(String(format: "%.2f", row.overlap), 6)
                    + pad(String(format: "%.0f", row.ms), 7)
                    + "\(row.pair.a) / \(row.pair.b)")
        }
    }

    /// **Does the prefilter even let the duplicates through?** A judge measured behind a
    /// filter that drops half the real duplicates looks perfect and does nothing.
    private static func printPrefilterRecall(_ rows: [(LabeledPair, PrefilterRead)]) {
        print("\n── prefilter (the population the judge actually sees) ──")
        guard embeddingAvailable else {
            print(
                "  NOT MEASURED — no sentence embedding on this host, so `candidatePairs` skips"
                    + " every pair for want of a vector. This is a property of the HOST, not of"
                    + " the floors; run on a device before reading anything into it.")
            return
        }
        let duplicates = rows.filter { $0.0.isDuplicate }
        let shown = duplicates.filter { $0.1.survives }.count
        let nearMisses = rows.filter { !$0.0.isDuplicate }
        print(
            "  real duplicates reaching the judge: \(shown)/\(duplicates.count)"
                + (shown < duplicates.count
                    ? "  ← the floors, not the model, are the ceiling on this feature" : ""))
        print("  near-misses reaching the judge:     \(nearMisses.filter { $0.1.survives }.count)/\(nearMisses.count)")
        for (pair, read) in duplicates where !read.survives {
            let simStr = read.similarity.map { String(format: "%.2f", $0) } ?? "—"
            print(
                "    dropped by the floors: \(pair.a) / \(pair.b)"
                    + "  sim=\(simStr) lex=\(String(format: "%.2f", read.overlap))")
        }
        print(
            String(
                format: "  floors: similarity ≥ %.2f · word overlap ≥ %.2f",
                DuplicateSweep.embeddingFloor, DuplicateSweep.lexicalFloor))
    }

    @discardableResult
    private static func printQuadrant(_ rows: [Row]) -> Int {
        var counts: [Verdict: Int] = [:]
        for row in rows { counts[row.verdict, default: 0] += 1 }
        let order: [(Verdict, String)] = [
            (.falseMerge, "merged two DIFFERENT tasks — the person loses a real errand"),
            (.trueMerge, "merged a real duplicate — the feature working"),
            (.missedDuplicate, "left a real duplicate in place — clutter, not damage"),
            (.correctlyLeft, "left two different tasks alone — the system working"),
            (.noArtifact, "the judge did not answer"),
        ]
        for (verdict, gloss) in order {
            print("  " + pad(verdict.rawValue, 15) + pad("\(counts[verdict] ?? 0)", 5) + gloss)
        }
        return counts[.falseMerge] ?? 0
    }

    /// The two distributions, separately. One mean over everything would hide exactly the
    /// overlap the threshold has to sit in.
    private static func printConfidence(_ rows: [Row]) {
        let served = rows.filter(\.served)
        let onTrue = served.filter { $0.pair.isDuplicate }.map(\.confidence)
        let onFalse = served.filter { !$0.pair.isDuplicate }.map(\.confidence)
        print("\n── confidence, by truth ──")
        print(line("real duplicates", onTrue))
        print(line("near-misses    ", onFalse))
        if let worstTrue = onTrue.min(), let bestFalse = onFalse.max() {
            print(
                bestFalse < worstTrue
                    ? String(
                        format:
                            "  SEPARABLE: every near-miss scored below every duplicate (gap %.2f) — the threshold has room",
                        worstTrue - bestFalse)
                    : String(
                        format:
                            "  OVERLAPPING: a near-miss scored %.2f, at or above a real duplicate's %.2f — "
                            + "no single threshold separates them on this corpus",
                        bestFalse, worstTrue))
        }
    }

    private static func line(_ label: String, _ values: [Double]) -> String {
        guard !values.isEmpty else { return "  \(label): —" }
        let mean = values.reduce(0, +) / Double(values.count)
        return String(
            format: "  %@: min %.2f · mean %.2f · max %.2f  (n=%d)", label, values.min() ?? 0, mean,
            values.max() ?? 0, values.count)
    }

    /// **0.85 is a number somebody chose.** Sweeping it turns the threshold into an output
    /// of the measurement, the same way `AdvisorBenchmark` makes a routing percentage one.
    private static func printThresholdSweep(_ rows: [Row]) {
        let served = rows.filter(\.served)
        print("\n── threshold sweep (current: \(DuplicateSweep.acceptThreshold)) ──")
        print("  " + pad("threshold", 11) + pad("false", 7) + pad("true", 6) + "note")
        for step in stride(from: 0.5, through: 0.95, by: 0.05) {
            let merged = served.filter {
                $0.survivesPrefilter && $0.judgedDuplicate && $0.confidence >= step
            }
            let falseMerges = merged.filter { !$0.pair.isDuplicate }.count
            let trueMerges = merged.filter { $0.pair.isDuplicate }.count
            let marker =
                abs(step - DuplicateSweep.acceptThreshold) < 0.001 ? "← current" : ""
            print(
                "  " + pad(String(format: "%.2f", step), 11) + pad("\(falseMerges)", 7)
                    + pad("\(trueMerges)", 6) + marker)
        }
        print("  the right line is the LOWEST threshold with zero false merges — lower catches more clutter")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard text.count < width else { return String(text.prefix(width - 1)) + " " }
        return text + String(repeating: " ", count: width - text.count)
    }
}

#endif
