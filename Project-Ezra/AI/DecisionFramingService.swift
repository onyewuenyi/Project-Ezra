//
//  DecisionFramingService.swift
//  Project-Ezra
//
//  The Thinking Partner (Decision Framing, P0). When a task is a genuine choice, the
//  detail's decision section can, on demand, ask the on-device model to FRAME it — the
//  options in play with their tradeoffs, the cost of not deciding, and (since
//  2026-08-08, a recorded reversal of "the AI frames, never recommends") which option
//  best fits the given facts. The RECOMMENDATION is contained three ways: it must name
//  one of the framing's own options verbatim (`groundedRecommendation` drops anything
//  else), it must ground its why in the given facts, and it never persists or resolves
//  — `resolveDecision()` stays the only clearer, so the human still decides.
//  The instructions forbid invention (the householdNarrative pattern); no tools.
//
//  ⚠️ Device-verify: the `@Generable` framing and its latency. The simulator can't
//  exercise it, so `frame` returns nil there and the UI shows the lighter card.
//

import Foundation
import FoundationModels

/// The framing output: the options and the cost of waiting. Constrained by guided
/// generation so the model can only structure what it's given, not pad it with invention.
@Generable
struct DecisionFraming: Sendable {
    @Guide(
        description:
            "The distinct options the person is choosing between, 2 to 4. Draw them only from the task and its context; never invent an option that isn't implied."
    )
    let options: [FramedOption]

    @Guide(
        description:
            "One plain sentence on the cost of NOT deciding — what waiting risks. Empty string if there is no real cost."
    )
    let costOfWaiting: String

    @Guide(
        description:
            "The label of the ONE option above that best fits the given facts, copied exactly. Empty string when the facts don't clearly favor one."
    )
    let recommendation: String

    @Guide(
        description:
            "One plain sentence on why that option fits, grounded only in the given facts. Empty when recommendation is empty."
    )
    let recommendationWhy: String

    /// The recommendation, but only when it actually names one of this framing's own
    /// options (case-insensitive). Anti-hallucination at the read: a recommendation
    /// pointing at an option that doesn't exist is dropped whole, never rendered.
    var groundedRecommendation: (label: String, why: String)? {
        let trimmed = recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let match = options.first(where: {
                $0.label.caseInsensitiveCompare(trimmed) == .orderedSame
            })
        else { return nil }
        return (match.label, recommendationWhy.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@Generable
struct FramedOption: Sendable {
    @Guide(description: "A short label for this option, at most 6 words.")
    let label: String

    @Guide(description: "One plain sentence on this option's key tradeoff.")
    let tradeoff: String
}

/// The value snapshot a framing call needs — the decision's provenance chain plus the
/// titles of related tasks — so the call is Sendable and context-free.
struct DecisionContext: Sendable {
    var title: String
    var reasoning: String
    var rawCapture: String
    var notes: String?
    /// The umbrella this decision is a step of, named EXPLICITLY (the objective-lite
    /// signal: "part of Plan the Italy trip" frames the options better than an
    /// undifferentiated related-title).
    var parentTitle: String?
    var relatedTitles: [String]

    init(task: TaskItem, among all: [TaskItem]) {
        title = task.title
        reasoning = task.reasoning
        rawCapture = task.rawCapture
        notes = task.notes
        parentTitle = task.parentTaskID.flatMap { parentID in
            all.first { $0.uuid == parentID }?.title
        }
        // Related-edge titles: children and active blockers give the model the
        // surrounding shape of the decision without dragging the graph.
        var related: [String] = []
        related.append(contentsOf: task.activeBlockerTasks(among: all).map(\.title))
        if let selfID = task.uuid {
            related.append(
                contentsOf: all.filter { $0.parentTaskID == selfID }.map(\.title))
        }
        relatedTitles = Array(Set(related)).sorted()
    }
}

struct DecisionFramingService {
    /// Frame a decision on demand, bounded by `ModelDeadline.cardSeconds`. Never
    /// persisted; it may recommend, and the human still resolves — see the header.
    ///
    /// Returns a `ModelResult` so the card can distinguish absence from failure: off
    /// device the Thinking Partner is not drawn at all, whereas a timed-out attempt owes
    /// the user a retry.
    func frame(_ context: DecisionContext) async -> ModelResult<DecisionFraming> {
        await ModelRun.perform(.decisionFraming, deadline: ModelDeadline.cardSeconds) {
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(
                to: Self.prompt(for: context), generating: DecisionFraming.self
            ).content
        }
    }

    private static let instructions = """
        You are a calm thinking partner helping someone see a decision clearly. You are
        given a task that is a genuine choice, plus its context. Lay out the OPTIONS in
        play, each with its main tradeoff, name the cost of not deciding, and — when the
        facts clearly favor one option — say which fits best and why.

        Hard rules:
        - Structure ONLY what the task and context imply. Never invent an option, a fact,
          a deadline, or a consequence that isn't there.
        - A recommendation must copy the label of one of YOUR OWN options exactly, and
          its why must cite only the given facts. When the facts don't clearly favor
          one option, leave recommendation empty — an honest "it's genuinely close" is
          more useful than a coin flip dressed as advice.
        - You never DECIDE — the person does. No pressure language.
        - Plain and steady. No pep talk, no exclamation marks, no emoji.
        - If there is genuinely no cost to waiting, return an empty costOfWaiting.
        """

    private static func prompt(for context: DecisionContext) -> String {
        var lines = ["DECISION: \(context.title)"]
        if !context.reasoning.isEmpty { lines.append("Why it's a decision: \(context.reasoning)") }
        if !context.rawCapture.isEmpty { lines.append("They said: \(context.rawCapture)") }
        if let notes = context.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        if let parent = context.parentTitle {
            lines.append("Part of the larger goal: \(parent)")
        }
        if !context.relatedTitles.isEmpty {
            lines.append("Related tasks: " + context.relatedTitles.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
