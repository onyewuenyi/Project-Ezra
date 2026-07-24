//
//  CorrectionProfile.swift
//  Project-Ezra
//
//  Corrections are the product: every field the user fixed at the confirm glance
//  is a free labeled pair, and this is where those pairs become behavior. Pure
//  aggregation over `Correction` rows → a small set of learned rules that (a)
//  apply deterministically in the resolver — so the heuristic path, and thus the
//  simulator, learns too — and (b) render as instruction lines injected into the
//  Foundation Models session, so the on-device model generalizes from them.
//
//  Guardrails: a rule needs the same correction to happen at least TWICE (one-offs
//  are noise, not preference), the set is capped, and rules only ever touch fields
//  the engine actually produced. The loop must reduce required user attention over
//  time — never optimize for engagement.
//
//  (Sessions are created per triage call today, so plain instruction text is the
//  right injection point; `LanguageModelSession.DynamicInstructions` is the API to
//  adopt when the session becomes continuous.)
//

import Foundation

/// One learned preference, derived from repeated corrections.
enum LearnedRule: Equatable, Hashable {
    /// Tasks whose title mentions `keyword` belong in `category`
    /// ("gym…" corrected to Personal twice → gym ⇒ Personal).
    case categoryOverride(keyword: String, category: String)
    /// When the engine hears `spoken`, the user means `actual`
    /// ("mom" corrected to "Grandma" twice).
    case ownerAlias(spoken: String, actual: String)
    /// A word the user consistently rewrites ("doctor" → "pediatrician").
    case titleRewrite(from: String, to: String)
}

enum CorrectionProfile {

    /// Aggregate raw correction rows into learned rules. `tasks` supplies titles
    /// for keyword extraction (a `Correction` links its task by uuid). Frequency-
    /// sorted, threshold ≥ 2, capped at `limit`.
    static func rules(
        from corrections: [Correction], tasks: [TaskItem], limit: Int = 8
    ) -> [LearnedRule] {
        let titlesByUUID = Dictionary(
            uniqueKeysWithValues: tasks.compactMap { task in task.uuid.map { ($0, task.title) } })

        // Each candidate rule accumulates (count, latest) so ties break by recency.
        var counts: [LearnedRule: (count: Int, latest: Date)] = [:]
        func bump(_ rule: LearnedRule, at date: Date) {
            let prior = counts[rule] ?? (0, .distantPast)
            counts[rule] = (prior.count + 1, max(prior.latest, date))
        }

        for correction in corrections {
            switch correction.fieldCorrected {
            case "category":
                // The lesson isn't "Health ⇒ Personal" wholesale — it's keyed to the
                // task's own words, so it only fires on similar tasks.
                guard let uuid = correction.taskUUID, let title = titlesByUUID[uuid] else { continue }
                for word in significantWords(title) {
                    bump(
                        .categoryOverride(keyword: word, category: correction.userValue),
                        at: correction.createdAt)
                }
            case "owner":
                let spoken = correction.aiValue.lowercased()
                let actual = correction.userValue
                // Only alias name→name; "you" isn't a person the engine heard.
                guard spoken != "you", actual.lowercased() != "you", !actual.isEmpty else { continue }
                bump(.ownerAlias(spoken: spoken, actual: actual), at: correction.createdAt)
            case "title":
                // Learn only the crisp case: a single-word substitution.
                if let (from, to) = singleWordSubstitution(
                    ai: correction.aiValue, user: correction.userValue)
                {
                    bump(.titleRewrite(from: from, to: to), at: correction.createdAt)
                }
            default:
                continue
            }
        }

        return
            counts
            .filter { $0.value.count >= 2 }
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                if $0.value.latest != $1.value.latest { return $0.value.latest > $1.value.latest }
                // Stable final tie-break — dictionary order must never decide.
                return String(describing: $0.key) < String(describing: $1.key)
            }
            .prefix(limit)
            .map(\.key)
    }

    /// The rules as instruction text for the on-device model; nil when empty.
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
            }
        }
        return "Corrections this user has taught you — apply them:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// A single-word substitution between two titles, if that's the whole diff.
    static func singleWordSubstitution(ai: String, user: String) -> (from: String, to: String)? {
        let aiWords = ai.lowercased().split(separator: " ").map(String.init)
        let userWords = user.lowercased().split(separator: " ").map(String.init)
        guard aiWords.count == userWords.count, !aiWords.isEmpty else { return nil }
        let diffs = zip(aiWords, userWords).filter { $0 != $1 }
        guard diffs.count == 1, let diff = diffs.first else { return nil }
        return (diff.0, diff.1)
    }

    /// The same significant-word idiom the blocker matcher uses: lowercase,
    /// alphanumeric word split, stop-words and single characters dropped.
    static func significantWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !stopWords.contains($0) }
        )
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "my", "our", "your", "their", "his", "her", "its",
        "is", "are", "was", "be", "been", "get", "gets", "got", "getting",
        "to", "of", "for", "on", "in", "at", "up", "out", "with", "from",
        "it", "this", "that", "i", "we", "and", "or",
    ]
}
