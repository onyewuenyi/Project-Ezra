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
            text: oneThought, localRead: [], fromVoice: true, posture: .open, privateModelAvailable: false,
            boundaryPassAvailable: false)
        #expect(open.route == .cloud)
        #expect(open.arm == .authority(.emptyRead))
        let closed = CaptureFlow.plan(
            text: oneThought, localRead: [], fromVoice: true, posture: .onDevice,
            privateModelAvailable: false, boundaryPassAvailable: false)
        #expect(closed.route == .local)
        #expect(closed.escalation == nil)
        #expect(closed.arm == .revealAfterDwell)
        // And with the posture open, the plan is exactly what the router says.
        let drafts = AppBrain.provisionalDrafts(oneThought)
        let routed = CaptureRoute.route(for: oneThought, localRead: drafts, fromVoice: false)
        let plan = CaptureFlow.plan(
            text: oneThought, localRead: drafts, fromVoice: false, posture: .open,
            privateModelAvailable: false, boundaryPassAvailable: false)
        #expect(plan.route == routed.route && plan.escalation == routed.escalation)
    }

    @Test("One thought + a model + on-device posture runs the private engine; several things do not")
    func privateEngineEnvelope() {
        let drafts = AppBrain.provisionalDrafts(oneThought)
        let one = CaptureFlow.plan(
            text: oneThought, localRead: drafts, fromVoice: true, posture: .onDevice,
            privateModelAvailable: true, boundaryPassAvailable: false)
        #expect(one.arm == .privateEngine)
        #expect(one.route == .local)
        let noModel = CaptureFlow.plan(
            text: oneThought, localRead: drafts, fromVoice: true, posture: .onDevice,
            privateModelAvailable: false, boundaryPassAvailable: false)
        #expect(noModel.arm == .revealAfterDwell)
        let several = "book the flights and then renew the passport and also call the vet tomorrow"
        let many = CaptureFlow.plan(
            text: several, localRead: AppBrain.provisionalDrafts(several), fromVoice: true,
            posture: .onDevice, privateModelAvailable: true, boundaryPassAvailable: false)
        #expect(many.arm != .privateEngine)
        #expect(many.route == .local)
    }

    @Test("On-device posture stops being a quality trade once the boundary pass exists")
    func boundaryPassCoversTheSeveralThingsEnvelope() {
        // Several things on the on-device posture used to fall to ONE deterministic read
        // of the whole run-on — the very read whose under-segmentation escalates on the
        // open posture. Choosing privacy cost segmentation; now it does not.
        let several = "book the flights and then renew the passport and also call the vet tomorrow"
        let drafts = AppBrain.provisionalDrafts(several)
        let withPass = CaptureFlow.plan(
            text: several, localRead: drafts, fromVoice: true, posture: .onDevice,
            privateModelAvailable: true, boundaryPassAvailable: true)
        #expect(withPass.arm == .boundaryPass)
        // …and it never transmits, whatever the arm decides.
        #expect(withPass.route == .local)
        #expect(withPass.escalation == nil)

        // With the arm off, the plan is byte-identical to what shipped before it existed.
        let without = CaptureFlow.plan(
            text: several, localRead: drafts, fromVoice: true, posture: .onDevice,
            privateModelAvailable: true, boundaryPassAvailable: false)
        #expect(without.arm == .revealAfterDwell)

        // One thought still runs the private engine — the two envelopes are complementary,
        // and the boundary pass may not annex the single-thought case it cannot improve.
        let one = CaptureFlow.plan(
            text: oneThought, localRead: AppBrain.provisionalDrafts(oneThought), fromVoice: true,
            posture: .onDevice, privateModelAvailable: true, boundaryPassAvailable: true)
        #expect(one.arm == .privateEngine)

        // And with no model, the arm is unreachable however the flag is set.
        let noModel = CaptureFlow.plan(
            text: several, localRead: drafts, fromVoice: false, posture: .onDevice,
            privateModelAvailable: false, boundaryPassAvailable: true)
        #expect(noModel.arm == .revealInstantly)
    }

    @Test("the boundary pass never appears on the open posture's plan")
    func boundaryPassIsPostureOnlyInThePlan() {
        // On the open posture the arm lives inside the cloud path (it runs in front of the
        // transmission and is gated by `OnDeviceSegmenter.attempts`), never as a submit
        // arm — otherwise a refusal here would have nowhere to go but a second decision.
        let several = "book the flights and then renew the passport and also call the vet tomorrow"
        let plan = CaptureFlow.plan(
            text: several, localRead: AppBrain.provisionalDrafts(several), fromVoice: true,
            posture: .open, privateModelAvailable: true, boundaryPassAvailable: true)
        #expect(plan.arm != .boundaryPass)
    }

    @Test("Typed structure reveals instantly; the same words spoken earn the beat")
    func voiceEarnsTheBeat() {
        let drafts = AppBrain.provisionalDrafts(typedList)
        let typed = CaptureFlow.plan(
            text: typedList, localRead: drafts, fromVoice: false, posture: .open, privateModelAvailable: true,
            boundaryPassAvailable: false)
        let spoken = CaptureFlow.plan(
            text: typedList, localRead: drafts, fromVoice: true, posture: .open, privateModelAvailable: true,
            boundaryPassAvailable: false)
        #expect(typed.arm == .revealInstantly)
        #expect(spoken.arm == .revealAfterDwell)
        #expect(typed.route == .local && spoken.route == .local)
    }

    @Test("What the verifier escalates goes to the authority, with its reason on the plan")
    func authorityCarriesTheReason() {
        let plan = CaptureFlow.plan(
            text: oneThought, localRead: [], fromVoice: false, posture: .open, privateModelAvailable: true,
            boundaryPassAvailable: false)
        #expect(plan.route == .cloud)
        #expect(plan.arm == .authority(.emptyRead))
        #expect(plan.escalation == .emptyRead)
    }
}
