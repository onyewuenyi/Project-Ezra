//
//  CloudModelProvider.swift
//  Project-Ezra
//
//  Rung 3 — the one paid rung, and the one place the app knows a cloud model exists.
//
//  The intelligence ladder resolves every intelligent moment cheapest-first: facts →
//  memory → on-device → cloud. Rungs 0–2 are already whole systems in this codebase
//  (sensors and gates, the facts fingerprint, `ModelRun`). This file is the fourth,
//  and it is deliberately the thinnest of them: a protocol, one conformance, and a
//  slot.
//
//  **Why a protocol rather than a hard-wired model.** The cloud provider was always the
//  part of the AI stack most likely to change, so it became a seam before there was a
//  second thing to put in it. That paid off: the provider has since moved from Private
//  Cloud Compute to Gemini via Firebase AI Logic, and the move was one new conformance
//  (`GeminiProvider`) plus the default below — no caller changed, because every provider
//  is the same shape, a `LanguageModelSession` over a different model. It was once a
//  hard-wired branch inside `TodayPlanService`; now `TodayPlanService` cannot name a
//  provider at all.
//
//  **One slot, one provider — per Challenge 5.** Two cloud tiers means two privacy
//  stories and two failure modes for one slot, so `CloudModel.provider` is singular by
//  construction. If evidence ever justifies a different provider per workload, this
//  becomes a function of the workload; it is not one speculatively.
//
//  **Nothing above this seam may know which model answered.** The tier is `.cloud`.
//  The provider's `identifier` exists for the DEBUG diagnostics line and for metrics,
//  which is exactly the level at which "which model answered" is a legitimate
//  question, and no higher.
//

import Foundation
import FoundationModels

/// A cloud-hosted model reachable behind the existing session abstraction.
///
/// Static rather than instance members on purpose: a provider is a *build
/// configuration*, not a value anything owns. There is one of them and it is chosen at
/// compile time, so an instance would only be a thing to thread around.
protocol CloudModelProvider {
    /// Short, stable, and never user-facing: `"pcc"`, `"gemini-flash"`. It labels the
    /// DEBUG tier readout and the rung counters. **Do not** put it in UI copy — the
    /// user is told a briefing is deterministic rather than voiced (a consequence they
    /// feel), never which datacenter answered.
    static var identifier: String { get }

    /// The EXACT model this provider is pinned to (`"gemini-3.7-flash"`), where
    /// `identifier` is deliberately only the family.
    ///
    /// The split is load-bearing in both directions. `identifier` must stay coarse or a
    /// version bump silently forks its own counter history in two. But a per-capture
    /// receipt (`CaptureProvenance`) is answering the opposite question — *which model
    /// produced THIS reading* — and a family name cannot answer it, because the whole
    /// point of reading an old receipt is to notice that the answer changed when the
    /// version did. Same non-UI rule as `identifier`.
    static var modelVersion: String { get }

    /// Whether this provider may be *touched at all*.
    ///
    /// ⚠️ **This must not construct the model, and must not go to the network.** The
    /// rule was written in blood: `PrivateCloudComputeLanguageModel` fatal-errors — an
    /// uncatchable trap, not a `throw` — the instant it is constructed without the
    /// Apple-managed entitlement, including merely to read `.isAvailable`, so an
    /// availability check that reached for the model crashed every capacity tap on
    /// every device lacking the entitlement (which was most of them). PCC is gone, but
    /// the rule outlives it for a duller reason with the same shape: this is asked on
    /// the routing path, so a check that costs a round trip makes every routing
    /// decision wait on the network. Answer from something cheap and local — a
    /// compile-time flag, a configuration presence check — and never from the
    /// framework.
    static var isAvailable: Bool { get }

    /// A session for one generation, carrying this workload's instructions.
    ///
    /// Returning Apple's `LanguageModelSession` is the load-bearing choice: it is what
    /// keeps `TodayPlanSession.generate` — streaming, salvage, guided decoding —
    /// identical across providers, and it is the shape the Firebase bridge turned out to
    /// take (`GeminiLanguageModel` conforms to `FoundationModels.LanguageModel`, so it
    /// goes straight into Apple's session). A provider that cannot meet this contract is
    /// a signal to change the protocol deliberately, not to add a second parallel path.
    static func session(
        instructions: String, config: CapabilityProfiles.Config
    ) throws
        -> LanguageModelSession

    /// What this model can actually do, as the model itself advertises it.
    ///
    /// Asked so `CapabilityProfiles.supported(_:capabilities:)` can degrade a profile
    /// against the rung that will run it rather than against the device. Before this
    /// existed, a cloud session silently ran with whatever the on-device model could
    /// serve — which is how a reasoning-capable rung ended up being asked for no
    /// reasoning at all.
    static var capabilities: LanguageModelCapabilities { get }
}

extension CloudModelProvider {
    /// A provider that pins no version is its own family — the honest default for one
    /// that has nothing finer to report.
    static var modelVersion: String { identifier }

    /// A session with no profile configuration — the default for callers that only need
    /// instructions. Kept so adding a config to the protocol didn't churn every call site
    /// into passing an empty one.
    static func session(instructions: String) throws -> LanguageModelSession {
        try session(instructions: instructions, config: CapabilityProfiles.Config())
    }
}

// MARK: - The slot

/// **The** cloud provider. Swapping providers is this typealias and nothing else.
///
/// It is a `static var` of metatype rather than a `typealias` so tests and the
/// diagnostics seams can substitute a provider without a build flag; production code
/// must never assign it.
enum CloudModel {
    static var provider: any CloudModelProvider.Type = GeminiProvider.self

    /// Availability of the currently-installed provider, asked fresh. Safe to call on
    /// any device — see the protocol's warning about construction.
    static var isAvailable: Bool { provider.isAvailable }

    /// What the DEBUG readout calls this rung: `cloud(gemini-flash)`.
    static var label: String { "cloud(\(provider.identifier))" }
}
