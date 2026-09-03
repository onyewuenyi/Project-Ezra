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
}
