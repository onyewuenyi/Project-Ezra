//
//  CaptureSessionPool.swift
//  Project-Ezra
//
//  Prewarmed, single-use model sessions for the capture parse. Sessions were built
//  cold inside every triage call — and the rolling cadence chains a parse per
//  ~1.2s of continuous input, each paying construction plus prefill of a ~2.5KB
//  instruction block the anonymous `ModelWarmup` session never warmed.
//
//  The shape is a one-deep pool, NOT a continuous session (deliberate:
//  `LanguageModelSession` accrues transcript across turns, so re-sending the
//  growing ramble into one session would compound tokens — the continuous-session
//  upgrade is separately deferred in CLAUDE.md alongside `DynamicInstructions`).
//  `take` hands out the spare when its FINGERPRINT (instructions + roster, which
//  fold in personalization and the person tool) still matches, then immediately
//  builds and prewarms the next spare — parse N's generation overlaps parse N+1's
//  prewarm, so every chained parse in a burst starts on a warm session. Each
//  session serves exactly one respond/stream call.
//
//  Generic over the session type with an injected builder: the real builder
//  constructs a `LanguageModelSession` and prewarms the true instruction prefix
//  (`FoundationModelsEngine.sessionPool`), which cannot exist under XCTest — the
//  pool's fingerprint/reuse contract is tested with a dummy. This is the
//  coordinator-compatible shape (audit A2): if an app-wide ModelCoordinator lands,
//  this becomes its capture arm unchanged.
//

import Foundation

@MainActor
final class CaptureSessionPool<Session> {

    /// What makes a prepared session reusable: the exact instruction text (which
    /// folds in personalization and the tool-usage paragraph) and the roster the
    /// person tool was constructed over.
    struct Fingerprint: Equatable {
        let instructions: String
        let roster: [String]

        init(instructions: String, roster: [RosterPerson]) {
            self.instructions = instructions
            self.roster = roster.map { "\($0.name)|\($0.relationship)" }
        }
    }

    private let build: (TriageContext) -> Session
    private var spare: (session: Session, fingerprint: Fingerprint)?
    /// DEBUG evidence for the diagnostics footer: how often the pool actually serves.
    private(set) var hits = 0
    private(set) var misses = 0

    init(build: @escaping (TriageContext) -> Session) {
        self.build = build
    }

    /// The session for this parse — the prewarmed spare when its fingerprint still
    /// matches, a cold build otherwise (first parse after a personalization or
    /// roster change). Either way the NEXT spare starts warming immediately, under
    /// the fingerprint just requested.
    func take(context: TriageContext, fingerprint: Fingerprint) -> Session {
        defer { prepare(context: context, fingerprint: fingerprint) }
        if let spare, spare.fingerprint == fingerprint {
            self.spare = nil
            hits += 1
            return spare.session
        }
        misses += 1
        return build(context)
    }

    /// Build and prewarm the spare for `fingerprint` if it isn't already waiting —
    /// called at composer-present (the sheet animation absorbs the cost) and after
    /// every `take`.
    func prepare(context: TriageContext, fingerprint: Fingerprint) {
        guard spare?.fingerprint != fingerprint else { return }
        spare = (build(context), fingerprint)
    }

    /// Test seam / availability-change reset.
    func drain() {
        spare = nil
        hits = 0
        misses = 0
    }
}
