//
//  LaunchSeams.swift
//  Project-Ezra
//
//  **The launch-argument harnesses, out of the shell.** (G4 — the second audit)
//
//  `RootTabView` had grown to 1,100 lines, most of it `…IfRequested()` seams — the
//  RambleEval run, CaptureCompare, CaptureDiagnostics and their arms. The shell that owns
//  three sheets and one orb should be readable in one sitting; the diagnostic harness
//  should be its own thing, so a new seam stops touching the shell at all. This is a
//  MOVE, not a rewrite: the bodies are byte-identical to what ran in the shell, with
//  `brain`, `context` and `familyMembers` now the struct's own. The seams that write shell
//  STATE (seeds, `-OpenCapture`, `-OpenActivity`, the Ask seams) stay in `RootTabView`,
//  because they are about the shell.
//
//  Every seam is guarded on its argument and fires only in verification runs.
//

import CoreData
import FoundationModels
import SwiftUI

struct LaunchSeams {
    let brain: AppBrain
    let context: NSManagedObjectContext
    let familyMembers: [FamilyMember]

    /// The diagnostic seams, in the order the shell always ran them.
    func run() async {
        await runRambleEvalIfRequested()
        await runCaptureCompareIfRequested()
        await runCaptureDiagnosticsIfRequested()
    }

    /// Verification seam: `-RambleEval` runs the labeled eval set through **every arm
    /// available on this host**, scoring each against the SAME shared floors
    /// (`RambleEval.Floors`) and printing a per-field PASS/FAIL table plus named misses
    /// to stdout.
    ///
    /// It used to run "the ACTIVE engine" — one arm, whichever the host happened to
    /// select — and print percentages with no floors attached, so reading it meant
    /// eyeballing numbers against literals in a test file. That is how the front door
    /// went unmeasured: CI held the heuristic arm to the floors, the device printed the
    /// on-device arm's numbers next to nothing, and an unstructured spoken blob failed
    /// to segment while every number in the suite stayed green.
    ///
    /// Both arms run whenever both exist, deliberately. The interesting output is not
    /// either table but the DIFFERENCE, and a baseline the cloud arm must beat has to be
    /// measured on the same hardware in the same run — not inherited from CI.
    ///
    /// Non-destructive: nothing commits, same rule as `-CaptureDiagnostics`. DEBUG-only,
    /// like the fixture set it reads.
    func runRambleEvalIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-RambleEval") else { return }
        // `-EvalToFile`: tee the whole run into Documents/rambleeval-report.txt instead
        // of stdout, so a DEVICE run needs no live console. The `--console` attachment
        // is the least reliable link in the chain — the CoreDevice tunnel dropped three
        // times in one session, each time discarding an in-flight eval's output — and a
        // file in the app container is pullable afterward with a one-shot
        // `devicectl device copy from`, immune to every drop in between. Line-buffered
        // so a poll mid-run sees real progress; `=== END RAMBLE EVAL ===` is the
        // completion marker a puller greps for.
        if ProcessInfo.processInfo.arguments.contains("-EvalToFile") {
            Instrument.teeStdoutToDocuments("rambleeval-report.txt")
        }
        print("=== RAMBLE EVAL ===")
        print("host engine: \(brain.status.description)")

        // CAMPAIGN INVARIANT: a free-arm run makes ZERO cloud provider calls, and
        // that is PREVENTED, not merely observed. Without `-WithCloud` the provider
        // slot holds a throwing stub for the eval's whole duration, so a provider
        // call leaking from anywhere below the arm-selection layer throws instead of
        // billing — the class of regression a skip-line can never catch. The per-arm
        // `providerCalls` ledger delta is the visible receipt.
        let cloudDecision = Self.cloudArmDecision(
            arguments: ProcessInfo.processInfo.arguments,
            providerAvailable: CloudModel.isAvailable)
        let originalProvider = CloudModel.provider
        if cloudDecision != .run { CloudModel.provider = EvalQuotaGuard.self }
        defer { CloudModel.provider = originalProvider }

        // The deterministic arm always exists — it is the offline arm of everything, so
        // it is never "not applicable", only sometimes not the one that ships.
        await runEvalArm("heuristic") { utterance in
            let intents = try await HeuristicEngine().triage(rawText: utterance)
            return IntentResolver.resolve(intents)
        }

