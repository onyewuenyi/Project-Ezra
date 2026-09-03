//
//  Inquiry.swift
//  Project-Ezra
//
//  **The one operation every "ask Ezra" surface performs, written once.** (P-01)
//
//      scope → facts → budget → floor or model → validate → at most one move
//
//  Before this file, that operation existed twice in full — the task chat and the
//  household chat, built weeks apart, converged independently on the identical
//  seven-part structure (`Facts` → `fingerprint` → `Prompt` → `Turn` → `Service` →
//  `Store`, plus a floor on one of them) and shared nothing but a SwiftUI component
//  file. The Advisor reading and Ramble are the same shape with zero and one turns.
//  When one developer arrives at the same structure twice, that structure is the
//  primitive; this is it, named.
//
//  A SCOPE contributes only the two things that are genuinely its own — *what facts
//  does this scope have* (its instructions and its per-turn context) and *what does its
//  floor answer for free* — plus the small constants a workload owns (its metrics
//  feature, its token ceiling, its list clamp). Everything else is here and runs
//  identically for every scope: the continuity digest when the picture moves
//  mid-conversation, the reply clamp, verified citations, the per-scope session with
//  its warm prefix, the serial gate, the ledger write where the routing decision lands,
//  the in-order/retry/cancel loop, and the honest failure vocabulary.
//
//  Rules every scope inherits, because they are the product's and not the surface's:
//  - **Rung 0 answers before the model may.** A scope's floor is asked first; a floor
//    answer is instant, exact, cited, and costs no generation. `.facts` in the ledger.
//  - **On-device only, structurally.** This file never touches the cloud seam and is
//    grep-pinned alongside the chats. A question asked of Ezra has one answer to
//    "where did that go?" — nowhere.
//  - **The reply is revealed whole.** Streamed internally for salvage at the deadline,
//    never rendered as a sentence rewriting itself under the reader.
//  - **It never acts.** No scope carries a mutation seam; the model is told so.
//  - **One session per (scope, fingerprint).** Facts live in the instructions so the
//    prefix warms once; when the fingerprint moves the next turn carries a two-exchange
//    continuity digest and the session is rebuilt on the current truth.
//  - **In-memory per launch.** A conversation is a moment, not a record.
//
//  What a NEW scope costs after this: one `InquiryScope` conformance. "Ask about a
//  project", "ask about this week", "ask about a person" are configuration, not
//  features — which is the whole reason a primitive earns its noun.
//

import Foundation
import FoundationModels
import Observation

// MARK: - The scope contract

/// A thing Ezra can be asked about. A value, and `Sendable` so a turn can cross into the
/// responder's task. (Not `Equatable`: under main-actor default isolation a synthesized
/// conformance is isolated, and an isolated conformance cannot satisfy a requirement on
/// a `Sendable` `Self` — and nothing compares two scopes anyway; the fingerprint is the
/// identity that matters.)
@MainActor
protocol InquiryScope: Sendable {
    /// What conversations are keyed by — a task's id, or a singleton for the household.
    associatedtype Key: Hashable & Sendable

    var key: Key { get }

    /// Identity of the stable picture. Same fingerprint → same session; a moved
    /// fingerprint → a rebuilt session and a continuity digest on the next turn.
    var fingerprint: Int { get }

    /// The session's instructions: the scope's rules, then its stable facts block.
    var instructions: String { get }

    /// The noun the continuity header names: "the task", "the household".
    static var changedNoun: String { get }

    /// The metrics feature this scope's model turns are recorded under. A scope is its
    /// own workload — a chatty afternoon in one must not read as another climbing.
    /// Instance, not static: one scope type may carry two modes (a task's ASKED turns and
    /// its UNASKED reading) that count and configure differently.
    var feature: ModelFeature { get }

    /// Session config: temperature and the answer's token ceiling.
    var config: CapabilityProfiles.Config { get }

