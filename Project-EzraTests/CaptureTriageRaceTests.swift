//
//  CaptureTriageRaceTests.swift
//  Project-EzraTests
//
//  The composer's live parse was the one model call in the app with no deadline: a
//  wedged on-device generation left "Sorting…" pulsing forever. These pin the race's
//  contract with fake operations — most importantly that a deadline hit SALVAGES the
//  last streamed partial set (cards the user was already reading) rather than
//  discarding it, and that a debounce supersession reads as `.cancelled` so the
//  caller can keep it out of the metrics.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CaptureTriageRaceTests {

    private func intent(_ title: String) -> TaskIntent {
        TaskIntent(
            title: title, category: "Admin", confidence: 0.9, isJudgmentCall: false,
            reasoning: "")
    }

    @Test("An operation that finishes in time returns .finished with its value")
    func finishes() async {
        let expected = [intent("call vet")]
        let outcome = await CaptureTriageRace.run(deadline: 1.0, onPartial: nil) { _ in
            expected
        }
        guard case .finished(let value) = outcome else {
            Issue.record("expected .finished, got \(outcome)")
            return
        }
        #expect(value.map(\.title) == ["call vet"])
    }

    @Test("A deadline hit salvages the LAST streamed partial set")
    func salvagesLastPartial() async {
        let first = [intent("renew pass")]
        let second = [intent("renew passport"), intent("book dentist")]
        let outcome = await CaptureTriageRace.run(deadline: 0.05, onPartial: nil) { tee in
            tee(first)
            tee(second)
            try await Task.sleep(for: .seconds(60))
            return []
        }
        guard case .salvaged(let value) = outcome else {
            Issue.record("expected .salvaged, got \(outcome)")
            return
        }
        #expect(value.map(\.title) == ["renew passport", "book dentist"])
    }

    @Test("A deadline hit with no streamed partials is .timedOutEmpty")
    func timesOutEmpty() async {
        let outcome = await CaptureTriageRace.run(deadline: 0.05, onPartial: nil) { _ in
            try await Task.sleep(for: .seconds(60))
            return []
        }
        guard case .timedOutEmpty = outcome else {
            Issue.record("expected .timedOutEmpty, got \(outcome)")
            return
        }
    }

    @Test("Streamed partials still reach the caller's handler through the tee")
    func partialsForward() async {
        var received: [[String]] = []
        _ = await CaptureTriageRace.run(
            deadline: 1.0,
            onPartial: { received.append($0.map(\.title)) }
        ) { tee in
            tee([self.intent("one")])
            tee([self.intent("one"), self.intent("two")])
            return [self.intent("one"), self.intent("two")]
        }
        #expect(received == [["one"], ["one", "two"]])
    }

    @Test("Cancelling the enclosing task reads as .cancelled, never a timeout")
    func cancellation() async {
        let task = Task { @MainActor in
            await CaptureTriageRace.run(deadline: 60, onPartial: nil) { _ -> [TaskIntent] in
                try await Task.sleep(for: .seconds(120))
                return []
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value
        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
    }

    @Test("An operation that throws its own error is .failed, carrying that error")
    func failure() async {
        struct Boom: Error {}
        let outcome = await CaptureTriageRace.run(deadline: 1.0, onPartial: nil) {
            _ -> [TaskIntent] in
            throw Boom()
        }
        guard case .failed(let error) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(error is Boom)
    }
}
