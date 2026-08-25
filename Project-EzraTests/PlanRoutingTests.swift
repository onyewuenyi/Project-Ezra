//
//  PlanRoutingTests.swift
//  Project-EzraTests
//
//  The tier chain is an ordered preference, and the Brief's order is the product's one
//  deliberate inversion: **strongest tier first**, not cheapest. Everywhere else the
//  ladder is climbed as rarely as possible; here volume is capped at ~1/day by
//  construction and the VOICE is the feature, so the cloud rung leads, the on-device
//  model is the second choice, and the deterministic tail is always last — so the chain
//  is never empty and generation can never fail.
//
//  The parameter says `cloudAvailable`, not `pccAvailable`, and that is load-bearing:
//  which provider occupies the slot is `CloudModelProvider`'s business, and routing is
//  not allowed to name one.
//

import Testing

@testable import Project_Ezra

@Suite("Plan routing")
struct PlanRoutingTests {

    @Test("The strongest tier leads; deterministic is always the tail")
    func chain() {
        #expect(
            PlanRouting.decide(onDeviceAvailable: true, cloudAvailable: true)
                == [.cloud, .onDevice, .deterministic])
        #expect(
            PlanRouting.decide(onDeviceAvailable: true, cloudAvailable: false)
                == [.onDevice, .deterministic])
        #expect(
            PlanRouting.decide(onDeviceAvailable: false, cloudAvailable: true)
                == [.cloud, .deterministic])
        #expect(
            PlanRouting.decide(onDeviceAvailable: false, cloudAvailable: false)
                == [.deterministic])
    }

    @Test("A spent daily budget drops the cloud rung but never the voice entirely")
    func budgetDropsCloudNotTheBriefing() {
        // One Brief a day cannot plausibly exhaust the cap, so this is insurance against
        // a runaway elsewhere in the product — and what it buys is that the day's single
        // most valuable generation degrades to the on-device VOICE rather than to the
        // voiceless list.
        #expect(
            PlanRouting.decide(onDeviceAvailable: true, cloudAvailable: true, budgetAllows: false)
                == [.onDevice, .deterministic])
        #expect(
            PlanRouting.decide(onDeviceAvailable: false, cloudAvailable: true, budgetAllows: false)
                == [.deterministic])
    }

    @Test("Generation can never fail: every chain ends deterministic")
    func chainAlwaysTerminates() {
        for onDevice in [true, false] {
            for cloud in [true, false] {
                for budget in [true, false] {
                    let chain = PlanRouting.decide(
                        onDeviceAvailable: onDevice, cloudAvailable: cloud, budgetAllows: budget)
                    #expect(chain.last == .deterministic)
                    #expect(!chain.isEmpty)
                }
            }
        }
    }
}
