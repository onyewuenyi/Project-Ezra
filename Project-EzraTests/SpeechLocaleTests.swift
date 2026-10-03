//
//  SpeechLocaleTests.swift
//  Project-EzraTests
//
//  Which voice model transcribes for whom.
//
//  The app is voice-first — the capture sheet opens INTO listening — so "is dictation
//  available for this person" decides whether they meet the product or a typing box.
//  Until 2026-09-20 that question was answered by an exact BCP-47 match against
//  `SpeechTranscriber.supportedLocales`, and Apple ships regional English without
//  shipping all of it. An English speaker whose device reads `en-NG` was told "Voice
//  capture isn't available for your language yet" — permanently, and untruthfully: their
//  language is supported, their region is not.
//
//  None of these shapes exist on this Mac's simulator, which is exactly why the resolver
//  was made pure and is tested here rather than observed.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Speech locale · a region we do not ship is not a language we do not speak")
struct SpeechLocaleTests {

    private let supported = [
        Locale(identifier: "en-US"), Locale(identifier: "en-GB"), Locale(identifier: "en-AU"),
        Locale(identifier: "en-IN"), Locale(identifier: "es-ES"), Locale(identifier: "es-MX"),
        Locale(identifier: "fr-FR"),
    ]

    private func resolve(_ id: String, installed: [Locale] = []) -> String? {
        SpeechCaptureService.resolveLocale(
            preferred: Locale(identifier: id), supported: supported, installed: installed
        )?.identifier(.bcp47)
    }

    @Test("An exact match always wins, installed or not")
    func theExactMatchWins() {
        #expect(resolve("en-GB") == "en-GB")
        #expect(resolve("es-MX") == "es-MX")
        // Even when a different sibling is the one already downloaded: the person's own
        // region is a better transcript than a convenient one.
        #expect(resolve("en-AU", installed: [Locale(identifier: "en-US")]) == "en-AU")
    }

    /// The finding. A region Apple does not ship must not cost someone the microphone.
    @Test("An unshipped region falls back to a sibling of the same language")
    func anUnshippedRegionFallsBack() {
        #expect(resolve("en-NG") != nil)
        #expect(resolve("en-PH") != nil)
        #expect(resolve("es-AR") != nil)
        // Deterministic, not dictionary order — a resolver that answered differently on
        // two launches would make this bug unreproducible if it ever came back.
        #expect(resolve("en-NG") == resolve("en-NG"))
        #expect(resolve("en-NG") == "en-AU", "sorted first among the English siblings")
    }

    /// A model already on the phone beats one that has to be downloaded — the fallback
    /// must not turn a missing region into a cellular download on someone's first tap.
    @Test("An installed sibling is preferred to one that would download")
    func anInstalledSiblingWins() {
        #expect(resolve("en-NG", installed: [Locale(identifier: "en-IN")]) == "en-IN")
        #expect(resolve("en-KE", installed: [Locale(identifier: "en-GB")]) == "en-GB")
        // Installed locales the person does not speak are irrelevant.
        #expect(resolve("es-AR", installed: [Locale(identifier: "fr-FR")]) == "es-ES")
    }

    /// Nil still means something, and it must keep meaning it: the LANGUAGE is not
    /// supported. That is the only case where "not available for your language" is true,
    /// and the only case that should switch the microphone off.
    @Test("A language we genuinely do not support still returns nil")
    func anUnsupportedLanguageIsStillNil() {
        #expect(resolve("ja-JP") == nil)
        #expect(resolve("sw-KE") == nil)
        #expect(
            SpeechCaptureService.resolveLocale(
                preferred: Locale(identifier: "en-US"), supported: [], installed: []) == nil)
    }

    /// A bare language with no region is what several devices report, and it must not be
    /// read as an unsupported region.
    @Test("A bare language code resolves like any other")
    func aBareLanguageResolves() {
        #expect(resolve("en") == "en-AU")
        #expect(resolve("fr") == "fr-FR")
    }
}
