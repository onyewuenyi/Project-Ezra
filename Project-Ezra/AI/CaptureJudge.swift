//
//  CaptureJudge.swift
//  Project-Ezra
//
//  **The read makes the pieces; the model says what each piece is.** (2026-10-04)
//
//  Capture reads on the device only, and `-DumpEval` measured what that costs on a long
//  dump: the deterministic read holds every intended outcome in SOME card (recall 12/12)
//  and gets the card COUNT right on 4 of 12 — a greeting, a sign-off and "so I was
//  thinking" become cards, and "wash the uniform and refill the prescription" stays one.
//  The same run settled what the on-device model must not do: asked to CUT a dump it
//  over-cut or timed out (`OnDeviceSegmenter`, still off).
//
//  So the model gets the one job it has measured well at — read ONE short piece — and the
//  question is the one the read cannot answer: is this piece one task, several, or
//  nothing to do? `-CardJudgeEval`, per piece: no real task judged `none` in 165, every
//  fused piece caught, ~0.7 s a call.
//
//  **Every failure lands on the side of keeping the person's words.**
//  - A piece that plainly opens on an action never reaches the model (`screen`).
//  - `none` SETS ASIDE, never deletes: the piece rides to Confirm as a left-out line the
//    person can add back, and a piece that states a need is kept whatever the model said.
//  - `several` only licenses a re-split the app makes and validates itself (`resplit`):
//    every part must stand on its own, or the piece stays one card.
//  - No answer inside the budget is the same as `task`: the piece stays a card.
//
//  The model produces a verdict; deterministic code decides what the verdict may do. That
//  is rule 2 of the Ramble economics, and the asymmetry `CaptureEscalation` already
//  relies on: a signal that can only ask for a second look may read what an authoritative
//  one may not.
//

import Foundation
import FoundationModels

enum CaptureJudge {

    enum Verdict: String, CaseIterable, Sendable {
        case task, several, none
    }

    // MARK: - The schema

    @Generable
    struct PieceRead {
        @Guide(description: "Exactly one of: task, several, none.", .anyOf(["task", "several", "none"]))
        let kind: String
    }

    /// ~75 tokens. Changes here re-run `-CardJudgeEval` before they ship: the bracket is
    /// FALSE DROP 0 over the Ramble corpora's task clauses.
    nonisolated static let instructions = """
        You sort lines a person said or pasted into their to-do app. For a line, answer \
        with one word. task: it holds one thing they need to do, get, book, pay, send or \
        remember. several: it holds more than one separate thing to do. none: it is a \
        greeting, a sign-off, small talk or a remark with nothing to do. When unsure \
        between task and none, answer task.
        """

    /// A wedge guard per call, not a budget: measured p95 was under a second.
    nonisolated static let callCapSeconds: Double = 4
    /// The whole pass. A piece without an answer by then stays a card.
    nonisolated static let passBudgetSeconds: Double = 6
    /// More doubtful pieces than this are not all judged; the rest stay cards.
    nonisolated static let maxCalls = 12

    // MARK: - The screen (pure)

    /// Does this piece need the model at all? A piece that opens on an action and shows
    /// no sign of a second outcome is a task on its face: judging it costs a call and can
    /// only make it worse.
    static func needsJudgment(_ clause: String) -> Bool {
        let core = opening(of: clause)
        guard Segmentation.startsAnItem(core) else { return true }
        return CaptureEscalation.connectiveSignals(in: core) > 0
            || CaptureEscalation.interiorVerbSignals(in: core) > 0
    }

    /// The piece as its first real word starts it: lead-ins and a polite "please" gone.
    static func opening(of clause: String) -> String {
        var core = Segmentation.strippedLeadIn(clause.trimmingCharacters(in: .whitespacesAndNewlines))
        if core.lowercased().hasPrefix("please ") { core = String(core.dropFirst("please ".count)) }
        return core
    }

    private static let needMarkers = [
        "need to", "needs to", "have to", "has to", "got to", "gotta", "remember to", "don't forget",
        "dont forget", "please ", "must ", "is due", "are due", "remind ",
    ]

    /// A piece that states a need is kept as a card whatever the model answered: the
    /// person said they have something to do, in so many words.
    static func statesANeed(_ clause: String) -> Bool {
        let lowered = " " + clause.lowercased() + " "
        return Segmentation.startsAnItem(opening(of: clause)) || needMarkers.contains { lowered.contains($0) }
    }

    // MARK: - The re-split (pure)

    private static let splitPattern = try? NSRegularExpression(
        pattern:
            #"\s*(?:[,;]\s*(?:and\s+|also\s+|plus\s+|then\s+|oh\s+and\s+)?|\s(?:and|also|plus|then)\s)\s*"#,
        options: [.caseInsensitive])

