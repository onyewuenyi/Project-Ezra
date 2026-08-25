//
//  TaskAdvisorSessionPoolTests.swift
//  Project-EzraTests
//
//  The pool's contract, tested with a dummy session because the real builder constructs a
//  `LanguageModelSession`, which cannot exist under XCTest. Same approach as
//  `CaptureSessionPoolTests` — what is being tested is the reuse rule, not the model.
//
//  Why this matters enough to test: the Advisor's loading state renders as nothing, so a
//  cold prefix is felt directly as the feature being slow. A pool that silently missed
//  would look exactly like a pool that worked.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct TaskAdvisorSessionPoolTests {

    private final class Dummy {
        let instructions: String
        init(_ instructions: String) { self.instructions = instructions }
    }

    private func pool(_ built: @escaping () -> Void = {}) -> TaskAdvisorSessionPool<Dummy> {
        TaskAdvisorSessionPool<Dummy> { instructions in
            built()
            return Dummy(instructions)
        }
    }

    @Test("A prepared spare is served, and the next one starts warming immediately")
    func warmSpareIsServed() {
        var builds = 0
        let pool = pool { builds += 1 }

        pool.prepare(instructions: "A")
        #expect(builds == 1)  // the spare

        let session = pool.take(instructions: "A")
        #expect(session.instructions == "A")
        #expect(pool.hits == 1)
        #expect(pool.misses == 0)
        // `take` immediately warms the NEXT spare — that is what makes a pager swipe land
        // on a hot prefix rather than paying the prefill again.
        #expect(builds == 2)
    }

    @Test("A changed prefix is a miss — a stale spare is never served")
    func changedInstructionsMiss() {
        let pool = pool()
        pool.prepare(instructions: "A")

        let session = pool.take(instructions: "B")

        #expect(session.instructions == "B")
        #expect(pool.misses == 1)
        #expect(pool.hits == 0)
    }

    @Test("Taking twice without a warm spare in between still serves the right prefix")
    func consecutiveTakes() {
        let pool = pool()
        let first = pool.take(instructions: "A")   // cold: miss
        let second = pool.take(instructions: "A")  // served by the spare the first warmed
        #expect(first.instructions == "A")
        #expect(second.instructions == "A")
        #expect(pool.misses == 1)
        #expect(pool.hits == 1)
    }

    @Test("Preparing twice for the same prefix does not rebuild")
    func prepareIsIdempotent() {
        var builds = 0
        let pool = pool { builds += 1 }
        pool.prepare(instructions: "A")
        pool.prepare(instructions: "A")
        // Called on every page activation, so a non-idempotent prepare would rebuild the
        // session on every swipe — paying the exact cost the pool exists to avoid.
        #expect(builds == 1)
    }

    @Test("Draining clears the spare and the counters")
    func drain() {
        let pool = pool()
        pool.prepare(instructions: "A")
        _ = pool.take(instructions: "A")
        pool.drain()
        #expect(pool.hits == 0)
        #expect(pool.misses == 0)
    }
}
