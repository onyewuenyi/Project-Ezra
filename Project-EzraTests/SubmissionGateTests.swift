//
//  SubmissionGateTests.swift
//  Project-EzraTests
//
//  **The gates that block an App Store submission rather than an experience.**
//
//  Every one of these is invisible to a green build: the app compiles, runs, passes its
//  whole suite and is rejected — or, worse, stalls in App Store Connect on a question
//  nobody is watching for. They are pinned here because the only other way to find them
//  is to archive a build and read the result, which happens once a quarter at best.
//
//  Two of them are assertions about facts (a plist key, a usage string). The third is
//  deliberately NOT an assertion: `SupportLinks.privacyPolicy` is nil until someone
//  writes and hosts a privacy policy, and a red suite for an owner step that lives on a
//  web host is a broken window, not a reminder. What IS pinned is that the app behaves
//  honestly while the URL is missing — no dead link, and a DEBUG line that names the
//  consequence. See `docs/cohort0-checklist.md` §8 and `TODO.md`.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Submission gates · the checks a green build cannot make")
struct SubmissionGateTests {

    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    /// Without this key, App Store Connect stops EVERY upload on the export-compliance
    /// question and TestFlight will not distribute the build until a human answers it.
    /// `false` is the honest answer only while the app ships no cryptography of its own —
    /// the companion grep is in `docs/cohort0-checklist.md` §8.
    @Test("Export compliance is answered in the binary, not by hand on every upload")
    func exportComplianceIsDeclared() throws {
        let uses = try #require(
            try infoPlist()["ITSAppUsesNonExemptEncryption"] as? Bool,
            "ITSAppUsesNonExemptEncryption is missing — every upload will stall on the question")
        #expect(uses == false)
    }

    /// The capture sheet opens INTO listening, so the microphone prompt is the first
    /// system dialog a new user ever sees. A missing usage string is not a rejection, it
    /// is a CRASH the moment the sheet opens, and it would take the whole front door with
    /// it. The string must say what the mic is for in the product's own words.
    @Test("The microphone has a reason, in the product's words")
    func microphoneUsageIsDescribed() throws {
        let reason = try #require(
            try infoPlist()["NSMicrophoneUsageDescription"] as? String,
            "NSMicrophoneUsageDescription is missing — the capture sheet will crash on open")
        #expect(reason.count > 30, "a one-word reason reads as evasive and gets denied")
        #expect(reason.lowercased().contains("device"), "say that the words stay on the device")
        // The guardrail that outranks every other line of copy in the app.
        for vendor in ["AI", "Gemini", "OpenAI", "model", "LLM"] {
            #expect(
                !reason.contains(vendor),
                "the customer never hears \"\(vendor)\" — least of all in a system prompt")
        }
    }

    /// The transcriber is `SpeechAnalyzer`, which asks no speech-recognition permission —
    /// but upload processing reads framework linkage, not call sites, and a Speech-linked
    /// binary with no reason is a rejection mailed after the upload. Declared, and held to
    /// the microphone's rules (2026-09-30).
    @Test("Speech recognition has a reason, in the product's words")
    func speechRecognitionUsageIsDescribed() throws {
        let reason = try #require(
            try infoPlist()["NSSpeechRecognitionUsageDescription"] as? String,
            "NSSpeechRecognitionUsageDescription is missing")
        #expect(reason.count > 30)
        #expect(reason.lowercased().contains("device"), "say that the words stay on the device")
        for vendor in ["AI", "Gemini", "OpenAI", "model", "LLM"] {
            #expect(!reason.contains(vendor), "the customer never hears \"\(vendor)\"")
        }
    }

    /// Guideline 5.1.1(i): an app that collects data links its privacy policy from inside
    /// the app. Until the page exists the app must render NO link — a 404 under "Privacy
    /// policy" is the first thing a reviewer taps, and it is worse than an absence.
    @Test("With no privacy policy hosted, the app offers no link and says so in DEBUG")
    func theMissingPrivacyPolicyIsLoudRatherThanBroken() {
        guard SupportLinks.privacyPolicy == nil else {
            // The page exists: the only thing to check is that the app now claims it can
            // meet the guideline.
            #expect(SupportLinks.isReadyForSubmission)
            #expect(SupportLinks.debugStatusLine.contains("ready"))
            return
        }
        #expect(!SupportLinks.isReadyForSubmission)
        #expect(
            SupportLinks.debugStatusLine.contains("blocks submission"),
            "the DEBUG line must name the consequence, not the nil field")
    }

    private func appSources() -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        let files =
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.path.replacingOccurrences(of: root.path + "/", with: ""), text)
        }
    }

    /// **Every photo picker stays OUT of process (2026-09-20).** Passing `photoLibrary:`
    /// is the entire difference between a picker that needs no permission and one that
    /// needs photo-library authorization — and the app declares no
    /// `NSPhotoLibraryUsageDescription`, so an in-process picker terminates it on open.
    /// All four carried the argument, including the one on the first screen a new user
    /// sees, while the doc comment above one of them said the opposite. The simulator
    /// does not catch it: its permission state is usually already primed. Every site
    /// only reads the one chosen item, so library access buys nothing.
    @Test("No picker asks for photo-library access the app has no permission to have")
    func everyPickerIsOutOfProcess() {
        // Comments stripped: prose may NAME the argument — the whole point of the note
        // above `imageButton` is to say why it must never come back — while code may not
        // PASS it. The same distinction `InertSignalTests` and the cloud grep draw.
        let offenders = appSources()
            .filter { file in
                file.text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
                    .contains { $0.contains("photoLibrary:") }
            }
            .map(\.path)
        #expect(
            offenders.isEmpty,
            """
            `photoLibrary:` makes the picker in-process, which needs \
            NSPhotoLibraryUsageDescription — absent here, so iOS terminates the app: \
            \(offenders.joined(separator: ", "))
            """)
    }

    /// A stop that lands while the microphone is warming up must actually stop it. Until
    /// 2026-09-20 it did not: `start()` suspends on the permission prompt and again on
    /// the first-run speech model download, and neither honours cancellation, so the
    /// suspended call resumed afterwards and brought the microphone up on a sheet the
    /// person had already left — live, with no orb and nothing on screen saying so.
    @Test("A stop during warm-up is honoured, so the mic never comes back up alone")
    func stoppingInvalidatesAnInFlightStart() throws {
        let source = try #require(
            appSources().first { $0.path == "AI/SpeechCaptureService.swift" }?.text)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
        #expect(
            code.contains { $0.contains("startToken += 1") },
            "stop() must invalidate an in-flight start()")
        #expect(
            code.filter { $0.contains("token == startToken") }.count >= 2,
            "start() must re-check after BOTH awaits — the prompt and the model download")
    }

    /// The manifest is what the App Store Connect questionnaire is checked against, so a
    /// claim here that the code contradicts is a rejection. These are the three collected
    /// types and the one required-reason API the app actually has.
    @Test("The privacy manifest still describes this app")
    func theManifestMatchesTheApp() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let manifest = try #require(plist as? [String: Any])

        #expect(
            manifest["NSPrivacyTracking"] as? Bool == false,
            "the guardrails refuse tracking; the manifest must say so")
        let reasons = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        #expect(!reasons.isEmpty, "UserDefaults is a required-reason API and must be declared")
        let collected = manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        #expect(
            collected.count == 3,
            "three collected types: product interaction, the install id, the raw capture words")
        for type in collected {
            #expect(
                type["NSPrivacyCollectedDataTypeLinked"] as? Bool == false,
                "nothing the app collects is linked to a person — that is the whole posture")
            #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        }
    }
}
