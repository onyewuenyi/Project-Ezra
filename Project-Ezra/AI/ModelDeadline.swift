//
//  ModelDeadline.swift
//  Project-Ezra
//
//  A wall-clock deadline for any async operation.
//
//  Every Foundation Models call needs one. Without it a cold or wedged model leaves the
//  caller waiting forever — which, on a detail card, means a spinner the user cannot get
//  out of except by leaving the page. `TodayPlanService` learned this first and grew a
//  private, `GeneratedPlan`-shaped version of this function; this is that logic
//  generalized so the plan service is one caller among several rather than the only one
//  with the lesson baked in.
//
//  Deliberately just the race. Availability, error mapping, and metrics live in
//  `ModelRun`, so this stays a pure concurrency primitive that is trivial to test.
//

import Foundation

/// Holds the latest streamed partial so a deadline hit can SALVAGE it instead of
/// discarding work the user was already watching. Grew up in `TodayPlanService`
/// (plan-shaped); generalized here because capture streams too. MainActor because
/// every `onPartial` in the app is MainActor; timeout-side readers cross via `await`.
@MainActor
final class PartialBox<Value> {
    var latest: Value?
}

enum ModelDeadline {

    /// A user-facing detail card: the person tapped a button and is watching a spinner,
    /// so the deadline has to be short enough to respect that — but long enough to
    /// absorb a cold model load, which dominates the first call of a session.
    static let cardSeconds: Double = 20

    /// Background inference nobody is waiting on (re-classification after an edit).
    /// Shorter, because its output is a single word and nothing on screen is blocked.
    static let backgroundSeconds: Double = 10

    /// The composer's live parse. Longer than `cardSeconds` because the workload is
    /// categorically different: a card generates ONE short answer, while a capture
    /// generates a whole structured set whose size scales with how much the user
    /// dumped — and "dump it all" is the product's entire pitch.
    ///
    /// Measured on device with `-CaptureDiagnostics`, twice, on one 648-character
    /// ramble (thirteen items — an ordinary Sunday-night brain dump):
    ///
    ///     20s deadline →  5 drafts ·  4 owners · 0 dated · deadline hit
    ///     30s deadline → 11 drafts · 11 owners · 3 dated · deadline hit (30.15s)
    ///
    /// **Neither run finished.** The generation scales with how much was dumped, and
    /// "dump it all" makes the input unbounded — so no constant here ever guarantees a
    /// complete parse, and raising it further just trades the user's time for more
    /// candidates. That reframes what this number is: NOT a failure threshold, but the
    /// point where we stop waiting for MORE. Salvage means a hit costs completeness,
    /// never the capture — and because the user watches candidates stream in and can
    /// confirm at any moment, they are never actually blocked by it.
    ///
    /// So 30s is chosen as "long enough that a big dump parses substantially, short
    /// enough that the thinking indicator doesn't run forever", and a deadline hit on a
    /// long ramble is the EXPECTED path, recorded as `.salvaged` rather than a failure.
    /// If long captures need to be genuinely complete, the answer is chunking the input
    /// — not a bigger number here.
    static let captureSeconds: Double = 30

    /// The deadline fired. Distinct from the operation's own errors so a caller can tell
    /// "the model refused" from "the model never answered" — different fixes.
    struct Exceeded: Error {}

    /// Race `operation` against a deadline and cancel the loser.
    ///
    /// Three outcomes, and the distinction between them is the point:
    /// - the operation finishes first → its value, timer cancelled
    /// - the deadline fires first → `Exceeded`, operation cancelled
    /// - the operation THROWS first → **its own error**, never `Exceeded`
    ///
    /// Cancelling the enclosing task propagates: `Task.sleep` throws `CancellationError`,
    /// which surfaces here rather than being mistaken for a timeout.
    ///
    /// Cancellation is cooperative — `cancelAll()` cannot force a wedged `respond` call
    /// to return. It stops *us* waiting on it, which is what the UI needs.
    static func race<T: Sendable>(
        timeout seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Exceeded()
            }
            guard let result = try await group.next() else { throw Exceeded() }
            group.cancelAll()
            return result
        }
    }
}
