//
//  CaptureConversation.swift
//  Project-Ezra
//
//  The CONTINUOUS capture session — the deferred "continuous capture session
//  (DynamicInstructions)" item, now buildable on iOS 27's dynamic-profile API.
//
//  What it changes: the rolling chain currently re-prompts the FULL ramble every
//  ~1.2s through a fresh single-use session (see `CaptureSessionPool`), so
//  per-parse token cost grows with everything already said, and a long ramble's
//  completeness is bounded by the deadline (device evidence: a 648-char ramble
//  never finished at 30s — salvage costs completeness). A conversation instead
//  holds ONE session per composer session and feeds each parse as a TURN:
//  the first turn carries the full text; a grown ramble sends ONLY its new words
//  (the model sees its own previous task list in the transcript and returns the
//  complete updated list); a revision falls back to a full-text turn. Per-turn
//  cost is bounded by the delta + the last exchange — chunking, with the
//  framework doing the bookkeeping.
//
//  The moving parts, mapped to the API:
//  - `DynamicInstructions` body re-evaluates before EVERY request: the stable
//    instruction block leads (cache-friendly), the per-turn candidate package is
//    APPENDED at the end (Apple's KV-caching guidance: append in place), and the
//    person tool attaches only while a roster exists. Live state reads through a
//    lock-guarded box — profile evaluation's executor is the framework's business.
//  - `historyTransform` bounds what each request sees to the last
//    `historyWindow` transcript entries — the transcript can grow; requests can't.
//  - Deliberately NO temperature/reasoning modifiers in v1: the device A/B
//    (`-CaptureDiagnostics`) must isolate the architecture variable.
//
//  Status: complete and turn-contract-tested, but NOT yet the composer's default
//  path — the sim's model can't exercise it, so the default flips on device
//  evidence, the same way the capture deadline was tuned. `-CaptureDiagnostics`
//  runs it as the A/B arm and prints per-turn numbers.
//

import Foundation
import FoundationModels

@MainActor
final class CaptureConversation {

    /// Transcript entries each request may see. Two full exchanges: the previous
    /// user turn + response give the model its own last task list to update; one
    /// pair earlier absorbs a straggling tool call.
    nonisolated static let historyWindow = 4

    /// Live context the profile reads at each request. Lock-guarded because the
    /// framework owns where instruction bodies evaluate.
    final class ContextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _instructions: String = ""
        private var _roster: [RosterPerson] = []
        private var _candidates: [RetrievalCandidate] = []

        var instructions: String {
            get { lock.withLock { _instructions } }
            set { lock.withLock { _instructions = newValue } }
        }
        var roster: [RosterPerson] {
            get { lock.withLock { _roster } }
            set { lock.withLock { _roster = newValue } }
        }
        var candidates: [RetrievalCandidate] {
            get { lock.withLock { _candidates } }
            set { lock.withLock { _candidates = newValue } }
        }
    }

    struct CaptureProfile: LanguageModelSession.DynamicProfile {
        let box: ContextBox

        var body: some LanguageModelSession.DynamicProfile {
            LanguageModelSession.Profile {
                // Stable block first, volatile candidates appended — the prefix caches.
                Instructions(box.instructions + Self.candidateBlock(box.candidates))
                if !box.roster.isEmpty {
                    ResolvePersonTool(roster: box.roster)
                }
            }
            .historyTransform { history in
                Array(history.suffix(CaptureConversation.historyWindow))
            }
        }

        static func candidateBlock(_ candidates: [RetrievalCandidate]) -> String {
            guard !candidates.isEmpty else { return "" }
            let lines = candidates.map { "[\($0.id.uuidString)] \($0.title) — \($0.facts)" }
            return "\n\nCANDIDATES — the user's existing tasks most related to this capture. "
                + "These uuids are the ONLY valid ids for blocksExistingTasks, duplicateOfID, "
                + "and childOfID: copy one EXACTLY, or use null. Never invent an id.\n"
                + lines.joined(separator: "\n")
        }
    }

    private let box = ContextBox()
    private let session: LanguageModelSession
    /// The full text the LAST turn covered — the delta detector's baseline.
    private(set) var coveredText: String = ""

    init(context: TriageContext) {
        box.instructions =
            FoundationModelsEngine.instructionText(for: context) + Self.continuousContract
        box.roster = context.roster
        box.candidates = context.candidates
        session = LanguageModelSession(profile: CaptureProfile(box: box))
        session.prewarm(promptPrefix: Prompt(FoundationModelsEngine.promptHead))
    }

    /// The turn addendum that makes delta prompts safe: every response must be the
    /// COMPLETE current list, so a turn is never additive-only.
    nonisolated static let continuousContract = """


        This is a LIVE, CONTINUING capture: the user may keep talking, and you will \
        receive follow-up turns. When a turn says the ramble continued, combine the \
        new words with everything already captured and ALWAYS return the complete, \
        updated task list for the entire ramble so far — never only the new words' tasks.
        """

    // MARK: - Turn construction (pure, tested)

    enum Turn: Equatable {
        /// First words of the session — the standard full prompt.
        case initial(String)
        /// The ramble grew; send only the new words.
        case continuation(suffix: String)
        /// Earlier words changed; re-send everything.
        case revision(String)
    }

    /// What kind of turn moving from `covered` to `current` requires.
    nonisolated static func turn(from covered: String, to current: String) -> Turn {
        guard !covered.isEmpty else { return .initial(current) }
        guard current.hasPrefix(covered) else { return .revision(current) }
        let suffix = String(current.dropFirst(covered.count))
        return .continuation(suffix: suffix)
    }

    nonisolated static func prompt(for turn: Turn) -> String {
        switch turn {
        case .initial(let text):
            return "\(FoundationModelsEngine.promptHead)\n\n\(text)"
        case .continuation(let suffix):
            return "The ramble continued. New words:\n\n\(suffix)\n\nReturn the complete "
                + "updated task list for the entire ramble so far."
        case .revision(let text):
            return "The ramble was revised. Here is the full text now — return the complete "
                + "updated task list:\n\n\(text)"
        }
    }

    // MARK: - Parsing

    /// One parse as one TURN. Same streaming/partial contract as the single-use
    /// path; the caller owns deadlines (`CaptureTriageRace`) exactly as before.
    func triage(
        rawText: String,
        context: TriageContext,
        onPartial: (@MainActor ([TaskIntent]) -> Void)?
    ) async throws -> [TaskIntent] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Refresh the per-request context the profile body reads.
        box.candidates = context.candidates
        box.roster = context.roster
        let turn = Self.turn(from: coveredText, to: trimmed)
        let prompt = Self.prompt(for: turn)

        guard let onPartial else {
            let result = try await session.respond(to: prompt, generating: TriageResult.self)
                .content
            coveredText = trimmed
            return result.tasks.map { $0.toIntent() }
        }

        let stream = session.streamResponse(to: prompt, generating: TriageResult.self)
        var lastForwarded = Date.distantPast
        for try await snapshot in stream {
            let now = Date()
            guard
                now.timeIntervalSince(lastForwarded)
                    >= FoundationModelsEngine.partialThrottleSeconds
            else { continue }
            let intents = FoundationModelsEngine.intents(fromPartial: snapshot.content)
            if !intents.isEmpty {
                lastForwarded = now
                await onPartial(intents)
            }
        }
        let final = try await stream.collect().content
        // Covered only on a COMPLETED turn: a thrown/timed-out turn leaves the
        // baseline unchanged, so the next turn re-covers the words it missed.
        coveredText = trimmed
        return final.tasks.map { $0.toIntent() }
    }
}
