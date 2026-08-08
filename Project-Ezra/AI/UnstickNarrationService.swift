//
//  UnstickNarrationService.swift
//  Project-Ezra
//
//  The voice of the inertia capability. `StallDetector` decides WHETHER and WHY a task
//  stalled — deterministically, and that never changes here. This service only PHRASES
//  the diagnosis over the task's own facts, because the stalled moment is where trust
//  is won: a static template on its third viewing reads as a scold on repeat, while
//  "the passport office was the blocker; that cleared two weeks ago" removes the
//  re-orientation cost at exactly the moment the user must choose resume / defer / kill.
//
//  Restate-only (the householdNarrative pattern): the instructions forbid inventing
//  facts, and any non-success falls back to the deterministic headline — so the card
//  still renders identically off-device, minus voice. Never persisted; fresh per visit.
//
//  ⚠️ Device-verify: the `@Generable` phrasing and its tone. The simulator may or may
//  not exercise it (it follows the host's Apple Intelligence).
//

import Foundation
import FoundationModels

@Generable
struct UnstickNarration: Sendable {
    @Guide(
        description:
            "ONE plain sentence (two at most) saying why this task has stalled, using only the given facts. Reporting, never scoring."
    )
    let sentence: String
}

/// The deterministic facts the phrasing may use — a value, so the call is Sendable
/// and the prompt is a pure function of it (pinned by `UnstickNarrationTests`).
struct UnstickFacts: Sendable, Equatable {
    var title: String
    var diagnosis: StallDiagnosis
    var deferralCount: Int
    var quietDays: Int
    var blockerTitles: [String]
    var effortMinutes: Int?

    init(task: TaskItem, diagnosis: StallDiagnosis, among all: [TaskItem], now: Date = Date()) {
        title = task.title
        self.diagnosis = diagnosis
        deferralCount = Int(task.deferralCount)
        quietDays = max(0, Int(now.timeIntervalSince(task.humanTouchedAt) / 86_400))
        blockerTitles = task.activeBlockerTasks(among: all).map(\.title)
        effortMinutes = task.effortMinutes
    }

    init(
        title: String, diagnosis: StallDiagnosis, deferralCount: Int, quietDays: Int,
        blockerTitles: [String] = [], effortMinutes: Int? = nil
    ) {
        self.title = title
        self.diagnosis = diagnosis
        self.deferralCount = deferralCount
        self.quietDays = quietDays
        self.blockerTitles = blockerTitles
        self.effortMinutes = effortMinutes
    }
}

struct UnstickNarrationService {
    /// Phrase the diagnosis, bounded by `ModelDeadline.cardSeconds` (the card is on
    /// screen). Any non-success arm means the deterministic headline stays — there is
    /// deliberately no retry affordance, because the template IS the content and a
    /// voice that didn't arrive is not a failure the user needs to manage.
    func narrate(_ facts: UnstickFacts) async -> ModelResult<String> {
        let outcome = await ModelRun.perform(
            .unstickNarration, deadline: ModelDeadline.cardSeconds
        ) {
            let session = LanguageModelSession(instructions: Self.instructions)
            return try await session.respond(
                to: Self.prompt(facts), generating: UnstickNarration.self
            ).content
        }
        return outcome.map { $0.sentence.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static let instructions = """
        You phrase, in one calm sentence (two at most), WHY a person's task has stalled,
        so re-engaging with it costs them nothing. You are given the diagnosis and the
        facts; your job is wording, never judgment.

        Hard rules:
        - Restate ONLY the given facts. Never invent a blocker, a date, a number, or a
          consequence that is not in them.
        - The DIAGNOSIS is fixed. You may not soften it into a different one.
        - Reporting, never scoring: no streaks, no guilt, no pep talk, no exclamation
          marks, no emoji. Never call the person lazy or busy.
        - Do not tell them what to do — the card's buttons do that.
        """

    /// Pure fact lines — the whole prompt, pinned by tests so the facts the model may
    /// use are exactly the facts the detector used.
    static func prompt(_ facts: UnstickFacts) -> String {
        var lines = ["TASK: \(facts.title)"]
        switch facts.diagnosis {
        case .blocked:
            lines.append("DIAGNOSIS: waiting on something else")
        case .tooBig:
            lines.append("DIAGNOSIS: too big to start")
        case .reallyADecision:
            lines.append("DIAGNOSIS: worded as a choice, not a doable step")
        case .dying:
            lines.append("DIAGNOSIS: repeatedly set aside")
        }
        if facts.deferralCount > 0 {
            lines.append(
                "Set aside \(facts.deferralCount) time\(facts.deferralCount == 1 ? "" : "s") in a row")
        }
        if facts.quietDays > 0 { lines.append("No touch in \(facts.quietDays) days") }
        if !facts.blockerTitles.isEmpty {
            lines.append("Waiting on: " + facts.blockerTitles.joined(separator: "; "))
        }
        if let effort = facts.effortMinutes { lines.append("Estimated ~\(effort) min") }
        return lines.joined(separator: "\n")
    }
}
