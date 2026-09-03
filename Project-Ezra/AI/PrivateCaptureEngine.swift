//
//  PrivateCaptureEngine.swift
//  Project-Ezra
//
//  PRIVATE CAPTURE — one thought in, one trustworthy capture out, and the raw text
//  NEVER leaves the device. The mode's privacy guarantee is structural, not a badge:
//  this file builds `LanguageModelSession`s and nothing else — there is no
//  `CloudModel` reference to misroute, no network fallback to reach for, and the
//  degrade below FM is the deterministic read, which is grounded by construction.
//
//  Everything here ships the configuration Campaign 3 measured (2026-08-30, device):
//  single-object schema + ~55-token instructions → total p50 1.8s · p95 2.4s ·
//  seg 42/43 · grounding 43/43 · burst-stable. Two design decisions ride that data:
//
//  **The silence window hides the generation** (owner decision). Ramble's rule is
//  "nothing is parsed while listening"; Private Capture re-scopes it to what it
//  always protected: **nothing is ever SHOWN before capture-end.** When the silence
//  window arms (words exist, the person paused), a SPECULATIVE generation starts;
//  any further speech discards it silently; at capture-end a finished speculation
//  reveals near-instantly, an in-flight one is awaited. The call is local, so a
//  discarded run costs battery, never money or privacy. `SpeculationPlan` is the
//  pure decision core, test-pinned.
//
//  **Failure still produces value.** FM refusing, timing out (8s — measured p99 was
//  3.1s, so this is a wedge guard, not a budget), or emitting an ungrounded quote
//  never punishes the user: the deterministic read of their own words becomes the
//  capture. The words are always kept; the model only ever improves on them.
//
//  The multi-intent DETECTOR is deterministic, not FM — Campaign 3 measured FM's
//  boolean at 43% precision (it would nag one in two single thoughts) against the
//  signal detector's 90%. A miss degrades gracefully: one capture the user can
//  split. FM re-earns this job only by beating 90% on the same labels.
//
//  Everything the schema omits is BACKFILLED deterministically from the same words
//  (`draft(from:rawText:)` → `HeuristicEngine.intent(from:)`): category, urgency,
//  importance, effort, a named person, and the date phrase where the model emitted
//  none. The model's job is the interpretation; the app's job is the metadata.
//
//  The due-date regression (76% in Campaign 3) was DIAGNOSED AND FIXED 2026-08-30:
//  null-string normalization moved it to 90% on its own, and the remaining three
//  misses were one mechanism — the model filing time phrases under `blockerPhrase`
//  — closed deterministically by `classifiedTimePhrase` (a "blocker" that resolves
//  as a date IS a date) and pinned by the three named device misses as test
//  fixtures. Re-measure with `-QuickCaptureDiag` on a RESTED device before quoting
//  a new rate: the diagnosis run's own latency tail (p95 3.4s) reflected a phone
//  that had been running campaigns all day.
//

import Foundation
import FoundationModels

// MARK: - The schema (production twin of Campaign 3's measured shape)

/// One thought → one capture. No array: the schema itself encodes "one in, one
/// out", so the model structurally cannot decompose. The trust fields are kept —
/// `sourceQuote` is the grounding contract (verified, never trusted),
/// `dateExpression` the raw-expression rule — and everything `IntentResolver`
/// backfills deterministically is deliberately absent.
@Generable
struct PrivateCaptureRead {
    @Guide(description: "Short verb-led action, max 8 words.")
    let title: String
    @Guide(
        description: "The user's own words this capture comes from, copied VERBATIM from the input."
    )
    let sourceQuote: String
    @Guide(description: "The user's time phrase copied verbatim, or null. Never a computed date.")
    let dateExpression: String?
    @Guide(description: "True only for a values-based judgment call.")
    let isJudgmentCall: Bool
    @Guide(
        description:
            "The task, person, or event this waits on — NEVER a time or date (those go in dateExpression). Null otherwise."
    )
    let blockerPhrase: String?
}

