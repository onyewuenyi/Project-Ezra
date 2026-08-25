//
//  SerialGate.swift
//  Project-Ezra
//
//  One-at-a-time execution for work that shares a resource which cannot be re-entered.
//
//  **Extracted because the inline version was wrong twice, and the second time shipped.**
//  `AppBrain.briefSession` caches one `LanguageModelSession` per day so a mid-day re-entry
//  can be a delta TURN rather than a fresh call — and Foundation Models rejects a second
//  concurrent `respond` on a session outright ("This is a programmer error"). Two
//  overlapping Brief generations therefore killed the on-device tier and silently served
//  the deterministic tail.
//
//  The first fix stored a gate task that only awaited its PREDECESSOR. Every gate
//  completed the instant it was created, both callers sailed into generation together,
//  and the unit test still passed because both calls returned plans — an assertion about
//  outputs cannot see an overlap. It took a device run to notice the error was still
//  being printed.
//
//  So the rule this type exists to enforce, in the one place it can be tested with
//  controllable timing: **the stored task must wrap the WORK, not the wait.**
//
//  Queueing rather than refusing is deliberate. A second caller usually has a genuinely
//  different request (a delta turn against a changed day), so it wants its own answer —
//  just not at the same time as the first.
//

import Foundation

@MainActor
final class SerialGate {

    /// The tail of the chain: completes only when the work it wraps has finished.
    private var tail: Task<Void, Never>?

    /// How many bodies are executing right now. Always 0 or 1 — the invariant this type
    /// exists for, exposed so a test can assert it rather than infer it from outputs.
    private(set) var active = 0

    /// The high-water mark of `active` across this gate's life. A correct gate never
    /// exceeds 1; the broken implementation reached 2 while every return value still
    /// looked right.
    private(set) var peakActive = 0

    /// Run `work` after everything already queued, and return its result.
    func run<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor [weak self] () -> T in
            if let previous { await previous.value }
            self?.enter()
            let value = await work()
            self?.leave()
            return value
        }
        // The tail wraps the TASK, so the next caller waits for this body to finish —
        // not merely for this caller to have started waiting.
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    private func enter() {
        active += 1
        peakActive = max(peakActive, active)
    }

    private func leave() {
        active -= 1
    }
}
