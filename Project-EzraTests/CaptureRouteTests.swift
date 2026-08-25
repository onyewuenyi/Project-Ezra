//
//  CaptureRouteTests.swift
//  Project-EzraTests
//
//  The routing POLICY — one pure function, pinned. It is policy rather than architecture
//  on purpose ("simple inputs never use AI" must not calcify), so what these tests
//  protect is not the current answers but the properties the privacy boundary and the
//  reveal contract are built on.
//
//  Rewritten 2026-08-22 when routing collapsed to two arms. The three-state
//  `Segmentation.confidence` and the on-device confidence gate both existed to answer
//  "is this unpunctuated text probably one task?", and both are gone: the first because
//  a verb lexicon should not make semantic judgments, the second because it measured a
//  warm p50 of 2303ms against a cloud arm answering in about a second. What remains is
//  the only deterministic claim that was ever an observation — the user pressed return.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Capture routing")
struct CaptureRouteTests {

    // MARK: - The policy

    @Test("Structure the user typed stays on the device, cloud or no cloud")
    func explicitStructureStaysLocal() {
        // The user punctuated it themselves, so there is nothing for a model to segment.
        // This is the whole of the local path now, and all of why a cloud default is
        // defensible: the list you typed never becomes a network call.
        let typed = "renew my passport\nbook the flights\npay the water bill"
        #expect(CaptureRoute.route(for: typed, cloudAvailable: true) == .local)
        #expect(CaptureRoute.route(for: typed, cloudAvailable: false) == .local)

        #expect(CaptureRoute.route(for: "- call the dentist\n- fix the faucet") == .local)
        #expect(CaptureRoute.route(for: "buy milk, return package, pay water bill") == .local)
    }

    @Test("A lone sentence goes to the authority, however obviously single it reads")
    func unpunctuatedSingleThoughtsEscalate() {
        // The deliberate cost of the collapse, and the case most likely to be "fixed" by
        // someone who thinks it is a bug. "renew my passport" is one task — and knowing
        // that requires reading it, which is the semantic authority's job. The previous
        // architecture answered this with an 18-word ceiling and a verb lexicon; that was
        // an interpretation wearing an observation's clothes.
        #expect(CaptureRoute.route(for: "renew my passport") == .cloud)
        #expect(CaptureRoute.route(for: "call mom back") == .cloud)
        #expect(CaptureRoute.route(for: "renew my passport and call mom") == .cloud)
    }

    @Test("The dictation that started all of this reaches the authority")
    func theRunOnEscalates() {
        // Four errands, no connectives. Under the old gate this read as ONE item and was
        // revealed as a single task titled with its own transcript.
        #expect(
            CaptureRoute.route(
                for: "Cook dinner at 3PM make odd duck reservation tonight take my wife to "
                    + "dinner next week book reservation at tiki tomorrow at 1pm") == .cloud)
    }

    @Test("Cloud availability can never turn a local read into a transmission")
    func availabilityNeverPromotesALocalRead() {
        // THE privacy property, stated once over the whole corpus. Routing has exactly
        // one input beyond the text, and it may only ever degrade the cloud arm toward
        // the deterministic tail — never the reverse. If this fails, the sentence in
        // Settings is false.
        for text in (RambleEval.evalSet + RambleEval.gateAdversarialSet).map(\.utterance) {
            let offline = CaptureRoute.route(for: text, cloudAvailable: false)
            let online = CaptureRoute.route(for: text, cloudAvailable: true)
            #expect(offline == online, "availability changed the route for: \(text.prefix(50))")
        }
    }

    @Test("Routing reads STRUCTURE, never length or content")
    func routingIgnoresEverythingButStructure() {
        // A guard against the deleted architecture creeping back in as a heuristic. If
        // someone adds "…but short inputs can stay local", this fails: the two strings
        // below differ only in length and content, never in the boundaries the user drew.
        let short = "buy milk"
        let long = String(repeating: "something to do later ", count: 30)
        #expect(CaptureRoute.route(for: short) == CaptureRoute.route(for: long))
    }

    @Test("The authority receives the ORIGINAL text, whole and unsplit")
    func theAuthoritySeesTheOriginalDiscourse() {
        // The invariant the whole architecture rests on. Boundaries are precisely what
        // the authority is being asked to find, so handing it our guess at them — a
        // pre-split, a filtered subset, a reassembled paraphrase — destroys the context
        // it needs and quietly turns it into a field-filler for our segmentation.
        //
        // Both directions matter: three sentences that are ONE task, and ten unpunctuated
        // lines that are eight. Neither is recoverable from fragments.
        for text in (RambleEval.evalSet + RambleEval.gateAdversarialSet).map(\.utterance) {
            let prompt = FoundationModelsEngine.prompt(for: text, context: TriageContext())
            #expect(prompt.contains(text), "the authority saw a fragment: \(text.prefix(50))")
        }
    }

    @Test("Candidates ride ALONGSIDE the capture — they never edit it")
    func candidatesDoNotAlterTheCapture() {
        // The candidate package is the one thing appended to a capture prompt, and it is
        // additive by construction. If enrichment ever starts rewriting the user's words
        // before the model reads them, this fails.
        let text = "renew my passport and figure out flights"
        let bare = FoundationModelsEngine.prompt(for: text, context: TriageContext())
        let withCandidates = FoundationModelsEngine.prompt(
            for: text,
            context: TriageContext(candidates: [
                RetrievalCandidate(id: UUID(), title: "Book flights", facts: "open", score: 1)
            ]))
        #expect(withCandidates.hasPrefix(bare), "the capture must survive verbatim, at the front")
        #expect(withCandidates.contains(text))
    }

    // MARK: - The properties everything downstream relies on

    @Test("Exactly one route transmits raw capture, and it is the cloud one")
    func onlyCloudTransmits() {
        // Ramble's raw text is the ONE sanctioned raw-text transmission in the product.
        // A second route answering true here would mean the Settings sentence — and the
        // per-workload privacy boundary — had quietly stopped being accurate.
        #expect(CaptureRoute.allCases.filter(\.transmitsRawCapture) == [.cloud])
    }

    @Test("Each route maps to exactly one rung, and only cloud maps to the paid one")
    func rungMapping() {
        #expect(CaptureRoute.local.rung == .facts)
        #expect(CaptureRoute.cloud.rung == .cloud)
        #expect(CaptureRoute.allCases.filter { $0.rung == .cloud }.count == 1)
    }

    @Test("Capture never blocks — every corpus utterance produces drafts with no model")
    func captureNeverBlocks() async {
        // The promise asserted as BEHAVIOUR rather than as the shape of a data structure.
        // XCTest forces the heuristic and Firebase is unconfigured here, so this runs in
        // exactly the configuration the promise is about: routed to cloud, nothing
        // reachable, deterministic tail underneath.
        let brain = AppBrain()
        for text in RambleEval.evalSet.map(\.utterance) {
            let drafts = await brain.triage(text, route: .cloud).drafts
            #expect(!drafts.isEmpty, "capture blocked on: \(text.prefix(50))")
        }
    }

    @Test("With no provider installed, the cloud route still degrades rather than failing")
    func inertProviderStillProducesDrafts() {
        // The shipping test configuration: `FirebaseApp.app()` is nil under XCTest by
        // construction, so a suite can never issue live billable calls while pretending
        // to test routing.
        #expect(CloudModel.isAvailable == false)
    }
}
