//
//  CapabilityProfilesTests.swift
//  Project-EzraTests
//
//  The per-capability session configs, pinned so a drive-by edit is visible in review.
//  Every value is a PRIOR — the device pass re-tunes them against ModelMetrics — but a
//  prior that changes should change loudly, in a diff that says why.
//

import Foundation
import FoundationModels
import Testing

@testable import Project_Ezra

@Suite("Capability profiles — pinned priors")
struct CapabilityProfilesTests {

    @Test("The Advisor says the most — and asks for the deepest thinking")
    func advisor() {
        let config = CapabilityProfiles.taskAdvisor
        // This assertion has now been three things, and the history is the lesson.
        //
        // It pinned `.moderate` while nothing could serve it, which is how a profile that
        // failed EVERY on-device generation with `unsupportedCapability` survived in a
        // green suite — the simulator cannot exercise the capability check, so the test
        // agreed with the code all the way to the device. It then pinned `nil`, which was
        // correct while on-device was the only rung.
        //
        // It pins `.deep` now because a rung exists that advertises `.reasoning`, and the
        // safety is no longer in the constant — it is in `supported(_:capabilities:)`,
        // which is what `reasoningDegradesRatherThanFails` covers. A config states what
        // the capability WANTS; the degrade step decides what each rung is asked for.
        #expect(config.reasoningLevel == .deep)
        #expect(config.temperature == 0.5)
        #expect(config.maximumResponseTokens == 500)
    }

    @Test("The Advisor's profile is degraded, not sent, on the rung that cannot reason")
    func advisorDegradesOnDevice() {
        // The regression that matters: asking an on-device model for `.deep` fails the
        // call outright. Pinning the constant is not enough — pin the pipeline.
        let onDevice = CapabilityProfiles.supported(
            CapabilityProfiles.taskAdvisor,
            capabilities: LanguageModelCapabilities([.guidedGeneration, .toolCalling]))
        #expect(onDevice.reasoningLevel == nil)
        #expect(onDevice.maximumResponseTokens == 500)  // depth is dropped; the contract is not

        let cloud = CapabilityProfiles.supported(
            CapabilityProfiles.taskAdvisor, capabilities: GeminiProvider.capabilities)
        #expect(cloud.reasoningLevel == .deep)
    }

    @Test("Capture asks for no reasoning on ANY rung — depth there buys latency, not accuracy")
    func captureStaysShallow() {
        #expect(CapabilityProfiles.capture.reasoningLevel == nil)
        // Even against the rung that could serve it. Ramble is Level 2–3 semantic parsing,
        // not deep reasoning, and the front door is the one place latency is felt most.
        let onCloud = CapabilityProfiles.supported(
            CapabilityProfiles.capture, capabilities: GeminiProvider.capabilities)
        #expect(onCloud.reasoningLevel == nil)
    }

    @Test("The installed cloud provider advertises reasoning — the premise the profiles rest on")
    func cloudRungCanReason() {
        #expect(GeminiProvider.capabilities.contains(.reasoning))
        #expect(GeminiProvider.capabilities.contains(.guidedGeneration))
    }

    @Test("An unsupported reasoning level is dropped, not sent and rejected")
    func reasoningDegradesRatherThanFails() {
        let asking = CapabilityProfiles.Config(
            temperature: 0.5, reasoningLevel: .moderate, maximumResponseTokens: 500)

        let withoutReasoning = CapabilityProfiles.supported(
            asking, capabilities: LanguageModelCapabilities([.guidedGeneration, .toolCalling]))
        #expect(withoutReasoning.reasoningLevel == nil)
        // Everything else survives — degrading is not resetting.
        #expect(withoutReasoning.temperature == 0.5)
        #expect(withoutReasoning.maximumResponseTokens == 500)

        // A path that DOES advertise reasoning keeps the level it was configured with;
        // the guard is capability-aware, not a blanket ban (the cloud rung is real).
        let withReasoning = CapabilityProfiles.supported(
            asking, capabilities: LanguageModelCapabilities([.reasoning, .guidedGeneration]))
        #expect(withReasoning.reasoningLevel == .moderate)
    }

