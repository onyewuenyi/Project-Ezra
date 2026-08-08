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
    struct Config: Equatable, Sendable {
        var temperature: Double?
        var reasoningLevel: ContextOptions.ReasoningLevel?
        var maximumResponseTokens: Int?
    }

    /// The Thinking Partner: the hardest cognitive content in the app (options,
    /// tradeoffs, a grounded recommendation), on demand with the user watching.
    /// `.moderate` reasoning is the prior — `.deep` is the candidate promotion once
    /// the device pass shows the 20s budget absorbs it.
    static let decisionFraming = Config(
        temperature: 0.7, reasoningLevel: .moderate, maximumResponseTokens: 500)

    /// Steps should be conservative and repeatable, not creative.
    static let breakdown = Config(
        temperature: 0.3, reasoningLevel: nil, maximumResponseTokens: 400)

    /// One or two sentences, restate-only.
    static let unstickNarration = Config(
        temperature: 0.5, reasoningLevel: nil, maximumResponseTokens: 120)

    /// One concrete move, at most 12 words.
    static let kickoff = Config(
        temperature: 0.3, reasoningLevel: nil, maximumResponseTokens: 60)

    /// One word from a two-word vocabulary — determinism over flair.
    static let workIntent = Config(
        temperature: 0.0, reasoningLevel: nil, maximumResponseTokens: 30)

    /// A configured session, the one construction path every card service uses.
    static func session(instructions: String, config: Config) -> LanguageModelSession {
        LanguageModelSession(profile: Profile(instructions: instructions, config: config))
    }

    /// The `CaptureProfile` pattern: a declarative profile binding instructions to how
    /// this configuration runs. Static per call — the card services are stateless per
    /// call by design, so nothing here needs capture's mutable context box.
    struct Profile: LanguageModelSession.DynamicProfile {
        let instructions: String
        let config: Config

        var body: some LanguageModelSession.DynamicProfile {
            LanguageModelSession.Profile {
                Instructions(instructions)
            }
            .temperature(config.temperature)
            .reasoningLevel(config.reasoningLevel)
            .maximumResponseTokens(config.maximumResponseTokens)
        }
    }
}
