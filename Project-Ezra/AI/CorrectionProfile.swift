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
    /// Tasks mentioning `keyword` take about `minutes` — the user set the estimate on
    /// similar tasks twice ("mow…" → 60 min). Fills an EMPTY estimate only. (F-05)
    case effortForKeyword(keyword: String, minutes: Int)
    /// Tasks mentioning `keyword` are urgent to this person — flagged twice. (F-05)
    case urgentForKeyword(keyword: String)
}

enum CorrectionProfile {

    /// Aggregate raw correction rows into learned rules. `tasks` supplies titles
    /// for keyword extraction (a `Correction` links its task by uuid). Frequency-
    /// sorted, threshold ≥ 2, capped at `limit`.
    /// Aggregate raw correction rows into learned rules — the capture-side entry point,
    /// now an adapter: corrections become verdicts (`HumanVerdicts.collect`) and one
    /// learner (`Learned.rules`) does the counting for capture and the Advisor alike.
    static func rules(
        from corrections: [Correction], tasks: [TaskItem], limit: Int = Learned.cap
    ) -> [LearnedRule] {
        Learned.rules(from: HumanVerdicts.collect(corrections: corrections), tasks: tasks, limit: limit)
    }

    /// The rules as instruction text for the on-device model; nil when empty.
    static func instructionLines(_ rules: [LearnedRule]) -> String? { Learned.instructionLines(rules) }

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
    nonisolated static func significantWords(_ text: String) -> Set<String> {
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
