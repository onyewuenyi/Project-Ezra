//
//  CaptureEscalation.swift
//  Project-Ezra
//
//  The deterministic verifier behind capture's device-first routing (2026-08-29):
//  given the instant local read of an unstructured capture, is there observable
//  EVIDENCE it fell short — evidence worth a cloud escalation to Gemini?
//
//  **This is not the deleted confidence gate, and the difference is load-bearing.**
//  The gate asked a model a META question before any work ("is this safe to handle
//  locally?") — an extra 2.3s call that escalated 95–100% of what it saw, slower than
//  the network it existed to avoid. This asks NO model anything: the deterministic
//  read has already produced its answer in ~2ms, and these checks read FACTS about
//  that answer — counts, resolutions, coverage — in microseconds. Judging an output
//  it can see is deterministic work; predicting the semantics of an input it can't
//  read was the gate's mistake (and `.singleThought`'s before it).
//
//  **The lexical signals point in the DISTRUST direction only, which is why they are
//  legal here.** `.singleThought` died because a lexicon deciding "this is probably
//  one task" KEPT a read on its own authority — a semantic judgment wearing an
//  observation's clothes, whose false positives lost user intent silently. These
//  signals can only ESCALATE: a false positive costs one cloud call; a false negative
//  is caught the way every capture mistake is caught, at the confirm card. The
//  asymmetry is safe by construction, the opposite of the deleted case.
//
//  Cost: pure string work over one capture. The routing check the product was worried
//  about being slow is this file, and it is effectively free.
//

import Foundation

/// Why an unstructured capture's local read wasn't good enough to reveal.
/// The raw value lands in `CaptureRunTelemetry.escalationReason` — the receipt's
/// answer to "why did this capture cost a cloud call?"
enum CaptureEscalationReason: String, Equatable, CaseIterable, Sendable {
    /// The deterministic read produced nothing at all — there is no interpretation
    /// to reveal, so a model must make one.
    case emptyRead
    /// The capture is past the depth floors (`CaptureRoute.depthCharacterFloor` /
    /// `depthItemFloor`) — the population device evidence says deterministic
    /// segmentation fails on, sent to the authority without paying for a local
    /// attempt first.
    case bigDump
    /// One draft came back from a capture whose surface shows several boundary
    /// signals (connectives, or multiple time expressions). One item out of a
    /// multi-signal dictation is the LEAST certain outcome a splitter can produce —
    /// the founding failure of this pipeline was exactly this case revealed as one
    /// task titled with its own transcript.
    case underSegmented
    /// The user spoke a detail the resolver could not land (today: a time phrase
    /// that failed `resolveDate`). The words carried intent the local read is
    /// provably not representing.
    case unresolvedDetail
    /// Too much of what the user said is absent from the drafts — content was
    /// dropped, not reorganized.
    case lowCoverage
}

enum CaptureEscalation {

    /// The one question, answered from facts: does this local read show evidence of
    /// failure? `nil` means the read is revealed as-is — no model, no transmission,
    /// no quota. Order is diagnostic precedence, not severity: the first reason is
    /// the one the receipt reports.
    static func reason(
        for text: String, drafts: [TaskDraft]
    ) -> CaptureEscalationReason? {
        guard !drafts.isEmpty else { return .emptyRead }
        let items = Segmentation.items(from: text).count
        if text.count >= CaptureRoute.depthCharacterFloor || items >= CaptureRoute.depthItemFloor {
            return .bigDump
        }
        // N drafts account for at most N boundary regions; signals past that are
        // UNACCOUNTED — spoken separators and occasions the read gave no draft to. The
        // first shape of this check fired only on exactly ONE draft, and the corpus
        // immediately produced its counterexample: case 50 (251 chars, nine outcomes,
        // two drafts) sailed through with seven outcomes silently folded away. Two
        // drafts hiding seven is the same failure as one draft hiding three.
        if connectiveSignals(in: text) + timeSignals(in: text)
            >= drafts.count + boundarySignalFloor
        {
            return .underSegmented
        }
        if drafts.contains(where: { !$0.unresolved.isEmpty }) {
            return .unresolvedDetail
        }
        if let covered = coverage(of: text, by: drafts), covered < coverageFloor {
            return .lowCoverage
        }
        return nil
    }

    /// How many UNACCOUNTED boundary signals (signals beyond the draft count) make a
    /// read under-segmented. Two, not one: "buy bread and milk" is one task with one
    /// connective, and escalating every compound noun phrase would spend the quota
    /// the device-first policy exists to save.
    static let boundarySignalFloor = 2

    /// Below this share of the capture's content words appearing in the drafts, the
    /// read dropped content rather than reorganizing it. Tuned against the corpus via
    /// the `-RambleEval` policy report, not argued.
    static let coverageFloor = 0.5

    // MARK: - Signals (each pure, each an observation)

    /// Occurrences of the separators people speak between distinct outcomes.
    static func connectiveSignals(in text: String) -> Int {
        let lowered = " " + text.lowercased() + " "
        let separators = [", ", " and ", " then ", " also ", " plus ", "; "]
        return separators.reduce(0) { count, separator in
            count + lowered.components(separatedBy: separator).count - 1
        }
    }

    // Compiled once. Constructing NSRegularExpression per call is measurably wasteful
    // even at capture volume; the pattern is fixed so a static let is the right site.
    private static let timeSignalRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            "\\b(today|tonight|tomorrow"
            + "|next (week|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
            + "|this (weekend|week|month|morning|afternoon|evening)"
            + "|monday|tuesday|wednesday|thursday|friday|saturday|sunday"
            + "|at \\d{1,2}(:\\d{2})?\\s?(am|pm)?"
            + "|\\d{1,2}\\s?(am|pm))\\b",
        options: [.caseInsensitive])

    /// Distinct time expressions in the capture. Several of them beyond the draft
    /// count is the run-on-dictation shape: occasions competing for boundaries no
    /// draft accounts for. The vocabulary deliberately shadows
    /// `IntentResolver.resolveDate`'s — bare weekdays included, because the resolver
    /// resolves them and `expand` fans them out ("walk my dog monday and tuesday" IS
    /// two occasions) — so the signal never claims time-ness the pipeline doesn't
    /// recognize, and never misses one it does.
    static func timeSignals(in text: String) -> Int {
        guard let regex = timeSignalRegex else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    /// The share of the capture's content words that survived into the drafts, or nil
    /// when the capture is too short for the ratio to mean anything. Length ≥ 4 is a
    /// cheap stopword filter — the words that matter to coverage ("passport",
    /// "landlord", "registration") clear it; the glue ("the", "to", "my") doesn't.
    static func coverage(of text: String, by drafts: [TaskDraft]) -> Double? {
        let contentWords = words(in: text).filter { $0.count >= 4 }
        guard contentWords.count >= minimumCoverageWords else { return nil }
        let draftText = drafts.map(\.title).joined(separator: " ")
        let draftWords = Set(words(in: draftText))
        let covered = contentWords.filter(draftWords.contains).count
        return Double(covered) / Double(contentWords.count)
    }

    /// Under this many content words, a coverage ratio is noise (one dropped word
    /// swings it by a fifth or more), so the check abstains.
    static let minimumCoverageWords = 6

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