    /// Keeps two modes of one scope from sharing a session — the chat's instructions and
    /// the reading's are different prefixes. Default: none.
    var sessionDiscriminator: String { get }

    /// Rung 0 for the UNASKED turn — what the scope says before any question: the
    /// Advisor's deterministic reading, the household's day answer. Nil when there is
    /// nothing factual to open with. Default: nil.
    func opener() -> InquiryAnswer?

    /// The most lines a list-shaped reply may run to (the prose clamp is shared).
    static var maxLines: Int { get }

    /// The prompt head the warm prefix ends at — what every turn of this scope starts
    /// with, so prefill covers everything up to the question.
    static var prewarmPrefix: String { get }

    /// Rung 0. An exact answer, or nil to let the model speak. Default: no floor.
    func floor(for question: String) -> InquiryAnswer?

    /// The per-turn context — retrieval, when the instructions can't carry it all —
    /// and the citables that context showed the model. Default: none.
    func context(for question: String) -> InquiryContext

    /// The empty state's suggestions — what is askable here, from the facts.
    func starterQuestions() -> [String]
}

extension InquiryScope {
    func floor(for question: String) -> InquiryAnswer? { nil }
    func context(for question: String) -> InquiryContext { .none }
    var sessionDiscriminator: String { "" }
    func opener() -> InquiryAnswer? { nil }
}

/// What a floor or model answer carries back: the text and the tasks it is about.
struct InquiryAnswer: Equatable, Sendable {
    let text: String
    let citedTaskIDs: [UUID]
}

/// Something a reply may cite: a task the scope showed the model, by title.
struct InquiryCitable: Equatable, Sendable, Hashable {
    let id: UUID
    let title: String
}

/// The per-turn block and what it showed. `shown` is the ONLY set a reply may cite.
struct InquiryContext: Equatable, Sendable {
    let block: String?
    let shown: [InquiryCitable]

    static let none = InquiryContext(block: nil, shown: [])
}

/// Which rung answered — the DEBUG footer's receipt and the eval's route column.
enum InquiryRoute: Equatable, Sendable {
    case floor
    case model
}

// MARK: - One turn (the value the responder is given)

/// Everything one reply needs, as a value — so a store's responder can be injected and
/// the real service can be a pure function of it.
struct InquiryTurn<Scope: InquiryScope>: Sendable {
    let scope: Scope
    let question: String
    /// The last exchanges, when the picture changed since they happened. Nil on an
    /// unbroken thread — the session's own transcript carries it then.
    let continuity: String?
    let context: InquiryContext

    /// The full prompt this turn sends.
    var prompt: String {
        InquiryPrompt.turnPrompt(
            question: question, context: context, continuity: continuity,
            changedNoun: Scope.changedNoun)
    }
}

// MARK: - The prompt (pure, pinned by tests)

enum InquiryPrompt {

    /// Transcript entries each request may see: four exchanges. The facts live in the
    /// instructions, so nothing the window drops is load-bearing.
    static let historyWindow = 8

    /// The most sentences a prose reply may run to — enforced in code, not requested in
    /// prose. A collection clamp over sentences, never a mid-word cut.
    static let maxSentences = 4

    /// How many prior exchanges the continuity digest carries.
    static let continuityExchanges = 2

    /// The per-turn prompt: the digest (when the picture moved), the scope's context
    /// block (when it has one), then the question.
    static func turnPrompt(
        question: String, context: InquiryContext, continuity: String?, changedNoun: String
    ) -> String {
        var parts: [String] = []
        if let continuity, !continuity.isEmpty {
            parts.append("EARLIER IN THIS CONVERSATION (\(changedNoun) has changed since):\n\(continuity)")
        }
        if let block = context.block, !block.isEmpty { parts.append(block) }
        parts.append("QUESTION: \(question.trimmingCharacters(in: .whitespacesAndNewlines))")
        return parts.joined(separator: "\n\n")
    }

