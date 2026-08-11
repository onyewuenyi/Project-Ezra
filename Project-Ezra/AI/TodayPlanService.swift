//
//  TodayPlanService.swift
//  Project-Ezra
//
//  The generation side of the Today advisor briefing: tier routing, the two model
//  generators (on-device + Private Cloud Compute), the advisor instructions, and the
//  `AppBrain.todayPlan` seam that walks the tier chain and can never fail (the
//  deterministic tail always succeeds).
//
//  The model is now the advisor — it selects, orders, sizes, and reasons. Routing is
//  a simple ordered chain (on-device → PCC → deterministic); the capacity/divergence
//  inputs are gone with the capacity input. Instructions are a fresh per-call string
//  (stateless sessions), so a shifting throughput average needs no session teardown.
//
//  ⚠️ Device-verify only: the streamed `@Generable` briefing, PCC fallthrough, and
//  `Response.usage` wiring (tokens are −1 until verified). The simulator exercises the
//  deterministic fallback alone.
//

import CoreData
import Foundation
import FoundationModels

// MARK: - Errors

enum PlanGenerationError: Error {
    case unavailable
    case timedOut
}

/// Plan-shaped viability for the shared salvage box (`ModelDeadline.PartialBox`,
/// where the type itself now lives).
extension PartialBox where Value == GeneratedPlan {
    /// The last partial that's worth showing: a headline AND at least one action.
    func viablePartial() -> GeneratedPlan? {
        guard let latest, latest.headline != nil, !latest.actions.isEmpty else { return nil }
        return latest
    }
}

// MARK: - PCC entitlement gate

/// Whether the PCC tier may be touched at all. `PrivateCloudComputeLanguageModel`
/// **FATAL-ERRORS** (an uncatchable trap, not a `throw`) the instant it is constructed
/// — even to read `.isAvailable` — without the Apple-managed
/// `com.apple.developer.private-cloud-compute` entitlement, so `guard model.isAvailable`
/// never gets to run. iOS exposes no public API to read one's own entitlements at
/// runtime, so this is a compile-time gate: it stays `false` until the entitlement is
/// provisioned in signing, then flips to `true` and the PCC tier activates with no
/// other change (mirrors `PersistenceStack.cloudKitContainerID` being nil until
/// provisioned).
enum PCCEntitlement {
    static var isGranted = false
}

// MARK: - Routing (pure, ordered)

/// The per-call tier chain. `.deterministic` is always the tail, so the chain can
/// never be empty and generation can never fail. On-device is preferred (fast,
/// private, free); PCC is next when entitled; deterministic is the fallback.
enum PlanRouting {
    static func decide(onDeviceAvailable: Bool, pccAvailable: Bool) -> [PlanTier] {
        var chain: [PlanTier] = []
        if onDeviceAvailable { chain.append(.onDevice) }
        if pccAvailable { chain.append(.pcc) }
        chain.append(.deterministic)
        return chain
    }
}

// MARK: - Advisor instructions

/// The advisor role, rebuilt fresh from the live throughput before every call. The
/// throughput line is advisory context only, and is omitted at cold start (no claim
/// before data exists).
enum TodayPlanInstructions {
    static func text(for request: TodayPlanRequest) -> String {
        var blocks = [role]
        if let n = request.typicalCompleted {
            blocks.append(
                "Context: this person typically finishes about \(n) task\(n == 1 ? "" : "s") on a "
                    + "normal day. Size the plan to that reality — a focused few beats an "
                    + "unrealistic pile.")
        }
        return blocks.joined(separator: "\n\n")
    }

