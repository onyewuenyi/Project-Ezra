//
//  CaptureFlowTests.swift
//  Project-EzraTests
//
//  The submit decision as a value (G5, first cut): every rule the composer's submit path
//  enforces, pinned in order of precedence — posture over router, private engine for one
//  thought with a model, voice earns the beat, typed reveals instantly, the authority for
//  what the verifier escalates.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("CaptureFlow — the submit decision, pure")
struct CaptureFlowTests {

    private let oneThought = "call the dentist tomorrow about the crown"
    private let typedList = "renew the passport\nbook the flights\npay the water bill"

    @Test("On-device posture never transmits, whatever the router would say")
    func postureOutranksRouter() {
        // An EMPTY local read is the one case the router always sends to the cloud.
        let open = CaptureFlow.plan(
            text: oneThought, localRead: [], fromVoice: true, posture: .open, privateModelAvailable: false)
        #expect(open.route == .cloud)
        #expect(open.arm == .authority(.emptyRead))
        let closed = CaptureFlow.plan(
            text: oneThought, localRead: [], fromVoice: true, posture: .onDevice, privateModelAvailable: false)
        #expect(closed.route == .local)
        #expect(closed.escalation == nil)
        #expect(closed.arm == .revealAfterDwell)
        // And with the posture open, the plan is exactly what the router says.
        let drafts = AppBrain.provisionalDrafts(oneThought)
        let routed = CaptureRoute.route(for: oneThought, localRead: drafts, fromVoice: false)
        let plan = CaptureFlow.plan(
            text: oneThought, localRead: drafts, fromVoice: false, posture: .open, privateModelAvailable: false)
        #expect(plan.route == routed.route && plan.escalation == routed.escalation)
    }

    @Test("One thought + a model + on-device posture runs the private engine; several things do not")
    func privateEngineEnvelope() {
        let drafts = AppBrain.provisionalDrafts(oneThought)
        let one = CaptureFlow.plan(
            text: oneThought, localRead: drafts, fromVoice: true, posture: .onDevice,
            privateModelAvailable: true)
        #expect(one.arm == .privateEngine)
        #expect(one.route == .local)
        let noModel = CaptureFlow.plan(
            text: oneThought, localRead: drafts, fromVoice: true, posture: .onDevice,
            privateModelAvailable: false)
        #expect(noModel.arm == .revealAfterDwell)
        let several = "book the flights and then renew the passport and also call the vet tomorrow"
        let many = CaptureFlow.plan(
            text: several, localRead: AppBrain.provisionalDrafts(several), fromVoice: true,
            posture: .onDevice, privateModelAvailable: true)
        #expect(many.arm != .privateEngine)
        #expect(many.route == .local)
    }

    @Test("Typed structure reveals instantly; the same words spoken earn the beat")
    func voiceEarnsTheBeat() {
        let drafts = AppBrain.provisionalDrafts(typedList)
        let typed = CaptureFlow.plan(
            text: typedList, localRead: drafts, fromVoice: false, posture: .open, privateModelAvailable: true)
        let spoken = CaptureFlow.plan(
            text: typedList, localRead: drafts, fromVoice: true, posture: .open, privateModelAvailable: true)
        #expect(typed.arm == .revealInstantly)
        #expect(spoken.arm == .revealAfterDwell)
        #expect(typed.route == .local && spoken.route == .local)
    }

    @Test("What the verifier escalates goes to the authority, with its reason on the plan")
    func authorityCarriesTheReason() {
        let plan = CaptureFlow.plan(
            text: oneThought, localRead: [], fromVoice: false, posture: .open, privateModelAvailable: true)
        #expect(plan.route == .cloud)
        #expect(plan.arm == .authority(.emptyRead))
        #expect(plan.escalation == .emptyRead)
    }
}
