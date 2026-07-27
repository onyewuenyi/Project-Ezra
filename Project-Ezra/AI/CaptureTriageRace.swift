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

enum CaptureTriageRace {

    /// Race a streaming triage against `deadline`, teeing every partial into a
    /// salvage box. Always hands the engine a partial handler — even when the
    /// caller passed none — because salvage only works if partials flow.
    static func run(
        deadline: Double,
        onPartial: (@MainActor ([TaskIntent]) -> Void)?,
        operation:
            @escaping @MainActor (_ tee: @escaping @MainActor ([TaskIntent]) -> Void)
            async throws -> [TaskIntent]
    ) async -> CaptureTriageOutcome {
        let box = PartialBox<[TaskIntent]>()
        let tee: @MainActor ([TaskIntent]) -> Void = { intents in
            if !intents.isEmpty { box.latest = intents }
            onPartial?(intents)
        }
        do {
            let value = try await ModelDeadline.race(timeout: deadline) {
                try await operation(tee)
            }
            return .finished(value)
        } catch is ModelDeadline.Exceeded {
            if let salvaged = box.latest, !salvaged.isEmpty { return .salvaged(salvaged) }
            return .timedOutEmpty
        } catch is CancellationError {
            return .cancelled
        } catch {
            // A cancelled generation can surface as the engine's own error type;
            // the enclosing task's state is the honest signal either way.
            if Task.isCancelled { return .cancelled }
            return .failed(error)
        }
    }
}
