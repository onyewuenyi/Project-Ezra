//
//  CloudHealth.swift
//  Project-Ezra
//
//  **Configuration presence is not reachability**, and until this existed the capture
//  path could not tell the difference.
//
//  `CloudModelProvider.isAvailable` answers *may we touch this rung at all* from
//  something cheap and local — for Gemini, `FirebaseApp.app() != nil`. That rule is
//  right and stays (see the protocol's warning: an availability check that costs a round
//  trip makes every routing decision wait on the network). But it means a provider that
//  is configured and *failing every call* — an exhausted quota, a revoked key, a dead
//  network — reports `true` forever. So every capture re-issued a call it had no chance
//  of completing, and then paid `ModelDeadline.captureHedgeSeconds` waiting for the free
//  arm behind it. The cost of a known-down provider was being paid once per capture, on
//  the product's most latency-sensitive surface, indefinitely.
//
//  This is the health half. `isAvailable` says we *can ask*; `CloudModel.isReachable`
//  says we *should*.
//
//  **Why this is not the thing `CaptureRoute` refuses to consult.** Capture deliberately
//  does not ask `CloudBudget` — "a spend counter may not override an accuracy decision on
//  the product's front door", because that question is *should we spend a call?* and the
//  front door's objective is intent preservation with cost strictly tertiary. This asks a
//  different question: *is there anything at the other end?* A breaker never trades
//  accuracy for money — when it is open the cloud call would have failed anyway, so what
//  it saves is dead time, and the arm that answers is the one that was going to answer
//  regardless. Keep that distinction if this file ever grows a threshold that smells like
//  a ration.
//
//  **Three failure kinds, because they are three different facts.** Collapsing them was
//  the tempting shortcut and would have been wrong in both directions:
//
//  - `.refused` — the service told us to stop asking (`rateLimited`, quota, resource
//    exhausted). **One is enough.** A 429 is not a coin flip; re-asking immediately is
//    the one thing the response explicitly says not to do.
//  - `.transient` — the request did not get there (transport, offline, an unmapped
//    error). Needs corroboration, because a single blip must not disable the better
//    parser for a minute.
//  - `.contentual` — the service ANSWERED and the answer was unusable for content
//    reasons (a guardrail refusal, a decode failure, an unsupported guide). This is
//    **evidence of health**, not against it: bytes made the round trip. It resets the
//    breaker exactly like a success, and tripping on it would have disabled the cloud
//    rung over a prompt-wording problem the next capture would not have hit.
//
//  Classification reads `AppBrain.errorLabel`'s string rather than re-switching over
//  error types, honouring `ModelResult`'s rule that it is "the single mapping, not a
//  second taxonomy". That is also the more robust choice here: the label's fallback arm
//  carries `type: description` for errors in neither public vocabulary, which is exactly
//  where a private Firebase quota error lands — so a substring test sees "resource
//  exhausted" where a `switch` would see an opaque type it cannot name.
//
//  Local only, in-memory only, never transmitted, and deliberately NOT persisted: a
//  breaker that survives a relaunch would let one bad afternoon decide tomorrow morning's
//  routing, and the recovery probe is cheap enough that a cold start should just try.
//
//  **Capture is the only WRITER; everything reads.** `TodayPlanService` and
//  `TaskAdvisorStore` consult `CloudModel.isReachable` and skip a doomed tier for free,
//  but they do not report failures into it, and that asymmetry is deliberate rather than
//  unfinished. Capture's cloud failures are overwhelmingly transport and quota — the
//  things a breaker should react to — while the Brief's have historically been
//  *capability and token-budget* problems (the `.deep` reasoning level the on-device rung
//  could not serve; `maxOutputTokens` swallowed by Gemini's thinking tokens). Feeding
//  those in would let an oversized Brief prompt disable the cloud rung for capture, which
//  is the wrong rung being punished for the wrong reason. Capture is also the
//  highest-volume cloud workload, so it reaches a verdict first and the other two inherit
//  it without ever paying for one.
//

import Foundation

/// The cloud rung's recent behaviour, as a circuit breaker.
@MainActor
final class CloudHealth {
    static let shared = CloudHealth()

    /// What a failure says about whether the rung is reachable. See the file header —
    /// the three cases move the breaker in three different ways, and `.contentual`
    /// moving it *toward closed* is the one that looks wrong and is not.
    enum FailureKind: Equatable {
        case refused
        case transient
        case contentual
    }

    /// Consecutive transient failures needed to open. Deliberately more than one: the
    /// cloud arm is the better parser and a single blip must not cost a minute of it.
    static let transientThreshold = 2

    /// The first cooldown. Sized against how quota windows actually reset (per-minute
    /// buckets are the common case) rather than against how long an outage feels.
    static let baseCooldownSeconds: TimeInterval = 60

    /// The ceiling on backoff. A daily quota is the case this exists for: without
    /// backoff we would probe — and make one capture pay for it — every 60s for hours;
    /// without a ceiling a long outage would push recovery past the session.
    static let maxCooldownSeconds: TimeInterval = 600

    private(set) var consecutiveFailures = 0
    /// When the breaker may next be probed. Nil means closed.
    private(set) var openUntil: Date?
    /// How many times it has opened without an intervening success — the backoff
    /// exponent. Reset by any evidence of health.
    private(set) var consecutiveOpenings = 0
    /// The last label that moved the breaker, for the DEBUG line. A breaker that says
    /// it is open without saying why is a mystery, not a diagnostic.
    private(set) var lastFailureLabel: String?

