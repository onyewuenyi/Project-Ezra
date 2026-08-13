//
//  CaptureRoute.swift
//  Project-Ezra
//
//  Which machinery produces the interpretation for a capture — and NOTHING about whether
//  that interpretation is trustworthy.
//
//  This exists as its own type because the previous vocabulary ("certain" / "ambiguous")
//  quietly fused two different questions: *can we produce a useful reading without model
//  reasoning?* and *is that reading correct?* Only the first is answerable at submit, and
//  answering it made the second sound decided. The word "certain" then justified showing a
//  fallback read as final — which is how a four-errand dictation shipped as one task titled
//  with its own transcript.
//
//  **The routing policy is deliberately swappable and deliberately NOT architecture.** The
//  reveal boundary is the primitive: whatever produces the interpretation, it is final once
//  shown. Today the fast path skips the model, but that must never calcify into "simple
//  inputs never use AI" — the model may one day beat the deterministic resolver even on a
//  one-liner ("Sarah's birthday gift" → knows who Sarah is, the event it belongs to, the
//  shopping it implies). When that day comes, `route(for:)` changes and nothing else does.
//

import Foundation

/// How this capture's interpretation gets produced.
enum CaptureRoute: Equatable {
    /// Deterministic pipeline only — `Segmentation` → `HeuristicEngine.intent` →
    /// `IntentResolver`. Sub-frame, so the reveal is immediate.
    case fast
    /// The model decides, behind the orb. Its result IS the reveal.
    case reasoning

    /// The routing decision, in ONE place.
    ///
    /// The fast path is taken only when the deterministic read stands on evidence: structure
    /// the user themselves punctuated, or a single item that actually reads as one thought
    /// (see `Segmentation.readsAsOneThought` — one item is not, by itself, evidence of one
    /// thought). Everything else reasons.
    static func route(for text: String) -> CaptureRoute {
        Segmentation.confidence(text) == .ambiguous ? .reasoning : .fast
    }

    /// For metrics: the path rate is the number that tells us whether the routing policy is
    /// earning its keep, alongside time-to-reveal and the correction rate.
    var metricName: String {
        switch self {
        case .fast: return "fast"
        case .reasoning: return "reasoning"
        }
    }
}