    /// The last `continuityExchanges` answered exchanges, as "They asked / You said"
    /// lines. Pending and failed replies are skipped — they said nothing. Nil when there
    /// is nothing to carry.
    static func continuityDigest(_ messages: [ChatMessage]) -> String? {
        var exchanges: [(question: String, answer: String)] = []
        var pendingQuestion: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingQuestion = message.text
            case .advisor:
                guard message.state == .sent, let question = pendingQuestion else { continue }
                exchanges.append((question, message.text))
                pendingQuestion = nil
            }
        }
        let kept = exchanges.suffix(continuityExchanges)
        guard !kept.isEmpty else { return nil }
        return kept.map { "They asked: \($0.question)\nYou said: \($0.answer)" }
            .joined(separator: "\n")
    }

    /// The trust boundary for a reply: trimmed, clamped, nil when nothing survives.
    /// Model output is transport; this is what the surface renders.
    ///
    /// Two shapes, two clamps. PROSE (no line breaks) is clamped by sentence. A LIST
    /// keeps its line breaks and is clamped by line — the sentence clamp joins with
    /// spaces, so it would fold "1. Find the letter\n2. Call" into one line.
    static func validatedReply(_ raw: String, maxLines: Int) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count > 1 {
            return lines.prefix(maxLines).joined(separator: "\n")
        }
        let clamped = TaskAdvisorReading.clamped(trimmed, sentences: maxSentences)
        return clamped.isEmpty ? nil : clamped
    }
}

// MARK: - The floor's shared vocabulary (rung 0)

/// What every scope's floor shares: the words that turn a closed question into a
/// reasoning one, and whole-word phrase matching. A scope decides WHICH closed shapes
/// it answers; this decides whether a question is closed at all.
enum InquiryFloor {

    /// Words that send a question to the model even when a filter word is present —
    /// "why is it overdue?" is not a request for the overdue list.
    static let reasoningWords: Set<String> = [
        "why", "should", "how", "could", "would", "whether", "explain", "think", "suggest",
        "recommend", "plan", "prioriti", "first", "best", "matter", "help", "advice",
        "instead", "worth",
    ]

    /// Whole-word phrase matching. A substring match once took "what's on my plate" as
    /// "late" (→ overdue); the boundary is the fix.
    static func mentions(any phrases: [String], in lowered: String) -> Bool {
        phrases.contains { phrase in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            return lowered.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// True when the question carries a reasoning word ("how many" excepted — a count is
    /// the one "how" a floor takes).
    static func isReasoning(_ question: String) -> Bool {
        let lowered = question.lowercased()
        let words = Set(lowered.split { !$0.isLetter && $0 != "'" }.map(String.init))
        let gated = lowered.contains("how many") ? words.subtracting(["how"]) : words
        return gated.contains { word in reasoningWords.contains { word.hasPrefix($0) } }
    }
}

// MARK: - Citations (verify what the reply names)

enum InquiryCitations {

    /// The citables a reply NAMES, verified against what the model was shown: a title is
    /// cited when it appears in the reply (case-insensitive) or when its significant
    /// words appear IN ORDER with at most two other words between neighbours — "get the
    /// passport photos done" names "Get passport photos"; "the passport is waiting on the
    /// photos" does not. Single-word titles match whole only. Deterministic — the model
    /// cannot cite a task the facts do not hold, and a reply that names nothing cites
    /// nothing.
    static func cited(in reply: String, among shown: [InquiryCitable]) -> [UUID] {
        let lowered = reply.lowercased()
        return shown.filter { citable in
            let title = citable.title.lowercased()
            if lowered.contains(title) { return true }
            let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !CorrectionProfile.significantWords($0).isEmpty }
            guard words.count >= 2 else { return false }
            let pattern =
                "\\b"
                + words.map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "\\b(?:\\W+\\w+){0,2}\\W+\\b") + "\\b"
            return lowered.range(of: pattern, options: .regularExpression) != nil
        }
        .map(\.id)
    }
}

