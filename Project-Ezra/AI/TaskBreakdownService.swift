//
//  TaskBreakdownService.swift
//  Project-Ezra
//
//  "Break this down" — the capability that reduces COMPLEXITY. When a task is big or
//  compound, the detail can ask the on-device model to propose the steps it decomposes
//  into. Like the Thinking Partner it is generated on demand, shown, and discarded: the
//  proposal is never persisted, and nothing is created until the user accepts.
//
//  The split between this file and `BreakdownEligibility` is load-bearing. WHETHER to
//  offer a breakdown is deterministic, so it works in the simulator and for every user
//  with Apple Intelligence off. Only WHAT the steps are needs the model — so the card is
//  quietly absent off-device rather than broken, exactly like the Thinking Partner.
//
//  ⚠️ Device-verify: the `@Generable` schema and its latency. The simulator can't
//  exercise it, so `steps` returns nil there.
//

import Foundation
import FoundationModels

/// The proposed decomposition. Guided generation constrains the model to structuring
/// what it was given rather than inventing scope.
@Generable
struct TaskBreakdown: Sendable {
    @Guide(
        description:
            "The concrete steps this task decomposes into, 2 to 5. Each must be independently doable and drawn only from the task and its context — never invent scope the task doesn't imply."
    )
    let steps: [BreakdownStep]
}

@Generable
struct BreakdownStep: Sendable {
    @Guide(description: "A short imperative title for this step, at most 8 words.")
    let title: String

    @Guide(
        description:
            "Rough minutes for this step — one of 15, 30, 60, or 120. Use 15 for a quick call or message."
    )
    let effortMinutes: Int
}

/// The value snapshot a breakdown call needs. Sendable and context-free, mirroring
/// `DecisionContext`.
struct BreakdownContext: Sendable {
    var title: String
    var rawCapture: String
    var notes: String?
    var category: String
    /// The task's own estimate, when it has one — it bounds the sum of the steps.
    var effortMinutes: Int?

    init(task: TaskItem) {
        title = task.title
        rawCapture = task.rawCapture
        notes = task.notes
        category = task.category
        effortMinutes = task.effortMinutes
    }
}

struct TaskBreakdownService {

    /// How many steps a breakdown may propose. The cap is a product guardrail, not a
    /// model limit: a fifteen-step plan is a new source of overwhelm, which is the exact
    /// thing this capability exists to remove.
    static let maxSteps = 5

    /// Propose steps on demand, bounded by `ModelDeadline.cardSeconds` — the user tapped
    /// and is watching a spinner, so this must not be able to hang. Never persisted;
    /// nothing is created here.
    ///
    /// Returns a `ModelResult` rather than an optional so the card can tell "no model on
    /// this device" (draw nothing) from "the attempt failed" (offer a retry). Sanitizing
    /// to fewer than two steps is a `failed`, not a success: a response arrived, but a
    /// one-step "breakdown" is the task restated and there is nothing to accept.
    func steps(_ context: BreakdownContext) async -> ModelResult<[BreakdownStep]> {
        let outcome = await ModelRun.perform(.breakdown, deadline: ModelDeadline.cardSeconds) {
            let session = CapabilityProfiles.session(
                instructions: Self.instructions, config: CapabilityProfiles.breakdown)
            return try await session.respond(
                to: Self.prompt(for: context), generating: TaskBreakdown.self
            ).content
        }
        guard case .success(let result) = outcome else { return outcome.map { _ in [] } }
        let cleaned = Self.sanitize(result.steps)
        return cleaned.isEmpty ? .failed(ModelResult<[BreakdownStep]>.noUsableOutput) : .success(cleaned)
    }

    /// Anti-hallucination + guardrail pass, the same shape as the Today plan's
    /// `validated(against:)`: drop empties, de-duplicate, clamp effort to the bands the
    /// rest of the app speaks, and cap the count. It does NOT reorder — sequence is the
    /// model's contribution.
    static func sanitize(_ steps: [BreakdownStep]) -> [BreakdownStep] {
        var seen = Set<String>()
        var out: [BreakdownStep] = []
        for step in steps {
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 2 else { continue }
            let key = title.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(BreakdownStep(title: title, effortMinutes: clampEffort(step.effortMinutes)))
            if out.count == maxSteps { break }
        }
        // One step is not a breakdown — it is the task restated.
        return out.count >= 2 ? out : []
    }

    /// Snap to the bands the engines and the effort chip already use, so a step never
    /// shows an estimate the rest of the app can't render.
    private static func clampEffort(_ minutes: Int) -> Int {
        let bands = [15, 30, 60, 120]
        return bands.min { abs($0 - minutes) < abs($1 - minutes) } ?? 30
    }

    private static let instructions = """
        You break an over-large task into the concrete steps it actually consists of.

        Hard rules:
        - Every step must be independently doable, and phrased as an action.
        - Draw ONLY on the task and its context. Never invent scope, deadlines, people,
          or purchases the task doesn't imply.
        - Between 2 and 5 steps. If it genuinely only takes one step, return fewer than
          two and the app will show nothing — that is the correct answer for a small task.
        - Steps are sequential where order matters, otherwise listed as stated.
        - Plain and steady. No pep talk, no exclamation marks, no emoji.
        """

    private static func prompt(for context: BreakdownContext) -> String {
        var lines = ["TASK: \(context.title)", "Area: \(context.category)"]
        if !context.rawCapture.isEmpty { lines.append("They said: \(context.rawCapture)") }
        if let notes = context.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        if let effort = context.effortMinutes {
            lines.append("They estimated about \(effort) minutes in total.")
        }
        return lines.joined(separator: "\n")
    }
}
