//
//  PlanRoutingTests.swift
//  Project-EzraTests
//
//  The tier chain is a simple ordered preference: on-device first (fast, private,
//  free), then PCC when entitled, then the deterministic fallback — which is always
//  the tail, so the chain is never empty and generation can never fail.
//

import Testing

@testable import Project_Ezra

@Suite("Plan routing")
struct PlanRoutingTests {

    @Test("On-device is preferred; deterministic is always the tail")
    func chain() {
        #expect(
            PlanRouting.decide(onDeviceAvailable: true, pccAvailable: true)
                == [.onDevice, .pcc, .deterministic])
        #expect(
            PlanRouting.decide(onDeviceAvailable: true, pccAvailable: false)
                == [.onDevice, .deterministic])
        #expect(
            PlanRouting.decide(onDeviceAvailable: false, pccAvailable: true)
                == [.pcc, .deterministic])
        #expect(
            PlanRouting.decide(onDeviceAvailable: false, pccAvailable: false)
                == [.deterministic])
    }
}
