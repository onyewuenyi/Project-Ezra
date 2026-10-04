//
//  CapturePillarTests.swift
//  Project-EzraTests
//
//  The capture pillar's features, pinned at the seam that makes each true:
//  F-01 the intent hands words over once and never creates a task; F-02 a spoken
//  conversation escalates with permission to return nothing, typed text never does;
//  F-03 the posture is persisted and outranks the router; F-04 the parked excerpt;
//  F-05 the two new learned shapes fill an empty estimate and add urgency.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("F-02 · the conversation guard")
struct ConversationGuardTests {

    /// A conversation the microphone caught — dictated, with sentence punctuation.
    static let caught =
        "So I was thinking about it. Yeah, I don't know. Did you see what she said? "
        + "It's fine, honestly. We can talk about it later. Okay, what do you want for dinner?"

    /// A real spoken to-do list of the same length.
    static let list =
        "Call the dentist tomorrow. Book the flights for the trip. Pick up the dry cleaning. "
        + "Renew the car insurance. Buy a birthday card for Maya. Fix the garage door."

    @Test("Talk reads as talk; a list of things to do does not")
    func detector() {
        #expect(CaptureEscalation.conversationSignal(in: Self.caught))
        #expect(!CaptureEscalation.conversationSignal(in: Self.list))
        // Too short to be a conversation — three items reveal, whatever they sound like.
        #expect(!CaptureEscalation.conversationSignal(in: "Yeah. I know. Okay."))
    }

    @MainActor
    @Test("A SPOKEN conversation escalates as .conversation; the same words TYPED never transmit")
    func voiceOnly() {
        let drafts = AppBrain.provisionalDrafts(Self.caught)
        let spoken = CaptureRoute.route(for: Self.caught, localRead: drafts, fromVoice: true)
        #expect(spoken.route == .cloud)
        #expect(spoken.escalation == .conversation)
        let typed = CaptureRoute.route(for: Self.caught, localRead: drafts, fromVoice: false)
        #expect(typed.route == .local)
        #expect(typed.escalation == nil)
    }

    @MainActor
    @Test("A spoken to-do list still reveals locally")
    func spokenListStaysLocal() {
        let drafts = AppBrain.provisionalDrafts(Self.list)
        let spoken = CaptureRoute.route(for: Self.list, localRead: drafts, fromVoice: true)
        #expect(spoken.escalation != .conversation)
    }

    @Test("The conversation budget is the answer-in-hand budget: a stalled cloud never makes talk wait long")
    func budget() {
        #expect(ModelDeadline.captureSeconds(for: .conversation) == ModelDeadline.captureStandbySeconds)
    }
}

@Suite("The privacy sentences, with capture on the device only")
struct CapturePostureTests {

    @Test("The data-boundary sentences name no vendor, in either configuration")
    func boundarySpeaks() {
        for reachable in [true, false] {
            for sentence in DataBoundary.current(cloudReachable: reachable).sentences {
                for vendor in ["Gemini", "Firebase", "Google", "Apple", "token", "credit", "quota", "model"] {
                    #expect(!sentence.localizedCaseInsensitiveContains(vendor), "\(sentence) names \(vendor)")
                }
            }
        }
        #expect(
            DataBoundary.current(cloudReachable: false).capture
                == "Everything you capture is understood on this device.")
    }

    /// **The promise that holds everywhere is about US, not about the device.** It read
    /// "Your corrections and your history never leave this device" until 2026-09-20, and
    /// that was false: the private store mirrors every entity to the person's own iCloud
    /// (`NSPersistentCloudKitContainerOptions`, `.private` scope, no exclusions). What it
    /// was really describing is the `CKShare` — those entities carry no `household` edge,
    /// so they never reach anyone invited. A privacy sentence that is wrong in the
    /// person's favour is still wrong, and this one sits on the screen where the app asks
    /// to be believed.
    @Test("What never leaves claims the two things that are actually true")
    func theNeverSentenceIsAccurate() {
        let never = DataBoundary.neverSentence
        #expect(never.localizedCaseInsensitiveContains("never reach us"))
        #expect(never.localizedCaseInsensitiveContains("invite"))
        #expect(
            !never.localizedCaseInsensitiveContains("never leave this device"),
            "they do leave it — to the person's own iCloud")
        // And the sync sentence is where that copy is accounted for, in a place a person
        // already understands.
        #expect(DataBoundary.syncSentence.localizedCaseInsensitiveContains("your own iCloud"))
        for sentence in [never, DataBoundary.syncSentence] {
            for vendor in ["CloudKit", "Core Data", "Gemini", "Firebase", "Google", "AI"] {
                #expect(!sentence.contains(vendor), "\(sentence) names \(vendor)")
            }
        }
    }

    /// The short form onboarding uses. It exists because the paragraph does not fit under
    /// a 220-point editor at accessibility sizes — but a shorter promise that is a
    /// WEAKER promise would be worse than no line at all, so it is pinned against the
    /// long one in both directions.
    @Test("The short capture line makes the same promise as the paragraph")
    func theShortBoundaryAgreesWithTheLongOne() {
        let quiet = DataBoundary.captureShort(cloudReachable: false)
        // The whole point of the unreachable arm: the words are not sent to be read, so
        // say so plainly rather than warning about a transmission that cannot happen.
        // **Scoped to "understood", not "anywhere" (2026-09-20)** — this line appears
        // without the sync sentence beside it, and on a signed-in phone the person's own
        // copy does reach their own iCloud. An over-broad promise is still a wrong one.
        #expect(quiet.localizedCaseInsensitiveContains("not sent"))
        #expect(quiet.localizedCaseInsensitiveContains("understood"))
        #expect(!quiet.localizedCaseInsensitiveContains("cloud"))

        let open = DataBoundary.captureShort(cloudReachable: true)
        // The common case first, the exception named — the same order as the paragraph.
        #expect(open.localizedCaseInsensitiveContains("on your device"))
        #expect(open.localizedCaseInsensitiveContains("cloud"))
        #expect(open.localizedCaseInsensitiveContains("may"), "an exception, never a default")

        for line in [quiet, open] {
            #expect(line.count < 100, "it has to fit where the paragraph did not")
            for vendor in ["Gemini", "Firebase", "Google", "Apple", "AI", "model"] {
                #expect(!line.contains(vendor), "\(line) names \(vendor)")
            }
        }
    }
}

