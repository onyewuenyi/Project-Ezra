//
//  CapabilityProfilesTests.swift
//  Project-EzraTests
//
//  The per-capability session configs, pinned so a drive-by edit is visible in review.
//  Every value is a PRIOR — the device pass re-tunes them against ModelMetrics — but a
//  prior that changes should change loudly, in a diff that says why.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Capability profiles — pinned priors")
struct CapabilityProfilesTests {

    @Test("Framing thinks hardest and says the most")
    func framing() {
        let config = CapabilityProfiles.decisionFraming
        #expect(config.reasoningLevel == .moderate)
        #expect(config.temperature == 0.7)
        #expect(config.maximumResponseTokens == 500)
    }

    @Test("The output caps order by how much each capability is allowed to say")
    func capOrdering() {
        let caps = [
            CapabilityProfiles.workIntent, CapabilityProfiles.kickoff,
            CapabilityProfiles.unstickNarration, CapabilityProfiles.breakdown,
            CapabilityProfiles.decisionFraming,
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