    @Test("The output caps order by how much each capability is allowed to say")
    func capOrdering() {
        let caps = [
            CapabilityProfiles.workIntent, CapabilityProfiles.kickoff,
            CapabilityProfiles.taskAdvisor,
        ].map { $0.maximumResponseTokens ?? .max }
        #expect(caps == caps.sorted())
        #expect(caps.allSatisfy { $0 != .max })  // nobody runs uncapped

        // The depth guardrail, as an assertion: a deeper rung must produce better
        // judgment, never more text. Raising `taskAdvisor.reasoningLevel` must not come
        // with a raised ceiling — if this ever fails, someone bought prose with depth.
        #expect(CapabilityProfiles.taskAdvisor.maximumResponseTokens == 500)
    }

    @Test("Classification runs cold — one word from a two-word vocabulary")
    func classifier() {
        #expect(CapabilityProfiles.workIntent.temperature == 0.0)
        #expect(CapabilityProfiles.workIntent.reasoningLevel == nil)
    }

    // MARK: - Thinking tokens share the output ceiling (measured 2026-08-21)

    @Test("A reasoning rung is given room to think ON TOP of its answer budget")
    func reasoningRungGetsThinkingHeadroom() {
        // The live failure: Gemini 3.x counts thinking against `maxOutputTokens`, so
        // `.deep` against a hard 500 meant the model spent the whole allowance thinking
        // (measured: 573 thought tokens, 12 answer tokens, finishReason MAX_TOKENS) and
        // the Brief served its deterministic tail on every cloud attempt. Nothing in the
        // suite could see it, because the constant was right and the REQUEST was wrong.
        let cloud = CapabilityProfiles.supported(
            CapabilityProfiles.taskAdvisor, capabilities: GeminiProvider.capabilities)
        let sent = try! #require(cloud.maximumResponseTokens)
        #expect(sent > 573 + 500, "the measured failure must not fit inside the ceiling")
        #expect(sent == 500 + CapabilityProfiles.thinkingHeadroom(for: .deep))
    }

    @Test("The answer budget is what the profile states — headroom is added, never baked in")
    func headroomIsAdditiveNotAConfigChange() {
        // The product rule and the fix must stay separable. If someone later wants the
        // Advisor to say more, they raise 500; if a model starts thinking harder, they
        // raise the headroom. Conflating them is how the ceiling stopped meaning anything.
        for level in [ContextOptions.ReasoningLevel.light, .moderate, .deep] {
            let asking = CapabilityProfiles.Config(
                temperature: 0.5, reasoningLevel: level, maximumResponseTokens: 400)
            let sent = CapabilityProfiles.supported(
                asking, capabilities: GeminiProvider.capabilities)
            #expect(
                sent.maximumResponseTokens == 400 + CapabilityProfiles.thinkingHeadroom(for: level))
            #expect(sent.reasoningLevel == level)
        }
    }

    @Test("A rung that cannot think is given no headroom — it would only buy prose")
    func nonReasoningRungIsUnchanged() {
        // The depth guardrail's other half. On device there are no thinking tokens, so
        // the ceiling is purely an answer budget and must stay exactly where the profile
        // put it — otherwise this fix would quietly hand the on-device Advisor a longer
        // leash, which is the thing `capOrdering` exists to prevent.
        let onDevice = CapabilityProfiles.supported(
            CapabilityProfiles.taskAdvisor,
            capabilities: LanguageModelCapabilities([.guidedGeneration, .toolCalling]))
        #expect(onDevice.maximumResponseTokens == 500)
        #expect(onDevice.reasoningLevel == nil)
    }

    @Test("No reasoning profile leaves its answer budget to the framework's default")
    func reasoningProfilesStateTheirAnswerBudget() {
        // `nil` meant "the framework decides", and the framework decided on something
        // small enough that thinking ate it whole. On a thinking rung, nil is not a
        // shrug — it is an unowned number. Any profile asking to reason must name its
        // reply budget so the headroom has something to be added to.
        let reasoning = [CapabilityProfiles.taskAdvisor, CapabilityProfiles.briefPlan]
            .filter { $0.reasoningLevel != nil }
        #expect(!reasoning.isEmpty)
        for config in reasoning {
            #expect(config.maximumResponseTokens != nil)
        }
    }
}
