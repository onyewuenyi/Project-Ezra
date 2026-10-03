//
//  CaptureEscalationFillerTests.swift
//  Project-EzraTests
//
//  An empty read escalates because the deterministic pass may have missed a task —
//  unless there was nothing to read. "hmm ok so" is not a capture a model could find a
//  task in, and sending it to the cloud bought a 30 s wait to learn nothing.
//

import Testing

@testable import Project_Ezra

@Suite("Capture escalation — nothing in, nothing to escalate")
struct CaptureEscalationFillerTests {

    @Test("A filler-only line with no drafts does not escalate")
    func fillerDoesNotEscalate() {
        #expect(CaptureEscalation.reason(for: "hmm ok so", drafts: []) == nil)
        #expect(CaptureEscalation.reason(for: "um", drafts: []) == nil)
    }

    @Test("A real line the read could not turn into a draft still escalates as an empty read")
    func realEmptyReadStillEscalates() {
        #expect(CaptureEscalation.reason(for: "the thing with the school", drafts: []) == .emptyRead)
    }

    @Test("The router agrees: filler stays local, a real empty read goes to the authority")
    func routerAgrees() {
        let filler = CaptureRoute.route(for: "hmm ok so", localRead: [])
        #expect(filler.route == .local && filler.escalation == nil)
        let real = CaptureRoute.route(for: "the thing with the school", localRead: [])
        #expect(real.route == .cloud && real.escalation == .emptyRead)
    }
}