// MARK: - The service (on-device, one session per scope + fingerprint)

/// The real responder for every scope. Holds the live session per scope key so a thread
/// of questions is a thread of turns, and rebuilds it when the fingerprint moves.
/// Everything here is on-device: `SystemLanguageModel.default` through
/// `CapabilityProfiles.session`, bounded by `ModelDeadline.seconds(for: .reply)` through
/// `ModelRun`.
@MainActor
final class InquiryService {

    static let shared = InquiryService()

    private struct Live {
        let fingerprint: Int
        let session: LanguageModelSession
    }

    /// Keyed by scope TYPE, key and discriminator together, so two scopes with colliding
    /// key values — or two modes of one scope — can never share a session.
    private var live: [String: Live] = [:]

    /// One warm SPARE per instruction set, adopted by the first scope that needs those
    /// instructions. This is what `TaskAdvisorSessionPool` used to be: a prefix warmed
    /// while a detail page settles, so the first reading doesn't pay prefill against the
    /// person's pause. Keyed by instructions + config, so a changed prefix never hands
    /// out a stale spare.
    private var spares: [Int: LanguageModelSession] = [:]

    /// The profile: the scope's instructions, history windowed. No tools in v1 — the
    /// facts block already carries everything the ambient Advisor sees, and a tool is
    /// the tripwire for "readings starved of context", not a default.
    struct Profile: LanguageModelSession.DynamicProfile {
        let instructions: String
        let config: CapabilityProfiles.Config

        var body: some LanguageModelSession.DynamicProfile {
            LanguageModelSession.Profile {
                Instructions(instructions)
            }
            .temperature(config.temperature)
            .maximumResponseTokens(config.maximumResponseTokens)
            .historyTransform { history in
                Array(history.suffix(InquiryPrompt.historyWindow))
            }
        }
    }

    /// Warm the session the moment a scope's surface appears — the person is about to
    /// type, which absorbs the prefill. A no-op off-device and under tests.
    func prewarm<S: InquiryScope>(_ scope: S) {
        guard AppBrain.onDeviceModelAvailable() else { return }
        _ = session(for: scope)
    }

    /// Warm a spare for an instruction set whose SCOPE is not known yet — the Advisor's
    /// static instructions while a page settles, before the facts are read. Skips when a
    /// spare is already waiting. A no-op off-device and under tests.
    func prewarmSpare(instructions: String, config: CapabilityProfiles.Config) {
        guard AppBrain.onDeviceModelAvailable() else { return }
        let key = Self.spareKey(instructions: instructions, config: config)
        guard spares[key] == nil else { return }
        let session = CapabilityProfiles.session(instructions: instructions, config: config)
        session.prewarm()
        spares[key] = session
    }

    /// The ZERO-TURN answer (G2): one typed, guided generation over the scope's session —
    /// the ambient Advisor reading. Streaming and salvage stay the reply path's; a judgment
    /// is one value or nothing, never a partial rendered as truth.
    func respond<S: InquiryScope, T: Generable & Sendable>(
        _ scope: S, prompt: String, generating type: T.Type
    ) async throws -> T {
        let session = session(for: scope)
        return try await session.respond(to: prompt, generating: type).content
    }

    /// One reply. Streamed internally so a deadline hit can salvage what arrived;
    /// revealed by the caller as a whole.
    func reply<S: InquiryScope>(_ turn: InquiryTurn<S>) async -> ModelResult<String> {
        let prompt = turn.prompt
        let box = PartialBox<String>()
        let started = Date()
        let outcome = await ModelRun.perform(turn.scope.feature, deadline: ModelDeadline.seconds(for: .reply)) {
            let session = self.session(for: turn.scope)
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                box.latest = snapshot.content
            }
            return try await stream.collect().content
        }
        // Salvage: the deadline fired mid-answer. What streamed is a real answer to the
        // question — shorter than the model intended, which the clamp would have done
        // anyway — and a person who asked deserves it over an error line.
        if case .timedOut = outcome, let partial = box.latest,
            InquiryPrompt.validatedReply(partial, maxLines: S.maxLines) != nil
        {
            ModelMetrics.shared.record(
                turn.scope.feature, .salvaged, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return .success(partial)
        }
        return outcome
    }

