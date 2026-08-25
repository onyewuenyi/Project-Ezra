//
//  TaskAdvisorStoreTests.swift
//  Project-EzraTests
//
//  The reveal gate's structural invariant and the store's deterministic paths. The
//  model half is untestable here by design — `ModelRun` short-circuits to
//  `.unavailable` under XCTest — so a worthy task lands in `.fallback` and the gating,
//  cancellation and fingerprint-no-op behavior are exactly what these pin. The live
//  judgment paths are device-pass territory (`-AdvisorDiagnostics`).
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Task Advisor — the reveal gate")
struct AdvisorRevealGateTests {

    private var reading: ValidatedReading {
        ValidatedReading(
            move: .advise, observation: "One thought.", guidance: nil, nextMove: nil,
            options: [], recommendation: nil, steps: [])
    }

    private var second: ValidatedReading {
        ValidatedReading(
            move: .advise, observation: "A different thought.", guidance: nil, nextMove: nil,
            options: [], recommendation: nil, steps: [])
    }

    @Test("A reading reveals once per fingerprint — a repeat is refused")
    func revealsOnce() {
        var gate = AdvisorRevealGate()
        let first = gate.propose(reading, fingerprint: 1)
        let repeated = gate.propose(second, fingerprint: 1)
        #expect(first)
        #expect(!repeated)
        #expect(gate.revealed == reading)  // the first thought stands
    }

    @Test("A new fingerprint is the only reopener")
    func newFingerprintReopens() {
        var gate = AdvisorRevealGate()
        gate.propose(reading, fingerprint: 1)
        let reopened = gate.propose(second, fingerprint: 2)
        #expect(reopened)
        #expect(gate.revealed == second)
    }
}

@MainActor
@Suite("Task Advisor — store gating")
struct TaskAdvisorStoreTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func freshStore() -> TaskAdvisorStore {
        let name = "advisor-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return TaskAdvisorStore(metrics: AdvisorMetrics(defaults: defaults))
    }

    @Test("A task the gate filters out judges to deterministic silence")
    func gatedTaskIsQuiet() {
        let context = context()
        let store = freshStore()
        let task = TaskItem(title: "Call the dentist", status: .todo, in: context)

        store.ensure(task: task, among: [task])
        #expect(store.state(for: task) == .quiet(.gate))
    }

    @Test("A worthy task with no model lands in fallback — an execution path, not a judgment")
    func worthyTaskFallsBack() {
        let context = context()
        let store = freshStore()
        let task = TaskItem(title: "Renovate the kitchen", status: .todo, effortMinutes: 120, in: context)

        // Under XCTest `AppBrain.onDeviceModelAvailable()` is false by design, so the
        // ambient trigger settles on the deterministic template path.
        store.ensure(task: task, among: [task])
        // And the fallback CARRIES rung-0 content rather than being an empty labelled
        // surface — the ladder promises a template fallback on every rung.
        guard case .fallback(let reading) = store.state(for: task) else {
            Issue.record("expected .fallback, got \(store.state(for: task))")
            return
        }
        #expect(reading?.observation.isEmpty == false)
    }

    @Test("Same fingerprint → same judgment, no re-evaluation; changed facts re-judge")
    func fingerprintIsTheCache() {
        let context = context()
        let store = freshStore()
        let task = TaskItem(title: "Call the dentist", status: .todo, in: context)

        store.ensure(task: task, among: [task])
        #expect(store.state(for: task) == .quiet(.gate))

        // Re-ensuring with nothing changed keeps the settled judgment (a no-op).
        store.ensure(task: task, among: [task])
        #expect(store.state(for: task) == .quiet(.gate))

        // A meaningful fact changes → the Advisor re-judges (here: the task becomes
        // worthy, and with no model that means fallback).
        task.effortMinutes = 120
        store.ensure(task: task, among: [task])
        if case .fallback = store.state(for: task) {
        } else {
            Issue.record("expected .fallback, got \(store.state(for: task))")
        }
    }

    @Test("A never-opened task is unevaluated, NOT a judgment of silence")
    func unknownTaskIsUnevaluated() {
        let context = context()
        let store = freshStore()
        let task = TaskItem(title: "Anything", status: .todo, in: context)

        // The two render identically and mean opposite things: "no judgment has been
        // made" versus "a judgment was made, and it was silence". Modelling them the
        // same way is how a store starts lying about what it knows.
        #expect(store.state(for: task) == .unevaluated)

        store.ensure(task: task, among: [task])
        #expect(store.state(for: task) == .quiet(.gate))
    }
}
