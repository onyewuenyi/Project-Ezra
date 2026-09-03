//
//  CaptureIntent.swift
//  Project-Ezra
//
//  **Capture without opening the app.** (F-01)
//
//  Thoughts arrive mid-life, in bursts, while your hands are full. Requiring a launch,
//  an unlock and a tap is the one form of capture friction Ramble did nothing about —
//  and it is the form that teaches people to stop capturing. This is the App Intent
//  behind "Hey Siri, tell Ezra…", the Action Button and Shortcuts: one parameter, the
//  words, spoken or typed.
//
//  What it deliberately does NOT do: create tasks. Confirm is the single publish
//  boundary, and an intent that committed straight to the store would be the first
//  creation path in the product without a human moment. So the intent PARKS the words
//  as a `Capture` (the same shape a dismissed composer leaves behind), opens the app,
//  and the composer resumes it and submits — the person lands on the confirm card with
//  the interpretation already made. Nothing said is retyped; nothing is created unseen.
//
//  Runs in the app's own process (`openAppWhenRun`), so it hands the words to the shell
//  through `PendingCapture` rather than touching the store from a foreign process.
//

import AppIntents
import Foundation
import Observation

/// The words an intent handed over, waiting for the shell to present the composer.
@MainActor
@Observable
final class PendingCapture {
    static let shared = PendingCapture()

    private(set) var words: String?
    private(set) var source: CaptureSource = .siri

    func hand(_ words: String, source: CaptureSource) {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.words = trimmed
        self.source = source
    }

    /// Take the pending words, once.
    func consume() -> (words: String, source: CaptureSource)? {
        guard let words else { return nil }
        self.words = nil
        return (words, source)
    }
}

struct CaptureToEzraIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Ezra"
    static let description = IntentDescription(
        "Say what's on your mind. Ezra reads it and shows you the tasks to confirm.")
    static let openAppWhenRun = true

    @Parameter(title: "What's on your mind?", requestValueDialog: "What's on your mind?")
    var words: String

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingCapture.shared.hand(words, source: .siri)
        return .result()
    }
}

struct EzraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToEzraIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Tell \(.applicationName)",
                "Add to \(.applicationName)",
                "Ramble to \(.applicationName)",
            ],
            shortTitle: "Capture",
            systemImageName: "waveform")
    }
}
