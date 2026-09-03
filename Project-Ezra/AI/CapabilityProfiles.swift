//
//  CapabilityProfiles.swift
//  Project-Ezra
//
//  One home for how each capability's session RUNS — the modifiers capture's profile
//  (`CaptureConversation.CaptureProfile`) deliberately skipped in its v1.
//
//  Before this, the card services constructed bare sessions: no output cap (a runaway
//  framing could eat the whole 20s deadline and then fail — the user watched a spinner
//  and got nothing, recorded as a timeout that was really an unbounded output), and the
//  Thinking Partner — whose entire value is reasoning depth — ran at the same defaults
//  as a one-word classifier. A profile per capability makes latency predictable, spends
//  reasoning where depth pays, and makes the NEXT capability a config entry instead of
//  a bespoke sampling decision.
//
//  **Every number here is a prior, not a settled value** — the device pass that
//  re-measures capture on the new model A/Bs these too (`ModelMetrics` per-capability
//  timeout/latency rows are the evidence). Capture itself stays out: its uncapped
//  output is deliberate (salvage semantics), and it has its own profile.
//
//  Values are pinned by `CapabilityProfilesTests` so a drive-by edit is visible.
//

import Foundation
import FoundationModels

enum CapabilityProfiles {

    /// How one capability's session runs. `nil` means "the framework's default".
    ///
    /// **`maximumResponseTokens` is the ANSWER budget, always.** On a thinking model it is
    /// NOT what gets sent — see `supported(_:capabilities:)`, which adds the thinking
    /// headroom. Write these numbers as "how long should the reply be", never as "how much
    /// may this call generate in total"; the second reading is what broke both reasoning
    /// profiles in production.
    struct Config: Equatable, Sendable {
        var temperature: Double?
        var reasoningLevel: ContextOptions.ReasoningLevel?
        var maximumResponseTokens: Int?
    }

    /// Room for a thinking model's internal tokens, ON TOP of the answer budget.
    ///
    /// **The bug this exists for, because the reasoning that caused it was sound.** Gemini
    /// 3.x counts thinking tokens against the same `maxOutputTokens` ceiling as the reply.
    /// On device that distinction does not exist — there are no thinking tokens — so
    /// `maximumResponseTokens` had always meant "how long may the answer be", and the
    /// Advisor's 500 was deliberately tight to enforce "sophistication appears as better
    /// judgment, never more text". Correct principle; wrong units the moment a rung
    /// started thinking. Measured on 2026-08-21: a Brief cloud call returned
    /// `finishReason: MAX_TOKENS` with `thoughtsTokenCount: 573` and
    /// `candidatesTokenCount: 12` — the model spent its entire allowance thinking and was
    /// truncated before it could answer, every time. The Brief had been silently serving
    /// its deterministic tail on every cloud attempt, and `taskAdvisor` was worse: `.deep`
    /// against a hard 500.
    ///
    /// **A ceiling is not a spend.** Raising it cannot cost anything the model does not
    /// actually generate; it only removes a truncation. So these are deliberately generous
    /// — the failure mode of too-low is a silently broken feature, and the failure mode of
    /// too-high is nothing at all until the model genuinely rambles, which the answer
    /// budget still bounds.
    ///
    /// This does NOT relax the product rule. The answer ceiling in each profile is
    /// unchanged, so a deeper rung still cannot buy itself more text — it can only now
    /// afford to finish the thought before writing.
    static func thinkingHeadroom(for level: ContextOptions.ReasoningLevel) -> Int {
        switch level {
        case .light: return 1024
        case .moderate: return 2048
        default: return 4096  // .deep, and anything the SDK adds above it
        }
    }

    /// The answer budget assumed when a profile leaves `maximumResponseTokens` nil and the
    /// rung is a thinking one. Nil means "the framework's default", and the framework's
    /// default turned out to be small enough that thinking consumed it whole — so on a
    /// reasoning rung, nil has to become a number rather than a shrug.
    static let defaultAnswerTokens = 1024

    /// The Task Advisor: one ambient compositional reading (observation · guidance ·
    /// next move · payload) that absorbed the retired framing/breakdown/narration calls.
    ///
    /// **`reasoningLevel` is `.deep`, and `supported(_:capabilities:)` is what makes that
    /// safe.** The history matters: it used to be `.moderate` unconditionally, which made
    /// EVERY Advisor generation fail on device with `unsupportedCapability` — the feature
    /// had never once produced a reading on real hardware, because `SystemLanguageModel`
    /// reports `capabilities.contains(.reasoning) == false` and nothing surfaces that gap
    /// until a call is rejected. The fix then was to stop asking, because no path could
    /// serve it.
    ///
    /// **A path can serve it now.** The cloud rung is Gemini 3.7 Flash, which advertises
    /// `.reasoning`, so the profile states what the Advisor actually wants and the
    /// degrade step removes it on the arm that cannot do it. That is the product's
    /// gold-standard-first method expressed in a config: the strongest rung defines the
    /// ceiling, cheaper rungs run the same profile minus what they cannot serve.
    ///
    /// The design consequence still stands and is the reason this is `.deep` rather than
    /// a dial to keep turning: **sophistication must appear as better judgment, never
    /// more text.** A deeper rung should produce a sharper diagnosis and sharper silence,
    /// not a longer reading — the ANSWER ceiling stays at 500 on every rung for exactly
    /// that reason, and the one-judgment/one-move contract is constant across them.
    ///
    /// 500 is the reply budget, not the request's ceiling: `supported(_:capabilities:)`
    /// adds thinking headroom on a rung that will actually reason. Read as a total, this
    /// number silently broke the feature it was protecting — `.deep` against a hard 500
    /// meant the model thought until it was truncated and never answered at all.
    static let taskAdvisor = Config(
        temperature: 0.5, reasoningLevel: .deep, maximumResponseTokens: 500)

