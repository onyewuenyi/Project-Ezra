//
//  AttentionEngineTests.swift
//  Project-EzraTests
//
//  The Reasoning layer: attention is a computed system score over SLOW-MOVING inputs
//  only. These pin the composition, the caps/clamps, the importance carry-forward, and
//  — most importantly — that the score never reads a fast-moving fact (overdue/blocked),
//  which is what keeps the persist-slow / compute-fast split honest.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Attention engine")
struct AttentionEngineTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("An unscored task reads the neutral default (35, no contributors)")
    func neutralDefault() {
        let task = TaskItem(title: "plain", status: .todo)
        #expect(task.attention == .neutral)
        #expect(task.attention.score == 35)
    }

    @Test("Composition sums base + urgent + importance + effort shape")
    func composition() {
        let task = TaskItem(title: "x", status: .todo, isUrgent: true, effortMinutes: 10)
        let meta = AttentionEngine.metadata(for: task, among: [task], aiImportance: 0.5, now: now)
        // 35 base + 30 urgent + round(0.5×20)=10 + 5 quick-win effort = 80.
        #expect(meta.score == 80)
        #expect(meta.contributors.contains { $0.kind == .urgentSignal && $0.points == 30 })
        #expect(meta.contributors.contains { $0.kind == .aiImportance && $0.points == 10 })
        #expect(meta.contributors.contains { $0.kind == .effortShape && $0.points == 5 })
    }

    @Test("Effort shape: ≤15m earns +5, ≤60m earns +2, larger earns nothing")
    func effortBands() {
        func score(_ minutes: Int) -> Double {
            let t = TaskItem(title: "e", status: .todo, effortMinutes: minutes)
            return AttentionEngine.metadata(for: t, among: [t], aiImportance: nil, now: now).score
        }
        #expect(score(15) == 40)  // 35 + 5
        #expect(score(60) == 37)  // 35 + 2
        #expect(score(120) == 35)  // no bonus
    }

    @Test("The score clamps to 0…100 even when every contributor fires")
    func clampsToHundred() {
        let target = TaskItem(title: "hub", status: .todo, isUrgent: true, effortMinutes: 5)
        // Four open dependents → centrality caps at +18 (three), not +24.
        let deps = (0..<4).map {
            TaskItem(title: "d\($0)", status: .todo, blockedBy: [target.uuid!])
        }
        let all = [target] + deps
        let meta = AttentionEngine.metadata(for: target, among: all, aiImportance: 1.0, now: now)
        // 35 + 30 + 20 + 5 + 18 = 108 → clamped to 100.
        #expect(meta.score == 100)
        #expect(meta.contributors.contains { $0.kind == .graphCentrality && $0.points == 18 })
    }

    @Test("Graph centrality is +6 per open direct dependent")
    func centralityPerDependent() {
        let target = TaskItem(title: "hub", status: .todo)
        let d1 = TaskItem(title: "d1", status: .todo, blockedBy: [target.uuid!])
        let d2 = TaskItem(title: "d2", status: .todo, blockedBy: [target.uuid!])
        let all = [target, d1, d2]
        let meta = AttentionEngine.metadata(for: target, among: all, aiImportance: nil, now: now)
        #expect(meta.score == 35 + 12)
        // A resolved dependent no longer counts.
        d2.complete(now: now)
        let after = AttentionEngine.metadata(for: target, among: all, aiImportance: nil, now: now)
        #expect(after.score == 35 + 6)
    }

    @Test("AI importance is carried forward when a fresh estimate isn't supplied")
    func importanceCarryForward() {
        let task = TaskItem(title: "x", status: .todo)
        task.attention = AttentionEngine.metadata(for: task, among: [task], aiImportance: 0.6, now: now)
        #expect(task.attention.carriedImportance == 0.6)
        // A later recompute with no importance keeps the earlier contribution.
        AttentionEngine.recompute([task], among: [task], now: now)
        #expect(task.attention.contributors.contains { $0.kind == .aiImportance && $0.points == 12 })
        #expect(task.attention.score == 35 + 12)
    }

    @Test("The score never reads a fast-moving fact — flipping overdue/blocked leaves it identical")
    func fastFactsAbsent() {
        let task = TaskItem(title: "x", status: .todo, isUrgent: true, effortMinutes: 30)
        let before = AttentionEngine.metadata(for: task, among: [task], aiImportance: 0.4, now: now)

        // Make it overdue and blocked — neither is an attention input.
        task.dueDate = now.addingTimeInterval(-10 * 24 * 3600)
        task.addExternalBlocker("waiting on the world", among: [task])
        let after = AttentionEngine.metadata(for: task, among: [task], aiImportance: 0.4, now: now)

        #expect(after.score == before.score)
    }
}
