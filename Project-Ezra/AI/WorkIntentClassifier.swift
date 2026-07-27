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
struct WorkIntentClassification: Sendable {
    @Guide(
        description:
            "Exactly one of: action, decision, or planning. Use decision ONLY when the task is choosing between options."
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
    /// Re-classify on-device, bounded by `ModelDeadline.backgroundSeconds` — shorter than
    /// a card's deadline because the output is one word and nothing on screen is blocked
    /// waiting for it.
    ///
    /// Anything other than `.success` leaves the cached `workIntent` untouched; this path
    /// never clobbers a good value with a guess. A word outside the enum (the model
    /// reaching for a kind that no longer exists) is `noUsableOutput`, not a silent nil —
    /// otherwise a systematically wrong prompt would look exactly like a quiet model.
    func classify(_ context: WorkIntentContext) async -> ModelResult<WorkIntent> {
        let outcome = await ModelRun.perform(.workIntent, deadline: ModelDeadline.backgroundSeconds) {
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(
                to: Self.prompt(context), generating: WorkIntentClassification.self
            ).content
        }
        guard case .success(let result) = outcome else { return outcome.map { _ in .action } }
        let raw = result.workIntent.trimmingCharacters(in: .whitespaces).lowercased()
        guard let intent = WorkIntent(rawValue: raw) else {
            return .failed(ModelResult<WorkIntent>.noUsableOutput)
        }
        return .success(intent)
    }

    private static let instructions = """
        You classify a single task by the KIND of work it represents: action (a concrete
        thing to do), decision (a choice between options), or planning (figuring out an
        approach or breaking something down). Answer with exactly one word.
        Use "decision" ONLY when the task is genuinely choosing between options.
        There is NO "waiting" kind: being blocked is a separate axis the app derives
        from the task graph, so classify blocked work by what it actually is.
        There is NO "reference" kind either: a note worth keeping is still a task here,
        so classify it by what it asks of the person — usually "action".
        """

    private static func prompt(_ context: WorkIntentContext) -> String {
        var lines = ["TASK: \(context.title)"]
        if let notes = context.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        if context.hasChildren { lines.append("It has been broken into sub-steps.") }
        if context.isBlocked { lines.append("It is currently waiting on something.") }
        return lines.joined(separator: "\n")
    }
}
