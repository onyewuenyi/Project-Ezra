//
//  TodayPlanService.swift
//  Project-Ezra
//
//  The generation side of the Brief's advisor briefing: tier routing, the two model
//  generators (on-device + the cloud rung), the advisor instructions, and the
//  `AppBrain.todayPlan` seam that walks the tier chain and can never fail (the
//  deterministic tail always succeeds).
//
//  The model is now the advisor — it selects, orders, sizes, and reasons. Routing is
//  an ordered chain, and the Brief's order is the product's ONE deliberate inversion:
//  **strongest tier first** (cloud → on-device → deterministic), because volume here is
//  capped at ~1/day by construction and the voice IS the feature. The
//  capacity/divergence inputs are gone with the capacity input.
//
//  **What the inversion costs, stated plainly.** The on-device tier is a SESSION
//  (`BriefSession`: per-day profile, bounded transcript, two read-only tools, mid-day
//  re-entry as a delta turn); the cloud tier is a stateless per-call generator. So a
//  cloud-led day gets no live transcript and no tool calls — and that is survivable
//  rather than fine, because continuity was never allowed to depend on the session
//  being alive: `TodayPlanPrompt.body` carries the "SINCE THIS MORNING: …" digest, which
//  is the same mechanism a process restart has always used to reconstruct the day. The
//  tools are the real loss, and the tripwire is explicit — if cloud-led briefings turn
//  out to be measurably worse for want of `task_details`/`yesterday_outcome`, the answer
//  is a tooled cloud session, not a return to on-device-first.
//
//  This file names no cloud PROVIDER. Rung 3 arrives through `CloudModelProvider`, so
//  the day the slot holds Gemini instead of PCC nothing here changes.
//
//  ⚠️ Device-verify only: the streamed `@Generable` briefing, cloud fallthrough, and
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

// MARK: - Routing (pure, ordered)

