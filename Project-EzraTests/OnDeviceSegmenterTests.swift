import Foundation
import Testing

@testable import Project_Ezra

/// The boundary pass's contract (WS4 / Campaign 5, P-A).
///
/// Everything here is the PURE half — the cut and the gate. The model is not involved and
/// deliberately cannot be: `onDeviceModelAvailable()` is hard-false under the test host, so
/// what CI can pin is the artifact-handling, which is where the trust story lives. The
/// generation itself is measured on device by `-FMPrimitives`.
///
/// The three properties the arm is built on are each a test below: nothing can be invented
/// (every fragment is a substring), nothing can be lost (the fragments tile the text), and
/// an artifact that does not fully ground is refused WHOLE rather than partly used.
@Suite("on-device segmenter")
@MainActor
struct OnDeviceSegmenterTests {

    // MARK: - The cut

    @Test("cuts a spoken run-on at the anchors the model named")
    func cutsAtAnchors() throws {
        let text = "call the dentist about thursday then pick up the dry cleaning and email sarah the invoice"
        let fragments = try #require(
            OnDeviceSegmenter.cut(text, at: ["call the dentist", "pick up the dry", "email sarah"]))
        #expect(fragments.count == 3)
        #expect(fragments[0].hasPrefix("call the dentist"))
        #expect(fragments[1].hasPrefix("pick up the dry cleaning"))
        #expect(fragments[2] == "email sarah the invoice")
    }

    @Test("nothing can be invented — every fragment is the person's own words")
    func fragmentsAreSubstrings() throws {
        let text = "book the flights then sort the visa forms and tell mum we are going"
        let fragments = try #require(
            OnDeviceSegmenter.cut(text, at: ["book the flights", "sort the visa", "tell mum"]))
        for fragment in fragments {
            #expect(text.contains(fragment), "\(fragment) is not in the capture")
        }
    }

    @Test("nothing can be lost — the fragments tile the whole capture")
    func fragmentsTileTheText() throws {
        let text = "water the plants then take the bins out and change the smoke alarm battery"
        let fragments = try #require(
            OnDeviceSegmenter.cut(text, at: ["water the plants", "take the bins", "change the smoke"]))
        let rejoined = fragments.joined(separator: " ")
        for word in text.split(separator: " ") {
            #expect(rejoined.contains(word), "the cut dropped \"\(word)\"")
        }
    }

    @Test("a lead-in before the first anchor is kept, not dropped")
    func leadInSurvives() throws {
        // The model quite reasonably starts its first anchor at the verb. Everything the
        // person said before it still belongs to the first fragment — dropping it is the
        // one way this arm could lose words.
        let text = "so tomorrow morning renew the passport and then book the dentist"
        let fragments = try #require(
            OnDeviceSegmenter.cut(text, at: ["renew the passport", "book the dentist"]))
        #expect(fragments[0].contains("tomorrow morning"))
    }

    @Test("matching survives case, punctuation and spacing the model did not reproduce")
    func matchingIsTokenWise() throws {
        let text = "Call Mom's office,  then  pick up the parcel"
        let fragments = try #require(OnDeviceSegmenter.cut(text, at: ["call mom's", "pick up the"]))
        #expect(fragments.count == 2)
        #expect(fragments[1] == "pick up the parcel")
    }

    // MARK: - Refusals

    @Test("an anchor that is not in the capture refuses the WHOLE artifact")
    func ungroundedAnchorRefusesEverything() {
        // Partly using it would silently merge two outcomes back together — the exact
        // failure the arm exists to fix — so the answer is nil and the cloud runs.
        let text = "call the dentist then pick up the dry cleaning"
        #expect(OnDeviceSegmenter.cut(text, at: ["call the dentist", "buy printer paper"]) == nil)
    }

    @Test("anchors must be monotonic — a repeated or reordered artifact refuses")
    func anchorsMustAdvance() {
        let text = "call the dentist then pick up the dry cleaning"
        #expect(OnDeviceSegmenter.cut(text, at: ["call the dentist", "call the dentist"]) == nil)
        #expect(OnDeviceSegmenter.cut(text, at: ["pick up the dry", "call the dentist"]) == nil)
    }

    @Test("fewer than two boundaries is no gain, not an answer")
    func oneAnchorIsNoGain() {
        let text = "call the dentist then pick up the dry cleaning"
        #expect(OnDeviceSegmenter.cut(text, at: ["call the dentist"]) == nil)
        #expect(OnDeviceSegmenter.cut(text, at: []) == nil)
    }

    @Test("an implausible anchor count refuses rather than shredding the capture")
    func tooManyAnchorsRefuse() {
        let text = String(repeating: "one two three four five six ", count: 3)
        let anchors = (0..<(OnDeviceSegmenter.maxAnchors + 1)).map { _ in "one two" }
        #expect(OnDeviceSegmenter.cut(text, at: anchors) == nil)
    }

    @Test("an empty anchor refuses")
    func emptyAnchorRefuses() {
        #expect(OnDeviceSegmenter.cut("call the dentist then pick up milk", at: ["", "pick up"]) == nil)
    }

    // MARK: - The gate

    @Test("the arm handles ONLY under-segmentation")
    func handlesOnlyBoundaryFailures() {
        #expect(OnDeviceSegmenter.handles(.underSegmented))
        for reason in CaptureEscalationReason.allCases where reason != .underSegmented {
            #expect(!OnDeviceSegmenter.handles(reason), "\(reason) is not a boundary failure")
        }
        #expect(!OnDeviceSegmenter.handles(nil))
    }

    @Test("the arm is inert under the test host — no model, nothing attempted")
    func inertWithoutAModel() {
        // Two conditions hold it shut here and each matters on its own: the routing
        // constant is off, and there is no on-device model under XCTest.
        #expect(!OnDeviceSegmenter.attempts(.underSegmented))
    }

    @Test("with no model the pass refuses instead of hanging or throwing")
    func refusesWithoutAModel() async {
        let outcome = await OnDeviceSegmenter.segment(text: "call the dentist then pick up milk")
        #expect(outcome == .refused(.unavailable))
    }

    // MARK: - The validator keeps the last word

    @Test("a cut that still reads under-segmented is refused by the existing validator")
    func validatorStillDecides() {
        // The whole acceptance rule, exercised on the pieces the arm composes: cut →
        // drafts → the SAME `CaptureEscalation.reason`. A model that answered with two
        // boundaries on a capture holding five outcomes gets no credit for trying.
        let text =
            "call the dentist on thursday then pick up the dry cleaning and email sarah the invoice "
            + "and book the car in for friday and text mum about sunday"
        let fragments = OnDeviceSegmenter.cut(text, at: ["call the dentist", "pick up the dry"])
        let drafts = AppBrain.drafts(fromClauses: fragments ?? [])
        #expect(CaptureEscalation.reason(for: text, drafts: drafts) != nil)
    }

    @Test("a cut the deterministic read could not make resolves into one draft per fragment")
    func cutResolvesThroughTheSamePipeline() throws {
        let text = "call the dentist then pick up the dry cleaning then email sarah the invoice"
        let fragments = try #require(
            OnDeviceSegmenter.cut(text, at: ["call the dentist", "pick up the dry", "email sarah"]))
        let drafts = AppBrain.drafts(fromClauses: fragments)
        #expect(drafts.count == 3)
        // Fully populated, exactly like any other capture — the deterministic pipeline
        // does every field job, which is the reason the schema only asks for boundaries.
        #expect(drafts.allSatisfy { !$0.title.isEmpty && !$0.category.isEmpty })
        // And each draft carries the fragment it came from, so a later model pass can
        // still match it (`DraftMerge` Pass C).
        #expect(drafts.allSatisfy { $0.provisionalSource != nil })
    }

    @Test("a conjunction stranded by the cut does not survive into a title")
    func strandedConjunctionIsCleaned() throws {
        // Cutting at the model's anchor leaves the connective on the END of the PREVIOUS
        // fragment ("…the dry cleaning and"), which is the one artifact this approach
        // creates that generating tasks would not. `HeuristicEngine.cleanTitle` already
        // owns that shape — a dangling function word at the end of a cut-off dictation —
        // and this pins that the two actually meet.
        let text = "call the dentist and pick up the dry cleaning and email sarah the invoice"
        let fragments = try #require(
            OnDeviceSegmenter.cut(text, at: ["call the dentist", "pick up the dry", "email sarah"]))
        let drafts = AppBrain.drafts(fromClauses: fragments)
        for draft in drafts {
            let title = draft.title.lowercased()
            #expect(!title.hasSuffix(" and"), "\(draft.title) kept the connective the cut stranded")
            #expect(!title.hasSuffix(" then"), "\(draft.title) kept the connective the cut stranded")
        }
    }

    // MARK: - The arm's structural privacy

    @Test("the boundary pass never references the cloud — structurally")
    func noCloudReference() throws {
        // The arm's whole claim is that it REMOVES a transmission. If this file could
        // reach the cloud seam, the claim would rest on discipline rather than on
        // architecture — and the absence of a symbol is what a grep can pin and a type
        // system cannot. Prose may name the cloud; code may not touch it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        let content = try String(
            contentsOf: root.appendingPathComponent("AI/OnDeviceSegmenter.swift"), encoding: .utf8)
        #expect(
            !content.contains("CloudModel.") && !content.contains("GeminiProvider")
                && !content.contains("FirebaseAI"),
            "the boundary pass touches the cloud seam — it can no longer claim to be on-device")
    }
}