@Suite("F-04 · parked captures are findable")
struct ParkedCapturesTests {

    @Test("The excerpt is the first few words, marked when cut")
    func excerpt() {
        #expect(ParkedCapturesRow.excerpt("call the dentist") == "call the dentist")
        #expect(
            ParkedCapturesRow.excerpt("take the kids to school tomorrow and then go to the park")
                == "take the kids to school tomorrow…")
    }
}

@Suite("F-05 · capture learns effort and urgency")
struct CaptureLearningTests {

    @MainActor
    @Test("The same estimate on similar tasks twice becomes a rule; it fills an EMPTY estimate only")
    func effortRule() {
        let context = TestStore.makeContext()
        let a = TaskItem(title: "Mow the back lawn", in: context)
        let b = TaskItem(title: "Mow the front lawn", in: context)
        let corrections = [a, b].map { task in
            Correction(
                taskUUID: task.uuid, fieldCorrected: "effortMinutes", aiValue: "", userValue: "60",
                in: context)
        }
        let rules = CorrectionProfile.rules(from: corrections, tasks: [a, b])
        #expect(rules.contains(.effortForKeyword(keyword: "mow", minutes: 60)))
        var intent = TaskIntent(
            title: "Mow the side strip", category: "Home", dateExpression: nil, personReference: nil,
            blockerPhrase: nil, confidence: 0.7, isJudgmentCall: false, reasoning: "")
        intent = IntentResolver.applyRules(rules, to: intent)
        #expect(intent.effortMinutes == 60)
        var spoken = intent
        spoken.effortMinutes = 15
        #expect(IntentResolver.applyRules(rules, to: spoken).effortMinutes == 15)
        #expect(CorrectionProfile.instructionLines(rules)?.contains("about 60 minutes") == true)
    }

    @MainActor
    @Test("Flagging similar tasks urgent twice becomes a rule that adds urgency, never clears it")
    func urgentRule() {
        let context = TestStore.makeContext()
        let a = TaskItem(title: "Pay the daycare invoice", in: context)
        let b = TaskItem(title: "Pay the daycare deposit", in: context)
        let corrections = [a, b].map { task in
            Correction(
                taskUUID: task.uuid, fieldCorrected: "urgent", aiValue: "false", userValue: "true",
                in: context)
        }
        let rules = CorrectionProfile.rules(from: corrections, tasks: [a, b])
        #expect(rules.contains(.urgentForKeyword(keyword: "daycare")))
        var intent = TaskIntent(
            title: "Email the daycare about pickup", category: "Family", dateExpression: nil,
            personReference: nil, blockerPhrase: nil, confidence: 0.7, isJudgmentCall: false, reasoning: "")
        intent = IntentResolver.applyRules(rules, to: intent)
        #expect(intent.isUrgent)
        // One correction is a mood, not a rule.
        let once = CorrectionProfile.rules(from: [corrections[0]], tasks: [a])
        #expect(!once.contains(.urgentForKeyword(keyword: "daycare")))
    }
}

@MainActor
@Suite("F-01 · capture without opening the app")
struct CaptureIntentTests {

    @Test("The intent hands words over once; consuming them empties the slot; blanks are ignored")
    func handOver() {
        let pending = PendingCapture()
        #expect(pending.consume() == nil)
        pending.hand("  book the dentist  ", source: .siri)
        let taken = pending.consume()
        #expect(taken?.words == "book the dentist")
        #expect(taken?.source == .siri)
        #expect(pending.consume() == nil)
        pending.hand("   ", source: .siri)
        #expect(pending.consume() == nil)
    }

    @Test("The intent never touches the store: it has no context, no commit, no TaskItem")
    func neverCreates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Project-Ezra")
        let content = try String(
            contentsOf: root.appendingPathComponent("Intents/CaptureIntent.swift"), encoding: .utf8)
        for seam in ["NSManagedObjectContext", "commit(", "TaskItem(", "PersistenceStack"] {
            #expect(!content.contains(seam), "the intent must park words, never create tasks: \(seam)")
        }
    }
}
