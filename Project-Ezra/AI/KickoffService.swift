//
//  KickoffService.swift
//  Project-Ezra
//
//  The first move, at the moment of commitment. The costliest instant in execution is
//  right after Start — the button relabels to "Mark done" and leaves the person alone
//  with a title like "Renew passport". On that tap (a deterministic trigger, and the
//  strongest "doing this now" signal in the app) the model produces the ONE concrete
//  first move from the task's own facts, rendered as a single quiet line under the
//  relabeled CTA. Fallback is silence: the button behaves identically without it.
//
//  Generative, not restate-only — the step is allowed to be a synthesis ("find the
//  DS-82 renewal form") — but the instructions forbid invented specifics: no phone
//  numbers, addresses, URLs, or names that aren't in the given facts. Never persisted.
//
//  ⚠️ Device-verify: the `@Generable` step and its usefulness on the real model.
//

import Foundation
import FoundationModels

@Generable
struct KickoffStep: Sendable {
    @Guide(
        description:
            "The single most concrete PHYSICAL first move for this task, at most 12 words. Draw only on the given facts; never invent a phone number, URL, address, or name."
    )
    let firstStep: String
}

/// The facts the step may draw on — a value, so the call is Sendable and the prompt is
/// a pure function of it (pinned by `KickoffTests`).
struct KickoffFacts: Sendable, Equatable {
    var title: String
    var notes: String?
    var category: String
    var effortMinutes: Int?
    var dueDescription: String?

    init(task: TaskItem, now: Date = Date()) {
        title = task.title
        notes = task.notes
        category = task.category
        effortMinutes = task.effortMinutes
        if let due = task.dueDate, let days = TaskItem.daysUntil(due, now: now) {
            dueDescription =
                days < 0
                ? "\(-days) day\(days == -1 ? "" : "s") overdue"
                : days == 0 ? "due today" : "due in \(days) day\(days == 1 ? "" : "s")"
        } else {
            dueDescription = nil
        }
    }

    init(
        title: String, notes: String? = nil, category: String, effortMinutes: Int? = nil,
        dueDescription: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.category = category
        self.effortMinutes = effortMinutes
        self.dueDescription = dueDescription
    }
}

struct KickoffService {
    /// One concrete first move, bounded by `ModelDeadline.cardSeconds` — the user just
    /// tapped Start and is looking at the button that changed under their thumb. Any
    /// non-success renders nothing: silence is the fallback, not an error state.
    func firstStep(_ facts: KickoffFacts) async -> ModelResult<String> {
        let outcome = await ModelRun.perform(.kickoff, deadline: ModelDeadline.seconds(for: .card)) {
            let session = CapabilityProfiles.session(
                instructions: Self.instructions, config: CapabilityProfiles.kickoff)
            return try await session.respond(
                to: Self.prompt(facts), generating: KickoffStep.self
            ).content
        }
        return outcome.map { $0.firstStep.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static let instructions = """
        Someone just committed to starting a task. Give them the ONE most concrete
        physical first move — the smallest real action that gets it underway. At most
        12 words. Plain and steady, no pep talk, no emoji.

        Hard rules:
        - Draw only on the given facts. NEVER invent a phone number, URL, address,
          time, or person's name that is not in them.
        - One move, not a plan. No numbered lists, no "then".
        - If the task is already a single concrete move, restate it smaller (the first
          physical piece of it), not bigger.
        """

    /// Pure fact lines, pinned by tests.
    static func prompt(_ facts: KickoffFacts) -> String {
        var lines = ["TASK: \(facts.title)", "Category: \(facts.category)"]
        if let notes = facts.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        if let effort = facts.effortMinutes { lines.append("Estimated ~\(effort) min") }
        if let due = facts.dueDescription { lines.append("Due: \(due)") }
        return lines.joined(separator: "\n")
    }
}