    /// Ramble's parse. **Deliberately no reasoning level, on any rung.** Capture is
    /// Level 2–3 semantic parsing — segmentation, modifier attachment, compound temporal
    /// structure — which is squarely inside a Flash-class model's reliable band and
    /// nowhere near needing a reasoning mode. Paying for depth here would buy latency at
    /// the front door and nothing else.
    static let capture = Config(
        temperature: nil, reasoningLevel: nil, maximumResponseTokens: nil)

    /// One concrete move, at most 12 words.
    static let kickoff = Config(
        temperature: 0.3, reasoningLevel: nil, maximumResponseTokens: 60)

    /// One word from a two-word vocabulary — determinism over flair.
    static let workIntent = Config(
        temperature: 0.0, reasoningLevel: nil, maximumResponseTokens: 30)

    /// A configured session, the one construction path every card service uses.
    ///
    /// The reasoning level is dropped when the model cannot serve it, rather than sent and
    /// rejected. It is the only place that knows the difference between "this profile
    /// wants deeper thinking" and "this model path can provide it", and those are
    /// genuinely different questions — the cloud rung (Gemini, which advertises
    /// `.reasoning`) SHOULD receive the level it was configured with, and the on-device
    /// rung should quietly run the same profile without it.
    ///
    /// Asking anyway is what cost the Advisor its entire existence on device: an
    /// unsupported capability fails the call outright, so the difference between degrading
    /// and asking is the difference between a slightly plainer reading and no reading at
    /// all. Degrade, never fail — the same rule the rest of the AI layer follows.
    static func session(instructions: String, config: Config) -> LanguageModelSession {
        LanguageModelSession(
            profile: Profile(instructions: instructions, config: supported(config)))
    }

    /// The same construction path, on a specific model — the cloud rung's entry point.
    ///
    /// Providers call this rather than building a bare `LanguageModelSession(model:)`, so
    /// temperature, response ceiling, and the degrade rule are identical on every rung
    /// and there is exactly one place that turns a `Config` into a session. `capabilities`
    /// is the provider's, not the device's: that is the whole point of asking here.
    static func session(
        instructions: String, config: Config, model: any LanguageModel,
        capabilities: LanguageModelCapabilities
    ) -> LanguageModelSession {
        LanguageModelSession(
            profile: Profile(
                instructions: instructions,
                config: supported(config, capabilities: capabilities),
                model: model))
    }

    /// `config`, fitted to what this rung can actually do — in BOTH directions.
    ///
    /// Two adjustments, and they are exact opposites of each other, which is why they
    /// belong in one function: this is the only place that knows whether the configured
    /// reasoning level is going to run.
    ///
    ///   * **Reasoning unsupported → strip it.** Asking anyway fails the call outright
    ///     (`unsupportedCapability`), which is what cost the Advisor its entire existence
    ///     on device. Degrade, never fail.
    ///   * **Reasoning supported → pay for it.** The level will run, so the ceiling has to
    ///     cover the thinking as well as the answer, or the model is truncated mid-thought
    ///     and returns nothing. See `thinkingHeadroom(for:)` for the measurement.
    ///
    /// The symmetry is the point. Before this, "can this rung reason?" had exactly one
    /// consequence, and the unasked half — "then it needs room to" — was left to profiles
    /// that had no way to know which rung they were about to run on.
    static func supported(
        _ config: Config, capabilities: LanguageModelCapabilities = SystemLanguageModel.default.capabilities
    ) -> Config {
        guard let level = config.reasoningLevel else { return config }

        guard capabilities.contains(.reasoning) else {
            var degraded = config
            degraded.reasoningLevel = nil
            return degraded
        }

        var budgeted = config
        budgeted.maximumResponseTokens =
            (config.maximumResponseTokens ?? defaultAnswerTokens) + thinkingHeadroom(for: level)
        return budgeted
    }

    /// The `CaptureProfile` pattern: a declarative profile binding instructions to how
    /// this configuration runs. Static per call — the card services are stateless per
    /// call by design, so nothing here needs capture's mutable context box.
    struct Profile: LanguageModelSession.DynamicProfile {
        let instructions: String
        let config: Config
        /// Always explicit, defaulting to the on-device model. Stating it uniformly keeps
        /// one profile type for both rungs instead of branching the body on a optional.
        var model: any LanguageModel = SystemLanguageModel.default

        var body: some LanguageModelSession.DynamicProfile {
            LanguageModelSession.Profile {
                Instructions(instructions)
            }
            .model(model)
            .temperature(config.temperature)
            .reasoningLevel(config.reasoningLevel)
            .maximumResponseTokens(config.maximumResponseTokens)
        }
    }
}
