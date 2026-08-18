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

    /// The Task Advisor: one ambient compositional reading (observation · guidance ·
    /// next move · payload) that absorbed the retired framing/breakdown/narration calls.
    ///
    /// **`reasoningLevel` is nil, and that is a finding rather than a default (2026-08-17).**
    /// It used to be `.moderate`, which made EVERY Advisor generation fail on device with
    /// `unsupportedCapability` — the feature had never once produced a reading on real
    /// hardware. `SystemLanguageModel` reports `capabilities.contains(.reasoning) == false`;
    /// `availability == .available` only says an on-device model exists, not that it can do
    /// what a profile asks of it, and nothing surfaces the gap until a call is rejected.
    ///
    /// `.light` / `.moderate` / `.deep` belong to reasoning-capable model paths, which
    /// includes Private Cloud Compute. **PCC is not the answer here**: the product
    /// constraint is 100% on-device, so the fix is to stop asking for a mode this path
    /// does not offer — not to route around it.
    ///
    /// The consequence for design, which matters more than the one-line fix: **Advisor
    /// quality cannot be bought with a reasoning dial.** It has to come from better
    /// context, tighter constrained decisions, decomposition, and app-side logic — the
    /// capabilities this model actually exposes (`guidedGeneration` and `toolCalling` both
    /// report true on device). Any future "just raise the reasoning level" instinct is
    /// answered here.
    static let taskAdvisor = Config(
        temperature: 0.5, reasoningLevel: nil, maximumResponseTokens: 500)

    /// One concrete move, at most 12 words.
    static let kickoff = Config(
        temperature: 0.3, reasoningLevel: nil, maximumResponseTokens: 60)

    /// One word from a two-word vocabulary — determinism over flair.
    static let workIntent = Config(
        temperature: 0.0, reasoningLevel: nil, maximumResponseTokens: 30)

    /// A configured session, the one construction path every card service uses.
    ///
    /// The reasoning level is dropped when the model cannot serve it, rather than sent and
    /// rejected. This is NOT belt-and-braces around the nil above: it is the only place
    /// that knows the difference between "this profile wants deeper thinking" and "this
    /// model path can provide it", and those are genuinely different questions — the app
    /// also has a PCC tier (`TodayPlanService`, entitlement-gated), and a reasoning-capable
    /// path SHOULD receive the level it was configured with.
    ///
    /// Asking anyway is what cost the Advisor its entire existence on device: an
    /// unsupported capability fails the call outright, so the difference between degrading
    /// and asking is the difference between a slightly plainer reading and no reading at
    /// all. Degrade, never fail — the same rule the rest of the AI layer follows.
    static func session(instructions: String, config: Config) -> LanguageModelSession {
        LanguageModelSession(
            profile: Profile(instructions: instructions, config: supported(config)))
    }

    /// `config`, minus anything the on-device model does not advertise.
    static func supported(
        _ config: Config, capabilities: LanguageModelCapabilities = SystemLanguageModel.default.capabilities
    ) -> Config {
        guard config.reasoningLevel != nil, !capabilities.contains(.reasoning) else {
            return config
        }
        var degraded = config
        degraded.reasoningLevel = nil
        return degraded
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
