//
//  AdvisorDiagnostics.swift
//  Project-Ezra
//
//  `-AdvisorDiagnostics` — the judgment-quality eval, the real acceptance test for the
//  Advisor: "would a competent human agree this is the most useful next move given the
//  facts?" A curated table of task states with expected moves runs through the ACTIVE
//  path (gate → model → validation) and prints expected vs actual to stdout, readable
//  headlessly over the cable (the `-CaptureDiagnostics` pattern).
//
//  Non-destructive by construction: fixtures are built in the in-memory scratch
//  context, nothing commits, safe to re-run. Under XCTest / no model, every worthy
//  case reports the fallback — the run is only meaningful on device (or a sim whose
//  host has Apple Intelligence on; read the engine line, don't assume).
//
//  Deterministic-half expectations (the gate rows) are ALSO pinned in
//  `CapabilityTests`; this harness exists for the half only a real model answers —
//  move choice, abstention behavior, and the `nothing` frequency.
//

#if DEBUG
import CoreData
import Foundation
import FoundationModels

@MainActor
enum AdvisorDiagnostics {

    struct Fixture {
        let name: String
        let expected: Set<AdvisorMove>
        /// nil = the gate itself should answer (deterministic silence).
        let expectGateQuiet: Bool
        /// The facts genuinely favour no option, so a recommendation is WRONG here —
        /// scored, not merely printed: without this, `decide` + an invented pick passes
        /// a fixture that exists to say "don't recommend". A product principle only
        /// counts once it is a behavioural contract.
        let expectAbstention: Bool
        let build: (NSManagedObjectContext) -> (TaskItem, [TaskItem])

        init(
            _ name: String, expected: Set<AdvisorMove> = [], gateQuiet: Bool = false,
            abstains: Bool = false,
            build: @escaping (NSManagedObjectContext) -> (TaskItem, [TaskItem])
        ) {
            self.name = name
            self.expected = expected
            self.expectGateQuiet = gateQuiet
            self.expectAbstention = abstains
            self.build = build
        }
    }

    static let fixtures: [Fixture] = [
        Fixture("simple executable task", gateQuiet: true) { context in
            let task = TaskItem(
                title: "Call the dentist", status: .todo, effortMinutes: 15, in: context)
            return (task, [task])
        },
        Fixture("resolved task", gateQuiet: true) { context in
            let task = TaskItem(title: "Should we move to Lisbon", status: .todo, in: context)
            task.needsDecision = true
            task.complete()
            return (task, [task])
        },
        Fixture("repeated deferral, decision-shaped", expected: [.decide]) { context in
            let task = TaskItem(
                title: "Decide which pediatrician to switch to", status: .todo, in: context)
            task.deferralCount = 4
            return (task, [task])
        },
        Fixture("broad complex task", expected: [.createSteps]) { context in
            let task = TaskItem(
                title: "Renovate the kitchen", status: .todo, effortMinutes: 120,
                in: context)
            task.notes = "Cabinets, counters, and the leaking sink"
            return (task, [task])
        },
        Fixture("actively blocked task", expected: [.openBlocker, .advise]) { context in
            let task = TaskItem(title: "Fix the boiler", status: .todo, in: context)
            let blocker = TaskItem(
                title: "Get the replacement part quote", status: .todo, in: context)
            task.addTaskBlocker(blocker.uuid!, among: [task, blocker])
            task.deferralCount = 3
            return (task, [task, blocker])
        },
        Fixture("in progress, ready to continue", expected: [.advise, .nothing]) { context in
            let task = TaskItem(
                title: "Write the school application", status: .doing, effortMinutes: 60,
                in: context)
            return (task, [task])
        },
        Fixture("ambiguous decision — abstention expected", expected: [.decide], abstains: true) {
            context in
            let task = TaskItem(title: "Pick between the two schools", status: .todo, in: context)
            task.needsDecision = true
            task.isJudgmentCall = true
            return (task, [task])
        },
        Fixture("stalled with no other signal", expected: [.advise, .nothing]) { context in
            let task = TaskItem(title: "Sort the garage", status: .todo, in: context)
            task.deferralCount = 5
            return (task, [task])
        },
    ]

