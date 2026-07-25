//
//  WorkIntentTests.swift
//  Project-EzraTests
//
//  workIntent is computed, cached, and refreshable — never permanent. These pin the
//  round-trip, the stamp-at-commit, that the classifier returns nil off-device (the sim
//  path), and — the constitutional guard — that NOTHING on the intent path ever
//  reads or writes `needsDecision`. Framing generation itself is device-verify.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Work intent")
struct WorkIntentTests {

    @Test("workIntent round-trips through the raw store")
    func roundTrip() {
        let task = TaskItem(title: "x", status: .todo)
        #expect(task.workIntent == nil)
        task.workIntent = .decision
        #expect(task.workIntent == .decision)
        task.workIntent = nil
        #expect(task.workIntent == nil)
    }

    @Test("A draft's workIntent is stamped onto the created task at commit")
    func stampAtCommit() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        var draft = TaskDraft(
            title: "Decide on the vendor", category: "Work", confidence: 0.9,
            autonomy: .silent, isJudgmentCall: false, reasoning: "")
        draft.workIntent = .decision
        let created = brain.commit([draft], rawCapture: "", into: context)
        #expect(created.first?.workIntent == .decision)
    }

    @Test("A .decision intent unlocks the Thinking Partner without fabricating the flag")
    func intentUnlocksCapabilityGuardsFlag() {
        let task = TaskItem(title: "Choose a plan", status: .todo)
        task.workIntent = .decision
        #expect(TaskCapabilities.available(for: task).contains(.thinkingPartner))
        #expect(!task.needsDecision)  // the intent path never sets the flag
    }

    @Test("The needsDecision flag also unlocks the capability; re-stamping intent never clears it")
    func flagUnlocksAndSurvives() {
        let task = TaskItem(title: "Figure it out", status: .todo, needsDecision: true)
        #expect(TaskCapabilities.available(for: task).contains(.thinkingPartner))
        task.workIntent = .action  // "re-classify" to a non-decision kind
        #expect(task.needsDecision)  // untouched — only resolveDecision clears the flag
    }

    @Test("A plain action task offers no capability")
    func actionOffersNothing() {
        let task = TaskItem(title: "Buy milk", status: .todo)
        task.workIntent = .action
        #expect(TaskCapabilities.available(for: task).isEmpty)
    }

    @Test("The classifier returns nil off-device and never touches the flag")
    func classifyNilInSim() async {
        let task = TaskItem(title: "x", status: .todo, needsDecision: true)
        let result = await WorkIntentClassifier().classify(
            WorkIntentContext(task: task, among: [task]))
        #expect(result == nil)  // simulator / test host → nil
        #expect(task.needsDecision)  // classification is read-only over the flag
    }
}
