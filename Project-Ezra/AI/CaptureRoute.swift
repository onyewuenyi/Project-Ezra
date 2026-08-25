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

/// How this capture's interpretation gets produced. Two arms, one question.
///
/// **The whole routing policy is now "did the user draw the boundaries?"** — and that
/// simplicity was earned by deleting two things that tried to answer a harder question.
///
/// The first was `Segmentation.confidence`'s `.singleThought`: a word ceiling and a verb
/// lexicon deciding that an unpunctuated sentence probably described one task. The second
/// was an on-device confidence gate, built to make that call properly with a model. It
/// was measured on device and failed: warm p50 2303ms against a 400ms budget, escalating
/// 95-100% of what it saw. The decisive number was the comparison — the cloud answers a
/// median ramble in about a second, so the "local-first" path was slower than the
/// network it was avoiding.
///
/// What survives is the only deterministic claim that was ever an observation rather than
/// an interpretation: the user pressed return. Everything else is Gemini's.
enum CaptureRoute: String, Equatable, CaseIterable {

    /// The user gave us the boundaries, so there is no segmentation problem to solve.
    /// `Segmentation` reads the structure they typed and `HeuristicEngine` +
    /// `IntentResolver` fill the fields. Sub-frame — the measured pipeline p50 is 3ms —
    /// so the reveal lands without the orb ever appearing.
    case local

    /// The semantic authority. Receives the COMPLETE original text, never fragments,
    /// because boundaries are precisely what it is being asked for.
    case cloud

    /// THE routing decision, in one place and one line.
    ///
    /// No `budgetAllows` parameter: a spend counter may not override an accuracy
    /// decision on the product's front door. `CloudBudget` still guards the Advisor's
    /// speculative precompute, where the thing being bought is a guess.
    ///
    /// `cloudAvailable` is the one input, and it may only ever degrade `.cloud` toward
    /// the deterministic tail — never promote a local read into a transmission.
    static func route(
        for text: String, cloudAvailable: Bool = CloudModel.isAvailable
    ) -> CaptureRoute {
        Segmentation.structure(of: text).isExplicit ? .local : .cloud
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
        let items = itemCount ?? Segmentation.items(from: text).count
        guard text.count >= depthCharacterFloor || items >= depthItemFloor else { return nil }
        return .moderate
    }
}
