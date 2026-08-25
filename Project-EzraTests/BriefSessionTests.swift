//
//  BriefSessionTests.swift
//  Project-EzraTests
//
//  The deterministic halves of the advisor session: the context budget, the
//  yesterday digest, the tool detail index, and the delta block's place in the
//  prompt. The session itself (reasoning, tool calls, the live delta turn) is model
//  behavior — device-pass territory, never fake-tested here.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Advisor session — deterministic halves")
struct BriefSessionTests {

    @Test("The context budget floors, ceilings, and fills the real window")
    func budget() {
        // Tiny window → floor, huge window → ceiling, middle → proportional.
        #expect(AdvisorContextBudget.candidateCount(overheadTokens: 3000, contextSize: 4096) == 8)
        #expect(AdvisorContextBudget.candidateCount(overheadTokens: 800, contextSize: 32768) == 24)
        // 2400 − 600 − 1200 = 600 → 15 candidates: proportional, inside the clamps.
        let mid = AdvisorContextBudget.candidateCount(overheadTokens: 600, contextSize: 2400)
        #expect(mid == 15)
        // Unknown context size → the fixed cap, never garbage.
        #expect(
            AdvisorContextBudget.candidateCount(overheadTokens: 0, contextSize: 0)
                == TodayPlanRequest.candidateCap)
    }

    @Test("The yesterday digest reports counts and names, and stays nil with nothing to say")
    func digest() {
        let context = TestStore.makeContext()
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!

        #expect(YesterdayDigest.make(tasks: [], logs: [], now: now) == nil)

        let slid = TaskItem(title: "Renew passport", status: .todo, in: context)
        slid.lastSurfacedAt = yesterday
        slid.deferralCount = 2
        let carried = TaskItem(title: "Book flights", status: .todo, in: context)
        carried.lastSurfacedAt = yesterday
        let log = CapacityLog(
            date: yesterday, capacity: .steady, planCount: 4, completedCount: 3, skippedCount: 1)

        let digest = YesterdayDigest.make(tasks: [slid, carried], logs: [log], now: now)!
        #expect(digest.contains("Yesterday: 3 completed."))
        #expect(digest.contains("Carried into today: Book flights."))
        #expect(digest.contains("Slid without a touch: Renew passport."))
    }

    @Test("The tool index serves candidate ids only, falling back to the fact line")
    func detailIndex() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Fix the gutter", status: .todo, in: context)
        task.notes = "Ladder is in the garage"
        let request = TodayPlanRequest.make(
            candidateItems: [task], allTasks: [task], recapCount: 0,
            typicalCompleted: nil, now: Date())
        let index = BriefSession.detailIndex(for: request)
        #expect(index.count == 1)
        let detail = index[task.uuid!.uuidString.lowercased()]!
        #expect(detail.contains("Ladder is in the garage"))
    }

    @Test("A delta turn leads the prompt and demands the complete plan")
    func deltaPrompt() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Call the vet", status: .todo, in: context)
        var request = TodayPlanRequest.make(
            candidateItems: [task], allTasks: [task], recapCount: 2,
            typicalCompleted: nil, now: Date())
        request.deltaContext = "SINCE THIS MORNING: completed 2 of this morning's plan."
        let prompt = TodayPlanPrompt.body(for: request)
        #expect(prompt.hasPrefix("SINCE THIS MORNING:"))
        #expect(prompt.contains("Return the COMPLETE updated plan"))
        #expect(prompt.contains("CANDIDATE TASKS"))
    }
}
