//
//  CaptureEscalationTests.swift
//  Project-EzraTests
//
//  The verifier behind device-first capture routing (2026-08-29), bracketed the way
//  every instrument here is bracketed: a known-clean read must pass, a known-broken
//  one must be caught, and each signal is pinned at its boundary so a threshold can't
//  drift silently. The property that makes the whole design safe — the verifier can
//  only ESCALATE — is structural (its one entry returns a reason or nil), so what
//  these tests guard is the signals staying honest, not the direction of authority.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CaptureEscalationTests {

    /// The production input shape: the deterministic pipeline's own read.
    private func read(_ text: String) async -> [TaskDraft] {
        IntentResolver.resolve((try? await HeuristicEngine().triage(rawText: text)) ?? [])
    }

    @Test("A clean everyday capture is kept — no reason, no transmission")
    func cleanReadKept() async {
        for text in ["renew my passport", "call the dentist about the crown"] {
            let drafts = await read(text)
            #expect(!drafts.isEmpty)
            #expect(CaptureEscalation.reason(for: text, drafts: drafts) == nil, Comment(rawValue: text))
        }
    }

    @Test("An empty read of a real line escalates — there is nothing to reveal")
    func emptyReadEscalates() {
        // A line with words the read could not turn into a draft goes to the authority.
        #expect(CaptureEscalation.reason(for: "the thing with the school", drafts: []) == .emptyRead)
        // A line the segmenter dropped whole (filler only) has nothing to escalate
        // (2026-09-18): it reveals locally as "Nothing actionable".
        #expect(CaptureEscalation.reason(for: "hmm", drafts: []) == nil)
    }

    @Test("A big dump escalates on the existing depth floors, by characters or items")
    func bigDumpEscalates() async {
        let longText = String(repeating: "another errand I keep forgetting to handle ", count: 12)
        let drafts = await read(longText)
        #expect(longText.count >= CaptureRoute.depthCharacterFloor)
        #expect(CaptureEscalation.reason(for: longText, drafts: drafts) == .bigDump)
    }

    @Test("One draft against several boundary signals reads as under-segmented")
    func underSegmentationEscalates() async {
        // The founding failure's shape: a run-on dictation with multiple time
        // expressions and no punctuation, collapsed to one draft.
        let runOn =
            "Cook dinner at 3PM make odd duck reservation tonight take my wife to "
            + "dinner next week book reservation at tiki tomorrow at 1pm"
        #expect(CaptureEscalation.timeSignals(in: runOn) >= CaptureEscalation.boundarySignalFloor)
        let drafts = await read(runOn)
        if drafts.count == 1 {
            #expect(CaptureEscalation.reason(for: runOn, drafts: drafts) == .underSegmented)
        } else {
            // If the heuristic ever learns to split this, the escalation correctly
            // stops firing — the verifier judges the read it was given, not the text.
            #expect(CaptureEscalation.reason(for: runOn, drafts: drafts) != .underSegmented)
        }
    }

    @Test("A compound noun is not an interior verb — a correct three-item read stays local")
    func compoundNounsAreNotVerbs() async {
        // "action plan" put a lexicon verb mid-sentence; counted, it was the fifth
        // signal against three drafts and sent a correctly-read capture to the cloud
        // — which on a stalled network meant thirty seconds behind the orb for an
        // answer the device already had (2026-09-02, simulator).
        let text =
            "Cook dinner at 3 PM, make an action plan this Sunday for the week and text mom about thanksgiving"
        #expect(CaptureEscalation.interiorVerbSignals(in: text) == 0)
        let drafts = await read(text)
        #expect(drafts.count == 3)
        #expect(CaptureEscalation.reason(for: text, drafts: drafts) == nil)
        // The signal still fires where a verb really does start a juxtaposed outcome.
        #expect(CaptureEscalation.interiorVerbSignals(in: "go to the park cook a lunch walk my dog") == 2)
    }

    @Test("The capture budget is sized by WHY the words left the device")
    func budgetFollowsEscalationReason() {
        // A second opinion over a read already in hand waits the standby budget; a
        // dump the local arm cannot represent, or an empty read, waits the full one.
        #expect(ModelDeadline.captureSeconds(for: .underSegmented) == ModelDeadline.captureStandbySeconds)
        #expect(ModelDeadline.captureSeconds(for: .unresolvedDetail) == ModelDeadline.captureStandbySeconds)
        #expect(ModelDeadline.captureSeconds(for: .lowCoverage) == ModelDeadline.captureStandbySeconds)
        #expect(ModelDeadline.captureSeconds(for: .bigDump) == ModelDeadline.captureSeconds)
        #expect(ModelDeadline.captureSeconds(for: .emptyRead) == ModelDeadline.captureSeconds)
        #expect(ModelDeadline.captureSeconds(for: nil) == ModelDeadline.captureSeconds)
        #expect(ModelDeadline.captureStandbySeconds < ModelDeadline.captureSeconds)
    }

    @Test("Case 50 — the named target — escalates instead of hiding seven outcomes")
    func caseFiftyEscalates() async {
        // The utterance the cloud arm exists for: 251 chars, nine outcomes, and the
        // deterministic read folds most of them away. The first verifier KEPT it
        // (under-segmentation only fired on exactly one draft), which made the policy
        // report's false-keep line its own counterexample within the hour. Pinned so
        // the escalation path's founding case can never silently go quiet again.
        let caseFifty =
            "take the kids to school tomorrow go to the park cook a lunch for three days "
            + "of the week for next week figure out what to finish up with work plan "
            + "birthday dinner with my wife walk my dog monday and tuesday plan the year "
            + "of 2027 review the year of 2026"
        let drafts = await read(caseFifty)
        #expect(CaptureEscalation.reason(for: caseFifty, drafts: drafts) == .underSegmented)
    }

    @Test("One connective does not make a compound errand two tasks")
    func singleConnectiveIsNotEvidence() async {
        // "buy bread and milk" is one task with one connective; escalating every
        // compound noun phrase would spend the quota the device-first policy saves.
        let text = "buy bread and milk"
        #expect(CaptureEscalation.connectiveSignals(in: text) < CaptureEscalation.boundarySignalFloor)
        let drafts = await read(text)
        #expect(CaptureEscalation.reason(for: text, drafts: drafts) == nil)
    }

    @Test("A spoken detail the resolver could not land escalates")
    func unresolvedDetailEscalates() async throws {
        let text = "call the landlord about the lease"
        var drafts = await read(text)
        try #require(!drafts.isEmpty)
        drafts[0].unresolved = [.date]
        #expect(CaptureEscalation.reason(for: text, drafts: drafts) == .unresolvedDetail)
    }

    @Test("Dropped content escalates; reorganized content does not")
    func coverageCatchesDroppedContent() async throws {
        let text = "schedule the plumber inspection before the kitchen renovation deadline"
        var drafts = await read(text)
        try #require(!drafts.isEmpty)
        // The read as produced covers its own words — kept.
        #expect(CaptureEscalation.reason(for: text, drafts: drafts) == nil)
        // Simulate a read that dropped most of the capture's content.
        drafts = [drafts[0]]
        drafts[0].title = "do a thing"
        #expect(CaptureEscalation.reason(for: text, drafts: drafts) == .lowCoverage)
    }

    @Test("Coverage abstains on short captures, where the ratio is noise")
    func coverageAbstainsWhenShort() {
        #expect(CaptureEscalation.coverage(of: "buy milk now", by: []) == nil)
    }

    @Test("The signals are pinned at their floors")
    func signalFloors() {
        #expect(CaptureEscalation.boundarySignalFloor == 2)
        #expect(CaptureEscalation.connectiveSignals(in: "call mom, email bob, and fix the sink") >= 2)
        #expect(CaptureEscalation.timeSignals(in: "dentist tomorrow then the gym at 6pm") >= 2)
        #expect(CaptureEscalation.timeSignals(in: "sort out the garage") == 0)
        // The clock vocabulary is the resolver's: "noon" and "9 p.m." are occasions.
        #expect(CaptureEscalation.timeSignals(in: "make lunch at noon") == 1)
        #expect(CaptureEscalation.timeSignals(in: "cook dinner at 9 p.m.") == 1)
        // A day word and the clock beside it are ONE occasion — counted as two, this
        // real single-thought capture nagged "sounds like several things" and would
        // have escalated a one-line capture to the cloud.
        #expect(CaptureEscalation.timeSignals(in: "clean my room tomorrow at 3 PM") == 1)
        #expect(CaptureEscalation.timeSignals(in: "take micah to daycare monday at 8 am") == 1)
        // …in either order: the clock before the day is still one occasion.
        #expect(CaptureEscalation.timeSignals(in: "Cook at 3PM today") == 1)
        #expect(CaptureEscalation.timeSignals(in: "make a plan this sunday") == 1)
        // A trailing dictation comma is not a boundary.
        #expect(CaptureEscalation.connectiveSignals(in: "Clean my car tomorrow,") == 0)
        #expect(!PrivateCaptureEngine.soundsLikeSeveralThings("Clean my car tomorrow,"))
        #expect(!PrivateCaptureEngine.soundsLikeSeveralThings("Cook at 3PM today"))
        #expect(
            CaptureEscalation.timeSignals(
                in: "pick up groceries at noon make an action plan this sunday for the week") == 2)
    }
}
