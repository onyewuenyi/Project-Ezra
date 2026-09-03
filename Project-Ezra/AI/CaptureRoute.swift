//
//  CaptureRoute.swift
//  Project-Ezra
//
//  Which machinery produces the interpretation for a capture — and NOTHING about whether
//  that interpretation is trustworthy.
//
//  This exists as its own type because an earlier vocabulary ("certain" / "ambiguous")
//  quietly fused two different questions: *can we produce a useful reading without model
//  reasoning?* and *is that reading correct?* Only the first is answerable at submit, and
//  answering it made the second sound decided. The word "certain" then justified showing a
//  fallback read as final — which is how a four-errand dictation shipped as one task titled
//  with its own transcript.
//
//  **The routing policy is deliberately swappable and deliberately NOT architecture.** The
//  reveal boundary is the primitive: whatever produces the interpretation, it is final once
//  shown. Today the local path skips the model, but that must never calcify into "simple
//  inputs never use AI" — the model may one day beat the deterministic resolver even on a
//  one-liner ("Sarah's birthday gift" → knows who Sarah is, the event it belongs to, the
//  shopping it implies). When that day comes, `route(for:)` changes and nothing else does.
//

import Foundation
import FoundationModels

/// How this capture's interpretation gets produced. Two arms; since 2026-08-29, two
/// questions asked in order.
///
/// **The policy is "did the user draw the boundaries — and if not, did the instant
/// deterministic read visibly fall short?"** The first is a structural observation
/// (`Segmentation`); the second reads facts about an answer that already exists
/// (`CaptureEscalation`). Neither asks a model anything, so routing costs microseconds.
///
/// The lineage matters because two prior attempts at "keep it local" died on
/// measurement, and this one is shaped by their autopsies. `.singleThought` was a
/// lexicon TRUSTING a read it couldn't verify — false positives silently lost intent.
/// The on-device confidence gate asked a model a pre-parse meta-question — 2.3s of
/// pure overhead that escalated 95–100% of what it saw, slower than the network it
/// avoided. This policy inverts both failure modes: the local read is verified after
/// the fact, from evidence, and the verifier can only escalate — its false positives
/// cost a cloud call, never the user's words. The FM on-device model, measured
/// 2026-08-29 at p90 21s against the deterministic read's 2ms with no accuracy
/// advantage on this corpus, is out of the capture chain entirely (it remains the
/// Advisor's rung 2, where seconds-long judgment is the job).
enum CaptureRoute: String, Equatable, CaseIterable {

    /// The user gave us the boundaries, so there is no segmentation problem to solve.
    /// `Segmentation` reads the structure they typed and `HeuristicEngine` +
    /// `IntentResolver` fill the fields. Sub-frame — the measured pipeline p50 is 3ms —
    /// so the reveal lands without the orb ever appearing.
    case local

    /// The semantic authority. Receives the COMPLETE original text, never fragments,
    /// because boundaries are precisely what it is being asked for.
    case cloud

    /// The STRUCTURAL half of routing: did the user draw the boundaries? Still one
    /// line, still text-only — but since 2026-08-29 it is no longer the whole policy.
    /// `.cloud` from here means "a model COULD be needed"; whether one actually is
    /// belongs to `route(for:localRead:)`, which checks the deterministic read's own
    /// evidence first. Callers that only need the observation (seams, prints) may use
    /// this; the composer must not.
    static func route(for text: String) -> CaptureRoute {
        Segmentation.structure(of: text).isExplicit ? .local : .cloud
    }

    /// THE routing decision (2026-08-29): device-first, escalate on evidence.
    ///
    /// The 2026-08-22 policy sent every unstructured capture to the cloud, on the
    /// grounds that judging task boundaries is the semantic authority's job. What the
    /// owner reversed — deliberately, re-weighting capture's objectives — is the
    /// DEFAULT: the deterministic read runs first (it holds every eval floor at p90
    /// 2ms, measured on device 2026-08-29), and the capture transmits only when
    /// `CaptureEscalation` finds observable evidence that read fell short. Most
    /// captures now reveal instantly, privately, and for free; the hard tail still
    /// gets Gemini.
    ///
    /// What this is NOT is the deleted confidence gate returning: no model is asked
    /// anything before routing (the check is microseconds of string work over an
    /// answer that already exists), and the verifier can only ESCALATE — a wrong
    /// signal costs a cloud call, never a lost intent (see `CaptureEscalation`'s
    /// header for the asymmetry argument).
    ///
    /// Still no `budgetAllows` parameter, and still no availability input: a spend
    /// counter may not override an accuracy decision on the front door, and with no
    /// reachability input a dead cloud structurally cannot promote a local read into
    /// a transmission — escalated captures that find no reachable provider fall to
    /// the deterministic tail in `AppBrain.triage`.
    static func route(
        for text: String, localRead drafts: [TaskDraft], fromVoice: Bool = false
    ) -> (route: CaptureRoute, escalation: CaptureEscalationReason?) {
        // An empty read can't be revealed whatever the structure said — this arm
        // predates the verifier (the composer's old `local.isEmpty ? .cloud`), and it
        // outranks the explicit short-circuit for the same reason it always did.
        guard !drafts.isEmpty else { return (.cloud, .emptyRead) }
        // A SPOKEN capture that reads like a caught conversation escalates BEFORE the
        // explicit short-circuit (F-02): dictated sentence punctuation is not structure
        // the person drew, and only the authority may say "nothing here". Typed text
        // never takes this arm — the rule that typed structure never transmits stands.
        if fromVoice, CaptureEscalation.conversationSignal(in: text) { return (.cloud, .conversation) }
        guard !Segmentation.structure(of: text).isExplicit else { return (.local, nil) }
        if let reason = CaptureEscalation.reason(for: text, drafts: drafts) {
            return (.cloud, reason)
        }
        return (.local, nil)
    }

