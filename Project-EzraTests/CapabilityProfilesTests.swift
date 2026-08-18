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

    @Test("The Advisor says the most — and asks for no reasoning mode")
    func advisor() {
        let config = CapabilityProfiles.taskAdvisor
        // Was `.moderate`, and this test PINNED THAT — which is why a profile that made
        // every on-device Advisor generation fail with `unsupportedCapability` survived
        // in a green suite. The simulator cannot exercise the capability check, so the
        // test agreed with the code all the way to the device.
        #expect(config.reasoningLevel == nil)
        #expect(config.temperature == 0.5)
        #expect(config.maximumResponseTokens == 500)
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
        // the guard is capability-aware, not a blanket ban (the PCC tier is real).
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
    }

    @Test("Classification runs cold — one word from a two-word vocabulary")
    func classifier() {
        #expect(CapabilityProfiles.workIntent.temperature == 0.0)
        #expect(CapabilityProfiles.workIntent.reasoningLevel == nil)
    }
}