        // The escalation-policy report (2026-08-29): for every unstructured case, would
        // the deterministic read have been KEPT or ESCALATED — and of the keeps, how
        // many the labels say were wrong (the false-keep rate, the one number that can
        // kill the device-first policy). Printed before the model arms because it needs
        // none of them: the policy is deterministic end to end.
        await printEscalationPolicyReport()

        // The FM on-device arm — RETIRED from the capture chain (2026-08-29: p90 21s
        // against the deterministic read's 2ms, no floor the deterministic arm doesn't
        // hold), kept HERE as the tripwire instrument: a materially faster Apple model
        // re-opens capture routing, and a tripwire nobody can measure never fires.
        // Constructed DIRECTLY — its first configured-device run reached the model via
        // `route: .cloud` + availability degrade, and a dead-quota provider turned that
        // into 429 noise with 31 of 52 cases scoring the fallback. A pinned engine
        // cannot be polluted by whatever the router would have done.
        if brain.status.isOnDevice {
            // Every case is BOUNDED, and a failing case scores rather than aborts.
            // Session B's first device run earned both rules: the forward pass served
            // ~13 minutes of answers, hit one SensitiveContentAnalysisML error, and the
            // whole arm aborted — discarding every number it had already produced; the
            // reverse pass hung on a wedged `respond` with no deadline anywhere, and
            // the run sat silent for 30 minutes before a human diagnosed it. Now a
            // hung case is a named `.timedOut` after `evalCaseTimeoutSeconds`, a
            // failed case records and scores as an empty read (a segmentation miss —
            // honest, since the user would have gotten nothing), and only
            // `evalConsecutiveFailureLimit` failures IN A ROW abort the arm — the
            // model being globally wedged, where burning a minute per remaining case
            // would measure nothing but the wall.
            let failures = EvalFailureStreak()
            await runEvalArm("on-device(direct)", expectsModel: true) { utterance in
                let started = Date()
                let engine = FoundationModelsEngine()
                func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
                do {
                    let intents = try await ModelDeadline.race(
                        timeout: LaunchSeams.evalCaseTimeoutSeconds
                    ) {
                        try await engine.triage(
                            rawText: utterance, context: TriageContext(), onPartial: nil)
                    }
                    // The served-call proof: a direct engine call bypasses `AppBrain.triage`,
                    // where capture metrics are normally recorded, so the arm records its
                    // own — without this the DEGRADED banner would cry wolf on every run.
                    ModelMetrics.shared.record(
                        .captureTriage, .success, latencyMs: elapsed())
                    failures.streak = 0
                    return IntentResolver.resolve(intents)
                } catch is ModelDeadline.Exceeded {
                    ModelMetrics.shared.record(.captureTriage, .timedOut, latencyMs: elapsed())
                    try failures.recordOrAbort(
                        "per-case deadline (\(Int(LaunchSeams.evalCaseTimeoutSeconds))s) hit")
                    return []
                } catch {
                    // `errorLabel`, not the bare type name: an unmapped error's label
                    // carries its description, and "last: NSError" diagnoses nothing.
                    let label = AppBrain.errorLabel(error)
                    ModelMetrics.shared.record(
                        .captureTriage, .failed(label), latencyMs: elapsed())
                    try failures.recordOrAbort(label)
                    return []
                }
            }
        } else {
            print("\n(on-device(direct) arm skipped — no on-device model on this host)")
        }

        // The cloud arm — OPT-IN behind `-WithCloud`, the `-CaptureCompare` rule:
        // one sweep is one billable call per case, and measuring the product must not
        // cost the product. Configured is not authorized.
        switch cloudDecision {
        case .run:
            // The hedge is gone from capture, so this measures the cloud arm plainly;
            // an unreachable or throttled provider falls to the deterministic tail and
            // the served-ratio DEGRADED banner says so rather than letting the fallback
            // wear a cloud label.
            await runEvalArm("cloud(\(CloudModel.provider.identifier))", expectsModel: true) {
                utterance in
                await brain.triage(utterance, route: .cloud).drafts
            }
        case .skippedNoFlag:
            print(
                """

                (cloud arm SKIPPED — provider configured, -WithCloud not passed; this \
                run spent 0 cloud calls. The tables above have NO cloud baseline — do \
                not read a free-arm pass as a routing verdict.)
                """)
        case .skippedNoProvider:
            print("\n(cloud arm skipped — no provider installed; CloudModel.provider is inert)")
        }

