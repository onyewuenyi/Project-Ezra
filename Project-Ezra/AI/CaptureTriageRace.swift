//
//  CaptureTriageRace.swift
//  Project-Ezra
//
//  The deadline for the composer's live parse — the one model call `ModelRun` cannot
//  own, and the last one that had no deadline at all.
//
//  Why not `ModelRun.perform`: its contract has no streaming seam, and its
//  `.unavailable` short-circuit is wrong here — capture must still run the heuristic
//  when the model is absent, not render an absence. Why not inside the engine: an
//  engine is only its prompt and its parsing. So the race lives at the call site's
//  seam, reusing `ModelDeadline.race` and the shared `PartialBox`, and honoring the
//  streaming contract the CLAUDE.md exclusion note was protecting: a deadline hit
//  SALVAGES the last streamed partial set — cards the user is already reading —
//  instead of discarding them for a heuristic wipe.
//
//  The debounce keeps its own job (cancelling superseded parses when the text moves);
//  this bounds the case the debounce structurally cannot: the user stopped typing and
//  is waiting on a model that neither yields nor throws.
//

import Foundation

/// The product-shaped outcomes of a raced triage. `cancelled` is deliberately
/// separate so the caller can skip metrics — a debounce supersession says nothing
/// about whether the deadline is well chosen (the same rule `ModelRun` applies).
enum CaptureTriageOutcome {
    case finished([TaskIntent])
    /// The deadline fired, but streamed partials had already produced intents —
    /// return those. Recorded as a timeout (that's the tuning evidence), shown as
    /// a result (that's the salvage).
    case salvaged([TaskIntent])
    case timedOutEmpty
    case cancelled
    case failed(Error)
}

/// Which arm of a hedged capture produced the interpretation.
enum CaptureArm: String, Equatable, Sendable {
    /// The route's own arm — the cloud model on an ambiguous ramble.
    case primary
    /// The free arm, started only because the primary was slow or came back empty.
    case hedge
}

/// A MainActor box for an arm's error, so the task group can stay `Sendable` without
/// carrying `any Error` across it.
@MainActor
private final class ArmFailure {
    var error: Error?
}

/// Lets the hedge skip the rest of its delay. Set the moment the primary is known to
/// have produced nothing — waiting out a timer to start the fallback for a network that
/// already failed is pure dead time on the product's most latency-sensitive surface.
@MainActor
private final class HedgeGate {
    var released = false
    var started = false
}

enum CaptureTriageRace {

    // MARK: - Hedging the free arm

    /// The result of a hedged capture: the outcome, and which arm earned it.
    struct HedgedResult {
        var outcome: CaptureTriageOutcome
        /// The arm whose work this is; nil when nothing was produced by either.
        var arm: CaptureArm?
        /// Whether the hedge arm actually issued a call. The caller needs this to record
        /// the rung it really used — a hedge that never woke up must not be counted.
        var hedgeStarted: Bool
    }

