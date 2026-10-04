//
//  CaptureFlow.swift
//  Project-Ezra
//
//  **The capture arc's decisions, out of the view.** (G5 — the second audit, first cut)
//
//  `ComposerView` is the largest file in the tree because the capture arc — submit →
//  route → parse → dwell → propose → reveal — is a state machine that happens to be
//  written inside a SwiftUI view. This file is the first extraction: the SUBMIT DECISION
//  as a pure function of what is known at submit time, so the branch the view takes is
//  a tested value rather than a nest of conditions with comments explaining why each
//  must not animate. The view still owns `RamblePhase`, the parse task and the
//  interpretation; those follow once Ramble's loop sits on `Inquiry`, so the move happens
//  once.
//
//  The plan encodes every rule the submit path enforces, in order of precedence. Capture
//  reads on the device only (2026-10-04), so there is no posture and no route to decide:
//  1. **A model + a doubtful piece**: the judge (`CaptureJudge`) says what each doubtful
//     piece is; the app re-splits and sets aside only what it can validate.
//  2. **A model + ONE thought the read could not land** (nothing drafted, or a spoken
//     detail it could not resolve): the single-thought engine.
//  3. Otherwise the deterministic read is the interpretation. A SPOKEN capture earns the
//     thinking beat; typed text reveals instantly.
//

import Foundation

enum CaptureFlow {

    /// Which arm interprets, and how the reveal is paced.
    enum Arm: Equatable, Sendable {
        /// Typed text the read handled: the deterministic read, revealed on the next frame.
        case revealInstantly
        /// A spoken capture the deterministic read handled: the read, after the orb's beat.
        case revealAfterDwell
        /// One thought the read could not land, a model present: the single-thought engine
        /// (`PrivateCaptureEngine`), which falls back to the read itself.
        case privateEngine
        /// A model is present and at least one piece of the read is doubtful: the
        /// on-device judge says what each doubtful piece is — a task, several, or nothing
        /// to do — and the app acts on the verdicts it can validate (`CaptureJudge`).
        /// A piece with no answer stays a card.
        case judge
    }

    struct SubmitPlan: Equatable, Sendable {
        let arm: Arm
    }

    /// The decision, from everything known at submit.
    ///
    /// `modelAvailable` is a REQUIRED parameter, and the reason is scar tissue: this
    /// codebase has twice shipped a capability decided by an unset default parameter — the
    /// candidate-blind capture prompt (a feature silently disabled for weeks, every test
    /// green) and `triage`'s `route:` defaulting to `.cloud` (a new user's first brain dump
    /// silently transmitted). A capability the caller does not name is a capability nobody
    /// is deciding about.
    static func plan(
        text: String, localRead: [TaskDraft], fromVoice: Bool, modelAvailable: Bool,
        duplicateCandidates: Bool
    ) -> SubmitPlan {
        let quiet = SubmitPlan(arm: fromVoice ? .revealAfterDwell : .revealInstantly)
        guard modelAvailable else { return quiet }
        // A doubtful piece, or a card with something close to it already on the list
        // (`CaptureDuplicates`): both are the judge arm's model pass.
        if duplicateCandidates || !CaptureJudge.doubtfulIndices(in: Segmentation.items(from: text)).isEmpty {
            return SubmitPlan(arm: .judge)
        }
        // The single-thought engine earns its seconds only on evidence the read fell
        // short, and only on the envelope it was measured on: one thought.
        if !PrivateCaptureEngine.soundsLikeSeveralThings(text),
            let evidence = CaptureEscalation.reason(for: text, drafts: localRead),
            evidence == .emptyRead || evidence == .unresolvedDetail
        {
            return SubmitPlan(arm: .privateEngine)
        }
        return quiet
    }

    /// The routing decision for a caller that has no composer around it — onboarding,
    /// and the diagnostic seams that run a canned ramble.
    ///
    /// It exists because those callers used to name no route at all, and `triage`'s
    /// default was `.cloud`: they claimed the transmitting rung and never asked the
    /// router. That is both a privacy hole (explicit structure the user typed reaching
    /// the network, which the policy would never do) and a quality one (a newline-
    /// separated dump handed to a model's segmentation instead of to the deterministic
    /// read that already has the boundaries).
    ///
    /// Same policy as `plan`, minus the presentation arm those callers have no use for:
    /// the persisted POSTURE outranks the router, and otherwise the deterministic read
    /// is computed first so `route(for:localRead:)` can judge it — which is the whole
    /// shape of device-first routing. `fromVoice` is false because none of these callers
    /// has a microphone.
    static func route(
        for text: String, learned: [LearnedRule] = [], now: Date = Date()
    ) -> (route: CaptureRoute, escalation: CaptureEscalationReason?) {
        let read = AppBrain.provisionalDrafts(text, learned: learned, now: now)
        return CaptureRoute.route(for: text, localRead: read)
    }

    // MARK: - The "nothing actionable" way forward

    /// The longest a kept-as-said title may run before it is cut at a word boundary. A
    /// title is a NAME; past this the card would become a transcript viewer.
    static let keptTitleMaxLength = 96

    /// One task from a capture the read found nothing in — because the PERSON says it is
    /// one. "Nothing actionable in that" used to be a dead end: the only exits were to
    /// rewrite the words and Re-read, or to leave and let them park. But the person just
    /// told Ezra something they wanted to remember, and a system that answers "not a task"
    /// with no way to say "it is to me" has put its own reading above theirs.
    ///
    /// This is a USER act, not an AI proposal: it runs from a tap, lands through the
    /// user's own edit path (`Interpretation.editableDrafts`), and the title is the words
    /// as they were said. The resolver still backfills the rest (category, effort, owner,
    /// kind of work) so the card arrives populated like any other — the fields stay
    /// The outcome a capture NAMES for its own list — "Lagos trip: renew passport, book
    /// flights" — offered as the group alert's starting text, never applied on its own.
    /// Deterministic and narrow: the lead before the first colon, one to six words, and
    /// only when something follows it. Nil for everything else, so the field starts
    /// empty rather than with a guess.
    static func suggestedOutcomeTitle(from text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let lead = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lead.split(whereSeparator: \.isWhitespace)
        guard !rest.isEmpty, (1...6).contains(words.count) else { return nil }
        return lead
    }

    /// assumed and editable; only the existence of the task is the person's call.
    ///
    /// Nil when there is nothing to keep (whitespace only).
    static func keepAsOneTask(
        text: String, learned: [LearnedRule] = [], now: Date = Date()
    ) -> TaskDraft? {
        let collapsed =
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!-–— "))
        guard !collapsed.isEmpty else { return nil }
        var title = collapsed
        if title.count > keptTitleMaxLength {
            let cut = title.index(title.startIndex, offsetBy: keptTitleMaxLength)
            let head = title[..<cut]
            title =
                (head.lastIndex(of: " ").map { String(head[..<$0]) } ?? String(head))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!-–— "))
        }
        var intent = HeuristicEngine.intent(from: title)
        intent.action = .create
        intent.title = title
        intent.reasoning = "Kept as you said it."
        // The person vouched for it, so the "not sure this is a task" confidence class
        // must not follow it onto the card (that half is cleared at confirm anyway) or
        // into provenance as an engine judgment it never made.
        intent.confidence = 1
        // The resolver's title is kept as the AI original too: the person authored the
        // words, not a correction of them, so commit must not diff a phantom title edit
        // into the learning signal.
        return IntentResolver.resolve([intent], rules: learned, now: now).first
    }
}
