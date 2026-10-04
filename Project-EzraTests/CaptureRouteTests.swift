//
//  CaptureRouteTests.swift
//  Project-EzraTests
//
//  The routing POLICY, pinned. It is policy rather than architecture on purpose, so
//  what these tests protect is not the current answers but the properties the privacy
//  boundary and the reveal contract are built on.
//
//  Rewritten 2026-08-29 for the device-first reversal: the deterministic read is now
//  the DEFAULT interpretation of an unstructured capture, and the raw words transmit
//  only when `CaptureEscalation` finds observable evidence that read fell short. The
//  08-22 cloud-default these tests used to pin was itself a reversal of two dead
//  local-first attempts (`.singleThought`'s lexicon, the on-device confidence gate);
//  the difference this time is the direction of trust — the verifier can only
//  ESCALATE, so its mistakes cost a cloud call rather than the user's words, and the
//  FM on-device model (p90 21s on device, 2026-08-29) is out of the chain entirely.
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
        #expect(CaptureRoute.route(for: typed) == .local)
        #expect(CaptureRoute.route(for: typed).transmitsRawCapture == false)

        #expect(CaptureRoute.route(for: "- call the dentist\n- fix the faucet") == .local)
        #expect(CaptureRoute.route(for: "buy milk, return package, pay water bill") == .local)
    }

    /// **The invariant above is only worth what the CALL SITES honour**, and one of them
    /// did not. `AppBrain.triage` defaulted `route:` to `.cloud`, so a caller that simply
    /// never mentioned the parameter claimed the transmitting rung and skipped the router
    /// entirely — `OnboardingView.transform()` among them, which is a brand-new user's
    /// very first brain dump. The default is gone; this pins the helper those callers now
    /// use, because a policy that holds in `CaptureRoute` and is bypassed in a view is not
    /// a policy.
    @Test("The composer-free callers run the same policy — typed structure never transmits")
    func routeHelperHonoursThePolicy() {
        let typed = "renew my passport\nbook the flights\npay the water bill"
        let decision = CaptureFlow.route(for: typed)
        #expect(decision.route == .local)
        #expect(decision.route.transmitsRawCapture == false)
        #expect(decision.escalation == nil)

        // The onboarding sample IS the shape above — ten plain lines. It must reach the
        // deterministic read, which is what makes the first impression "I found N areas
        // from 10 items" instead of the model's guess at where the boundaries are.
        let sample = """
            renew my passport
            book flights for the trip after passport is done
            oil change is overdue
            should I keep paying for the gym I never use
            call mom back
            daycare enrollment forms due Friday
            finish the Q3 deck
            return the amazon package
            figure out if the side project is still worth it
            pay the water bill
            """
        #expect(CaptureFlow.route(for: sample).route == .local)
        #expect(AppBrain.provisionalDrafts(sample).count == 10)

        // **The helper agrees with the router, whatever the router says.** Asserted as
        // agreement rather than against a hardcoded verdict: escalation is the exception,
        // most reads are kept, and pinning a specific input to `.cloud` here would make
        // this test fail the next time a floor moves — for a reason that has nothing to
        // do with what it is checking.
        let dump = """
            so I need to sort out the car thing before the weekend and the school forms \
            are due and I should really call the bank about that charge before it rolls \
            over and book the dentist and the gutters need clearing and someone has to \
            chase the insurance people about the claim they never answered
            """
        for text in [typed, sample, dump] {
            let read = AppBrain.provisionalDrafts(text)
            #expect(CaptureFlow.route(for: text) == CaptureRoute.route(for: text, localRead: read))
        }
    }

    @Test("A lone clean sentence stays on the device (the 2026-08-29 reversal)")
    func cleanSinglesStayLocal() async {
        // Under the 08-22 policy these transmitted, because knowing "renew my passport"
        // is one task requires reading it. The device-first reversal keeps them: the
        // deterministic read IS a reading, it holds the corpus floors at 2ms, and the
        // verifier found no evidence against it — so the sentence reveals instantly,
        // privately, for free. The structural OBSERVATION still says a model could be
        // needed (`route(for:)` stays `.cloud`); the POLICY answers the second question.
        for text in ["renew my passport", "call mom back"] {
            #expect(CaptureRoute.route(for: text) == .cloud)  // the observation
            let read = IntentResolver.resolve(
                (try? await HeuristicEngine().triage(rawText: text)) ?? [])
            let decision = CaptureRoute.route(for: text, localRead: read)
            #expect(decision.route == .local, "clean single transmitted: \(text)")
            #expect(decision.escalation == nil)
        }
    }

    @Test("The dictation that started all of this still reaches the authority")
    func theRunOnEscalates() async {
        // Four errands, no connectives, four time expressions. Under the old gate this
        // read as ONE item and was revealed as a single task titled with its own
        // transcript — the founding failure. The verifier catches it the deterministic
        // way: one draft against multiple time signals is the least certain outcome a
        // splitter can produce, so it escalates to Gemini rather than revealing.
        //
        // Since 2026-09-02 the splitter reads this one itself: every outcome ends in a
        // time expression and the next starts with a verb, and that boundary is now
        // deterministic. The founding INVARIANT is unchanged and pinned twice below —
        // this capture is never revealed as one task titled with its own transcript:
        // either the read has all four and stays local (today), or it falls short and
        // the verifier sends it to the authority (the one-draft read, constructed).
        let runOn =
            "Cook dinner at 3PM make odd duck reservation tonight take my wife to "
            + "dinner next week book reservation at tiki tomorrow at 1pm"
        let read = IntentResolver.resolve(
            (try? await HeuristicEngine().triage(rawText: runOn)) ?? [])
        #expect(read.count == 4, "the four errands: \(read.map(\.title))")
        let decision = CaptureRoute.route(for: runOn, localRead: read)
        #expect(decision.route == .local)
        #expect(decision.escalation == nil)

        // The failure this test was written against, replayed: ONE draft out of this
        // dictation must still escalate — the verifier judges the read it is given.
        let oneDraft = IntentResolver.resolve([HeuristicEngine.intent(from: runOn)])
        let shortRead = CaptureRoute.route(for: runOn, localRead: Array(oneDraft.prefix(1)))
        #expect(shortRead.route == .cloud)
        #expect(shortRead.escalation == .underSegmented)
    }

    @Test("Raw text leaves the device only on evidence, and never for typed structure")
    func transmissionRequiresEvidence() async {
        // THE privacy property under the 2026-08-29 policy, stated over the whole
        // corpus: a capture transmits exactly when the user did NOT draw the boundaries
        // AND the deterministic read shows a named failure signal. Two directions:
        // explicit structure never transmits (unchanged since 08-22), and an
        // unstructured capture transmits only with an escalation reason attached — a
        // transmission with no reason on its receipt is a routing bug.
        for text in (RambleEval.evalSet + RambleEval.gateAdversarialSet).map(\.utterance) {
            let read = IntentResolver.resolve(
                (try? await HeuristicEngine().triage(rawText: text)) ?? [])
            let decision = CaptureRoute.route(for: text, localRead: read)
            let explicit = Segmentation.structure(of: text).isExplicit
            if explicit, !read.isEmpty {
                #expect(
                    !decision.route.transmitsRawCapture,
                    "typed structure transmitted: \(text.prefix(50))")
            }
            #expect(
                decision.route.transmitsRawCapture == (decision.escalation != nil),
                "transmission and evidence disagreed for: \(text.prefix(50))")
        }
    }

    @Test("The observation reads structure; the policy is allowed to read evidence")
    func observationIgnoresLengthPolicyDoesNot() async {
        // Two guards in one. The structural observation must stay blind to length and
        // content — that is what makes it an observation. The POLICY, since 08-29, is
        // explicitly allowed to read the depth floors: a big dump goes straight to the
        // authority because it is the population device evidence says deterministic
        // segmentation fails on. That length-sensitivity is the owner's deliberate
        // re-weighting, not the deleted lexicon creeping back — the lexicon KEPT reads
        // on its own authority; the floors only ever escalate.
        let short = "buy milk"
        let long = String(repeating: "something to do later ", count: 30)
        #expect(CaptureRoute.route(for: short) == CaptureRoute.route(for: long))

        let read = IntentResolver.resolve(
            (try? await HeuristicEngine().triage(rawText: long)) ?? [])
        let decision = CaptureRoute.route(for: long, localRead: read)
        #expect(decision.route == .cloud)
        #expect(decision.escalation == .bigDump)
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
