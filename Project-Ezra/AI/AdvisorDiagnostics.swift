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

@MainActor
enum AdvisorDiagnostics {

    struct Fixture {
        let name: String
        let expected: Set<AdvisorMove>
        /// nil = the gate itself should answer (deterministic silence).
        let expectGateQuiet: Bool
        let build: (NSManagedObjectContext) -> (TaskItem, [TaskItem])

        init(
            _ name: String, expected: Set<AdvisorMove> = [], gateQuiet: Bool = false,
            build: @escaping (NSManagedObjectContext) -> (TaskItem, [TaskItem])
        ) {
            self.name = name
            self.expected = expected
            self.expectGateQuiet = gateQuiet
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
        Fixture("ambiguous decision — abstention expected", expected: [.decide]) { context in
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

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-AdvisorDiagnostics") else { return }
        print("=== ADVISOR DIAGNOSTICS ===")
        print("model available: \(AppBrain.onDeviceModelAvailable())")
        let context = PersistenceStack.scratch
        let service = TaskAdvisorService()
        var agreements = 0
        var judged = 0

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
            let started = Date()
            let outcome = await service.read(facts)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            judged += 1

            switch outcome {
            case .success(let reading):
                let agreed = fixture.expected.contains(reading.move)
                if agreed { agreements += 1 }
                var line =
                    "\(fixture.name): \(agreed ? "✓" : "✗") \(reading.move.rawValue) "
                    + "(expected \(fixture.expected.map(\.rawValue).sorted().joined(separator: "/")), \(ms)ms)"
                if reading.move == .decide {
                    line +=
                        reading.recommendation.map { " · recommended “\($0.label)”" }
                        ?? " · abstained"
                }
                print(line)
                print("    “\(reading.observation)”")
            case .unavailable:
                print("\(fixture.name): — no model (fallback path); run on device")
            case .timedOut:
                print("\(fixture.name): ✗ timed out (\(ms)ms) — the salvage tripwire")
            case .cancelled:
                print("\(fixture.name): — cancelled")
            case .failed(let label):
                print("\(fixture.name): ✗ failed (\(label))")
            }
        }
        print("agreement: \(agreements)/\(judged)")
        print("=== END ADVISOR DIAGNOSTICS ===")
    }
}
#endif