    private static let notAVerb: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "some", "any", "this", "that",
        "these", "those", "it", "they", "we", "he", "she", "you", "i", "there", "and", "but", "so", "or",
        "because", "if", "when", "after", "before", "for", "with", "about", "on", "in", "at", "to", "of",
    ]

    private static let determiners: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "some", "up", "out", "off", "back",
    ]

    private static let stateOpeners = ["we're out of", "we are out of", "i'm out of", "out of "]

    /// Could this part be a card by itself? An imperative the lexicon knows, an
    /// imperative it does not ("refill the prescription": an unknown word straight into
    /// an object), or a stated need ("the car needs an oil change", "we're out of milk").
    static func standsAlone(_ part: String) -> Bool {
        let core = opening(of: part)
        let words = core.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard words.count >= 2 else { return false }
        if Segmentation.startsAnItem(core) { return true }
        if !notAVerb.contains(words[0]), determiners.contains(words[1]),
            !CaptureEscalation.conversationalOpeners.contains(words[0])
        {
            return true
        }
        let lowered = " " + core.lowercased() + " "
        if stateOpeners.contains(where: { lowered.contains($0) }) { return true }
        return [" needs ", " need ", " is due", " are due"].contains { lowered.contains($0) }
    }

    /// Split a piece the model called `several`, or refuse. A part that cannot stand
    /// alone glues back onto the part before it ("milk" + "eggs"); if what is left is not
    /// at least two parts that EACH stand alone, the answer is nil and the piece stays
    /// one card. The model's word is the licence; this is the judgment.
    static func resplit(_ clause: String) -> [String]? {
        guard let regex = splitPattern else { return nil }
        let text = clause as NSString
        var raw: [(text: String, joiner: String)] = []
        var cursor = 0
        for match in regex.matches(in: clause, range: NSRange(location: 0, length: text.length)) {
            raw.append(
                (text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), ""))
            raw[raw.count - 1].joiner = text.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        raw.append((text.substring(from: cursor), ""))

        var parts: [String] = []
        var pendingJoiner = ""
        for piece in raw {
            let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                pendingJoiner = piece.joiner
                continue
            }
            if parts.isEmpty || standsAlone(trimmed) {
                parts.append(trimmed)
            } else {
                parts[parts.count - 1] += pendingJoiner + trimmed
            }
            pendingJoiner = piece.joiner
        }
        guard parts.count >= 2, parts.allSatisfy({ standsAlone($0) }) else { return nil }
        return parts
    }

    /// A short imperative whose only object is "it" belongs to the piece before it:
    /// "…so sign it" + "send it in" is one errand. Mirrors
    /// `IntentResolver.resolvingAnaphoricWaits`: a pronoun points back.
    static func foldingAnaphora(_ clauses: [String]) -> [String] {
        var folded: [String] = []
        for clause in clauses {
            let words = clause.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            let pointsBack =
                words.count <= 4 && (words.contains("it") || words.contains("them"))
                && !words.contains(where: { $0.count > 2 && !notAVerb.contains($0) && $0 != words.first })
            if pointsBack, !folded.isEmpty {
                folded[folded.count - 1] += " and " + clause
            } else {
                folded.append(clause)
            }
        }
        return folded
    }

    // MARK: - The reading

    struct Reading: Equatable, Sendable {
        /// The pieces that become cards, in the order they were said.
        var clauses: [String]
        /// Pieces judged `none`: carried to Confirm, never dropped.
        var leftOut: [String]
        var judged = 0
        var answered = 0
        var resplit = 0
    }

    /// Apply verdicts to pieces. Pure: the model's answers come in as a dictionary, so
    /// every rule above is a test rather than a claim. A missing verdict keeps the piece.
    static func apply(_ verdicts: [Int: Verdict], to clauses: [String]) -> Reading {
        var kept: [String] = []
        var leftOut: [String] = []
        var splits = 0
        for (index, clause) in clauses.enumerated() {
            switch verdicts[index] {
            case .some(.none) where !statesANeed(clause):
                leftOut.append(clause)
            case .some(.several):
                if let parts = resplit(clause) {
                    kept.append(contentsOf: parts)
                    splits += 1
                } else {
                    kept.append(clause)
                }
            default:
                kept.append(clause)
            }
        }
        return Reading(
            clauses: foldingAnaphora(kept), leftOut: leftOut, judged: 0, answered: verdicts.count,
            resplit: splits)
    }

    /// Screen → judge the doubtful pieces together → apply. `judge` is injected so the
    /// whole pass runs under test with no model.
    static func read(
        clauses: [String], budget: Double = passBudgetSeconds,
        judge: @escaping @Sendable (String) async -> Verdict?
    ) async -> Reading {
        let doubtful = clauses.enumerated().filter { needsJudgment($0.element) }.prefix(maxCalls)
        guard !doubtful.isEmpty else { return apply([:], to: clauses) }
        let verdicts: [Int: Verdict] =
            (try? await ModelDeadline.race(timeout: budget) {
                await withTaskGroup(of: (Int, Verdict?).self) { group in
                    for (index, clause) in doubtful {
                        group.addTask { (index, await judge(clause)) }
                    }
                    var answers: [Int: Verdict] = [:]
                    for await (index, verdict) in group { if let verdict { answers[index] = verdict } }
                    return answers
                }
            }) ?? [:]
        var reading = apply(verdicts, to: clauses)
        reading.judged = doubtful.count
        return reading
    }

    /// One call to the on-device model. Nil on a refusal, a timeout or an answer outside
    /// the three words: all of them keep the piece.
    nonisolated static func modelVerdict(_ clause: String) async -> Verdict? {
        let started = Date()
        do {
            let verdict = try await ModelDeadline.race(timeout: callCapSeconds) {
                let session = LanguageModelSession(instructions: instructions)
                let read = try await session.respond(to: "Line: \(clause)", generating: PieceRead.self)
                    .content
                return Verdict(rawValue: read.kind.lowercased())
            }
            await ModelMetrics.shared.record(
                .captureJudge, verdict == nil ? .failed("off-vocabulary") : .success,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return verdict
        } catch is ModelDeadline.Exceeded {
            await ModelMetrics.shared.record(
                .captureJudge, .timedOut, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return nil
        } catch {
            await ModelMetrics.shared.record(
                .captureJudge, .failed(AppBrain.errorLabel(error)),
                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return nil
        }
    }
}