    /// Drop a scope's session — the conversation was cleared, or the scope left the
    /// working set.
    func forget<S: InquiryScope>(_ scopeType: S.Type, key: S.Key, discriminator: String = "") {
        live[Self.sessionKey(scopeType, key: key, discriminator: discriminator)] = nil
    }

    private static func sessionKey<S: InquiryScope>(_ scopeType: S.Type, key: S.Key, discriminator: String) -> String {
        "\(S.self)#\(key)#\(discriminator)"
    }

    private static func spareKey(instructions: String, config: CapabilityProfiles.Config) -> Int {
        var hasher = Hasher()
        hasher.combine(instructions)
        hasher.combine(config.temperature)
        hasher.combine(config.maximumResponseTokens)
        return hasher.finalize()
    }

    /// The live session for this scope: reused while the fingerprint holds, rebuilt on
    /// the new facts when it moves. The continuity digest is the store's job — the
    /// service only knows sessions.
    private func session<S: InquiryScope>(for scope: S) -> LanguageModelSession {
        let key = Self.sessionKey(S.self, key: scope.key, discriminator: scope.sessionDiscriminator)
        if let current = live[key], current.fingerprint == scope.fingerprint {
            return current.session
        }
        // A spare warmed for exactly these instructions is adopted rather than rebuilt —
        // the prefill already happened while the page settled.
        let spareKey = Self.spareKey(instructions: scope.instructions, config: scope.config)
        let session: LanguageModelSession
        if let spare = spares.removeValue(forKey: spareKey) {
            session = spare
        } else {
            session = LanguageModelSession(
                profile: Profile(
                    instructions: scope.instructions,
                    config: CapabilityProfiles.supported(scope.config)))
            session.prewarm(promptPrefix: Prompt(S.prewarmPrefix))
        }
        live[key] = Live(fingerprint: scope.fingerprint, session: session)
        return session
    }
}

// MARK: - The store (the loop, once)

/// The conversations for one scope type, per key, for this launch — and the one loop
/// that turns a question into a reply. An injected responder so the loop is a unit test
/// rather than a sim check (`ModelRun` is inert under XCTest), a `SerialGate` per key
/// because Foundation Models rejects a second concurrent `respond` on one session, and
/// the ledger written where the routing decision lands (`.facts` for a floor answer,
/// `.onDevice` for a model one — the two outcomes the economics turn on).
///
/// Two rules the store enforces that no view has to know:
/// - **A question is answered in order.** Two quick asks queue; they never overlap on
///   the session, and the second one's reply lands after the first's.
/// - **A changed picture is a new session, not a lost thread.** The fingerprint is
///   re-read on every ask; when it moved, the next turn carries the continuity digest
///   and the responder rebuilds the session on the current facts.
@MainActor
@Observable
final class InquiryStore<Scope: InquiryScope> {

    struct Conversation {
        var messages: [ChatMessage] = []
        /// The fingerprint the LAST turn was sent over. Nil until the first ask.
        var fingerprint: Int?
        /// In-flight replies, keyed by the advisor message they will fill.
        var work: [UUID: Task<Void, Never>] = [:]
        /// Which rung answered the last question.
        var lastRoute: InquiryRoute?
    }

    typealias Responder = @MainActor (InquiryTurn<Scope>) async -> ModelResult<String>

    private(set) var conversations: [Scope.Key: Conversation] = [:]
    /// One gate per key: the session is per key, and only the session is the resource
    /// that cannot be re-entered. Two keys' conversations may run side by side.
    private var gates: [Scope.Key: SerialGate] = [:]