    // MARK: - Reading

    /// Whether the cloud rung should be asked right now.
    ///
    /// Half-open is deliberately indistinguishable from closed to the caller: once the
    /// cooldown has elapsed we really do want the call attempted, and a caller that had
    /// to handle "probably closed" would grow a second policy. The probe's *cost* is
    /// what differs, and that is `isProbing`'s job.
    func isClosed(now: Date = Date()) -> Bool {
        guard let openUntil else { return true }
        return now >= openUntil
    }

    /// True when the next call is a RECOVERY PROBE — the breaker opened, its cooldown
    /// elapsed, and nothing has proved the rung healthy since.
    ///
    /// The capture path reads this to drop the hedge delay to zero. Making someone wait
    /// `captureHedgeSeconds` behind a call we already believe will fail is the exact dead
    /// time this file exists to remove; if the probe succeeds nothing was lost but a
    /// little battery, and if it fails the free arm was already running.
    func isProbing(now: Date = Date()) -> Bool {
        guard let openUntil else { return false }
        return now >= openUntil
    }

    // MARK: - Writing

    /// The rung answered. Any answer at all — including an empty parse — is proof the
    /// round trip works, which is the only thing this type tracks.
    func recordSuccess() {
        reset()
    }

    /// The rung threw. Returns the classification, so a caller that wants to log or
    /// meter the decision does not have to re-derive it.
    @discardableResult
    func recordFailure(_ error: Error, now: Date = Date()) -> FailureKind {
        let label = AppBrain.errorLabel(error)
        let kind = Self.kind(ofLabel: label)
        lastFailureLabel = label
        switch kind {
        case .contentual:
            // Bytes made the round trip. The rung is reachable and the problem is the
            // prompt — treat it as health, or a wording bug disables the better parser.
            reset()
        case .refused:
            open(now: now)
        case .transient:
            consecutiveFailures += 1
            if consecutiveFailures >= Self.transientThreshold { open(now: now) }
        }
        return kind
    }

    /// Drop all state. Exposed for tests and for a deliberate manual retry; nothing in
    /// the app calls it on a timer.
    func reset() {
        consecutiveFailures = 0
        openUntil = nil
        consecutiveOpenings = 0
        lastFailureLabel = nil
    }

    private func open(now: Date) {
        let cooldown = min(
            Self.maxCooldownSeconds,
            Self.baseCooldownSeconds * pow(2, Double(consecutiveOpenings)))
        consecutiveOpenings += 1
        consecutiveFailures = 0
        openUntil = now.addingTimeInterval(cooldown)
        #if DEBUG
        // Same reasoning as `CloudBudget.allows`: silence is the right PRODUCT behaviour
        // (a user told the AI is rationed gains an anxiety and loses nothing else) and
        // the wrong DEVELOPMENT behaviour — an eval that silently stops exercising the
        // rung it is evaluating reports the breaker's opinion as the model's.
        print(
            "⚠️ cloud breaker OPEN for \(Int(cooldown))s after \(lastFailureLabel ?? "?") "
                + "— capture degrades to the on-device arm.")
        #endif
    }

    // MARK: - Classification

    /// Which kind of failure a label describes. Substring matching on
    /// `AppBrain.errorLabel`'s output — see the file header for why that beats a second
    /// `switch` over error types here.
    static func kind(ofLabel label: String) -> FailureKind {
        // Matched on a SEPARATOR-FREE form, which is the difference between this working
        // and it silently not. The same concept arrives spelled three ways depending on
        // which layer surfaced it — `rateLimited` (Apple's enum), `RESOURCE_EXHAUSTED`
        // (the gRPC status, and how a Firebase quota error actually lands), `rate limit`
        // (prose in an unmapped error's description) — so a list of literal spellings is
        // a list that is one spelling short on the day it matters. The first version of
        // this had `resourceexhausted` and `resource exhausted` and missed the underscore
        // form, i.e. missed the exact error the whole file exists for.
        let l = label.lowercased().filter { !" _-.".contains($0) }
        // The service answered and said "not now".
        if l.contains("ratelimit") || l.contains("resourceexhausted") || l.contains("quota")
            || l.contains("toomanyrequests") || l.contains("429")
        {
            return .refused
        }
        // The service answered and the answer was unusable. Reachability is fine.
        if l.contains("guardrail") || l.contains("refusal") || l.contains("decoding")
            || l.contains("unsupported") || l.contains("contextsize")
            || l.contains("exceededcontext")
        {
            return .contentual
        }
        return .transient
    }

    // MARK: - Diagnostics

    /// The DEBUG line. Like `CloudBudget.statusLine`, the reading we WANT is the boring
    /// one — a breaker that never opens is a provider that never fails.
    func statusLine(now: Date = Date()) -> String {
        guard let openUntil else {
            return consecutiveFailures == 0
                ? "cloud health: ok"
                : "cloud health: ok · \(consecutiveFailures) transient"
        }
        let why = lastFailureLabel.map { " · \($0)" } ?? ""
        if now >= openUntil { return "cloud health: probing\(why)" }
        return "cloud health: open \(Int(openUntil.timeIntervalSince(now)))s\(why)"
    }
}