    private static let role = """
        You are a calm, sharp personal advisor writing today's briefing. You are given
        the person's candidate tasks with observable facts. Decide what actually
        matters today, put it in priority order, and keep it to only what's worth
        doing — a short, honest plan beats a long one.

        The candidate list is already in the system's current priority order — built
        from deadlines, blockers, relevance, and the person's explicit urgency
        signals. Treat that ordering as a strong prior; deviate when the facts
        justify it.

        Return: a one-line headline; the chosen actions (each a task id from the list
        plus one grounded line); the tradeoff (what you're setting aside and why); and
        the risks (what's overdue, blocked, or undecided that could bite).

        Hard rules:
        - Choose ONLY from the given task ids. Never invent a task, a deadline, or a
          fact that isn't in the list.
        - Reason only from the given facts (due/overdue, blocks, decision, effort).
        - If a task is marked "in progress", the person already committed to it —
          prefer finishing that over starting something new.
        - "planning work" means the task needs approach-forming rather than direct
          execution. Compose a day that makes progress — concrete actions carry
          momentum, and a planning task is best placed where there is room to think.
          This is a consideration, not a rule; choose several planning tasks when the
          candidates genuinely warrant it.
        - "set aside N×" means the task has resisted execution enough to deserve
          deliberate reconsideration — consider naming one such task. Never treat it
          as a demand to re-plan it, and never scold.
        - Two tools exist: task_details (extra detail on ONE candidate) and
          yesterday_outcome (what happened yesterday). Consult them only when weighing
          a candidate — a few calls at most; the candidate lines usually suffice.
        - This is a LIVE day: you may receive follow-up turns as it changes
          ("SINCE THIS MORNING: …"). Always return the complete plan for the rest of
          the day — never only the changes.
        - Plain and steady. No pep talk, no exclamation marks, no emoji.
        """
}

// MARK: - Prompt

