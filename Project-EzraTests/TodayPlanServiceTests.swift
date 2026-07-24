//
//  TodayPlanServiceTests.swift
//  Project-EzraTests
//
//  Regression guard for the capacity-tap crash: `PrivateCloudComputeLanguageModel`
//  FATAL-ERRORS (an uncatchable trap) the instant it is constructed without the
//  ungranted `com.apple.developer.private-cloud-compute` entitlement. `todayPlan`
//  builds its routing decision by asking `pccAvailable()`, which used to construct the
//  model — so EVERY capacity tap trapped. The `PCCEntitlement` gate must keep the PCC
//  tier untouched and let routing fall through to the deterministic tail.
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

    @Test("The PCC entitlement is ungranted in the test host — the tier must stay dormant")
    func pccGateClosed() {
        #expect(PCCEntitlement.isGranted == false)
    }

    @Test("todayPlan degrades to deterministic without the PCC entitlement, never trapping")
    func todayPlanDegradesWithoutPCCEntitlement() async throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()

        // `pccAvailable()` used to construct the PCC model to read `.isAvailable`, which
        // traps without the entitlement. With no entitlement and no on-device model
        // (test host), the chain must collapse to the deterministic tail.
        let overdue = TaskItem(
            title: "Renew car insurance", status: .active, dueDate: days(-2), isUrgent: true)
        let dueToday = TaskItem(
            title: "Submit the expense report", status: .active, dueDate: now)
        let all = [overdue, dueToday]
        let request = TodayPlanRequest.make(
            candidateItems: all, allTasks: all, recapCount: 0, typicalCompleted: nil, now: now)

        let plan = await brain.todayPlan(for: request, in: context)
        #expect(plan.tier == .deterministic)
        #expect(!plan.actions.isEmpty)
        #expect(plan.actions.count == request.fallbackCount)

        // The generation is logged as one reversible `.ai` "planned" entry.
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(entries.contains { $0.action == "planned" && $0.initiatedBy == .ai })
    }
}
