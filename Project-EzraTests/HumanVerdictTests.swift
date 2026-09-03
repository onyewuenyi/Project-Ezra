//
//  HumanVerdictTests.swift
//  Project-EzraTests
//
//  The one noun for the human's "no" — and the claim it exists to make true: a
//  dismissed Advisor reading stays dismissed across a relaunch, until the facts change.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("HumanVerdict — one home for the human's no")
struct HumanVerdictTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("verdicts-\(UUID().uuidString).json")
    }

    @Test("A verdict survives a reload from the file")
    func persists() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let task = UUID()
        let store = HumanVerdictStore(fileURL: url)
        store.record(HumanVerdict(subject: .reading(taskID: task, fingerprint: 7), verdict: .declined))

        let reloaded = HumanVerdictStore(fileURL: url)
        #expect(reloaded.isDeclined(reading: task, fingerprint: 7))
        // A different fingerprint is a different subject — the facts moved, the verdict
        // no longer applies.
        #expect(!reloaded.isDeclined(reading: task, fingerprint: 8))
    }

    @Test("A subject has one current verdict, not a history")
    func oneVerdictPerSubject() {
        let store = HumanVerdictStore(fileURL: nil)
        let subject = HumanVerdict.Subject.proposedEdge(key: "duplicateMerge:a:b")
        store.record(HumanVerdict(subject: subject, verdict: .declined, at: Date(timeIntervalSince1970: 1)))
        store.record(HumanVerdict(subject: subject, verdict: .changed, at: Date(timeIntervalSince1970: 2)))
        #expect(store.all.count == 1)
        #expect(store.verdict(on: subject)?.verdict == .changed)
    }

    @Test("Housekeeping prunes by age only; the binding is the fingerprint, not the clock")
    func prune() {
        let store = HumanVerdictStore(fileURL: nil)
        let now = Date()
        store.record(
            HumanVerdict(
                subject: .reading(taskID: UUID(), fingerprint: 1), verdict: .declined,
                at: now.addingTimeInterval(-HumanVerdictStore.maxAge - 1)))
        let fresh = UUID()
        store.record(
            HumanVerdict(subject: .reading(taskID: fresh, fingerprint: 1), verdict: .declined, at: now))
        #expect(store.prune(now: now) == 1)
        #expect(store.isDeclined(reading: fresh, fingerprint: 1))
    }

    @Test("The read seam unifies all three storages into one vocabulary, newest first")
    func collect() {
        let context = TestStore.makeContext()
        let correction = Correction(
            taskUUID: UUID(), fieldCorrected: "category", aiValue: "Home", userValue: "Errands",
            createdAt: Date(timeIntervalSince1970: 100), in: context)
        let suppression = RelationshipSuppression(
            kind: .duplicateMerge, pairKey: "a:b", targetID: nil, normalizedTitle: nil,
            createdAt: Date(timeIntervalSince1970: 300))
        let store = HumanVerdictStore(fileURL: nil)
        store.record(
            HumanVerdict(
                subject: .reading(taskID: UUID(), fingerprint: 1), verdict: .declined,
                at: Date(timeIntervalSince1970: 200)))

        let verdicts = HumanVerdicts.collect(
            corrections: [correction], suppressions: [suppression], store: store)
        #expect(verdicts.count == 3)
        #expect(verdicts.map(\.at.timeIntervalSince1970) == [300, 200, 100])
        #expect(verdicts[0].subject == .proposedEdge(key: "duplicateMerge:a:b"))
        #expect(verdicts[0].verdict == .declined)
        #expect(verdicts[2].verdict == .changed)
    }

    @Test("The shared store is in-memory under the test host")
    func sharedIsInert() {
        let task = UUID()
        HumanVerdictStore.shared.record(
            HumanVerdict(subject: .reading(taskID: task, fingerprint: 1), verdict: .declined))
        #expect(HumanVerdictStore.shared.isDeclined(reading: task, fingerprint: 1))
        HumanVerdictStore.shared.reset()
        #expect(!HumanVerdictStore.shared.isDeclined(reading: task, fingerprint: 1))
    }
}

@MainActor
@Suite("HumanVerdict — the Advisor honours it across launches")
struct AdvisorDismissalDurabilityTests {

    private func advisorStore(verdicts: HumanVerdictStore) -> TaskAdvisorStore {
        TaskAdvisorStore(
            judge: { facts, _, _ in
                .success(
                    ValidatedReading(
                        move: .advise, observation: "Start with the policy number.",
                        guidance: nil, nextMove: nil, options: [], recommendation: nil, steps: []))
            },
            isModelAvailable: { true },
            metrics: AdvisorMetrics(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            ledger: IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            verdicts: verdicts)
    }

    @Test(
        "A dismissed reading is still dismissed in a FRESH store over the same facts — and costs no generation"
    )
    func dismissalSurvivesRelaunch() async throws {
        let context = TestStore.makeContext()
        let task = TaskItem(
            title: "Renew the car insurance",
            dueDate: Calendar.current.date(byAdding: .day, value: -3, to: Date()),
            isUrgent: true, in: context)
        try context.save()
        let verdicts = HumanVerdictStore(fileURL: nil)

        let first = advisorStore(verdicts: verdicts)
        first.ensure(task: task, among: [task])
        await first.awaitPendingJudgment(for: task.uuid)
        guard case .revealed = first.state(for: task) else {
            Issue.record("expected a revealed reading; got \(first.state(for: task))")
            return
        }
        first.dismiss(taskID: task.uuid)
        #expect(first.state(for: task) == .dismissed)

        // "Relaunch": a new store, the same verdicts file, the same facts.
        var judged = 0
        let second = TaskAdvisorStore(
            judge: { _, _, _ in
                judged += 1
                return .failed("should not be asked")
            },
            isModelAvailable: { true },
            metrics: AdvisorMetrics(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            ledger: IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            verdicts: verdicts)
        second.ensure(task: task, among: [task])
        await second.awaitPendingJudgment(for: task.uuid)
        #expect(second.state(for: task) == .dismissed)
        #expect(judged == 0)

        // The facts move → a new subject → the Advisor may speak again.
        task.title = "Renew the car insurance before the trip"
        let third = advisorStore(verdicts: verdicts)
        third.ensure(task: task, among: [task])
        await third.awaitPendingJudgment(for: task.uuid)
        if case .dismissed = third.state(for: task) {
            Issue.record("a moved fingerprint must not inherit the old dismissal")
        }
    }
}