    private let responder: Responder
    private let isModelAvailable: @MainActor () -> Bool
    private let ledger: IntelligenceLedger

    init(
        responder: @escaping Responder = { await InquiryService.shared.reply($0) },
        isModelAvailable: @escaping @MainActor () -> Bool = { AppBrain.onDeviceModelAvailable() },
        ledger: IntelligenceLedger = .shared
    ) {
        self.responder = responder
        self.isModelAvailable = isModelAvailable
        self.ledger = ledger
    }

    // MARK: Reads

    func messages(key: Scope.Key?) -> [ChatMessage] {
        guard let key else { return [] }
        return conversations[key]?.messages ?? []
    }

    /// Is a reply in flight? The surface disables Send on it — not to forbid a second
    /// question (the gate would queue it honestly) but because a person watching one
    /// thinking mark should not be invited to stack another.
    func isReplying(key: Scope.Key?) -> Bool {
        guard let key, let conversation = conversations[key] else { return false }
        return conversation.messages.contains { $0.state == .pending }
    }

    func lastRoute(key: Scope.Key?) -> InquiryRoute? {
        guard let key else { return nil }
        return conversations[key]?.lastRoute
    }

    // MARK: The loop

    /// Ask. The floor answers synchronously when it can — no pending state, no thinking
    /// mark, the rows are simply there. Otherwise a pending reply is appended and filled
    /// through the gate. Empty questions are ignored rather than sent.
    func ask(_ question: String, scope: Scope, now: Date = Date()) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var conversation = conversations[scope.key] ?? Conversation()
        conversation.messages.append(ChatMessage(role: .user, text: trimmed))

        if let floor = scope.floor(for: trimmed) {
            ledger.record(.facts, for: .chat, now: now)
            conversation.lastRoute = .floor
            conversation.messages.append(
                ChatMessage(role: .advisor, text: floor.text, citedTaskIDs: floor.citedTaskIDs))
            conversations[scope.key] = conversation
            return
        }