/// The per-call tier chain. `.deterministic` is always the tail, so the chain can
/// never be empty and generation can never fail.
///
/// **The Brief prefers the STRONGEST tier, not the cheapest — and it is the only
/// workload in the product that does.** Everywhere else the ladder is climbed as
/// rarely as possible, because volume is unbounded and the cheap rungs are genuinely
/// good enough most of the time. The Brief is the exception on both counts: its volume
/// is capped at roughly one generation a day by construction (plays-once, plus a delta
/// re-entry that recomposes rather than regenerates), and its VOICE — the headline, the
/// tradeoff, the risk it names — is not a nice-to-have on top of the feature, it *is*
/// the feature. A deterministic Brief is a ranked list wearing a headline, and the
/// surface says so out loud rather than pretending otherwise.
///
/// The on-device tier stays in the chain, one rung down, and it matters more than it
/// looks: it is what a user with no connection, no entitlement, or a spent budget
/// actually gets, and it is still a voiced briefing.
///
/// The parameter is `cloudAvailable`, not `pccAvailable`: which provider occupies the
/// slot is `CloudModel`'s business and nothing this function should be able to name.
enum PlanRouting {
    static func decide(
        onDeviceAvailable: Bool, cloudAvailable: Bool, budgetAllows: Bool = true
    ) -> [PlanTier] {
        var chain: [PlanTier] = []
        // The daily cap applies here too. One Brief a day cannot plausibly exhaust it,
        // which is exactly why this line is cheap insurance rather than a constraint:
        // if the cap is ever hit, the day's most valuable single generation should not
        // be the one that jumps the queue past a runaway elsewhere.
        if cloudAvailable && budgetAllows { chain.append(.cloud) }
        if onDeviceAvailable { chain.append(.onDevice) }
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
    ///
    /// **Read by the on-device profile only** (`BriefSession`). It is deliberately NOT
    /// passed as per-call `GenerationOptions` any more — see `generate` below.
    static let responseTokenCap = 600

    /// The cap is set by the SESSION'S PROFILE, never per call.
    ///
    /// **The bug this fixes, which only a device run could show.** Both rungs used to
    /// receive `GenerationOptions(maximumResponseTokens: 600)` here, and a per-call
    /// option overrides whatever the profile configured. On the cloud rung that ceiling
    /// is shared with Gemini's thinking tokens, so every briefing stopped at ~586 output
    /// tokens having spent ~572 of them thinking and 14 answering: `finishReason
    /// MAX_TOKENS`, no briefing, silent fall-through to the deterministic tail. Measured
    /// twice, months apart in prompt size, at the same ceiling — which is what gave it
    /// away, since a config-driven limit would have moved.
    ///
    /// Fixing `CapabilityProfiles.briefPlan` alone did nothing, because this line won.
    /// A second capability-blind cap beside a capability-aware one is not redundancy; it
    /// is the capability-aware one being unreachable. Both rungs already state the cap in
    /// their own profile — `BriefSession` uses `responseTokenCap` above, and the cloud
    /// rung gets `briefPlan` plus thinking headroom — so the per-call option was pure
    /// override.
    static func generate(
        session: LanguageModelSession,
        request: TodayPlanRequest,
        tier: PlanTier,
        onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        let prompt = TodayPlanPrompt.body(for: request)
        guard let onPartial else {
            let final = try await session.respond(
                to: prompt, generating: AdvisorBriefing.self
            ).content
            return plan(from: final, tier: tier).validated(against: request)
        }
        let stream = session.streamResponse(
            to: prompt, generating: AdvisorBriefing.self)
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

/// The on-device tier: the per-day `BriefSession` (profile-backed, tooled,
/// transcript-carrying), streamed. The session is the whole point — see
/// `BriefSession.swift`'s header.
struct OnDevicePlanGenerator: TodayPlanGenerator {
    let tier: PlanTier = .onDevice
    let session: BriefSession

    func generate(
        _ request: TodayPlanRequest, onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        try await session.respond(request: request, onPartial: onPartial)
    }
}

/// The cloud tier (Rung 3), whoever is currently in the provider slot. Any error —
/// including an ungranted entitlement or an unconfigured provider — reads as
/// unavailability, so the router falls through to on-device/deterministic.
///
/// It names no provider. That is the point of `CloudModelProvider`: the day the slot
/// holds Gemini instead of PCC, this struct does not change, and neither does
/// `TodayPlanSession.generate` below it.
struct CloudPlanGenerator: TodayPlanGenerator {
    let tier: PlanTier = .cloud

    func generate(
        _ request: TodayPlanRequest, onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        let session = try CloudModel.provider.session(
            instructions: TodayPlanInstructions.text(for: request),
            config: CapabilityProfiles.briefPlan)
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
    /// SERIALIZED, because the on-device tier's session is shared for the whole day.
    ///
    /// `briefSession(for:)` caches one `BriefSession` per `dayKey` — deliberately, so the
    /// advisor keeps a transcript and a delta re-entry can be a turn rather than a fresh
    /// call. The consequence is that two overlapping generations reach the SAME
    /// `LanguageModelSession`, and Foundation Models rejects that outright: *"You
    /// attempted to call a respond method a second time before the first call completed.
    /// This is a programmer error."* The whole on-device tier then throws and the Brief
    /// serves its deterministic tail — the familiar silent degrade, caused by us.
    ///
    /// Overlap is reachable without anyone doing anything strange: the self-heal
    /// regenerates in the BACKGROUND while a cached briefing stays on screen, and a
    /// mid-day delta recompose can land on top. Waiting rather than bailing is the right
    /// resolution — the second caller usually has a genuinely different request (a delta
    /// turn), so it wants its own answer, just not concurrently.
    ///
    /// **The chain must wrap the WORK, not the wait.** The first attempt at this stored a
    /// gate task that only awaited its predecessor, so every gate completed the instant it
    /// was created and both callers sailed into generation together — the fix built, shipped
    /// to device, and changed nothing, which the diagnostics seam caught by still printing
    /// the programmer error. The stored task now IS the generation.
    func todayPlan(
        for request: TodayPlanRequest,
        in context: NSManagedObjectContext,
        onPartial: (@MainActor (GeneratedPlan) -> Void)? = nil
    ) async -> GeneratedPlan {
        await planGate.run { [self] in
            await generatePlan(for: request, in: context, onPartial: onPartial)
        }
    }

    private func generatePlan(
        for request: TodayPlanRequest,
        in context: NSManagedObjectContext,
        onPartial: (@MainActor (GeneratedPlan) -> Void)? = nil
    ) async -> GeneratedPlan {
        let chain = PlanRouting.decide(
            onDeviceAvailable: Self.onDeviceAvailable(), cloudAvailable: Self.cloudAvailable(),
            budgetAllows: CloudBudget.allows())

        let availability = Self.availabilityLabel()
        let start = Date()
        for tier in chain {
            do {
                let generated = try await run(tier: tier, request: request, onPartial: onPartial)
                let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                // The rung is recorded on the tier that actually PRODUCED the plan, not
                // on every tier attempted: a cloud call that was tried and threw cost
                // nothing, and counting it would inflate the one number the daily cap
                // reads. Failures are already named by `recordFailure` below.
                IntelligenceLedger.shared.record(tier.rung, for: .brief)
                planMetrics.recordGeneration(
                    tier: tier, latencyMs: latencyMs, promptTokens: -1, outputTokens: -1,
                    toolCalls: tier == .onDevice ? briefSession?.box.toolCalls ?? 0 : 0,
                    turn: tier == .onDevice ? briefSession?.turn ?? 0 : 0)
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
    /// The cloud rung's deadline. Deliberately its own number rather than the
    /// on-device one: a network round trip has a different failure shape than a cold
    /// local model, and the two must be tunable against separate evidence.
    private static let cloudTimeoutSeconds: Double = 20

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
            let session = briefSession(for: request)
            return try await Self.race(timeout: Self.onDeviceTimeoutSeconds, salvage: box) {
                try await OnDevicePlanGenerator(session: session).generate(
                    request,
                    onPartial: { partial in
                        box.latest = partial
                        forward?(partial)
                    })
            }
        case .cloud:
            return try await Self.race(timeout: Self.cloudTimeoutSeconds) {
                try await CloudPlanGenerator().generate(request, onPartial: onPartial)
            }
        }
    }

    /// The per-day advisor session: created on the day's first on-device generation,
    /// reused for every later turn (the recompose transcript), replaced on day change.
    /// Instructions freeze at creation — per-day is exactly their cadence (the
    /// throughput line changes daily), and a stable prefix is what the KV cache wants.
    private func briefSession(for request: TodayPlanRequest) -> BriefSession {
        let dayKey = TodayPlanStore.dayKey(for: request.now)
        if let session = briefSession, session.dayKey == dayKey { return session }
        let session = BriefSession(
            dayKey: dayKey, instructions: TodayPlanInstructions.text(for: request))
        briefSession = session
        return session
    }

    /// The measured candidate budget, once the session has computed it (nil → the
    /// fixed cap). Read by the request builder so heavy days fill the real window.
    var advisorCandidateCap: Int {
        briefSession?.measuredCandidateCap ?? TodayPlanRequest.candidateCap
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
        // An error from NEITHER public vocabulary. The bare type name was all this used
        // to report, which is how `[TodayPlan] tier onDevice failed: GenerativeError`
        // stood in the log as an unactionable fact: `GenerativeError` is not in the public
        // SDK at all — a private type leaking through the API — so there is no case to
        // switch on and the name alone says nothing about what went wrong.
        //
        // Carry the description too. It is the only channel an unmapped error has, and a
        // diagnostic that names a failure without describing it costs a device round-trip
        // per guess (the `unsupportedCapability` hunt is the worked example).
        let name = String(describing: type(of: error))
        let detail = String(describing: error)
        return detail.isEmpty || detail == name ? name : "\(name): \(detail)"
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

    /// Cloud-rung availability — the installed provider's, whoever that is. The
    /// defensive ordering that used to live here (entitlement gate before touching the
    /// model, because constructing PCC unentitled traps the process) is now a
    /// documented requirement of `CloudModelProvider.isAvailable`, where it applies to
    /// every future provider rather than only this one.
    /// REACHABILITY, not configuration. A configured-but-failing provider used to keep
    /// the cloud tier at the head of the chain all day, so every Brief paid a doomed
    /// call before falling through to the on-device voice it was going to use anyway.
    private static func cloudAvailable() -> Bool { CloudModel.isReachable }

    // MARK: ChangeLog

    /// One `.ai` entry per generation, kept as a record and deliberately NOT reversible
    /// and NOT inbox-visible (`ChangeLogEntry.plannedAction`).
    ///
    /// It used to claim both. That badged the Activity screen on first open, on every Replan,
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
        case .cloud: source = "private cloud"
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
