//
//  TaskAdvisorStore.swift
//  Project-Ezra
//
//  The Advisor's judgment cache and its one ambient trigger. Every task detail has an
//  Advisor; this store holds its current judgment — often silence — keyed by the FACTS
//  FINGERPRINT, so the invariant holds: same task + same meaningful context → same
//  Advisor state. Continuously understanding ≠ continuously generating: `ensure` runs
//  on every page activation and is a no-op unless a meaningful fact changed.
//
//  Evaluation and visibility are separate dimensions, shipped as one practical enum —
//  read the case comments; the semantics matter more than the shape:
//  `.dismissed` is NOT "no opinion" (the Advisor had one; the human chose not to
//  engage — valuable state), and `.fallback` is an execution path, not a judgment.
//
//  In-memory only, deliberately: the schema froze at generation 10, judgments
//  regenerate on relaunch, and the per-launch `Hasher` seed in the fingerprint is
//  harmless because nothing here outlives the launch.
//

import Combine
import Foundation
import SwiftUI

/// Who concluded silence. Both are judgments — never "no Advisor here": the gate is
/// the deterministic (zero-model-cost) evaluation path, `.model` is the model's own
/// honest "nothing useful to add".
enum QuietOrigin: Equatable, Sendable {
    case gate
    case model
}

enum AdvisorState: Equatable {
    /// The Advisor judged silence — see `QuietOrigin`. Renders nothing.
    case quiet(QuietOrigin)
    /// Evaluation in flight. The quiet visual treatment; never a spinner.
    case loading
    /// One coherent interpretation — immutable for this fingerprint (the reveal gate).
    case revealed(ValidatedReading)
    /// The Advisor HAD an opinion; the human chose not to engage. Bound to the
    /// fingerprint: it never resurfaces until the facts genuinely change.
    case dismissed
    /// No model on this device — the deterministic template content renders instead.
    /// An execution path, not a judgment.
    case fallback
    /// A real attempt that failed. Owes the user a retry when retryable.
    case failed(retryable: Bool)
}

/// A reading can be revealed ONCE per fingerprint — the structural encoding of
/// "a revealed reading is immutable until the facts change" (the `Interpretation`
/// lesson: three rule-based attempts leaked; a type that refuses can't). Retries,
/// pager transitions, `.onAppear` re-fires and model latency structurally cannot
/// churn the screen: the reading arrives as a single thought.
struct AdvisorRevealGate: Equatable {
    private(set) var revealed: ValidatedReading?
    private(set) var fingerprint: Int?

    /// True when the proposal was accepted (first reveal for this fingerprint).
    /// A repeat for the same fingerprint is refused; a NEW fingerprint is the only
    /// reopener.
    @discardableResult
    mutating func propose(_ reading: ValidatedReading, fingerprint: Int) -> Bool {
        if revealed != nil, self.fingerprint == fingerprint { return false }
        revealed = reading
        self.fingerprint = fingerprint
        return true
    }
}

@MainActor
final class TaskAdvisorStore: ObservableObject {

    static let shared = TaskAdvisorStore()

    struct Entry {
        var fingerprint: Int
        var state: AdvisorState
        var gate = AdvisorRevealGate()
        var work: Task<Void, Never>?
    }

    @Published private(set) var entries: [UUID: Entry] = [:]

    private let service: TaskAdvisorService
    private let metrics: AdvisorMetrics

    init(service: TaskAdvisorService = TaskAdvisorService(), metrics: AdvisorMetrics = .shared) {
        self.service = service
        self.metrics = metrics
    }

    func state(for task: TaskItem) -> AdvisorState {
        guard let id = task.uuid, let entry = entries[id] else { return .quiet(.gate) }
        return entry.state
    }