        let reply = ChatMessage(role: .advisor, text: "", state: .pending)
        conversation.messages.append(reply)
        conversations[scope.key] = conversation
        start(replyID: reply.id, question: trimmed, scope: scope, now: now)
    }

    /// The UNASKED turn (G2): open a conversation with the scope's rung-0 opener — the
    /// Advisor's reading, the household's day answer — as the first advisor line, once
    /// per fingerprint, and only while nobody has asked anything yet. A conversation that
    /// already has a question keeps its thread; a moved fingerprint on an untouched thread
    /// replaces the opener rather than stacking a second one.
    func open(scope: Scope, now: Date = Date()) {
        var conversation = conversations[scope.key] ?? Conversation()
        guard !conversation.messages.contains(where: { $0.role == .user }) else { return }
        guard conversation.fingerprint != scope.fingerprint else { return }
        conversation.messages.removeAll()
        conversation.fingerprint = scope.fingerprint
        if let opener = scope.opener() {
            ledger.record(.facts, for: .chat, now: now)
            conversation.lastRoute = .floor
            conversation.messages.append(
                ChatMessage(role: .advisor, text: opener.text, citedTaskIDs: opener.citedTaskIDs))
        }
        conversations[scope.key] = conversation
    }

    /// Retry a failed reply in place — the question stays where it was, the failed slot
    /// becomes pending again. Only meaningful from `.failed`.
    func retry(replyID: UUID, scope: Scope, now: Date = Date()) {
        guard var conversation = conversations[scope.key],
            let index = conversation.messages.firstIndex(where: { $0.id == replyID }),
            case .failed = conversation.messages[index].state,
            index > 0, conversation.messages[index - 1].role == .user
        else { return }
        let question = conversation.messages[index - 1].text
        conversation.messages[index].state = .pending
        conversation.messages[index].text = ""
        conversations[scope.key] = conversation
        start(replyID: replyID, question: question, scope: scope, now: now)
    }

    /// Cancel every reply in flight for a key. The pending slots become retryable
    /// failures rather than vanishing — the question was asked, and a reopened
    /// conversation should show it unanswered rather than pretend it never happened.
    func cancel(key: Scope.Key?) {
        guard let key, var conversation = conversations[key] else { return }
        for (replyID, work) in conversation.work {
            work.cancel()
            if let index = conversation.messages.firstIndex(where: { $0.id == replyID }) {
                conversation.messages[index].state = .failed(retryable: true)
            }
        }
        conversation.work = [:]
        conversations[key] = conversation
    }

    /// Forget the whole conversation — the "Clear" in the menu.
    func clear(key: Scope.Key?) {
        guard let key else { return }
        cancel(key: key)
        conversations[key] = nil
        gates[key] = nil
        InquiryService.shared.forget(Scope.self, key: key)
    }

    /// Await every reply in flight for a key — the seam the tests use to step the loop
    /// deterministically. A no-op once settled.
    func awaitPendingReplies(key: Scope.Key?) async {
        guard let key else { return }
        let pending = conversations[key].map { Array($0.work.values) } ?? []
        for work in pending {
            await work.value
        }
    }

    #if DEBUG
    /// Verification fixtures: a canned thread so every message state is on screen at
    /// once on a host with no model. Never runs outside a launch-argument seam.
    func seed(key: Scope.Key, messages: [ChatMessage]) {
        conversations[key] = Conversation(messages: messages)
    }
    #endif

    // MARK: Internals

    private func start(replyID: UUID, question: String, scope: Scope, now: Date) {
        let key = scope.key
        guard isModelAvailable() else {
            // The entry point hides itself off-device, so this is a defensive arm: it
            // answers honestly rather than spinning forever.
            settle(key, replyID: replyID, outcome: .unavailable, shown: [])
            return
        }
        // A moved fingerprint means the responder will rebuild its session on the new
        // facts; the digest is what keeps the thread readable across that rebuild.
        let previous = conversations[key]?.fingerprint
        let continuity: String? =
            (previous != nil && previous != scope.fingerprint)
            ? InquiryPrompt.continuityDigest(messages(key: key)) : nil
        conversations[key]?.fingerprint = scope.fingerprint
        conversations[key]?.lastRoute = .model
        let context = scope.context(for: question)
        let turn = InquiryTurn(scope: scope, question: question, continuity: continuity, context: context)
        ledger.record(.onDevice, for: .chat, now: now)

        let gate = gates[key] ?? SerialGate()
        gates[key] = gate
        let work = Task { [responder] in
            let outcome = await gate.run { await responder(turn) }
            guard !Task.isCancelled else { return }
            self.settle(key, replyID: replyID, outcome: outcome, shown: context.shown)
        }
        conversations[key]?.work[replyID] = work
    }

    private func settle(
        _ key: Scope.Key, replyID: UUID, outcome: ModelResult<String>, shown: [InquiryCitable]
    ) {
        guard var conversation = conversations[key],
            let index = conversation.messages.firstIndex(where: { $0.id == replyID })
        else { return }
        conversation.work[replyID] = nil
        switch outcome {
        case .success(let raw):
            if let text = InquiryPrompt.validatedReply(raw, maxLines: Scope.maxLines) {
                conversation.messages[index].text = text
                conversation.messages[index].state = .sent
                conversation.messages[index].citedTaskIDs = InquiryCitations.cited(in: text, among: shown)
            } else {
                conversation.messages[index].state = .failed(retryable: true)
            }
        case .unavailable:
            conversation.messages[index].state = .failed(retryable: false)
        case .cancelled:
            // `cancel` already marked the slot; a cancelled task that reaches here (the
            // responder observed cancellation itself) gets the same honest state.
            conversation.messages[index].state = .failed(retryable: true)
        case .timedOut, .failed:
            conversation.messages[index].state = .failed(retryable: true)
        }
        conversations[key] = conversation
    }
}
