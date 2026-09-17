//
//  OnDeviceSegmenter.swift
//  Project-Ezra
//
//  **The model draws the boundaries; the app does the cutting.** (WS4 / Campaign 5, P-A)
//
//  One question, asked of the on-device model and of nothing else: *where does each
//  separate thing the person wants to do BEGIN?* Not what the tasks are — the
//  deterministic pipeline already knows how to turn a clause into a populated draft, and
//  it does that job in microseconds. The only thing it demonstrably cannot do is find the
//  boundaries inside an unpunctuated spoken run-on, which is exactly the population that
//  escalates today: `CaptureEscalation.underSegmented` — connective, time and interior-verb
//  signals exceeding the draft count by two or more.
//
//  So this arm buys back precisely that population, and nothing else. It sits between the
//  deterministic read and Gemini: the read falls short → the on-device model names the
//  starting words of each outcome → the app cuts the user's own text at those points →
//  the SAME deterministic pipeline resolves each fragment → the SAME validator judges the
//  result. Accepted, the capture never leaves the device. Refused, it transmits exactly as
//  it does today. The arm can only ever REMOVE a transmission; it can never cause one.
//
//  **Why anchors instead of tasks.** Campaign 1 attributed FM's 20s capture latency to
//  output volume (62%), and Campaign 3 measured the single-object envelope — one small
//  object out — at p50 1.8s. Asking for the tasks means emitting every title, category and
//  date the app is about to recompute anyway; asking for the boundaries means emitting
//  five words per outcome. It is the same move as `IntentResolver.expand` ("parse the
//  intent in the model, expand the schedule in app code") and as `sourceQuote` ("the model
//  names its evidence and the SYSTEM verifies it"), applied to segmentation.
//
//  **Three properties fall out of cutting rather than generating, and they are the reason
//  this shape was chosen over a smaller `TriageResult`:**
//
//  1. **Nothing can be invented.** Every fragment is a substring of what the person said.
//     There is no path by which "pick up food later" grows a printer-paper errand.
//  2. **Nothing can be lost.** The fragments TILE the text — the cut is a partition, so
//     coverage is 100% by construction and `lowCoverage` is unreachable from this arm.
//  3. **Grounding is total, not sampled.** An anchor that is not found verbatim rejects
//     the WHOLE artifact rather than dropping one boundary, because a dropped boundary
//     silently merges two outcomes back together — the exact failure this arm exists to
//     fix. Rejection costs a cloud call, which is what would have happened anyway.
//
//  **Acceptance is the existing validator's, not this file's.** `CaptureEscalation.reason`
//  is re-asked over the new drafts and its answer is final (invariant 2 of the economics
//  rules: models produce artifacts, deterministic validators decide acceptance). A read
//  the model "fixed" that still reads under-segmented is still under-segmented.
//
//  **Shipping state: built, measurable, OFF.** `isRoutingEnabled` is false and the arm is
//  inert in production. That is not the posture's "wait for the benchmark" default — it is
//  the specific standing decision in `docs/capture.md` ▸ *Ramble economics* (WS4): capture
//  routing reopens after the GA evaluation, by a human over the report, and the report
//  does not exist until the GA runtime does. What flips it is `-FMPrimitives` on the GA
//  runtime showing P-A and P-D holding inside the latency envelope; the constant is the
//  one line that moves. `-OnDeviceSegment` runs the arm live for dogfooding before then.
//
//  **The cost of being wrong, stated.** A refused pass spends its own latency before the
//  cloud call it did not avoid. That is the whole risk of this arm, it is paid only by the
//  captures that already escalate, and it is what `generationCapSeconds` bounds.
//

import Foundation
import FoundationModels

enum OnDeviceSegmenter {

    // MARK: - The schema

    /// Boundaries, not tasks. A list of short verbatim openings — the smallest artifact
    /// that answers the only question the deterministic read gets wrong.
    @Generable
    struct BoundaryRead {
        @Guide(
            description:
                "For each separate thing the person wants to do, the first three or four words of that part, copied VERBATIM from their message, in the order they said them. One entry per separate thing. If it is all one thing, return one entry."
        )
        let starts: [String]
    }

    /// ~60 tokens, the shape Campaign 3 priced: a short instruction set over a small
    /// schema. Changes here re-run `-FMPrimitives` before they ship.
    static let instructions = """
        The user said several things in one breath. Find where each separate thing \
        begins. Copy the first three or four words of each part VERBATIM from their \
        message, in order. Never rewrite, never summarise, never add a part they did \
        not say. A quantity or a repeat inside one outcome is still one part.
        """

