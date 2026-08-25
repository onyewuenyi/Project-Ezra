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
    ///
    /// `"is it worth"` was added on 2026-08-22, when the narrower `"worth it"` was found
    /// to miss the far more common phrasing: "is it worth renewing the subscription" is
    /// the same question and matched nothing here.
    ///
    /// It was found because this lexicon briefly guarded a SAFETY property — an
    /// on-device capture gate escalated decision-shaped text so a values-laden decision
    /// could never be created without its `needsDecision` flag. That gate was measured
    /// and deleted, so the stakes are back to what they were: a miss means a Thinking
    /// Partner that fails to unlock, not a judgment call born unflagged. The wider
    /// lexicon is kept regardless — it was always the right answer, and the episode is
    /// worth remembering the next time something starts depending on this list.
    static let phrases = [
        "should i", "should we", "figure out if", "figure out whether", "decide whether",
        "pick between", "choose between", "worth it", "is it worth",
    ]

    static let words: Set<String> = ["decide", "decision", "choose", "whether"]
}
