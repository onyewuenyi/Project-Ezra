//
//  PrivateCaptureEngineTests.swift
//  Project-EzraTests
//
//  Private Capture's pure decision core. The speculation plan is the part that can
//  betray the product silently: a wrong rule either reveals a STALE interpretation
//  (words the capture no longer is — the cardinal sin) or throws away a good run
//  (the latency win wasted). Both directions are pinned here, along with the
//  grounding gate and the never-fails fallback.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct PrivateCaptureEngineTests {

    // MARK: - The speculation plan

    @Test("A speculation is used only for EXACTLY the text it was started from")
    func speculationMatchesExactText() {
        var plan = SpeculationPlan()
        #expect(plan.armed(text: "call the dentist") == .speculate("call the dentist"))
        // Same text (whitespace aside) → the run is valid for the finish.
        #expect(plan.matches(finalText: "call the dentist"))
        #expect(plan.matches(finalText: "  call the dentist  "))
        // ANY textual drift → the run is about a capture that no longer exists.
        #expect(!plan.matches(finalText: "call the dentist tomorrow"))
    }

    @Test("More speech invalidates; re-arming on identical text never burns a fresh run")
    func speculationLifecycle() {
        var plan = SpeculationPlan()
        #expect(plan.armed(text: "renew passport") == .speculate("renew passport"))
        // A duplicate arm (same pause, same words) keeps the in-flight run.
        #expect(plan.armed(text: "renew passport") == .keep)
        // Words moved: the old run is stale — and the next arm speculates fresh.
        plan.invalidated()
        #expect(!plan.matches(finalText: "renew passport"))
        #expect(plan.armed(text: "renew passport today") == .speculate("renew passport today"))
    }

    @Test("Empty text never speculates")
    func emptyNeverSpeculates() {
        var plan = SpeculationPlan()
        #expect(plan.armed(text: "   ") == .none)
        #expect(!plan.matches(finalText: ""))
    }

    // MARK: - Grounding gate

    @Test("An ungrounded quote is refused — the model may not attribute unsaid words")
    func ungroundedReadIsRefused() {
        let read = PrivateCaptureRead(
            title: "Buy printer paper", sourceQuote: "buy new printer paper",
            dateExpression: nil, isJudgmentCall: false, blockerPhrase: nil)
        // The user never said it: the mapping returns nil and the deterministic
        // fallback serves instead — never a substituted quote.
        #expect(
            PrivateCaptureEngine.draft(from: read, rawText: "pick up food from the store")
                == nil)
        // Grounded, the same read becomes a draft.
        let grounded = PrivateCaptureRead(
            title: "Pick up food", sourceQuote: "pick up food from the store",
            dateExpression: nil, isJudgmentCall: false, blockerPhrase: nil)
        let draft = PrivateCaptureEngine.draft(
            from: grounded, rawText: "pick up food from the store")
        #expect(draft?.title == "Pick up food")
    }

    @Test("The deterministic fallback always yields a capture — failure produces value")
    func fallbackNeverFails() {
        let draft = PrivateCaptureEngine.deterministicDraft(
            from: "that insurance thing")
        #expect(!draft.title.isEmpty)
        // Even degenerate input produces something savable, not an error state.
        let odd = PrivateCaptureEngine.deterministicDraft(from: "…")
        #expect(!odd.title.isEmpty)
    }

    @Test("Model null-strings normalize to real nil — a 'null' blocker must not suppress dates")
    func nullStringNormalization() {
        // The decoder emitting the WORD "null" into an optional field is routine for
        // a 3B model; treated as content it corrupts the resolver — a "null" blocker
        // suppresses due-date inference, a "none" dateExpression reads as a spoken
        // time that failed to parse.
        #expect(PrivateCaptureEngine.normalizedOptional(nil) == nil)
        #expect(PrivateCaptureEngine.normalizedOptional("") == nil)
        #expect(PrivateCaptureEngine.normalizedOptional("  ") == nil)
        #expect(PrivateCaptureEngine.normalizedOptional("null") == nil)
        #expect(PrivateCaptureEngine.normalizedOptional("None") == nil)
        #expect(PrivateCaptureEngine.normalizedOptional("N/A") == nil)
        #expect(PrivateCaptureEngine.normalizedOptional("tomorrow") == "tomorrow")
        #expect(PrivateCaptureEngine.normalizedOptional(" friday ") == "friday")
        // And end-to-end: a read with a "null" blocker still gets the renewal arm's
        // inferred date (the exact corruption the normalization exists to prevent).
        let read = PrivateCaptureRead(
            title: "Renew my passport", sourceQuote: "renew my passport",
            dateExpression: "null", isJudgmentCall: false, blockerPhrase: "null")
        let draft = PrivateCaptureEngine.draft(from: read, rawText: "renew my passport")
        #expect(draft?.dueDate != nil, "the renewal inference was suppressed by a null-string")
        #expect(draft?.blockedBy == nil)
    }

    @Test("A time phrase filed as a blocker becomes the date — the three named device misses")
    func timePhraseBlockerReclassifies() {
        // The exact emissions the device diagnosis caught, as fixtures. Each was one
        // field confusion producing three corruptions: no spoken date, suppressed
        // inference, and a phantom wait.
        for (title, quote, phantomBlocker) in [
            ("Water the plants", "water the plants today", "today"),
            ("Take the trash out", "trash goes out monday", "monday"),
            ("Submit the expense report", "submit the expense report tomorrow", "tomorrow"),
        ] {
            let read = PrivateCaptureRead(
                title: title, sourceQuote: quote, dateExpression: nil,
                isJudgmentCall: false, blockerPhrase: phantomBlocker)
            let draft = PrivateCaptureEngine.draft(from: read, rawText: quote)
            #expect(draft?.dueDate != nil, "\(quote): the time phrase was lost")
            #expect(draft?.blockedBy == nil, "\(quote): a time survived as a wait")
        }
        // A REAL blocker does not resolve as a date and survives untouched.
        let (date, blocker) = PrivateCaptureEngine.classifiedTimePhrase(
            dateExpression: nil, blockerPhrase: "the passport coming through")
        #expect(date == nil)
        #expect(blocker == "the passport coming through")
        // A time-blocker beside a REAL date: the phantom clears, the date stays.
        let (kept, cleared) = PrivateCaptureEngine.classifiedTimePhrase(
            dateExpression: "friday", blockerPhrase: "tomorrow")
        #expect(kept == "friday")
        #expect(cleared == nil)
    }

    // MARK: - The detector (production home of the measured winner)

    @Test("The schema's omissions are backfilled from the same words — category, date, effort")
    func deterministicBackfill() {
        // The model interprets; the deterministic read of the SAME words fills every
        // field the single-object schema deliberately dropped. Before this, every
        // private capture reached the card as "Admin" with nothing else known.
        let read = PrivateCaptureRead(
            title: "Clean my room", sourceQuote: "clean my room tomorrow at 3 pm",
            dateExpression: nil, isJudgmentCall: false, blockerPhrase: nil)
        let draft = PrivateCaptureEngine.draft(from: read, rawText: "Clean my room tomorrow at 3 PM.")
        #expect(draft?.category == "Home")
        // The model emitted no time phrase; the extractor's own read of the raw text
        // serves — grounded by construction, it is the user's words.
        let tomorrow = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        #expect(draft?.dueDate == tomorrow)
        #expect(draft?.unresolved.isEmpty == true)

        // The model's own time phrase wins where it emitted one (P1: bare clock → today).
        let dated = PrivateCaptureRead(
            title: "Cook dinner", sourceQuote: "cook dinner at 3", dateExpression: "at 3",
            isJudgmentCall: false, blockerPhrase: nil)
        let datedDraft = PrivateCaptureEngine.draft(from: dated, rawText: "Cook dinner at 3")
        #expect(datedDraft?.dueDate == Calendar.current.startOfDay(for: Date()))
        #expect(datedDraft?.unresolved.isEmpty == true)

        // A quick verb earns the quick-win effort signal, as it does on the Ramble path.
        let call = PrivateCaptureRead(
            title: "Call the dentist", sourceQuote: "call the dentist", dateExpression: nil,
            isJudgmentCall: false, blockerPhrase: nil)
        let callDraft = PrivateCaptureEngine.draft(from: call, rawText: "call the dentist")
        #expect(callDraft?.category == "Health")
        #expect(callDraft?.effortMinutes == 15)
    }

    @Test("The detector is the deterministic one — fires on rich signals, quiet on traps")
    func detectorBehaviour() {
        #expect(
            PrivateCaptureEngine.soundsLikeSeveralThings(
                "call the dentist tomorrow and buy diapers on friday"))
        #expect(!PrivateCaptureEngine.soundsLikeSeveralThings("renew my passport"))
        // The compound-is-one trap must not nag.
        #expect(
            !PrivateCaptureEngine.soundsLikeSeveralThings(
                "email the landlord about the boiler and the leak"))
    }

    // MARK: - The mode's structural privacy

    @Test("The Private Capture path never references the cloud — structurally")
    func noCloudReference() throws {
        // The guarantee is architecture, not discipline: neither the engine nor the
        // surface may USE the cloud seam. A grep for member access / the provider
        // type, because the absence of a symbol is what a grep can pin and a type
        // system cannot. (The first shape of this grepped the bare words and caught
        // its own header comments explaining the guarantee — prose may NAME the
        // cloud; code may not touch it.)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        for file in [
            "AI/PrivateCaptureEngine.swift", "Models/CapturePosture.swift",] {
            let content = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(
                !content.contains("CloudModel.") && !content.contains("GeminiProvider")
                    && !content.contains("FirebaseAI"),
                "\(file) touches the cloud seam — the Private Capture guarantee is broken")
        }
    }
}
