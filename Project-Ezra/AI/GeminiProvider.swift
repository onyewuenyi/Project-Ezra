//
//  GeminiProvider.swift
//  Project-Ezra
//
//  Rung 3's installed provider: Gemini 3.7 Flash, reached through Firebase AI Logic's
//  bridge into Apple's Foundation Models framework.
//
//  **Why this is a conformance and not a refactor.** `CloudModelProvider` exists so this
//  file could be written without touching anything above it, and that claim is now
//  tested rather than asserted. Firebase's `GeminiLanguageModel` conforms to
//  `FoundationModels.LanguageModel`, so it drops into the same `LanguageModelSession`
//  every caller already builds — streaming, salvage, and guided decoding are unchanged,
//  and `TodayPlanService` / `TaskAdvisorService` / `FoundationModelsEngine` still cannot
//  name a provider. That bridge is the entire reason the SPM dependency is pinned to
//  firebase-ios-sdk's `wwdc26-preview` branch; a tagged release has no
//  `GeminiLanguageModel` and this file would not compile against one.
//
//  **The availability gate is configuration presence, never a model construction.** The
//  protocol forbids reaching for the framework to answer `isAvailable`, and that rule
//  was written for PCC's uncatchable trap. It holds here for a duller reason with the
//  same consequence: constructing a model and asking the network whether Gemini is
//  reachable would turn a routing question into a round trip on every capacity tap.
//  `FirebaseApp.app()` is a local dictionary lookup — nil until `configure()` has run
//  and found `GoogleService-Info.plist`, non-nil after. No network, no trap, safe on
//  every device, and false in the unit-test host by construction (see
//  `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, which does not configure
//  Firebase under XCTest — that is what keeps the routing tests on the deterministic
//  tail instead of quietly making live calls during a suite).
//
//  **Availability here means "we can ask", not "the answer will arrive."** A configured
//  app on a plane still fails, and that failure is a `throw` from `respond`, handled by
//  `ModelRun` and the tier chains exactly like any other cloud failure. Nothing about
//  this rung promises success; the ladder always has a deterministic tail beneath it.
//

import FirebaseAILogic
import FirebaseCore
import Foundation
import FoundationModels

/// Gemini via Firebase AI Logic — the installed cloud provider.
enum GeminiProvider: CloudModelProvider {

    /// The exact model asked for. Firebase validates only the `gemini-` prefix and logs
    /// a warning for anything it doesn't recognise, so a typo here fails at the network
    /// call rather than at build time — change it deliberately.
    ///
    /// Flash rather than Pro is the deliberate choice: Rung 3 exists for the judgments a
    /// 3B on-device model measurably cannot make (`AdvisorBenchmark`), not for the
    /// largest model available, and the cost target is reduction in required attention
    /// per dollar of reasoning. Revisit only if the benchmark shows Flash missing the
    /// ceiling, never because a bigger model exists.
    static let modelName = "gemini-3.7-flash"

    /// Deliberately the model FAMILY, not `modelName`.
    ///
    /// This string keys the rung counters in `ModelMetrics` / `IntelligenceLedger` and
    /// labels the DEBUG readout (`cloud(gemini-flash)`). Those counters are compared
    /// across weeks to tune deadlines and routing on evidence; if the identifier moved
    /// every time the model version bumped, each bump would silently split its own
    /// history into two series and every comparison spanning it would be wrong. The
    /// model version belongs in `modelName`, where changing it is the point.
    static let identifier = "gemini-flash"

    /// The pinned version, for the per-capture receipt. See `CloudModelProvider`.
    static var modelVersion: String { modelName }

    /// Whether Firebase has been configured in this process. See the file header for why
    /// this must not construct the model.
    static var isAvailable: Bool { FirebaseApp.app() != nil }

    /// What Gemini advertises through the bridge, mirrored from `GeminiLanguageModel`'s
    /// own `capabilities`. Declared statically rather than read off an instance because
    /// answering "can this rung reason?" must not construct a model or require Firebase to
    /// be configured — the same rule `isAvailable` follows. If the SDK's advertised set
    /// ever changes, this is the line to change with it.
    static let capabilities = LanguageModelCapabilities([
        .toolCalling,
        .vision,
        .reasoning,
        .guidedGeneration,
    ])

    static func session(
        instructions: String, config: CapabilityProfiles.Config
    ) throws
        -> LanguageModelSession
    {
        guard isAvailable else { throw ModelUnavailableError.unavailable }
        // `useLimitedUseAppCheckTokens` asks for a fresh single-use token per call
        // instead of a cached one replayed for its whole lifetime. That is the stronger
        // posture and the one this project's research preview should be running — the
        // rule is prefer the strongest available option and let a measurement argue it
        // down. It costs an attestation round trip the SDK amortises; if the capture
        // budget ever shows that cost, `-RambleEval`'s latency row is where it appears.
        let model = FirebaseAI.firebaseAI(backend: .googleAI(), useLimitedUseAppCheckTokens: true)
            .geminiLanguageModel(name: modelName)
        return CapabilityProfiles.session(
            instructions: instructions, config: config, model: model, capabilities: capabilities)
    }
}
