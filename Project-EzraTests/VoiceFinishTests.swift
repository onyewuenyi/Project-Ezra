//
//  VoiceFinishTests.swift
//  Project-EzraTests
//
//  The listening tenure's two pure decisions, pinned: when silence may arm at all
//  (only once words exist — the system never finishes an empty capture), and what
//  finishing does with what it heard (nothing → the canvas; words → the submit).
//  These are the rules the whole voice-first entry hangs on, extracted as statics so
//  they are testable without a mic or a mounted composer.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct VoiceFinishTests {

    @Test("Silence arms only once speech has occurred")
    func armingRule() {
        // An open mic over silence stays present forever; silence only becomes a
        // completion signal after words.
        #expect(!ComposerView.shouldArmSilence(transcript: ""))
        #expect(ComposerView.shouldArmSilence(transcript: "call the dentist"))
    }

    @Test("Finishing with nothing heard settles to the canvas, never a reveal")
    func finishDecision() {
        // "Said nothing, tapped the orb" gets the canvas — a "Nothing actionable"
        // reveal answers a question about words, and there were none.
        #expect(ComposerView.finishAction(trimmed: "") == .toCanvas)
        #expect(ComposerView.finishAction(trimmed: "renew my passport") == .submit)
    }

    @Test("sinceLastWord recovers the last-delta instant from the armed deadline")
    func sinceLastWordMath() {
        // The deadline is armed at last-delta + 5s, so the delta's instant is
        // recoverable without a second clock. Timer-fired finish: now == deadline,
        // so the measurement is the whole window (≈5000ms).
        let now = Date()
        #expect(ComposerView.sinceLastWord(deadline: now, now: now) == 5000)
        // Orb tap 2s into the window: 3s remain on the deadline, 2s since the word.
        let midWindow = now.addingTimeInterval(3)
        #expect(ComposerView.sinceLastWord(deadline: midWindow, now: now) == 2000)
        // No words ever armed the deadline → nothing to measure, never a zero.
        #expect(ComposerView.sinceLastWord(deadline: nil, now: now) == nil)
    }
}