enum TodayPlanPrompt {
    static func body(for request: TodayPlanRequest) -> String {
        var lines: [String] = []
        // A recompose turn leads with what changed. With the session alive this rides
        // on top of the morning transcript; after a process restart it IS the
        // continuity. Either way the response contract is the same: a complete plan.
        if let delta = request.deltaContext {
            lines.append(delta)
            lines.append("Return the COMPLETE updated plan for the rest of today.")
        }
        lines.append("COMPLETED TODAY SO FAR: \(request.recapCount)")
        lines.append("CANDIDATE TASKS (choose from these ids only):")
        for (index, snapshot) in request.candidates.enumerated() {
            lines.append(snapshot.promptLine(index: index + 1))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Shared session driver + schema mapping

/// The one place that touches the guided-generation session and the macro-generated
/// `PartiallyGenerated` shapes — shared by both model generators so streaming and
/// mapping live once. Every path ends in `validated(against:)` (anti-hallucination).
enum TodayPlanSession {
    /// Bound the worst-case generation time: the briefing schema is small, so a runaway
    /// tradeoffs/risks paragraph is the only thing that could eat the whole deadline.
    /// Capping output can't hurt this schema and keeps generation time predictable.
    static let responseTokenCap = 600

    static func generate(
        session: LanguageModelSession,
        request: TodayPlanRequest,
        tier: PlanTier,
        onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        let prompt = TodayPlanPrompt.body(for: request)
        let options = GenerationOptions(maximumResponseTokens: responseTokenCap)
        guard let onPartial else {
            let final = try await session.respond(
                to: prompt, generating: AdvisorBriefing.self, options: options
            ).content
            return plan(from: final, tier: tier).validated(against: request)
        }
        let stream = session.streamResponse(
            to: prompt, generating: AdvisorBriefing.self, options: options)
        for try await snapshot in stream {
            let partial = plan(fromPartial: snapshot.content, tier: tier).validated(against: request)
            await onPartial(partial)
        }
        let final = try await stream.collect().content
        return plan(from: final, tier: tier).validated(against: request)
    }

    /// Map the fully-generated briefing. Unknown-uuid ids drop here; `validated`
    /// double-checks against the candidate set.
    static func plan(from briefing: AdvisorBriefing, tier: PlanTier) -> GeneratedPlan {
        let actions = briefing.actions.compactMap { action -> PlannedAction? in
            guard let id = UUID(uuidString: action.taskID) else { return nil }
            let line = action.line.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlannedAction(taskID: id, rationale: line.isEmpty ? nil : line)
        }
        return GeneratedPlan(
            actions: actions, headline: briefing.headline, tradeoffs: briefing.tradeoffs,
            risks: briefing.risks, tier: tier)
    }

    /// Map a partial snapshot: only actions with a known-uuid id AND a non-empty line
    /// surface; the narrative fields stream in as they arrive.
    static func plan(
        fromPartial partial: AdvisorBriefing.PartiallyGenerated, tier: PlanTier
    ) -> GeneratedPlan {
        let actions = (partial.actions ?? []).compactMap { action -> PlannedAction? in
            guard let idString = action.taskID, let id = UUID(uuidString: idString),
                let line = action.line?.trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty
            else { return nil }
            return PlannedAction(taskID: id, rationale: line)
        }
        return GeneratedPlan(
            actions: actions, headline: partial.headline, tradeoffs: partial.tradeoffs,
            risks: partial.risks, tier: tier)
    }
}

// MARK: - Model generators

/// The on-device tier: the per-day `AdvisorSession` (profile-backed, tooled,
/// transcript-carrying), streamed. The session is the whole point — see
/// `AdvisorSession.swift`'s header.
struct OnDevicePlanGenerator: TodayPlanGenerator {
    let tier: PlanTier = .onDevice
    let session: AdvisorSession

    func generate(
        _ request: TodayPlanRequest, onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        try await session.respond(request: request, onPartial: onPartial)
    }
}

/// The Private Cloud Compute tier. Any error — including an ungranted entitlement —
/// reads as unavailability, so the router falls through to on-device/deterministic.
struct PCCPlanGenerator: TodayPlanGenerator {
    let tier: PlanTier = .pcc

    func generate(
        _ request: TodayPlanRequest, onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        // Never construct the model without the entitlement — it traps, not throws.
        guard PCCEntitlement.isGranted else { throw PlanGenerationError.unavailable }
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else { throw PlanGenerationError.unavailable }
        let session = LanguageModelSession(
            model: model, instructions: TodayPlanInstructions.text(for: request))
        return try await TodayPlanSession.generate(
            session: session, request: request, tier: tier, onPartial: onPartial)
    }
}

// MARK: - AppBrain seam

extension AppBrain {
    /// Produce today's advisor briefing by walking the routed tier chain. Never throws
    /// — the deterministic tail always succeeds. Mirrors `householdNarrative`'s
    /// degrade-on-failure contract. Availability is read fresh per call. Owns the
    /// instrumentation and the one `.ai` "planned" ChangeLog entry.
    func todayPlan(
        for request: TodayPlanRequest,
        in context: NSManagedObjectContext,
        onPartial: (@MainActor (GeneratedPlan) -> Void)? = nil
    ) async -> GeneratedPlan {
        let chain = PlanRouting.decide(
            onDeviceAvailable: Self.onDeviceAvailable(), pccAvailable: Self.pccAvailable())

        let availability = Self.availabilityLabel()
        let start = Date()
        for tier in chain {
            do {
                let generated = try await run(tier: tier, request: request, onPartial: onPartial)
                let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                planMetrics.recordGeneration(
                    tier: tier, latencyMs: latencyMs, promptTokens: -1, outputTokens: -1,
                    toolCalls: tier == .onDevice ? advisorSession?.box.toolCalls ?? 0 : 0,
                    turn: tier == .onDevice ? advisorSession?.turn ?? 0 : 0)
                logPlanned(generated, in: context)
                return generated
            } catch {
                // Don't silently swallow: record WHY this model tier failed (typed) so the
                // diagnostics footer can name it, then fall through to the next tier.
                let label = Self.errorLabel(error)
                planMetrics.recordFailure(tier: tier, label: label, availability: availability)
                #if DEBUG
                print("[TodayPlan] tier \(tier) failed: \(label) (availability: \(availability))")
                #endif
                continue  // tier unavailable / failed / timed out → next in chain
            }
        }
        // Structurally unreachable (deterministic can't throw), but stay honest.
        let fallback = GeneratedPlan(
            actions: [], headline: nil, tradeoffs: nil, risks: nil, tier: .deterministic)
        logPlanned(fallback, in: context)
        return fallback
    }

    // MARK: Tier execution + timeouts

    /// The on-device deadline. Cold generation of a full streamed briefing routinely
    /// needs well over 12s; a too-tight deadline consistently threw → deterministic.
    /// Prewarming (see `prewarmTodayModel`) shrinks the cold portion; the salvage path
    /// (below) means even hitting this deadline usually still yields a voiced briefing.
    private static let onDeviceTimeoutSeconds: Double = 30
    private static let pccTimeoutSeconds: Double = 20

    private func run(
        tier: PlanTier, request: TodayPlanRequest,
        onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        switch tier {
        case .deterministic:
            // Instant and infallible — no timeout race needed.
            return try await DeterministicPlanGenerator().generate(request, onPartial: nil)
        case .onDevice:
            // Tee the streamed partials into a box so a deadline hit can SALVAGE the
            // last viable partial (a 90%-streamed briefing) instead of discarding it.
            let box = PartialBox<GeneratedPlan>()
            let forward = onPartial
            let session = advisorSession(for: request)
            return try await Self.race(timeout: Self.onDeviceTimeoutSeconds, salvage: box) {
                try await OnDevicePlanGenerator(session: session).generate(
                    request,
                    onPartial: { partial in
                        box.latest = partial
                        forward?(partial)
                    })
            }
        case .pcc:
            return try await Self.race(timeout: Self.pccTimeoutSeconds) {
                try await PCCPlanGenerator().generate(request, onPartial: onPartial)
            }
        }
    }

    /// The per-day advisor session: created on the day's first on-device generation,
    /// reused for every later turn (the recompose transcript), replaced on day change.
    /// Instructions freeze at creation — per-day is exactly their cadence (the
    /// throughput line changes daily), and a stable prefix is what the KV cache wants.
    private func advisorSession(for request: TodayPlanRequest) -> AdvisorSession {
        let dayKey = TodayPlanStore.dayKey(for: request.now)
        if let session = advisorSession, session.dayKey == dayKey { return session }
        let session = AdvisorSession(
            dayKey: dayKey, instructions: TodayPlanInstructions.text(for: request))
        advisorSession = session
        return session
    }

    /// The measured candidate budget, once the session has computed it (nil → the
    /// fixed cap). Read by the request builder so heavy days fill the real window.
    var advisorCandidateCap: Int {
        advisorSession?.measuredCandidateCap ?? TodayPlanRequest.candidateCap
    }

    /// Race a generation against a deadline; cancel the loser. When a `salvage` box is
    /// supplied and the deadline fires, a viable streamed partial (headline + ≥1 action)
    /// is returned instead of throwing — a partially-voiced briefing beats the voiceless
    /// fact-line fallback. Only a timeout with nothing viable throws `.timedOut`.
    private static func race(
        timeout seconds: Double, salvage box: PartialBox<GeneratedPlan>? = nil,
        _ operation: @escaping @Sendable () async throws -> GeneratedPlan
    ) async throws -> GeneratedPlan {
        // The race itself now lives in `ModelDeadline` so every model call in the app
        // shares one implementation. What stays here is the part that is genuinely
        // plan-specific: salvaging a viable streamed partial instead of throwing, and
        // re-typing the timeout as `PlanGenerationError.timedOut` — the tier chain falls
        // through on `throws`, and `errorLabel` maps that case to the "timedOut" string
        // the DEBUG footer reads. Both contracts must survive this refactor.
        do {
            return try await ModelDeadline.race(timeout: seconds, operation)
        } catch is ModelDeadline.Exceeded {
            if let box, let salvaged = await box.viablePartial() { return salvaged }
            throw PlanGenerationError.timedOut
        }
    }

    // MARK: Diagnostics helpers (typed error + availability labels)

    /// A short, stable label for a swallowed tier failure — each maps to a *different*
    /// fix (guardrail → prompt wording; context window → trim candidates; modelNotReady →
    /// wait/prewarm; timedOut → raise the deadline), so the label must distinguish them.
    static func errorLabel(_ error: Error) -> String {
        if let e = error as? PlanGenerationError {
            switch e {
            case .timedOut: return "timedOut"
            case .unavailable: return "unavailable"
            }
        }
        if let g = error as? LanguageModelSession.GenerationError {
            switch g {
            case .exceededContextWindowSize(_): return "exceededContextWindowSize"
            case .assetsUnavailable(_): return "assetsUnavailable"
            case .guardrailViolation(_): return "guardrailViolation"
            case .unsupportedGuide(_): return "unsupportedGuide"
            case .unsupportedLanguageOrLocale(_): return "unsupportedLanguageOrLocale"
            case .decodingFailure(_): return "decodingFailure"
            case .rateLimited(_): return "rateLimited"
            case .concurrentRequests(_): return "concurrentRequests"
            case .refusal(_, _): return "refusal"
            @unknown default: return "generationError"
            }
        }
        // iOS 27's model-level error vocabulary — a second surface the new session
        // APIs can throw from. Losing the case to a bare type name would blunt the
        // one diagnostic the footer exists to sharpen.
        if let m = error as? LanguageModelError {
            switch m {
            case .contextSizeExceeded(_): return "contextSizeExceeded"
            case .rateLimited(_): return "rateLimited"
            case .guardrailViolation(_): return "guardrailViolation"
            case .refusal(_): return "refusal"
            case .unsupportedCapability(_): return "unsupportedCapability"
            case .unsupportedTranscriptContent(_): return "unsupportedTranscriptContent"
            @unknown default: return "languageModelError"
            }
        }
        return String(describing: type(of: error))
    }

    /// The current on-device model availability, as a short label for the footer.
    static func availabilityLabel() -> String {
        if AppBrain.isRunningUnderXCTest { return "test" }
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "deviceNotEligible"
            case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
            case .modelNotReady: return "modelNotReady"
            @unknown default: return "unavailable"
            }
        @unknown default: return "unknown"
        }
    }

    // MARK: Prewarm

    /// Warm the on-device model while the Recap cover plays, so the first real
    /// generation isn't paying the cold model-load cost against the deadline. A no-op
    /// off-device / under tests. Fire-and-forget; the shared model load benefits the
    /// per-call session that runs moments later.
    static func prewarmTodayModel() { ModelWarmup.prewarmSharedSession() }

    /// Whether the on-device advisor is available right now (for the self-heal upgrade).
    static func todayAdvisorAvailable() -> Bool { onDeviceModelAvailable() }

    // MARK: Availability

    /// The shared on-device-model gate — the one predicate every on-device feature routes
    /// through (Today advisor, prewarm, decision framing, work-intent classification), so a
    /// change to the availability check happens in exactly one place.
    static func onDeviceModelAvailable() -> Bool { onDeviceAvailable() }

    private static func onDeviceAvailable() -> Bool {
        // Never probe Foundation Models under XCTest (the sim has no on-device model
        // and the probe can fault the beta sim's intelligence daemon under a heavy run).
        guard !AppBrain.isRunningUnderXCTest else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// PCC availability, read defensively. The entitlement gate comes FIRST: without
    /// it, even constructing `PrivateCloudComputeLanguageModel` to ask `.isAvailable`
    /// traps the process, so this must short-circuit to false and never touch it.
    private static func pccAvailable() -> Bool {
        guard PCCEntitlement.isGranted else { return false }
        return PrivateCloudComputeLanguageModel().isAvailable
    }

    // MARK: ChangeLog

    /// One `.ai` entry per generation, kept as a record and deliberately NOT reversible
    /// and NOT inbox-visible (`ChangeLogEntry.plannedAction`).
    ///
    /// It used to claim both. That badged the Inbox tab on first open, on every Replan,
    /// and on every self-heal upgrade — the app generating engagement signal from its
    /// own background work — and it rendered an Undo button with nothing behind it:
    /// there is no `"planned"` arm in `ChangeLogUndo`, and the entry carries no
    /// `taskUUID` for `linkedTask` to resolve, so the tap struck the row through and
    /// stopped there. `Metrics.acceptanceRate` already excluded this verb for the same
    /// reason; the feed now agrees with the metric.
    private func logPlanned(_ plan: GeneratedPlan, in context: NSManagedObjectContext) {
        let source: String
        switch plan.tier {
        case .onDevice: source = "on-device"
        case .pcc: source = "private cloud"
        case .deterministic: source = "rules"
        }
        let count = plan.actions.count
        let entry = ChangeLogEntry(
            summary: "Planned \(count) action\(count == 1 ? "" : "s") for today (\(source))",
            detail: plan.headline,
            action: ChangeLogEntry.plannedAction,
            initiatedBy: .ai,
            isReversible: false,
            in: context)
        context.insert(entry)
        context.saveChanges()
    }
}
