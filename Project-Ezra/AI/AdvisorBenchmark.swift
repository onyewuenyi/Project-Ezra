//
//  AdvisorBenchmark.swift
//  Project-Ezra
//
//  **Routing is discovered, not decreed.**
//
//  The first version of the Advisor's router decided the hard band a priori: decisions,
//  multi-step chains and repeat-deferrals go to the paid rung because that is where deep
//  reasoning "obviously" helps. That is a guess wearing the costume of a policy, and it
//  fails in both directions — it pays for cases a local model already handles, and it
//  quietly withholds thought from cases that needed it.
//
//  v5's method inverts the development order. **Start at the top.** Let the strongest
//  practical model establish what excellent judgment looks like for each state in the
//  corpus — that is the CEILING. Then let cheaper rungs earn cases by matching it. The
//  routing percentage is whatever falls out: never "cloud should be 10%", always "these
//  cases measurably need deep reasoning; those don't."
//
//  What that buys, concretely:
//  - `AdvisorRouting.depthReason`'s three reasons become falsifiable hypotheses. A case
//    the shallow rung matches at the ceiling should LOSE its `.deep` claim rather than
//    keep it out of habit — and this file is what produces the evidence to take it away.
//  - The cost question gets its honest form. The optimization target is not minimum cloud
//    spend; it is **maximum reduction in required attention per dollar of reasoning.** If
//    deep reasoning writes better prose but buys no progression, we don't pay for it.
//  - Provider swaps stop being scary. The ceiling is re-measured, not re-argued.
//
//  **The corpus is the hard band on purpose.** It is not a sample of everyday tasks —
//  those are answered by the gate and by shallow reads, and a benchmark full of them
//  would report a comfortable high number about work nobody needs help with. It is the
//  states where the differentiating sentence is won or lost: stuck decisions, chains,
//  and tasks the user has bounced off repeatedly.
//
//  It shares `AdvisorDiagnostics.fixtures` deliberately — one corpus, two questions.
//  Diagnostics asks "does the active path agree with a competent human?"; the benchmark
//  asks "which rung is enough for this case?" Two corpora would drift, and the second one
//  to drift would be the one nobody was looking at.
//

#if DEBUG
import CoreData
import Foundation

@MainActor
enum AdvisorBenchmark {

    /// One rung's answer on one fixture.
    struct Sample: Equatable {
        let fixture: String
        let rung: IntelligenceRung
        /// The move it chose, or nil when nothing usable came back.
        let move: AdvisorMove?
        /// True when the facts favoured nobody and it correctly declined to recommend.
        let abstained: Bool
        /// Characters in the user-visible observation — the depth guardrail's evidence.
        let observationLength: Int
        let latencyMs: Int
    }

    /// What the ceiling rung concluded for a fixture, and whether a cheaper rung matched.
    struct Verdict {
        let fixture: String
        let ceiling: Sample?
        let candidate: Sample?
        /// The hypothesis the current router holds about this fixture.
        let claimedDeep: Bool

        /// Did the cheaper rung reach the same judgment the ceiling did?
        ///
        /// Move equality plus abstention equality — deliberately NOT text similarity. Two
        /// readings that both say "you haven't picked a restaurant, and everything else
        /// waits on that" in different words are the same judgment, and scoring prose
        /// would reward the model that writes more, which is precisely the failure the
        /// depth guardrail exists to prevent.
        var matched: Bool {
            guard let ceiling, let candidate else { return false }
            return ceiling.move == candidate.move && ceiling.abstained == candidate.abstained
        }

        /// The router claims this case needs depth AND the cheap rung matched anyway —
        /// so the claim is not earned. These are the rows that should change the policy.
        var overClaimed: Bool { claimedDeep && matched }

        /// The router claims this case is shallow AND the cheap rung diverged from the
        /// ceiling — thought was withheld from a case that needed it. Rarer and worse:
        /// over-claiming costs money, under-claiming costs the product's whole promise.
        var underClaimed: Bool { !claimedDeep && !matched && ceiling != nil && candidate != nil }
    }

    /// Score every fixture on the ceiling rung and on the candidate rung.
    ///
    /// `ceiling` defaults to `.cloud` because that is the strongest thing reachable; on a
    /// host with no provider the run reports honestly that it measured no ceiling rather
    /// than silently promoting on-device to "best available" — a benchmark whose ceiling
    /// is the thing being tested measures nothing at all.
    static func run(
        ceiling: IntelligenceRung = .cloud,
        candidate: IntelligenceRung = .onDevice,
        repeats: Int? = nil
    ) async -> [Verdict] {
        // Resolved inside the main-actor body rather than as a default argument, which
        // would be evaluated in a nonisolated context. Shared with the judgment eval on
        // purpose: `-AdvisorRepeats N` should tighten both reads at once, or the two
        // numbers stop being comparable.
        let repeats = repeats ?? AdvisorDiagnostics.repeats
        let context = PersistenceStack.scratch
        let service = TaskAdvisorService()
        var verdicts: [Verdict] = []

        for fixture in AdvisorDiagnostics.fixtures where !fixture.expectGateQuiet {
            let (task, among) = fixture.build(context)
            var facts = TaskAdvisorFacts.make(task: task, among: among)
            facts.relatedLines = await TaskAdvisorService.relatedLines(for: facts, among: among)
            let claimedDeep = AdvisorRouting.budget(for: facts) == .deep

            let ceilingSample = await modal(
                fixture: fixture.name, rung: ceiling, facts: facts, service: service,
                repeats: repeats)
            let candidateSample = await modal(
                fixture: fixture.name, rung: candidate, facts: facts, service: service,
                repeats: repeats)
            verdicts.append(
                Verdict(
                    fixture: fixture.name, ceiling: ceilingSample, candidate: candidateSample,
                    claimedDeep: claimedDeep))
        }
        return verdicts
    }