    static let promptHead = "Find the parts of this:"

    /// A wedge guard, not a budget — the same distinction `PrivateCaptureEngine`'s 8s cap
    /// draws, set tighter here because a cheaper arm is waiting behind this one. The
    /// single-object envelope measured p99 3.1s (Campaign 3) and this artifact is smaller;
    /// past this the run is hung and the cloud should already have the words.
    static let generationCapSeconds: Double = 3.5

    /// More boundaries than this inside a capture that is under the big-dump floors
    /// (<400 characters, <6 items) is not a reading of the text — it is an artifact that
    /// has come apart, and it is refused rather than cut on.
    static let maxAnchors = 12

    /// THE constant. See the header: false until a human reads the GA report.
    static var isRoutingEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-OnDeviceSegment")
        #else
        return false
        #endif
    }

    // MARK: - Outcomes

    /// Why an artifact was not accepted. Every case is a REFUSAL, never an error the user
    /// sees: each one falls through to the cloud arm that would have run anyway.
    enum Refusal: Equatable, Sendable {
        /// No on-device model on this host.
        case unavailable
        /// The wedge guard fired.
        case timedOut
        case failed(String)
        /// An anchor was not in the user's own words, or the artifact came apart.
        case ungrounded
        /// Fewer than two boundaries — there is nothing here the read did not already
        /// have. Note this is also the answer when the model says "it is all one thing":
        /// that claim is not accepted on the model's authority, because the signal count
        /// is what escalated and FM's own multi-intent boolean measured 43% precision
        /// against the deterministic detector's 90% (Campaign 3).
        case noGain
        /// The cut resolved, and the existing validator still refused it. Carries how many
        /// FRAGMENTS the cut produced (the model's count, not the resolver's draft count,
        /// which fans a day-list into several) — without it a caller cannot tell a cut
        /// that was nearly right from one that came apart, and a report scoring this cell
        /// would have to substitute the deterministic count and quietly score the wrong
        /// artifact.
        case validator(CaptureEscalationReason, fragments: Int)

        var label: String {
            switch self {
            case .unavailable: return "unavailable"
            case .timedOut: return "timed-out"
            case .failed(let label): return "failed(\(label))"
            case .ungrounded: return "ungrounded"
            case .noGain: return "no-gain"
            case .validator(let reason, _): return "validator(\(reason.rawValue))"
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        /// The capture stays on the device. `fragments` is how many boundaries the cut
        /// produced — drafts may exceed it where `IntentResolver.expand` fans one out.
        /// `anchors` are the model's verbatim openings, carried so a report can show
        /// WHERE it cut — a false accept with only a count cannot be argued with.
        case accepted(drafts: [TaskDraft], fragments: Int, anchors: [String] = [])
        case refused(Refusal)

        var isAccepted: Bool { if case .accepted = self { return true }; return false }
    }

    // MARK: - The cut (pure, and the whole trust story)

    /// Cut `text` at each anchor, or refuse. Pure — no model, no clock, no store — so
    /// every rule above is a test rather than a claim.
    ///
    /// Matching is by TOKEN, not by character range: the model reliably reproduces the
    /// words and unreliably reproduces the spacing, the case and the trailing comma of a
    /// dictated run-on, and a character search would reject good artifacts for whitespace.
    /// The search floor advances past each match, so the anchors are monotonic by
    /// construction — a model that repeats itself or answers out of order refuses here
    /// rather than producing overlapping fragments.
    ///
    /// The text before the first anchor is kept and joins the first fragment: dropping it
    /// would be the one way this arm could lose the user's words, and `strippedLeadIn`
    /// already removes the meta-narration that lives there ("I want to add that…").
    static func cut(_ text: String, at anchors: [String]) -> [String]? {
        guard anchors.count >= 2, anchors.count <= maxAnchors else { return nil }
        let haystack = tokenize(text)
        guard !haystack.isEmpty else { return nil }

        var starts: [String.Index] = []
        var floor = 0
        for anchor in anchors {
            let needle = tokenize(anchor).map(\.normalized)
            guard !needle.isEmpty else { return nil }
            guard let hit = firstMatch(of: needle, in: haystack, from: floor) else { return nil }
            starts.append(haystack[hit].start)
            floor = hit + 1
        }
        // The first anchor's own position is discarded: fragment one begins at the start
        // of the text so nothing before it is lost.
        let cuts = starts.dropFirst()
        var fragments: [String] = []
        var lower = text.startIndex
        for cut in cuts {
            fragments.append(String(text[lower..<cut]))
            lower = cut
        }
        fragments.append(String(text[lower...]))

        let cleaned = fragments.map {
            Segmentation.strippedLeadIn($0.trimmingCharacters(in: .whitespacesAndNewlines))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cleaned.count >= 2, !cleaned.contains(where: \.isEmpty) else { return nil }
        return cleaned
    }

    /// One word of the text, with where it starts. Punctuation is trimmed from the EDGES
    /// only, so "mom's," matches "mom's" and an em-dash between clauses disappears
    /// instead of failing a match.
    private struct Token {
        let normalized: String
        let start: String.Index
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let word = String(text[start..<index])
                .trimmingCharacters(in: CharacterSet.alphanumerics.union(.symbols).inverted)
                .lowercased()
            if !word.isEmpty { tokens.append(Token(normalized: word, start: start)) }
        }
        return tokens
    }

    private static func firstMatch(of needle: [String], in haystack: [Token], from floor: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var index = floor
        while index + needle.count <= haystack.count {
            var matched = true
            for offset in needle.indices where haystack[index + offset].normalized != needle[offset] {
                matched = false
                break
            }
            if matched { return index }
            index += 1
        }
        return nil
    }

    // MARK: - The arm

    /// Whether this capture may try the on-device pass before transmitting. Pure, so the
    /// gate is test-pinned rather than read out of a call site.
    ///
    /// Narrow on purpose: `underSegmented` is the one reason whose failure is a BOUNDARY
    /// failure. `bigDump` skips it by standing policy (a dump the deterministic read
    /// cannot hold goes straight to the authority rather than paying twice), `emptyRead`
    /// has nothing to re-cut, `conversation` needs the authority's permission to return
    /// nothing, and `unresolvedDetail` / `lowCoverage` describe fields and content rather
    /// than boundaries.
    static func handles(_ reason: CaptureEscalationReason?) -> Bool {
        reason == .underSegmented
    }

    /// The full gate the composer asks: the arm is on, the reason is ours, a model exists.
    @MainActor
    static func attempts(_ reason: CaptureEscalationReason?) -> Bool {
        isRoutingEnabled && handles(reason) && AppBrain.onDeviceModelAvailable()
    }

    /// Generate → cut → resolve → re-validate. Always returns; never throws; never shows
    /// the user anything of its own.
    @MainActor
    static func segment(
        text: String, learned: [LearnedRule] = [],
        ownership: OwnershipContext = .none, now: Date = Date()
    ) async -> Outcome {
        guard AppBrain.onDeviceModelAvailable() else { return .refused(.unavailable) }
        let started = Date()
        let read: BoundaryRead
        do {
            let session = LanguageModelSession(instructions: instructions)
            read = try await ModelDeadline.race(timeout: generationCapSeconds) {
                try await session.respond(
                    to: "\(promptHead)\n\n\(text)", generating: BoundaryRead.self
                ).content
            }
        } catch is ModelDeadline.Exceeded {
            ModelMetrics.shared.record(
                .captureSegment, .timedOut, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return .refused(.timedOut)
        } catch {
            if Task.isCancelled { return .refused(.failed("cancelled")) }
            let label = AppBrain.errorLabel(error)
            ModelMetrics.shared.record(
                .captureSegment, .failed(label),
                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return .refused(.failed(label))
        }
        ModelMetrics.shared.record(
            .captureSegment, .success, latencyMs: Int(Date().timeIntervalSince(started) * 1000))

        guard read.starts.count >= 2 else { return .refused(.noGain) }
        guard let fragments = cut(text, at: read.starts) else { return .refused(.ungrounded) }
        let drafts = AppBrain.drafts(
            fromClauses: fragments, learned: learned, ownership: ownership, now: now)
        guard !drafts.isEmpty else { return .refused(.ungrounded) }
        // The validator, unchanged and authoritative. It is asked about the ORIGINAL text
        // — the signals it counts are the person's, not the cut's.
        if let reason = CaptureEscalation.reason(for: text, drafts: drafts) {
            return .refused(.validator(reason, fragments: fragments.count))
        }
        return .accepted(drafts: drafts, fragments: fragments.count, anchors: read.starts)
    }
}
