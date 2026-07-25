//
//  WorkIntentClassifier.swift
//  Project-Ezra
//
//  Work intent is computed, cached, and REFRESHABLE — never permanent. When a task's
//  title/notes change materially, or its structure changes (it gains/loses a child or a
//  blocker), the cached `WorkIntent` may be stale (a "planning" task that just got
//  decomposed shouldn't stay "planning"), so the detail re-classifies via this on-device
//  service. Off-device / under tests it returns nil and the caller leaves the cached
//  value untouched.
//
//  Constitutional guard: this path NEVER reads or writes `needsDecision` —
//  `resolveDecision()` stays the only clearer. (Asserted in `WorkIntentTests`.)
//
//  ⚠️ Device-verify: the `@Generable` classification. The simulator returns nil.
//

import Foundation
import FoundationModels

@Generable
struct WorkIntentClassification {
    @Guide(
        description:
            "Exactly one of: action, decision, planning, reference. Use decision ONLY when the task is choosing between options."
    )
    let workIntent: String
}

/// The value snapshot a re-classification needs, so the call is Sendable.
struct WorkIntentContext: Sendable {
    var title: String
    var notes: String?
    var hasChildren: Bool
    var isBlocked: Bool

    init(task: TaskItem, among all: [TaskItem]) {
        title = task.title
        notes = task.notes
        isBlocked = task.hasActiveBlockers(among: all)
        if let selfID = task.uuid {
            hasChildren = all.contains { $0.parentTaskID == selfID }
        } else {
            hasChildren = false
        }
    }
}

struct WorkIntentClassifier {
    /// Re-classify on-device. Returns nil off-device, under tests, or on failure — the
    /// caller then leaves the cached `workIntent` unchanged (never clobbers with nil).
    func classify(_ context: WorkIntentContext) async -> WorkIntent? {
        guard AppBrain.onDeviceModelAvailable() else { return nil }
        let session = LanguageModelSession(instructions: Self.instructions)
        guard
            let result = try? await session.respond(
                to: Self.prompt(context), generating: WorkIntentClassification.self
            ).content
        else { return nil }
        return WorkIntent(rawValue: result.workIntent.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static let instructions = """
        You classify a single task by the KIND of work it represents: action (a concrete
        thing to do), decision (a choice between options), planning (figuring out an
        approach or breaking something down), or reference (a note to keep, not really a
        to-do). Answer with exactly one word.
        Use "decision" ONLY when the task is genuinely choosing between options.
        There is NO "waiting" kind: being blocked is a separate axis the app derives
        from the task graph, so classify blocked work by what it actually is.
        """

    private static func prompt(_ context: WorkIntentContext) -> String {
        var lines = ["TASK: \(context.title)"]
        if let notes = context.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        if context.hasChildren { lines.append("It has been broken into sub-steps.") }
        if context.isBlocked { lines.append("It is currently waiting on something.") }
        return lines.joined(separator: "\n")
    }
}
