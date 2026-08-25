//
//  TodayPlanServiceTests.swift
//  Project-EzraTests
//
//  Regression guard for the capacity-tap crash, kept after the provider swap because the
//  invariant it protects outlived the provider that taught it to us.
//
//  Originally: `PrivateCloudComputeLanguageModel` FATAL-ERRORED (an uncatchable trap) the
//  instant it was constructed without the ungranted private-cloud-compute entitlement,
//  and `todayPlan` builds its routing decision by asking `cloudAvailable()` — which used
//  to construct the model, so EVERY capacity tap trapped.
//
//  Now: the cloud rung is `GeminiProvider`, whose `isAvailable` is "has Firebase been
//  configured in this process". `AppDelegate` deliberately does NOT configure it under a
//  test host, so the rung stays dormant and routing must still fall through to the
//  deterministic tail. Same assertion, different mechanism — and the reason to keep it is
//  that a rung which quietly became reachable during a suite would make these tests issue
//  live, billable, network-dependent Gemini calls instead of testing routing.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Today plan service")
struct TodayPlanServiceTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 24 * 3600) }

    @Test("The cloud rung is dormant in the test host — Firebase is never configured")
    func cloudRungDormantUnderTest() {
        #expect(Project_EzraApp.isHostingUnitTests)
        #expect(CloudModel.isAvailable == false)
    }

    @Test("The installed cloud provider is Gemini — swapping it is a deliberate act")
    func installedProviderIsGemini() {
        // Pins the slot's default. `CloudModel.provider` is a `var` so diagnostics and
        // tests can substitute; this catches an accidental reassignment leaking into
        // production, and makes a real provider change show up as an edit here.
        #expect(CloudModel.provider.identifier == "gemini-flash")
        #expect(GeminiProvider.modelName == "gemini-3.7-flash")
    }

    @Test("todayPlan degrades to deterministic when the cloud rung is dormant, never trapping")
    func todayPlanDegradesWithDormantCloudRung() async throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()

        // `cloudAvailable()` used to construct the PCC model to read `.isAvailable`, which
        // trapped without the entitlement. It now asks whether Firebase is configured,
        // which it is not under a suite. With no cloud rung and no on-device model (test
        // host), the chain must collapse to the deterministic tail.
        let overdue = TaskItem(
            title: "Renew car insurance", status: .todo, dueDate: days(-2), isUrgent: true)
        let dueToday = TaskItem(
            title: "Submit the expense report", status: .todo, dueDate: now)
        let all = [overdue, dueToday]
        let request = TodayPlanRequest.make(
            candidateItems: all, allTasks: all, recapCount: 0, typicalCompleted: nil, now: now)

        let plan = await brain.todayPlan(for: request, in: context)
        #expect(plan.tier == .deterministic)
        #expect(!plan.actions.isEmpty)
        #expect(plan.actions.count == request.fallbackCount)

        // The generation is logged as one `.ai` "planned" entry — a record, but neither
        // reversible nor inbox-visible: it is the app's own background work, not an
        // action anyone took, and there is no undo arm that could honour the button.
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let planned = entries.filter { $0.action == ChangeLogEntry.plannedAction }
        #expect(planned.count == 1)
        #expect(planned.allSatisfy { $0.initiatedBy == .ai })
        #expect(planned.allSatisfy { !$0.isReversible })
        #expect(planned.allSatisfy { !$0.isActivityVisible })
    }

    @Test("Concurrent generations serialize — the shared per-day session is never re-entered")
    func concurrentGenerationsSerialize() async throws {
        // The bug this pins, found on device with `-BriefDiagnostics`:
        //
        //   [TodayPlan] tier onDevice failed: Error: You attempted to call a respond
        //   method a second time before the first call completed. This is a programmer
        //   error.
        //
        // `briefSession(for:)` caches ONE `BriefSession` per dayKey so the advisor keeps a
        // transcript across a delta re-entry — so two overlapping generations reach the
        // same `LanguageModelSession`, which Foundation Models rejects. The on-device tier
        // then throws and the Brief quietly serves its deterministic tail. Reachable
        // without anything unusual: the self-heal regenerates in the BACKGROUND while a
        // cached briefing is on screen, and a mid-day recompose can land on top.
        let context = TestStore.makeContext()
        let brain = AppBrain()
        let all = [
            TaskItem(title: "Renew car insurance", status: .todo, dueDate: days(-2), isUrgent: true),
            TaskItem(title: "Submit the expense report", status: .todo, dueDate: now),
        ]
        let request = TodayPlanRequest.make(
            candidateItems: all, allTasks: all, recapCount: 0, typicalCompleted: nil, now: now)

        async let first = brain.todayPlan(for: request, in: context)
        async let second = brain.todayPlan(for: request, in: context)
        let plans = await [first, second]

        #expect(plans.count == 2)
        #expect(plans.allSatisfy { !$0.actions.isEmpty }, "a queued generation still owes a plan")
        // THE assertion. Return values cannot distinguish a serialized run from an
        // overlapping one — both callers get plans either way, which is exactly why the
        // first (broken) fix passed this test before the peak counter existed.
        #expect(brain.planGate.peakActive <= 1, "two generations overlapped on a shared session")
    }

    @Test("The gate wraps the WORK, not the wait — the distinction the first fix got wrong")
    func serialGateSerializesOverlappingWork() async {
        // The regression test for the fix itself. The original implementation stored a
        // task that only awaited its predecessor, so every gate completed instantly and
        // callers ran concurrently anyway. With real async work inside, that shape lets
        // `peakActive` reach 2; the correct one holds it at 1.
        let gate = SerialGate()
        var order: [Int] = []

        async let a: Void = gate.run {
            order.append(1)
            try? await Task.sleep(for: .milliseconds(60))
            order.append(2)
        }
        async let b: Void = gate.run {
            order.append(3)
            try? await Task.sleep(for: .milliseconds(10))
            order.append(4)
        }
        _ = await (a, b)

        #expect(gate.peakActive == 1, "the second body started before the first finished")
        // Strict ordering falls out of that: the first body completes before the second
        // begins, so its two marks are adjacent.
        #expect(order == [1, 2, 3, 4])
    }

    @Test("The gate returns each caller its OWN result, not the first one's")
    func serialGateDoesNotShareResults() async {
        // Queueing must not collapse into de-duplication. A delta recompose is a
        // genuinely different request against a changed day; handing it the earlier
        // caller's answer would be a subtler bug than the one being fixed.
        let gate = SerialGate()
        async let a = gate.run { "first" }
        async let b = gate.run { "second" }
        let results = await [a, b]
        #expect(Set(results) == ["first", "second"])
    }
}