// MARK: - The speculation plan (pure, test-pinned)

/// The decision core of hiding generation inside the silence window. Pure state, no
/// tasks: the engine executes what this decides, and the tests pin the decisions —
/// a wrong rule here would either show stale interpretations (the product's cardinal
/// sin) or throw away perfectly good ones (the latency win wasted).
struct SpeculationPlan: Equatable {
    /// The text the in-flight (or finished) speculative run was started from.
    /// Nil = nothing speculated.
    private(set) var speculatedText: String?

    enum Decision: Equatable {
        /// Start a speculative run for this text (any previous one is stale).
        case speculate(String)
        /// Keep whatever is running — the text hasn't moved.
        case keep
        /// Nothing to do.
        case none
    }

    /// The silence window armed (words exist, the person paused). Speculate iff the
    /// text moved since the last speculation — re-arming on the SAME text (a tap
    /// that didn't change anything, a duplicate delta) must not burn a fresh run.
    mutating func armed(text: String) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        guard trimmed != speculatedText else { return .keep }
        speculatedText = trimmed
        return .speculate(trimmed)
    }

    /// More words arrived: any in-flight speculation is about a capture that no
    /// longer exists. The engine cancels; the plan forgets.
    mutating func invalidated() {
        speculatedText = nil
    }

    /// Capture-end. `true` = the speculative run (finished or in-flight) is FOR this
    /// exact text and may be used/awaited; `false` = generate fresh.
    func matches(finalText: String) -> Bool {
        speculatedText == finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The engine

@MainActor
final class PrivateCaptureEngine {

    /// ~55 tokens — the whole instruction set, the configuration Campaign 3 priced.
    /// A PRODUCT constant now (the measurement twin stays quarantined in the
    /// diagnostics seam); changes here re-run `-QuickCaptureDiag` first.
    static let instructions = """
        Turn the user's single thought into one captured task. The capture must come \
        from what they actually said — never invent. Copy their own words verbatim \
        into sourceQuote. Copy any time phrase verbatim into dateExpression; never \
        compute dates. Title: short, verb-led, max 8 words.
        """

    /// The wedge guard, not a budget: measured p99 was 3.1s; a run past this is a
    /// hung call, and the deterministic fallback serves the user instead.
    static let generationCapSeconds: Double = 8

    /// Private Capture's silence window. HALF of Ramble's 5s, deliberately: a ramble
    /// is thinking out loud (pauses routinely pass 2.5s); a quick capture is a
    /// thought the person already has. Owner decision, 2026-08-30.
    static let silenceStopSeconds: Double = 2.5

    /// How one capture resolved — the receipt the surface renders and the metric
    /// records.
    enum Outcome {
        /// The FM read, grounded and resolved. `speculative` = the generation was
        /// already done (or in flight) when capture ended — the latency win landed.
        case captured(TaskDraft, speculative: Bool)
        /// FM failed/timed out/ungrounded: the deterministic read of the user's own
        /// words. Never an error state — the words are kept, the capture exists.
        case fallback(TaskDraft)

        var draft: TaskDraft {
            switch self {
            case .captured(let draft, _), .fallback(let draft): return draft
            }
        }
    }

    private var plan = SpeculationPlan()
    private var speculativeTask: Task<PrivateCaptureRead?, Never>?
    private var warmSession: LanguageModelSession?

    /// Whether the on-device model can serve this mode at all. Off-device the mode
    /// still works — the deterministic read is the whole pipeline.
    static func modelAvailable() -> Bool { AppBrain.onDeviceModelAvailable() }

    /// Build the session early — the sheet-presentation animation absorbs the model
    /// load (the expensive part on a cold launch; Campaign 2 measured session
    /// CONSTRUCTION itself in single-digit ms).
    func prewarm() {
        guard Self.modelAvailable(), warmSession == nil else { return }
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm(promptPrefix: Prompt(Self.promptHead))
        warmSession = session
    }

    static let promptHead = "Here is the user's thought. Capture it:"

    // MARK: Speculation lifecycle (driven by the surface)

    /// More words arrived while listening: any in-flight speculation is stale.
    func transcriptChanged() {
        plan.invalidated()
        speculativeTask?.cancel()
        speculativeTask = nil
    }

    /// The silence window armed. Start (or keep) the hidden generation.
    func silenceArmed(text: String) {
        switch plan.armed(text: text) {
        case .none, .keep:
            return
        case .speculate(let trimmed):
            speculativeTask?.cancel()
            speculativeTask = Task { [weak self] in
                await self?.generate(text: trimmed)
            }
        }
    }

    /// Capture-end: produce the capture. Uses the speculative run when it is for
    /// exactly this text; generates fresh otherwise; falls back to the deterministic
    /// read on any model shortfall. Always returns a capture — failure produces
    /// value here, never an error screen.
    func finish(text: String, learned: [LearnedRule] = []) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            speculativeTask = nil
            plan.invalidated()
        }
        guard !trimmed.isEmpty else {
            return .fallback(Self.deterministicDraft(from: trimmed, learned: learned))
        }
        let speculative = plan.matches(finalText: trimmed)
        let read: PrivateCaptureRead?
        if speculative, let task = speculativeTask {
            read = await task.value
        } else {
            speculativeTask?.cancel()
            read = await generate(text: trimmed)
        }
        guard let read, let draft = Self.draft(from: read, rawText: trimmed, learned: learned)
        else {
            ModelMetrics.shared.record(.privateCapture, .failed("fallback"), latencyMs: 0)
            return .fallback(Self.deterministicDraft(from: trimmed, learned: learned))
        }
        return .captured(draft, speculative: speculative)
    }

    /// Everything torn down — the sheet closed or the user backed out.
    func cancel() {
        speculativeTask?.cancel()
        speculativeTask = nil
        plan.invalidated()
    }

    // MARK: The generation itself

    private func generate(text: String) async -> PrivateCaptureRead? {
        guard Self.modelAvailable() else { return nil }
        let session: LanguageModelSession
        if let warm = warmSession {
            session = warm
            warmSession = nil  // single use; rebuild behind this run
        } else {
            session = LanguageModelSession(instructions: Self.instructions)
        }
        defer { prewarm() }
        let started = Date()
        do {
            let read = try await ModelDeadline.race(timeout: Self.generationCapSeconds) {
                try await session.respond(
                    to: "\(Self.promptHead)\n\n\(text)", generating: PrivateCaptureRead.self
                ).content
            }
            ModelMetrics.shared.record(
                .privateCapture, .success,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return read
        } catch is ModelDeadline.Exceeded {
            ModelMetrics.shared.record(
                .privateCapture, .timedOut,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return nil
        } catch {
            if !Task.isCancelled {
                ModelMetrics.shared.record(
                    .privateCapture, .failed(AppBrain.errorLabel(error)),
                    latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            }
            return nil
        }
    }

    // MARK: Mapping + grounding + fallback (pure, test-pinned)

    /// The FM read → the pipeline's own vocabulary → one draft. Grounding is CHECKED
    /// here, not trusted: an ungrounded quote returns nil and the deterministic read
    /// serves instead — the model is never allowed to attribute words the user
    /// didn't say.
    ///
    /// **The model interprets; the deterministic read fills in the rest.** The schema
    /// deliberately carries only what needs a reader (title, quote, time phrase,
    /// judgment, wait); every field it dropped — category, urgency, importance,
    /// effort, a named person — is backfilled from the SAME words by
    /// `HeuristicEngine.intent(from:)`, the read Ramble's fallback already trusts, so
    /// a private capture reaches the card as fully populated as a rambled one instead
    /// of filed under "Admin" with nothing else known about it. The heuristic's date
    /// phrase serves only where the model emitted none: the raw text is the user's
    /// own words, so a phrase cut from it is grounded by construction — and a model
    /// that missed "tomorrow" is a model that missed it, not a reason the user
    /// should.
    static func draft(
        from read: PrivateCaptureRead, rawText: String, learned: [LearnedRule] = []
    ) -> TaskDraft? {
        let (dateExpression, blockerPhrase) = classifiedTimePhrase(
            dateExpression: read.dateExpression, blockerPhrase: read.blockerPhrase)
        let base = HeuristicEngine.intent(from: rawText)
        let intent = TaskIntent(
            title: read.title, category: base.category,
            dateExpression: dateExpression ?? base.dateExpression,
            personReference: base.personReference,
            blockerPhrase: blockerPhrase, confidence: 0.7,
            isJudgmentCall: read.isJudgmentCall, reasoning: base.reasoning,
            isUrgent: base.isUrgent, importance: base.importance,
            effortMinutes: base.effortMinutes,
            sourceQuote: read.sourceQuote)
        guard AppBrain.grounded(intent, in: rawText) else { return nil }
        return IntentResolver.resolve([intent], rules: learned).first
    }

    /// The floor that cannot fail: the deterministic single-thought read. Grounded
    /// by construction (it cuts from the text itself), instant, and always a capture.
    static func deterministicDraft(
        from rawText: String, learned: [LearnedRule] = []
    )
        -> TaskDraft
    {
        AppBrain.provisionalDrafts(rawText, learned: learned).first
            ?? IntentResolver.resolve([
                TaskIntent(
                    title: String(rawText.prefix(60)), category: "Admin",
                    dateExpression: nil, personReference: nil, blockerPhrase: nil,
                    confidence: 0.5, isJudgmentCall: false, reasoning: "",
                    effortMinutes: nil)
            ]).first
            ?? TaskDraft(
                title: String(rawText.prefix(60)), category: "Admin", confidence: 0.5,
                autonomy: .silent, isJudgmentCall: false, reasoning: "")
    }

    /// **A "blocker" that resolves as a date IS a date** — the device diagnosis
    /// (2026-08-30, three named misses, one mechanism) caught the model filing time
    /// phrases under `blockerPhrase` ("water the plants today" → blocker "today"),
    /// which is linguistically defensible ("the task waits on tomorrow") and
    /// semantically wrong three ways at once: no spoken date, due-inference
    /// suppressed (blocked tasks skip it), and a phantom wait on the card. The app
    /// decides, deterministically: a blocker `resolveDate` can read moves to
    /// `dateExpression` (when that slot is empty) and never survives as a wait —
    /// a time is not a thing a task waits ON in this model's vocabulary.
    static func classifiedTimePhrase(
        dateExpression: String?, blockerPhrase: String?
    ) -> (dateExpression: String?, blockerPhrase: String?) {
        var date = normalizedOptional(dateExpression)
        var blocker = normalizedOptional(blockerPhrase)
        if let candidate = blocker,
            IntentResolver.resolveDate(expression: candidate) != nil
        {
            if date == nil { date = candidate }
            blocker = nil
        }
        return (date, blocker)
    }

    /// Small models emit the WORD "null" into optional string fields often enough
    /// that treating it as content corrupts everything downstream: a blockerPhrase
    /// of "null" SUPPRESSES the due-date inference (`resolve` skips blocked tasks),
    /// and a dateExpression of "none" reads as a spoken-but-unresolvable time. An
    /// absent value and the string "null" mean the same thing from a 3B decoder;
    /// only one of them is honest input to the resolver.
    static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let lowered = trimmed.lowercased()
        if ["null", "none", "n/a", "nil", "no", "-"].contains(lowered) { return nil }
        return trimmed
    }

    /// "Sounds like more than one thing?" — the DETERMINISTIC detector (measured
    /// precision 90% vs FM's 43%). Fires the gentle hand-off to Ramble; a miss
    /// degrades to one capture the user can split.
    static func soundsLikeSeveralThings(_ text: String) -> Bool {
        CaptureEscalation.connectiveSignals(in: text) + CaptureEscalation.timeSignals(in: text)
            >= 2
    }
}