    /// The ambient trigger — called when a detail page becomes active. Recomputes the
    /// facts and their fingerprint; a settled entry for the same fingerprint is a
    /// no-op (the cache), and a changed fingerprint cancels stale work and re-judges.
    func ensure(task: TaskItem, among tasks: [TaskItem], now: Date = Date()) {
        guard let id = task.uuid else { return }
        let facts = TaskAdvisorFacts.make(task: task, among: tasks, now: now)
        let fingerprint = facts.fingerprint
        if let entry = entries[id], entry.fingerprint == fingerprint { return }
        entries[id]?.work?.cancel()

        guard TaskCapabilities.advisorWorthy(for: task, among: tasks, now: now) else {
            settle(id, fingerprint: fingerprint, state: .quiet(.gate))
            return
        }
        guard AppBrain.onDeviceModelAvailable() else {
            settle(id, fingerprint: fingerprint, state: .fallback)
            return
        }
        read(id: id, facts: facts, fingerprint: fingerprint, among: tasks)
    }

    /// The page stopped being the one on screen (the pager keeps neighbours mounted, so
    /// `.onDisappear` is not a signal). An in-flight judgment is spend with nobody
    /// waiting — cancel it and drop the entry so the next activation re-judges.
    func cancel(taskID: UUID?) {
        guard let id = taskID, let entry = entries[id] else { return }
        entry.work?.cancel()
        if case .loading = entry.state { entries[id] = nil }
    }

    /// Only meaningful from `.failed` — the retry the failure owes.
    func retry(task: TaskItem, among tasks: [TaskItem], now: Date = Date()) {
        guard let id = task.uuid else { return }
        guard case .failed = entries[id]?.state else { return }
        entries[id] = nil
        ensure(task: task, among: tasks, now: now)
    }

    /// Collapse the reading for the CURRENT fingerprint. It never resurfaces until the
    /// facts genuinely change — and the dismissal is counted: repeated dismissals are a
    /// judgment-quality signal, not an engagement problem.
    func dismiss(taskID: UUID?) {
        guard let id = taskID, let entry = entries[id] else { return }
        guard case .revealed(let reading) = entry.state else { return }
        metrics.recordDismissed(reading.move)
        entries[id]?.state = .dismissed
    }

    // MARK: - Internals

    private func settle(_ id: UUID, fingerprint: Int, state: AdvisorState) {
        let previousGate = entries[id]?.gate ?? AdvisorRevealGate()
        entries[id] = Entry(fingerprint: fingerprint, state: state, gate: previousGate)
        // Silence is a first-class outcome — the honesty denominator. Recorded here,
        // once per fingerprint (the `ensure` no-op dedupes re-visits).
        if case .quiet = state { metrics.recordOffered(.nothing) }
    }

    private func read(id: UUID, facts: TaskAdvisorFacts, fingerprint: Int, among tasks: [TaskItem]) {
        var entry = Entry(
            fingerprint: fingerprint, state: .loading,
            gate: entries[id]?.gate ?? AdvisorRevealGate())
        let work = Task { [service] in
            var enriched = facts
            enriched.relatedLines = await TaskAdvisorService.relatedLines(
                for: facts, among: tasks)
            let outcome = await service.read(enriched)
            guard !Task.isCancelled else { return }
            self.apply(outcome, id: id, fingerprint: fingerprint)
        }
        entry.work = work
        entries[id] = entry
    }

    private func apply(_ outcome: ModelResult<ValidatedReading>, id: UUID, fingerprint: Int) {
        guard var entry = entries[id], entry.fingerprint == fingerprint else { return }
        switch outcome {
        case .success(let reading):
            if reading.move == .nothing {
                entry.state = .quiet(.model)
                metrics.recordOffered(.nothing)
            } else if entry.gate.propose(reading, fingerprint: fingerprint) {
                entry.state = .revealed(reading)
                metrics.recordOffered(reading.move)
            }
        case .unavailable:
            entry.state = .fallback
        case .cancelled:
            // The user left mid-judgment; `cancel` already dropped or will drop the
            // entry. Writing a state for a page nobody is on would be noise.
            return
        case .timedOut:
            entry.state = .failed(retryable: true)
        case .failed:
            entry.state = .failed(retryable: true)
        }
        entry.work = nil
        entries[id] = entry
    }
}