    /// Run the route's arm, and start the FREE arm alongside it once the paid one is
    /// slow — first usable answer wins, whole thing bounded by ONE budget.
    ///
    /// **What this replaces, and why it was the worst latency bug available here.** The
    /// chain used to be strictly serial: the cloud arm got the full capture deadline, and
    /// only when it came back empty did the on-device arm start — with a *fresh* full
    /// deadline of its own. So the documented promise that the deadline "measures the
    /// user's patience" was true per rung and false per capture: a dead network cost 30
    /// seconds of nothing, then up to 30 more, on the one surface where the product
    /// claims to be instant. Patience is spent once by the person; it must be budgeted
    /// once by the code.
    ///
    /// **Why hedge rather than merely shorten.** The two arms fail in uncorrelated ways —
    /// the cloud arm is the better parser and the one that can vanish with the network;
    /// the on-device arm is weaker on hard segmentation and cannot fail for network
    /// reasons. Racing them from t=0 would spend a paid call on every capture and hand
    /// most reveals to the weaker parser, which is the quality reversal undone. Starting
    /// the free arm only after the paid one is *late* keeps the cloud read as the normal
    /// outcome and cuts the tail, which is exactly where the pain was. The hedge costs
    /// battery, never money, so the cheap resource absorbs the variance of the expensive
    /// one.
    ///
    /// The hedge is released EARLY when the primary finishes with nothing: at that point
    /// its delay is protecting a call that already failed.
    ///
    /// Partials: only the primary tees to `onPartial`, so the two arms can never
    /// interleave into one stream and `firstPartialMs` keeps meaning one thing. Each arm
    /// salvages from its own box.
    static func hedged(
        budget: Double,
        hedgeAfter: Double,
        onPartial: (@MainActor ([TaskIntent]) -> Void)?,
        primary:
            @escaping @MainActor (_ tee: @escaping @MainActor ([TaskIntent]) -> Void)
            async throws -> [TaskIntent],
        hedge: (
            @MainActor (_ tee: @escaping @MainActor ([TaskIntent]) -> Void) async throws
                -> [TaskIntent]
        )? = nil
    ) async -> HedgedResult {
        let primaryBox = PartialBox<[TaskIntent]>()
        let hedgeBox = PartialBox<[TaskIntent]>()
        let failure = ArmFailure()
        let gate = HedgeGate()

        let primaryTee: @MainActor ([TaskIntent]) -> Void = { intents in
            if !intents.isEmpty { primaryBox.latest = intents }
            onPartial?(intents)
        }
        let hedgeTee: @MainActor ([TaskIntent]) -> Void = { intents in
            if !intents.isEmpty { hedgeBox.latest = intents }
        }

        enum Event: Sendable {
            case produced(CaptureArm, [TaskIntent])
            /// Finished or threw without anything usable. The distinction doesn't change
            /// what we do next — keep waiting on the other arm — so it isn't carried.
            case barren(CaptureArm)
            case cancelled
            case deadline
        }

        return await withTaskGroup(of: Event.self) { group in
            group.addTask { @MainActor in
                do {
                    let value = try await primary(primaryTee)
                    if value.isEmpty { gate.released = true }
                    return value.isEmpty ? .barren(.primary) : .produced(.primary, value)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    if Task.isCancelled { return .cancelled }
                    failure.error = error
                    gate.released = true
                    return .barren(.primary)
                }
            }

            if let hedge {
                group.addTask { @MainActor in
                    // Slice the delay so an early release is honoured immediately. A
                    // continuation would be tidier and is not worth the plumbing: the
                    // whole wait is a couple of seconds and the slices are idle.
                    let slice = 0.05
                    var waited = 0.0
                    while !gate.released && waited < hedgeAfter {
                        do { try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000)) } catch {
                            return .cancelled
                        }
                        waited += slice
                    }
                    guard !Task.isCancelled else { return .cancelled }
                    gate.started = true
                    do {
                        let value = try await hedge(hedgeTee)
                        return value.isEmpty ? .barren(.hedge) : .produced(.hedge, value)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        if Task.isCancelled { return .cancelled }
                        if failure.error == nil { failure.error = error }
                        return .barren(.hedge)
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                // `try?` swallows the cancellation, so without this check a cancelled
                // capture reports `.deadline` — and it RACES the primary's honest
                // `.cancelled`, so the same user action lands as a timeout or a cancel
                // depending on scheduling. `.cancelled` exists precisely to stay out of
                // the timeout metrics (a supersession says nothing about whether the
                // deadline is well chosen), so a coin-flip between the two quietly
                // poisons the evidence `captureSeconds` is tuned on.
                return Task.isCancelled ? .cancelled : .deadline
            }

            /// Everything the arms managed to stream, preferring the primary — it is the
            /// better parser, and on a deadline hit "most complete" is not knowable while
            /// "better arm" is.
            @MainActor func salvage() -> HedgedResult {
                if let value = primaryBox.latest, !value.isEmpty {
                    return HedgedResult(
                        outcome: .salvaged(value), arm: .primary, hedgeStarted: gate.started)
                }
                if let value = hedgeBox.latest, !value.isEmpty {
                    return HedgedResult(
                        outcome: .salvaged(value), arm: .hedge, hedgeStarted: gate.started)
                }
                return HedgedResult(
                    outcome: .timedOutEmpty, arm: nil, hedgeStarted: gate.started)
            }

            var armsRemaining = hedge == nil ? 1 : 2
            while let event = await group.next() {
                switch event {
                case .produced(let arm, let intents):
                    group.cancelAll()
                    return HedgedResult(
                        outcome: .finished(intents), arm: arm, hedgeStarted: gate.started)
                case .cancelled:
                    group.cancelAll()
                    return HedgedResult(
                        outcome: .cancelled, arm: nil, hedgeStarted: gate.started)
                case .barren:
                    armsRemaining -= 1
                    // Both arms are done and neither produced. Salvage before declaring
                    // nothing — a failed arm may still have streamed real candidates.
                    if armsRemaining <= 0 {
                        group.cancelAll()
                        let salvaged = await salvage()
                        if case .timedOutEmpty = salvaged.outcome, let error = await failure.error {
                            return HedgedResult(
                                outcome: .failed(error), arm: nil,
                                hedgeStarted: salvaged.hedgeStarted)
                        }
                        return salvaged
                    }
                case .deadline:
                    group.cancelAll()
                    return await salvage()
                }
            }
            return await salvage()
        }
    }
}
