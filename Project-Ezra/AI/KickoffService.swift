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
    /// The person's own words at capture, clipped — the one place the concrete detail
    /// ("need to find the old one first") usually lives, and the title never carries it.
    var spoken: String?
    /// Closed `.doing` visits in the stall window: how many times this was picked up
    /// and put back down. The strongest evidence that the obvious first move already
    /// failed once, so the next one should be smaller.
    var abandonedStarts: Int = 0

    /// Where the spoken line is cut — the first sentence or two is where the detail is.
    static let spokenClip = 200

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
        // A quote that only repeats the title says nothing the model lacks.
        let quote = task.rawCapture.trimmingCharacters(in: .whitespacesAndNewlines)
        spoken =
            quote.isEmpty || quote.caseInsensitiveCompare(task.title) == .orderedSame
            ? nil : TaskAdvisorFacts.clip(quote, to: Self.spokenClip)
        abandonedStarts = task.recentAbandonedStarts(within: StallDetector.quietThreshold, now: now)
    }

    init(
        title: String, notes: String? = nil, category: String, effortMinutes: Int? = nil,
        dueDescription: String? = nil, spoken: String? = nil, abandonedStarts: Int = 0
    ) {
        self.title = title
        self.notes = notes
        self.category = category
        self.effortMinutes = effortMinutes
        self.dueDescription = dueDescription
        self.spoken = spoken
        self.abandonedStarts = abandonedStarts
    }

    /// Every word the model was shown — what an emitted specific must be found in.
    var corpus: String {
        [title, notes ?? "", category, spoken ?? ""].joined(separator: "\n")
    }
}

struct KickoffService {
    /// One concrete first move, bounded by `ModelDeadline.cardSeconds` — the user just
    /// tapped Start and is looking at the button that changed under their thumb. Any
    /// non-success renders nothing: silence is the fallback, not an error state.
    func firstStep(_ facts: KickoffFacts) async -> ModelResult<String> {
        // The spare warmed while the Start button was on screen, if one is waiting —
        // the prefill already happened before the tap. Cold otherwise.
        let outcome = await ModelRun.perform(.kickoff, deadline: ModelDeadline.seconds(for: .card)) {
            let session =
                await InquiryService.shared.takeSpare(
                    instructions: Self.instructions, config: CapabilityProfiles.kickoff)
                ?? CapabilityProfiles.session(
                    instructions: Self.instructions, config: CapabilityProfiles.kickoff)
            return try await session.respond(
                to: Self.prompt(facts), generating: KickoffStep.self
            ).content
        }
        switch outcome {
        case .success(let step):
            // The instruction "never invent a number" is a hope; this is the check. A
            // step that names a specific the facts never held renders nothing — silence
            // was always the fallback, and a plausible wrong phone number is worse.
            guard let grounded = Self.validated(step.firstStep, against: facts) else {
                return .failed(ModelResult<String>.noUsableOutput)
            }
            return .success(grounded)
        case .unavailable: return .unavailable
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .failed(let label): return .failed(label)
        }
    }

    /// Warm a kickoff session while the Start button is on screen. Keyed on the
    /// instructions, so one spare serves whichever task is tapped; skipped when one is
    /// already waiting; a no-op off-device.
    static func prewarm() {
        InquiryService.shared.prewarmSpare(instructions: instructions, config: CapabilityProfiles.kickoff)
    }

    /// The trust boundary for the one line under the button. Trims; drops an empty
    /// step; drops a step carrying a SPECIFIC — a long digit run, a URL, an email — that
    /// is not in the facts the model was shown. Deterministic, pinned by `KickoffTests`.
    static func validated(_ raw: String, against facts: KickoffFacts) -> String? {
        let step = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !step.isEmpty else { return nil }
        let corpus = facts.corpus.lowercased()
        for specific in specifics(in: step) where !corpus.contains(specific.lowercased()) {
            return nil
        }
        return step
    }

    /// The tokens a first move should never mint: five or more digits in a row (a phone
    /// number, an account, a postcode), a web address, an email address.
    static func specifics(in text: String) -> [String] {
        let patterns = [
            #"\d[\d\-\s()]{4,}\d"#,
            #"(?i)\b(?:https?://|www\.)\S+"#,
            #"\S+@\S+\.\S+"#,
        ]
        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: range).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]) }
            }
        }
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
        - "They said" is the person's own words — the detail that names the real first
          move usually lives there, not in the title.
        - When the task was started before and put down, the obvious first move already
          failed once. Make this one smaller than that: a two-minute piece, not the job.
        """

    /// Pure fact lines, pinned by tests.
    static func prompt(_ facts: KickoffFacts) -> String {
        var lines = ["TASK: \(facts.title)", "Category: \(facts.category)"]
        if let notes = facts.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        if let effort = facts.effortMinutes { lines.append("Estimated ~\(effort) min") }
        if let due = facts.dueDescription { lines.append("Due: \(due)") }
        if let spoken = facts.spoken, !spoken.isEmpty { lines.append("They said: \(spoken)") }
        if facts.abandonedStarts > 0 {
            lines.append(
                "Started before and put down: \(facts.abandonedStarts) time\(facts.abandonedStarts == 1 ? "" : "s")"
            )
        }
        return lines.joined(separator: "\n")
    }
}