    /// The MODAL answer across repeats, not the first one.
    ///
    /// The judgment eval already learned this the hard way: at temperature 0.5 the same
    /// prompt and binary returned 5/8, 6/8, 7/8 and 6/8 across four runs. Comparing one
    /// sample from each rung would attribute coin flips to model capability, which is the
    /// mistake this whole file exists to avoid making at a larger scale.
    private static func modal(
        fixture: String, rung: IntelligenceRung, facts: TaskAdvisorFacts,
        service: TaskAdvisorService, repeats: Int
    ) async -> Sample? {
        var samples: [Sample] = []
        for _ in 0..<repeats {
            let started = Date()
            // Presence-time budget on both arms: the benchmark compares JUDGMENT quality,
            // so giving the ceiling rung a longer clock than the product will actually give
            // it would measure a configuration that never ships.
            let outcome = await service.read(facts, rung: rung, presenceTime: true)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            guard case .success(let reading) = outcome else { continue }
            samples.append(
                Sample(
                    fixture: fixture, rung: rung, move: reading.move,
                    abstained: reading.recommendation == nil,
                    observationLength: reading.observation.count, latencyMs: latency))
        }
        guard !samples.isEmpty else { return nil }
        // Most frequent move wins; ties break towards the first seen, which is arbitrary
        // and fine — a tie IS the instability signal, and the report prints the spread.
        let counts = Dictionary(grouping: samples, by: \.move).mapValues(\.count)
        let winner = counts.max { $0.value < $1.value }?.key
        return samples.first { $0.move == winner }
    }

    /// The report — routing as an OUTPUT, printed as one.
    static func report(_ verdicts: [Verdict]) -> String {
        guard !verdicts.isEmpty else { return "\n(benchmark: no non-gated fixtures)\n" }
        var lines = ["", "── Advisor Judgment Benchmark ──"]

        let measured = verdicts.filter { $0.ceiling != nil && $0.candidate != nil }
        if measured.isEmpty {
            lines.append(
                "no rung produced a reading — the ceiling is unmeasured, so nothing below")
            lines.append(
                "it can be said to have earned anything. Run on a host with both rungs.")
            lines.append("────────────────────────────────")
            return lines.joined(separator: "\n") + "\n"
        }

        for verdict in verdicts {
            let claim = verdict.claimedDeep ? "deep" : "shallow"
            let ceilingMove = verdict.ceiling?.move?.rawValue ?? "—"
            let candidateMove = verdict.candidate?.move?.rawValue ?? "—"
            var flag = verdict.matched ? "match" : "diverge"
            if verdict.overClaimed { flag = "OVER-CLAIMED — cheap rung matched the ceiling" }
            if verdict.underClaimed { flag = "UNDER-CLAIMED — cheap rung diverged" }
            lines.append(
                "\(verdict.fixture.padding(toLength: 38, withPad: " ", startingAt: 0))"
                    + "claim \(claim.padding(toLength: 8, withPad: " ", startingAt: 0))"
                    + "ceiling \(ceilingMove.padding(toLength: 12, withPad: " ", startingAt: 0))"
                    + "cheap \(candidateMove.padding(toLength: 12, withPad: " ", startingAt: 0))"
                    + flag)
        }

        // The number the whole method exists to produce: how much of the hard band
        // measurably needs depth. Not a target — an observation.
        let needsDepth = measured.filter { !$0.matched }
        let share = Int((Double(needsDepth.count) / Double(measured.count) * 100).rounded())
        lines.append("")
        lines.append(
            "measured \(measured.count) fixture(s) · \(needsDepth.count) genuinely need depth "
                + "(\(share)%) — this is an OUTPUT, not a target")

        let over = verdicts.filter(\.overClaimed)
        let under = verdicts.filter(\.underClaimed)
        if !over.isEmpty {
            lines.append(
                "→ \(over.count) case(s) claim depth and did not earn it: consider narrowing "
                    + "AdvisorRouting.depthReason")
        }
        if !under.isEmpty {
            lines.append(
                "→ \(under.count) case(s) were routed shallow and diverged from the ceiling: "
                    + "widen the band — this costs the product more than overspending does")
        }

        // The depth guardrail, measured rather than asserted. If the stronger rung's
        // observations are systematically longer, "better judgment, never more text" has
        // stopped being true and the clamp needs tightening.
        let ceilingLengths = verdicts.compactMap { $0.ceiling?.observationLength }
        let candidateLengths = verdicts.compactMap { $0.candidate?.observationLength }
        if !ceilingLengths.isEmpty, !candidateLengths.isEmpty {
            let avg = { (xs: [Int]) in xs.reduce(0, +) / xs.count }
            lines.append(
                "depth guardrail: observation length ceiling \(avg(ceilingLengths))c vs "
                    + "cheap \(avg(candidateLengths))c — depth must not mean length")
        }
        lines.append("────────────────────────────────")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Verification seam: `-AdvisorBenchmark` runs the gold-standard-first comparison and
    /// prints the report. Non-destructive (scratch context, nothing commits), DEBUG-only,
    /// and safe to re-run.
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-AdvisorBenchmark") else { return }
        print("=== ADVISOR JUDGMENT BENCHMARK ===")
        print("ceiling rung available: \(CloudModel.isAvailable)")
        if !CloudModel.isAvailable {
            print(
                "no cloud provider installed — the ceiling cannot be measured on this host, "
                    + "and a benchmark without a ceiling is not a benchmark. Reporting anyway "
                    + "so the shape is reviewable.")
        }
        let verdicts = await run()
        print(report(verdicts))
        print("=== END ADVISOR JUDGMENT BENCHMARK ===")
    }
}
#endif