    /// How many times each fixture runs. Three is the smallest number that can
    /// distinguish "usually" from "once" — a majority needs two, and two-of-two cannot
    /// tell a stable answer from a coin flip that landed twice. Raise it with
    /// `-AdvisorRepeats N` when a tuning decision needs a tighter read; each extra pass
    /// costs roughly eight seconds per worthy fixture.
    static var repeats: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-AdvisorRepeats"), args.indices.contains(i + 1),
            let n = Int(args[i + 1]), n > 0
        else { return 3 }
        return n
    }

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-AdvisorDiagnostics") else { return }
        print("=== ADVISOR DIAGNOSTICS ===")
        print("model available: \(AppBrain.onDeviceModelAvailable())")
        // Which capabilities this silicon actually has. `availability == .available` says
        // there IS a model; it does not say the model can do what a profile asks of it,
        // and the difference between those two is invisible until a call fails. Printed
        // because every Advisor generation on this device returned `unsupportedCapability`
        // while availability read healthy — the profile requests something the hardware
        // does not offer, and guessing which one costs a device round-trip per guess.
        let caps = SystemLanguageModel.default.capabilities
        print(
            "capabilities: reasoning=\(caps.contains(.reasoning)) "
                + "guidedGeneration=\(caps.contains(.guidedGeneration)) "
                + "toolCalling=\(caps.contains(.toolCalling)) vision=\(caps.contains(.vision))")
        print(
            "advisor profile asks for: reasoningLevel="
                + String(describing: CapabilityProfiles.taskAdvisor.reasoningLevel))
        // BOTH arms, over the SAME fixtures, in the same run — Challenge 8's A/B, made
        // readable. "Spend aggressively on the Advisor" is only a defensible position if
        // the spend can be shown to buy move-quality, and the only way to show that is
        // identical task states judged on-device and on cloud side by side. If cloud
        // wins the hard band, spend freely there and the per-generation cost is noise
        // against the value. If it doesn't, the ~$0 ladder IS the product — and that is
        // a fine answer, arrived at with data rather than instinct.
        await runArm(.onDevice)
        if CloudModel.isAvailable {
            await runArm(.cloud)
        } else {
            print("\n(cloud arm skipped — no provider installed; CloudModel.provider is inert)")
        }
        print("=== END ADVISOR DIAGNOSTICS ===")
    }

    /// Score every fixture on one rung. Extracted so the two arms cannot drift: the
    /// fixtures, the repeat count, the majority rule and the agreement definition are
    /// shared by construction, and the ONLY difference between the arms is where
    /// generation happened.
    private static func runArm(_ rung: IntelligenceRung) async {
        print("\n── arm: \(rung == .cloud ? CloudModel.label : "on-device") ──")
        let context = PersistenceStack.scratch
        let service = TaskAdvisorService()
        var agreements = 0
        var judged = 0
        var unstable = 0

        for fixture in fixtures {
            let (task, among) = fixture.build(context)
            let worthy = TaskCapabilities.advisorWorthy(for: task, among: among)

            if fixture.expectGateQuiet {
                let verdict = worthy ? "✗ expected gate-quiet, gate opened" : "✓ gate-quiet"
                if !worthy { agreements += 1 }
                judged += 1
                print("\(fixture.name): \(verdict)")
                continue
            }
            guard worthy else {
                judged += 1
                print("\(fixture.name): ✗ gate closed (expected \(fixture.expected))")
                continue
            }

            var facts = TaskAdvisorFacts.make(task: task, among: among)
            facts.relatedLines = await TaskAdvisorService.relatedLines(
                for: facts, among: among)

            // REPEATED, because one sample of a stochastic system is an anecdote. At
            // temperature 0.5 this eval returned 5/8, 6/8, 7/8 and 6/8 across four runs —
            // and two of those had byte-identical prompts and binaries. Reading a single
            // run as a measurement credited prompt edits with movement that was noise,
            // which is exactly the mistake this harness exists to prevent.
            var moves: [String] = []
            var agreedCount = 0
            var times: [Int] = []
            var observation = ""
            var failure: String?

            for _ in 0..<repeats {
                let started = Date()
                let outcome = await service.read(facts, rung: rung)
                times.append(Int(Date().timeIntervalSince(started) * 1000))

                switch outcome {
                case .success(let reading):
                    // Agreement is the move AND, where the facts favour nobody, the
                    // abstention. A confident pick on an ambiguous decision is a miss even
                    // when the move is right.
                    let abstained = reading.recommendation == nil
                    let agreed =
                        fixture.expected.contains(reading.move)
                        && (!fixture.expectAbstention || abstained)
                    if agreed { agreedCount += 1 }
                    moves.append(reading.move.rawValue + (abstained ? "" : "*"))
                    if observation.isEmpty { observation = reading.observation }
                case .unavailable:
                    failure = "no model (fallback path); run on device"
                case .timedOut:
                    failure = "timed out — the salvage tripwire"
                    moves.append("timeout")
                case .cancelled:
                    failure = "cancelled"
                case .failed(let label):
                    failure = "failed (\(label))"
                    moves.append("error")
                }
            }
            judged += 1
            // A fixture counts as agreed only on a MAJORITY, so a lucky single hit does
            // not read as a pass.
            let majority = agreedCount * 2 > repeats
            if majority { agreements += 1 }
            if agreedCount > 0, !majority { unstable += 1 }
            if agreedCount == 0, repeats > 1, Set(moves).count > 1 { unstable += 1 }

            let expected = fixture.expected.map(\.rawValue).sorted().joined(separator: "/")
            let spread = times.isEmpty ? "—" : "\(times.min()!)–\(times.max()!)ms"
            var line =
                "\(fixture.name): \(majority ? "✓" : "✗") \(agreedCount)/\(repeats) "
                + "[\(moves.joined(separator: ", "))] (expected \(expected), \(spread))"
            if let failure { line += " — \(failure)" }
            print(line)
            if !observation.isEmpty { print("    “\(observation)”") }
        }
        print("agreement: \(agreements)/\(judged) fixtures (majority of \(repeats) runs each)")
        if unstable > 0 {
            // The number that says whether the eval can be trusted to guide a tuning
            // decision at all. A fixture that flips between runs is not evidence — and it
            // is the first thing to check before reading a difference BETWEEN arms as
            // real, since two unstable arms can differ by luck alone.
            print("unstable: \(unstable) fixture(s) gave different answers across runs")
        }
    }
}
#endif
