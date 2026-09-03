//
//  Learned.swift
//  Project-Ezra
//
//  **One learner over the human's verdicts.** (G3 — the second audit; finishes F-10)
//
//  Two learners had grown the same rule: `CorrectionProfile` ("the same correction twice
//  becomes a rule, cap eight") over confirm-card edits, and `AdvisorPreferences` ("the
//  same decline twice becomes a preference") over dismissed readings. One idea, two
//  inputs — and `HumanVerdicts.collect` already existed to hand both inputs over in one
//  vocabulary. This is that idea, once: verdicts in, learned rules out, one threshold, one
//  cap, one renderer of instruction lines.
//
//  What stays where it was: `CorrectionProfile` keeps the word-level helpers
//  (`significantWords`, `singleWordSubstitution`) and its `rules(from corrections:)` entry
//  point as a thin adapter, because every capture caller already speaks it. What is
//  deleted: `AdvisorPreferences`, and the second place the verdict store was read.
//
//  The guardrail is the learning loop's own: **required attention goes down, never up.**
//  A rule needs the same "no" twice; a mood is not a preference. Capture rules only ever
//  touch AI-produced fields; Advisor preferences only ever change the SHAPE of help, never
//  ask for more text.
//

import Foundation

enum Learned {

    /// The same signal this many times before it counts. Shared by every rule shape.
    static let threshold = 2

    /// The most rules a profile carries. Instruction length is latency; a rule the model
    /// never needs is a tax on every call.
    static let cap = 8

    /// Days of Advisor verdicts that count as "lately".
    static let preferenceWindowDays = 30

    // MARK: - Capture rules (from changed draft fields)

    /// Aggregate verdicts into learned capture rules. `tasks` supplies titles for keyword
    /// extraction. Frequency-sorted, thresholded, capped, stable.
    static func rules(from verdicts: [HumanVerdict], tasks: [TaskItem], limit: Int = cap) -> [LearnedRule] {
        let titlesByUUID = Dictionary(
            uniqueKeysWithValues: tasks.compactMap { task in task.uuid.map { ($0, task.title) } })

        var counts: [LearnedRule: (count: Int, latest: Date)] = [:]
        func bump(_ rule: LearnedRule, at date: Date) {
            let prior = counts[rule] ?? (0, .distantPast)
            counts[rule] = (prior.count + 1, max(prior.latest, date))
        }

        for verdict in verdicts {
            guard verdict.verdict == .changed, case .draftField(let taskID, let field) = verdict.subject,
                let userValue = verdict.to
            else { continue }
            let aiValue = verdict.from ?? ""
            switch field {
            case "category":
                // The lesson isn't "Health ⇒ Personal" wholesale — it's keyed to the
                // task's own words, so it only fires on similar tasks.
                guard let taskID, let title = titlesByUUID[taskID] else { continue }
                for word in CorrectionProfile.significantWords(title) {
                    bump(.categoryOverride(keyword: word, category: userValue), at: verdict.at)
                }
            case "owner":
                let spoken = aiValue.lowercased()
                // Only alias name→name; "you" isn't a person the engine heard.
                guard spoken != "you", userValue.lowercased() != "you", !userValue.isEmpty else { continue }
                bump(.ownerAlias(spoken: spoken, actual: userValue), at: verdict.at)
            case "title":
                // Learn only the crisp case: a single-word substitution.
                if let (from, to) = CorrectionProfile.singleWordSubstitution(ai: aiValue, user: userValue) {
                    bump(.titleRewrite(from: from, to: to), at: verdict.at)
                }
            case "effort", "effortMinutes":
                guard let taskID, let title = titlesByUUID[taskID],
                    let minutes = Int(userValue.filter(\.isNumber)), minutes > 0
                else { continue }
                for word in CorrectionProfile.significantWords(title) {
                    bump(.effortForKeyword(keyword: word, minutes: minutes), at: verdict.at)
                }
            case "urgent", "isUrgent":
                guard ["true", "1", "yes", "urgent"].contains(userValue.lowercased()),
                    let taskID, let title = titlesByUUID[taskID]
                else { continue }
                for word in CorrectionProfile.significantWords(title) {
                    bump(.urgentForKeyword(keyword: word), at: verdict.at)
                }
            default:
                continue
            }
        }

        return
            counts
            .filter { $0.value.count >= threshold }
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                if $0.value.latest != $1.value.latest { return $0.value.latest > $1.value.latest }
                // Stable final tie-break — dictionary order must never decide.
                return String(describing: $0.key) < String(describing: $1.key)
            }
            .prefix(limit)
            .map(\.key)
    }

    // MARK: - Advisor preferences (from declined readings)

    /// How many readings of each shape the person declined inside the window.
    static func declinedMoveCounts(
        in verdicts: [HumanVerdict], within days: Int = preferenceWindowDays, now: Date = Date()
    ) -> [String: Int] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var counts: [String: Int] = [:]
        for verdict in verdicts where verdict.verdict == .declined && verdict.at >= cutoff {
            guard case .reading = verdict.subject, let move = verdict.move else { continue }
            counts[move, default: 0] += 1
        }
        return counts
    }

    /// The INTERNAL lines the Advisor's model reads. Depth is not length — a preference
    /// never asks for more text, only for a different shape of help.
    static func advisorPreferences(
        from verdicts: [HumanVerdict], within days: Int = preferenceWindowDays, now: Date = Date()
    ) -> [String] {
        advisorPreferences(declined: declinedMoveCounts(in: verdicts, within: days, now: now))
    }

    static func advisorPreferences(declined: [String: Int]) -> [String] {
        var lines: [String] = []
        for move in AdvisorMove.allCases {
            guard let count = declined[move.rawValue], count >= threshold else { continue }
            switch move {
            case .createSteps:
                lines.append(
                    "the person has declined \(count) step breakdowns recently — prefer one piece of advice over steps unless steps are plainly the only help"
                )
            case .decide:
                lines.append(
                    "the person has declined \(count) option framings recently — name the one thing that would settle it rather than laying out choices"
                )
            case .advise:
                lines.append(
                    "the person has declined \(count) pieces of advice recently — say nothing unless the observation is sharper than what they can already see"
                )
            case .openBlocker:
                lines.append(
                    "the person has declined \(count) blocker prompts recently — mention the blocker only if it is the whole story"
                )
            case .nothing:
                continue
            }
        }
        return lines
    }

    // MARK: - Instruction lines

    /// Capture rules as instruction text for the model; nil when empty.
    static func instructionLines(_ rules: [LearnedRule]) -> String? {
        guard !rules.isEmpty else { return nil }
        let lines = rules.map { rule in
            switch rule {
            case .categoryOverride(let keyword, let category):
                return "- Tasks mentioning “\(keyword)” belong in the \(category) category."
            case .ownerAlias(let spoken, let actual):
                return "- When the user says “\(spoken)”, the person they mean is \(actual)."
            case .titleRewrite(let from, let to):
                return "- The user prefers “\(to)” over “\(from)” in task titles."
            case .effortForKeyword(let keyword, let minutes):
                return "- Tasks mentioning “\(keyword)” usually take about \(minutes) minutes for this user."
            case .urgentForKeyword(let keyword):
                return "- Tasks mentioning “\(keyword)” are urgent for this user."
            }
        }
        return "Corrections this user has taught you — apply them:\n" + lines.joined(separator: "\n")
    }
}
