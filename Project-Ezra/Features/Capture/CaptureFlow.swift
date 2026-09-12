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
//  The plan encodes every rule the submit path enforces, in order of precedence:
//  1. **The posture outranks the router** (F-03): on-device never transmits.
//  2. **One thought + a model + on-device posture** runs the private engine.
//  3. Otherwise the device-first router decides (`CaptureRoute.route`), voice-aware (F-02).
//  4. A local read earns the thinking beat only when SPOKEN; typed structure reveals instantly.
//

import Foundation

enum CaptureFlow {

    /// Which arm interprets, and how the reveal is paced.
    enum Arm: Equatable, Sendable {
        /// Typed structure: the deterministic read, revealed on the next frame.
        case revealInstantly
        /// A spoken capture the deterministic read handled: the read, after the orb's beat.
        case revealAfterDwell
        /// On-device posture, one thought, a model present: the single-thought engine.
        case privateEngine
        /// The authority: the orb holds while the cloud (or its degrade) reads.
        case authority(CaptureEscalationReason?)
    }

    struct SubmitPlan: Equatable, Sendable {
        let route: CaptureRoute
        let escalation: CaptureEscalationReason?
        let arm: Arm
    }

    /// The decision, from everything known at submit.
    static func plan(
        text: String, localRead: [TaskDraft], fromVoice: Bool, posture: CapturePosture,
        privateModelAvailable: Bool
    ) -> SubmitPlan {
        if posture == .onDevice {
            if privateModelAvailable, !PrivateCaptureEngine.soundsLikeSeveralThings(text) {
                return SubmitPlan(route: .local, escalation: nil, arm: .privateEngine)
            }
            return SubmitPlan(
                route: .local, escalation: nil, arm: fromVoice ? .revealAfterDwell : .revealInstantly)
        }
        let decision = CaptureRoute.route(for: text, localRead: localRead, fromVoice: fromVoice)
        switch decision.route {
        case .cloud:
            return SubmitPlan(route: .cloud, escalation: decision.escalation, arm: .authority(decision.escalation))
        case .local:
            return SubmitPlan(
                route: .local, escalation: nil, arm: fromVoice ? .revealAfterDwell : .revealInstantly)
        }
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
        for text: String, learned: [LearnedRule] = [],
        posture: CapturePosture = .current(), now: Date = Date()
    ) -> (route: CaptureRoute, escalation: CaptureEscalationReason?) {
        guard posture != .onDevice else { return (.local, nil) }
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
