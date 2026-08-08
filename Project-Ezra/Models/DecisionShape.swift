//
//  DecisionShape.swift
//  Project-Ezra
//
//  Does this wording read as a CHOICE? The one decision lexicon, shared by every
//  consumer that needs the question answered.
//
//  This exists because Decision is no longer a stored work-intent (axis 2 collapsed to
//  action | planning — a product decision, 2026-08-08). Choice-ness is now noticed at
//  read time: the Thinking Partner triggers on the `needsDecision` flag OR on wording
//  that reads as a choice, and the stall detector's "really a decision" rung reads the
//  same lexicon. One vocabulary, hoisted from `IntentResolver`, so widening it in one
//  place widens every consumer together.
//
//  Deliberately NEVER reads `isJudgmentCall` or `needsDecision` — wording only. The
//  flag is axis 3 (an obligation a human discharges); this is a lexical observation.
//

import Foundation

enum DecisionShape {

    /// Does the title describe choosing between options?
    static func reads(title: String) -> Bool {
        let lower = title.lowercased()
        // Phrases first: "figure out if" and "figure out how" are different questions
        // and share a stem, so word-level matching can't separate them.
        if phrases.contains(where: lower.contains) { return true }
        return !words.isDisjoint(with: CorrectionProfile.significantWords(title))
    }

    /// Phrase-level signals ("figure out how" belongs to planning, not here).
    static let phrases = [
        "should i", "should we", "figure out if", "figure out whether", "decide whether",
        "pick between", "choose between", "worth it",
    ]

    static let words: Set<String> = ["decide", "decision", "choose", "whether"]
}