    var metricName: String { rawValue }

    /// `.local` is `.facts`: no model is consulted at all on that arm.
    var rung: IntelligenceRung { self == .cloud ? .cloud : .facts }

    /// Whether this route sends the user's raw words off the device.
    ///
    /// Its own property rather than `== .cloud` at the call sites, because this is the
    /// question the privacy boundary is written against and it should be asked by name.
    /// **Ramble's raw capture is the ONE sanctioned raw-text transmission in the
    /// product** — Advisor and Brief send structured snapshots only, and corrections and
    /// the change log never leave at all.
    var transmitsRawCapture: Bool { self == .cloud }
}

// MARK: - How hard to think about THIS ramble

extension CaptureRoute {

    /// Where "long enough to be worth thinking about" starts, in characters.
    ///
    /// Not invented: the labeled corpus (`RambleEvalSet`, 157 samples) has a median of
    /// **71** characters and a hard cluster below ~150, then an empty stretch and a long
    /// tail — 365, then nothing until 507, 703, 1007, 1348, 2664. This floor sits in that
    /// gap, so it separates the two populations instead of cutting through either. The
    /// ramble that actually failed on device was 648.
    static let depthCharacterFloor = 400

    /// How many distinct items make a dump structurally hard.
    ///
    /// Segmentation difficulty scales with the number of separate outcomes competing for
    /// boundaries, not with prose length, so this is the better of the two signals and
    /// the reason both exist. The measured failure had **13**; a median ramble has one or
    /// two.
    static let depthItemFloor = 6

    /// The reasoning level the cloud rung should run for this text, or `nil` for none.
    ///
    /// **Depth is bought per-ramble, not per-feature** — the reason `CapabilityProfiles`
    /// alone could not express this. Ramble's model choice is already settled (`route`
    /// sends every ambiguous capture to the cloud, and the cloud is Gemini); the only
    /// question here is whether *this particular* dump is hard enough to be worth thinking
    /// harder about. "Buy milk and call mum" is not, and paying depth on it would tax the
    /// most common path in the product to no measurable end.
    ///
    /// `.moderate` rather than `.deep` on purpose. Capture is Level 2–3 semantic parsing —
    /// segmentation, modifier attachment, compound temporal structure — not the multi-step
    /// judgment the Advisor's `.deep` exists for. This is a nudge for the hard tail, not a
    /// reclassification of what capture is.
    ///
    /// **Known tension, to be settled with `-CaptureDiagnostics` rather than argument:**
    /// the long rambles this fires on are the same ones already hitting the capture
    /// deadline (a 648-char/13-item dump finished at neither 20s nor 30s). Depth may buy
    /// cleaner segmentation, or it may just reach the salvage wall sooner with fewer
    /// drafts banked. Salvage is a served user either way, so the failure mode is
    /// "no better", not "broken" — but if the numbers say it costs drafts without
    /// improving them, raise these floors or drop this to nil. Do not raise the deadline.
    static func captureDepth(
        for text: String, itemCount: Int? = nil
    ) -> ContextOptions.ReasoningLevel? {
        // `.deep` at capture projects to `.moderate`: the BUDGET says this dump deserves
        // more thought than a card; the WORKLOAD decides how that is spent, and capture is
        // Level 2–3 semantic parsing, not the multi-step judgment `.deep` exists for.
        budget(for: text, itemCount: itemCount) == .deep ? .moderate : nil
    }

    /// How much cognition this capture deserves, in the product's ONE budget vocabulary
    /// (`ReasoningBudget` — P-03). Capture used to speak a private dialect of the same
    /// decision (`captureDepth` returning a reasoning level directly); now the policy is
    /// stated in the shared unit and the level is derived from it. A big dump is `.deep`
    /// for the same reason a multi-step task is: several things held at once.
    static func budget(for text: String, itemCount: Int? = nil) -> ReasoningBudget {
        let items = itemCount ?? Segmentation.items(from: text).count
        return (text.count >= depthCharacterFloor || items >= depthItemFloor) ? .deep : .shallow
    }
}