        print("=== END RAMBLE EVAL ===")
        #endif
    }

    #if DEBUG
    /// Score the 2026-08-29 routing policy itself: run every UNSTRUCTURED corpus case
    /// through the deterministic pipeline, ask `CaptureEscalation` for its verdict, and
    /// compare keeps against the labels. Three numbers matter: how often the policy
    /// escalates (the cost dial), how often it keeps (the savings), and how many keeps
    /// the labels call wrong (**false-keeps** — the intent-loss rate, the number that
    /// can kill device-first). Explicit-structure cases are excluded: they never had a
    /// routing question.
    func printEscalationPolicyReport() async {
        print("\n── Capture escalation policy (deterministic read + verifier) ──")
        let resolve: (String) async throws -> [TaskDraft] = { utterance in
            let intents = try await HeuristicEngine().triage(rawText: utterance)
            return IntentResolver.resolve(intents)
        }
        // THE ROUTING QUADRANT — both sides of the decision, over the unstructured
        // corpus (the only cases a routing decision exists for). Math and definitions
        // live in `RambleEval.routingRows`; this is a printer.
        let rows = await RambleEval.routingRows(over: RambleEval.evalSet, resolve: resolve)
        var cells: [RambleEval.RoutingVerdict: Int] = [:]
        for row in rows { cells[row.verdict, default: 0] += 1 }
        func count(_ verdict: RambleEval.RoutingVerdict) -> Int { cells[verdict] ?? 0 }
        let kept = count(.keptCorrect) + count(.falseKeep)
        let escalated = count(.escalatedJustified) + count(.escalatedUnnecessary)
        let reasons = rows.compactMap(\.reason).reduce(into: [String: Int]()) {
            $0[$1.rawValue, default: 0] += 1
        }
        let reasonText = reasons.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        print(
            "routing quadrant (\(rows.count) unstructured): "
                + RambleEval.RoutingVerdict.allCases
                .map { "\($0.rawValue) \(count($0))" }.joined(separator: " · ")
                + (reasonText.isEmpty ? "" : "  (\(reasonText))"))

        // Three questions, three registers. ACCURACY keeps the hard gate (a false
        // keep silently loses intent). COVERAGE and CLOUD WASTE are measured
        // diagnostics with their denominators printed — a bare label here would read
        // as a production-rate estimate, and an unnecessary escalation wastes one
        // call, which is why it gets no ceiling (the asymmetry the architecture
        // argues from; "maximize local" is refused as a target).
        let falseLocalRate = kept > 0 ? Double(count(.falseKeep)) / Double(kept) : 0
        let ceiling = CapturePerformanceContract.standard.falseLocalCeiling
        print(
            String(
                format: "accuracy: false-keeps %d/%d kept (%.1f%%) · ceiling %.0f%%  %@",
                count(.falseKeep), kept, falseLocalRate * 100, ceiling * 100,
                falseLocalRate > ceiling ? "FAIL" : "pass"))
        print(
            String(
                format: "coverage: %d/%d unstructured kept local (%.0f%%)",
                kept, rows.count, rows.isEmpty ? 0 : Double(kept) / Double(rows.count) * 100))
        print(
            "cloud waste: \(count(.escalatedUnnecessary))/\(escalated) escalations "
                + "unnecessary (\(count(.escalatedUnnecessary))/\(rows.count) eligible) · diagnostic")
        for row in rows where row.verdict == .falseKeep {
            print("  false-keep ← \(row.utterance.prefix(56))")
        }
        for row in rows where row.verdict == .escalatedUnnecessary {
            print(
                "  unnecessary ← \(row.utterance.prefix(56)) "
                    + "(\(row.reason?.rawValue ?? "?") — local count already right)")
        }

        // THE ADVERSARIAL NEAR-MISS SUITE — the campaign's boundary-tuning payload,
        // scored through the same quadrant and COUNTED APART: adversarial-by-
        // construction data must never move a number gated against
        // `falseLocalCeiling` (the observed-numbers rule). All 8 lines always — a
        // suite scored by nothing was the gap; one partially printed is the smaller
        // version of it. The paired halves are what stop `boundarySignalFloor`
        // tuning from becoming uniformly more suspicious of the word "and".
        print("\n── Adversarial near-miss suite (routing-only · NEVER in floors or the gate) ──")
        let adversarial = await RambleEval.routingRows(
            over: RambleEval.gateAdversarialSet, resolve: resolve)
        var advCells: [RambleEval.RoutingVerdict: Int] = [:]
        for row in adversarial {
            advCells[row.verdict, default: 0] += 1
            let half = row.expectedCount == 1 ? "[compound-is-one]" : "[atomic-is-not] "
            let verdict =
                row.verdict == .falseKeep ? "FALSE-KEEP" : row.verdict.rawValue
            let detail = row.reason.map { " (\($0.rawValue))" } ?? ""
            print(
                "  \(half) \(verdict.padding(toLength: 22, withPad: " ", startingAt: 0))"
                    + "\"\(row.utterance.prefix(52))\" "
                    + "(\(row.draftCount) draft\(row.draftCount == 1 ? "" : "s") vs \(row.expectedCount))"
                    + detail)
        }
        print(
            "adversarial quadrant: "
                + RambleEval.RoutingVerdict.allCases
                .map { "\($0.rawValue) \(advCells[$0] ?? 0)" }.joined(separator: " · ")
                + " · diagnostic")
    }
    #endif

    #if DEBUG
    /// Score one arm and print its table, WITH proof of which engine actually answered.
    ///
    /// `expectsModel` is the load-bearing parameter, and it exists because the first
    /// version of this seam reproduced the exact failure it was built to catch. On a
    /// host where `SystemLanguageModel.default.availability == .available` but the model
    /// catalog is empty (a real simulator state: *"There are no underlying assets … for
    /// asset set com.apple.modelcatalog"*), every generation throws and
    /// `AppBrain.triage` degrades to the heuristic — **by design**, because capture must
    /// never fail. The arm then produces the fallback's drafts, scores the fallback's
    /// numbers, and prints "on-device: ALL FLOORS HELD".
    ///
    /// Availability is a claim about a model EXISTING; it is not evidence that one
    /// ANSWERED. So the arm proves it: the `ModelMetrics` delta across the run says how
    /// many calls were served, and an arm that expected a model and served none is
    /// reported as **DEGRADED** rather than as a pass. A green table nobody can trust is
    /// worse than no table.
    ///
    /// A thrown error is reported as a failed ARM rather than a failed run, so one
    /// broken arm never hides another's numbers.
    /// The eval's quota guard: a provider that cannot bill. Installed in the
    /// `CloudModel.provider` slot for the duration of a free-arm eval run, so the
    /// campaign invariant "zero cloud calls" is enforced by construction — a leaked
    /// call throws `unavailable` and surfaces in the arm's failed count instead of on
    /// an invoice. `isAvailable == false` also keeps every reachability-gated path on
    /// its honest degrade.
    enum EvalQuotaGuard: CloudModelProvider {
        static let identifier = "eval-quota-guard"
        static var isAvailable: Bool { false }
        static let capabilities = LanguageModelCapabilities([])
        static func session(
            instructions: String, config: CapabilityProfiles.Config
        ) throws -> LanguageModelSession {
            throw ModelUnavailableError.unavailable
        }
    }

    /// One eval case may hang or fail; a RUN of them means the model is wedged. The
    /// per-case bound is generous — the measured healthy p90 was 21s, and an eval is
    /// not a UX budget — because its job is to convert an infinite hang into a named
    /// timeout, not to grade speed (the settled table already does that).
    static let evalCaseTimeoutSeconds: Double = 60
    static let evalConsecutiveFailureLimit = 3

    /// Consecutive-failure bookkeeping for a model eval arm. A class because the arm
    /// closure is `@escaping` and cannot capture a mutable local; MainActor like
    /// everything around it.
    final class EvalFailureStreak {
        var streak = 0
        struct ArmWedged: Error, CustomStringConvertible {
            var description: String
        }
        /// Count a failure; throw once the streak says the model is wedged, so the
        /// abort carries WHY instead of a bare rethrow that discards the table.
        func recordOrAbort(_ label: String) throws {
            streak += 1
            guard streak >= LaunchSeams.evalConsecutiveFailureLimit else { return }
            throw ArmWedged(
                description:
                    "aborted after \(streak) consecutive case failures — last: \(label). "
                    + "The model is wedged; remaining cases would measure only the wall.")
        }
    }

    /// Whether the eval's cloud arm may run. Configured ≠ authorized: the flag is the
    /// authorization, availability is only the capability. Pure, so the gate is a test
    /// subject rather than a habit.
    enum CloudArmDecision: Equatable {
        case run
        case skippedNoFlag
        case skippedNoProvider
    }
    static func cloudArmDecision(
        arguments: [String], providerAvailable: Bool
    ) -> CloudArmDecision {
        guard providerAvailable else { return .skippedNoProvider }
        return arguments.contains("-WithCloud") ? .run : .skippedNoFlag
    }

    /// The `-EvalCaseLimit N` argument — the smoke-test dial. Nil (full corpus) when
    /// absent or malformed. `-EvalCaseLimit 5` answers "is the model arm alive on
    /// this host?" in a couple of minutes before anyone commits to a 52-case sitting.
    private static var evalCaseLimit: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-EvalCaseLimit"), args.indices.contains(flag + 1),
            let value = Int(args[flag + 1]), value > 0
        else { return nil }
        return value
    }

    /// The `-CaptureRepeats N` argument, 1 when absent or malformed.
    private static var captureRepeats: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-CaptureRepeats"), args.indices.contains(flag + 1),
            let value = Int(args[flag + 1])
        else { return 1 }
        return max(1, value)
    }

    func runEvalArm(
        _ name: String, expectsModel: Bool = false,
        resolve: @escaping (String) async throws -> [TaskDraft]
    ) async {
        let before = ModelMetrics.shared.stats[.captureTriage] ?? ModelMetrics.Stats()
        let started = Date()
        // `-CaptureRepeats N`: extra timing-only passes per case, for percentiles a
        // single shot can't stabilize. FREE ARMS ONLY, deliberately — repeating a model
        // arm N× the corpus multiplies its call count by N, and on the cloud arm that
        // torches the day's quota measuring the product at the cost of the product
        // (the `-WithCloud` rule). Cloud percentiles come from the live report's
        // real-usage receipts instead.
        let repeats = expectsModel ? 1 : max(1, Self.captureRepeats)
        let reversed = ProcessInfo.processInfo.arguments.contains("-ReverseEvalOrder")
        let cloudBefore = IntelligenceLedger.shared.cloudCallsToday()
        do {
            // Heartbeat on MODEL arms only: at ~21s/case the per-case lines are the
            // run's pulse; on the heuristic's 260 sub-ms invocations they'd be spam.
            let report = try await RambleEval.score(
                resolve: resolve, repeats: repeats, reversed: reversed,
                limit: Self.evalCaseLimit, heartbeat: expectsModel)
            // The real-utterance corpus (2026-09-02) through the same arm, against
            // its OWN floors — a second table beside the authored one, never folded
            // into it. `-EvalCaseLimit` bounds it too, so a smoke pass stays short.
            let real = try await RambleEval.score(
                over: RambleEval.realSet, resolve: resolve, reversed: reversed,
                limit: Self.evalCaseLimit, heartbeat: expectsModel)
            let seconds = Date().timeIntervalSince(started)
            let after = ModelMetrics.shared.stats[.captureTriage] ?? ModelMetrics.Stats()
            let served = after.served - before.served
            let failed = (after.failures - before.failures) + (after.timeouts - before.timeouts)
            // The run reports its own shape — wall clock is diagnostic data in its own
            // right (session serialization and prewarm live in it), and `providerCalls`
            // is the ledger delta: the report self-audits its quota spend rather than
            // asking the reader to trust the arm gating.
            let providerCalls = IntelligenceLedger.shared.cloudCallsToday() - cloudBefore
            let timedOut = after.timeouts - before.timeouts

            print(report.table(against: .standard, arm: name))
            print(real.table(against: .real, arm: "\(name) · real utterances"))
            print(
                String(
                    format: "arm %@: cases %d · repeats %d · invocations %d · "
                        + "providerCalls %d · wall %.1fs · settled p50/p95 %d/%dms "
                        + "· model calls served %d · timedOut %d · failed %d",
                    name, report.caseCount, repeats, report.settledMs.count,
                    providerCalls, seconds, Int(report.settledP50Ms),
                    Int(report.settledP95Ms), served, timedOut, failed - timedOut))
            // DEGRADED is a RATIO, not a zero test.
            //
            // It used to fire only on `served == 0`, and that let the worst possible
            // report through: a cloud arm that served 2 of 52 calls printed "ALL FLOORS
            // HELD" with numbers identical to the heuristic's, because 96% of the corpus
            // had quietly scored the deterministic fallback. One survivor was enough to
            // suppress the warning. A partially degraded arm is not a weaker version of
            // a degraded arm — it is the same lie with better camouflage, because the
            // table looks plausible instead of empty.
            //
            // `lastError` is printed with it: an arm can now say WHY it degraded, which
            // is the difference between "re-run somewhere else" and a diagnosis. Without
            // it the only signal was a count, and a count cannot distinguish a missing
            // model from a rejected request.
            let attempted = served + failed
            let servedShare = attempted > 0 ? Double(served) / Double(attempted) : 0
            if expectsModel && (attempted == 0 || servedShare < 0.9) {
                let reason = ModelMetrics.shared.stats[.captureTriage]?.lastError
                print(
                    """
                    ⚠️  ARM DEGRADED — "\(name)" served \(served)/\(attempted) call\
                    \(attempted == 1 ? "" : "s"); the rest scored the DETERMINISTIC \
                    fallback, so this table describes the fallback, not \(name). \
                    \(reason.map { "Last error: \($0)." } ?? "No error label recorded.") \
                    Fix the arm before treating any number above as a baseline.
                    """)
            }
        } catch {
            print("arm \(name) FAILED: \(AppBrain.errorLabel(error))")
        }
    }
    #endif


    /// Verification seam for the ONE thing only real hardware can answer: how the
    /// capture pipeline behaves against a live on-device model.
    ///
    /// `-CaptureDiagnostics` runs a deliberately long ramble through the active engine
    /// and prints the result — tier, wall-clock, draft count, and the `ModelMetrics`
    /// tallies — to stdout, where `devicectl process launch --console` can read it.
    /// Everything here was previously legible only as text on a DEBUG footer, i.e. only
    /// to a human holding the phone, which is why "device-verify" had stayed a checklist
    /// someone had to perform rather than a thing that could simply be run.
    ///
    /// Deliberately does NOT commit: this measures the parse, and leaving a pile of
    /// tasks behind would make the seam destructive to re-run.
    /// `-CaptureCompare "<your ramble>"` — the same words, read by every arm, printed
    /// side by side. Add `-WithCloud` to include the paid rung.
    ///
    /// **The manual-judgment instrument.** `RambleEval` answers "does this match the
    /// labels?" over a frozen corpus; that is the right question for regressions and the
    /// wrong one for "is this good?". Quality on YOUR OWN messy sentences is a thing a
    /// person has to read and decide, and until now the only way to see a reading was to
    /// capture it in the app and inspect cards — one arm, no comparison, no way to tell
    /// which reader you were looking at.
    ///
    /// It matters more on the Spark plan than it would otherwise. Unstructured capture
    /// routes to the cloud, the cloud is rationed, and what actually serves the ramble is
    /// the DEGRADED OFFLINE arm — the one device evidence says is weakest at exactly this
    /// job. Whether that is tolerable to live with is a judgment call, and this is the
    /// tool for making it on real input instead of on the corpus.
    ///
    /// The cloud arm is OPT-IN (`-WithCloud`) because one eval sweep exhausts a day's
    /// free quota, which then breaks real capture — measuring the product must not cost
    /// you the product.
    func runCaptureCompareIfRequested() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-CaptureCompare") else { return }
        let text =
            args.indices.contains(flag + 1) && !args[flag + 1].hasPrefix("-")
            ? args[flag + 1]
            : "renew my passport before the trip and book flights after it comes through"

        print("=== CAPTURE COMPARE ===")
        print("input (\(text.count) chars): \(text)")
        // What PRODUCTION would do with this input, before any arm runs — so the
        // comparison is read against the route the user would actually get. Since
        // 2026-08-29 that decision includes the verifier, so it needs the local read.
        let structure = Segmentation.structure(of: text)
        let localRead = IntentResolver.resolve(
            (try? await HeuristicEngine().triage(rawText: text)) ?? [])
        let decision = CaptureRoute.route(for: text, localRead: localRead)
        print(
            "structure: \(structure.label) → route \(decision.route.metricName)"
                + (decision.escalation.map { " (escalates: \($0.rawValue))" }
                    ?? " (local read kept)"))

        await compareArm("deterministic (always available)") {
            IntentResolver.resolve(try await HeuristicEngine().triage(rawText: text))
        }

        if brain.status.isOnDevice {
            await compareArm("on-device FM (retired from capture; tripwire arm)") {
                let engine = FoundationModelsEngine(sessionSource: .onDevice)
                let intents = try await engine.triage(
                    rawText: text, context: TriageContext(), onPartial: nil)
                return IntentResolver.resolve(intents)
            }
        } else {
            print("\n— on-device FM: no on-device model on this host")
        }

        if args.contains("-WithCloud") {
            guard CloudModel.isAvailable else {
                print("\n— cloud: no provider configured")
                print("=== END CAPTURE COMPARE ===")
                return
            }
            await compareArm("cloud (the semantic authority)") {
                let engine = FoundationModelsEngine(sessionSource: .cloud)
                let intents = try await engine.triage(
                    rawText: text, context: TriageContext(), onPartial: nil)
                return IntentResolver.resolve(intents)
            }
        } else {
            print("\n— cloud: skipped (pass -WithCloud to spend a call)")
        }
        print("=== END CAPTURE COMPARE ===")
        #endif
    }

    #if DEBUG
    /// One arm's reading, printed as the DRAFTS THEMSELVES rather than as counts.
    ///
    /// Counts are what the old diagnostics gave ("11 drafts · 3 dated"), and they cannot
    /// answer the only question that matters here: did it understand the sentence? A
    /// wrong split and a right one both count as two.
    func compareArm(
        _ name: String, resolve: @escaping () async throws -> [TaskDraft]
    ) async {
        let started = Date()
        do {
            let drafts = try await resolve()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("\n── \(name) — \(drafts.count) task\(drafts.count == 1 ? "" : "s") · \(ms)ms ──")
            if drafts.isEmpty { print("   (nothing)") }
            for (i, d) in drafts.enumerated() {
                var line = "  \(i + 1). \(d.title)  [\(d.category)]"
                if let due = d.dueDate {
                    line += " · due \(Self.dayFormatter.string(from: due))"
                    if d.dueReason != nil { line += " (inferred)" }
                }
                if let owner = d.ownerName { line += " · @\(owner)" }
                if let blocker = d.blockedBy { line += " · waits on \(blocker)" }
                if d.isJudgmentCall { line += " · JUDGMENT" }
                if d.unresolved.contains(.date) { line += " · asks WHEN?" }
                print(line)
            }
        } catch {
            print("\n── \(name) — FAILED: \(AppBrain.errorLabel(error))")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
    #endif

    func runCaptureDiagnosticsIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CaptureDiagnostics") else { return }
        // Long, messy, and full of the shapes that make the model work: dates, a
        // delegation, a blocker, judgment calls, and a duplicate of a seeded task.
        let ramble =
            String(repeating: "", count: 1) + """
                ok brain dump time — renew my passport before the trip, and book flights \
                for that trip but only after the passport comes through, oil change is \
                overdue by like two weeks now, should I keep paying for the gym I honestly \
                never use, call mom back she left three voicemails, daycare enrollment \
                forms are due Friday, finish the Q3 deck for the board thing, return the \
                amazon package before the window closes, figure out if the side project is \
                still worth it or if I should let it go, pay the water bill it's the second \
                notice, ask Maya to sort out the insurance renewal, schedule the kitchen \
                plumber once the contractor calls back, and renew my passport
                """
        print("=== CAPTURE DIAGNOSTICS ===")
        print("engine: \(brain.status.description)")
        // The first line to read when a capture is slow. `configured` is whether this
        // build is wired to a provider at all; `health` is whether the last calls
        // actually landed. A run that shows `configured yes` and `health open` went
        // on-device DELIBERATELY and instantly — which is a completely different
        // diagnosis from a hung network, and was indistinguishable before the breaker.
        print("cloud: configured \(CloudModel.isAvailable) · \(CloudHealth.shared.statusLine())")
        print("input: \(ramble.count) chars")
        // The provisional arm FIRST — it is what the user now sees, and the gap
        // between these two numbers is the whole instant-capture claim, in one
        // re-runnable line. Also printed at three input lengths, because the
        // coalesce window is tuned on how this scales, not on how it reads once.
        for cut in [ramble.count / 3, (ramble.count * 2) / 3, ramble.count] {
            let slice = String(ramble.prefix(cut))
            let started = Date()
            let provisional = AppBrain.provisionalDrafts(slice)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print(
                "provisional @\(cut) chars: \(provisional.count) drafts · \(elapsed)ms "
                    + "· owners \(provisional.compactMap(\.ownerName).count) "
                    + "· dated \(provisional.compactMap(\.dueDate).count)")
        }
        let started = Date()
        let drafts = await brain.triage(ramble).drafts
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        print("drafts: \(drafts.count)")
        print("wall clock: \(elapsed)ms")
        print(
            "proposals: \(drafts.reduce(0) { $0 + $1.edgeProposals.count }) "
                + "· owners: \(drafts.compactMap(\.ownerName).count) "
                + "· blockers: \(drafts.compactMap(\.blockedBy).count) "
                + "· dated: \(drafts.compactMap(\.dueDate).count)")
        for line in ModelMetrics.shared.footerLines() { print("metrics: \(line)") }
        // AFTER the run: if the cloud arm threw, this names the classification that moved
        // the breaker, so a slow capture explains itself in one line instead of a guess.
        print("cloud after: \(CloudHealth.shared.statusLine())")
        // The performance contract, checked against this device's own committed
        // captures (the provenance sidecar, newest 200) — per-tier p50/p95 vs targets,
        // local share vs the 70–90% band, and the escalation-reason mix.
        for line in CapturePerformanceReport.measure(CaptureProvenanceStore.shared.all)
            .footerLines()
        {
            print("contract: \(line)")
        }
        await runContinuousDiagnosticsArm(ramble: ramble)
        print("=== END CAPTURE DIAGNOSTICS ===")
    }

    /// The A/B arm for the CONTINUOUS capture session (`CaptureConversation`): the
    /// same ramble fed as three growing snapshots — the shape the rolling chain
    /// produces — with per-turn wall-clock, draft counts, and token accounting. The
    /// continuous session becomes the composer's default the day these numbers beat
    /// the single-use baseline above on real hardware; until then it is measured,
    /// not shipped (the capture-deadline precedent: tuned on evidence).
    func runContinuousDiagnosticsArm(ramble: String) async {
        guard brain.status.isOnDevice else {
            print("continuous: skipped (engine is not on-device)")
            return
        }
        // Three prefixes at natural clause boundaries, ending with the full text —
        // turn 1 initial, turns 2-3 suffix continuations.
        let cuts = [ramble.count / 3, (ramble.count * 2) / 3, ramble.count]
        let snapshots = cuts.map { String(ramble.prefix($0)) }
        let conversation = CaptureConversation(context: TriageContext())
        for (index, snapshot) in snapshots.enumerated() {
            let turn = CaptureConversation.turn(
                from: conversation.coveredText, to: snapshot)
            let turnLabel: String
            switch turn {
            case .initial: turnLabel = "initial"
            case .continuation(let suffix): turnLabel = "continuation(+\(suffix.count) chars)"
            case .revision: turnLabel = "revision"
            }
            let started = Date()
            do {
                let intents = try await conversation.triage(
                    rawText: snapshot, context: TriageContext(), onPartial: nil)
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                let prompt = CaptureConversation.prompt(for: turn)
                let tokens =
                    (try? await SystemLanguageModel.default.tokenCount(for: prompt)) ?? -1
                print(
                    "continuous turn \(index + 1)/\(snapshots.count) [\(turnLabel)]: "
                        + "\(intents.count) intents · \(elapsed)ms · prompt \(tokens) tok")
            } catch {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                print(
                    "continuous turn \(index + 1)/\(snapshots.count) [\(turnLabel)]: "
                        + "FAILED after \(elapsed)ms · \(AppBrain.errorLabel(error))")
            }
        }
    }

}
