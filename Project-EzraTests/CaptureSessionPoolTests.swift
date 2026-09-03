//
//  CaptureSessionPoolTests.swift
//  Project-EzraTests
//
//  The pool's reuse contract, tested with a dummy session type (the real builder
//  constructs a LanguageModelSession, which cannot exist under XCTest). What must
//  hold: a matching fingerprint serves the prewarmed spare exactly once and
//  re-prepares behind it; a changed fingerprint (personalization or roster moved)
//  builds cold — never serves a stale session; prepare is idempotent.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct CaptureSessionPoolTests {

    private final class DummySession {}

    private func fingerprint(
        _ instructions: String, roster: [RosterPerson] = []
    )
        -> CaptureSessionPool<DummySession>.Fingerprint
    {
        .init(instructions: instructions, roster: roster)
    }

    @Test("A matching fingerprint serves the prepared spare once, and re-prepares behind it")
    func matchingFingerprintHits() {
        var builds = 0
        let pool = CaptureSessionPool<DummySession> { _ in
            builds += 1
            return DummySession()
        }
        let print = fingerprint("instructions v1")
        pool.prepare(context: TriageContext(), fingerprint: print)
        #expect(builds == 1)

        _ = pool.take(context: TriageContext(), fingerprint: print)
        #expect(pool.hits == 1)
        #expect(pool.misses == 0)
        // The take consumed the spare and immediately built its replacement — the
        // next parse in the burst hits too.
        #expect(builds == 2)
        _ = pool.take(context: TriageContext(), fingerprint: print)
        #expect(pool.hits == 2)
    }

    @Test("A changed fingerprint never serves the stale session")
    func changedFingerprintMisses() {
        var builds = 0
        let pool = CaptureSessionPool<DummySession> { _ in
            builds += 1
            return DummySession()
        }
        pool.prepare(context: TriageContext(), fingerprint: fingerprint("instructions v1"))

        // Personalization changed (a commit wrote corrections) — the spare's
        // instructions no longer match what this parse needs.
        _ = pool.take(context: TriageContext(), fingerprint: fingerprint("instructions v2"))
        #expect(pool.hits == 0)
        #expect(pool.misses == 1)

        // The re-prepare ran under the NEW fingerprint, so the burst recovers.
        _ = pool.take(context: TriageContext(), fingerprint: fingerprint("instructions v2"))
        #expect(pool.hits == 1)
    }

    @Test("A roster change alone changes the fingerprint — the person tool must match")
    func rosterChangesFingerprint() {
        let maya = RosterPerson(name: "Maya", relationship: "partner")
        let a = fingerprint("same instructions")
        let b = fingerprint("same instructions", roster: [maya])
        #expect(a != b)
    }

    @Test("Prepare is idempotent for a matching fingerprint")
    func prepareIsIdempotent() {
        var builds = 0
        let pool = CaptureSessionPool<DummySession> { _ in
            builds += 1
            return DummySession()
        }
        let print = fingerprint("instructions v1")
        pool.prepare(context: TriageContext(), fingerprint: print)
        pool.prepare(context: TriageContext(), fingerprint: print)
        #expect(builds == 1)
    }

    // MARK: - takeTimed ≡ take (the FM-diagnosis seam's window must not change the pool)

    @Test("takeTimed's hit path is behaviourally identical to take's")
    func takeTimedHitMatchesTake() {
        var builds = 0
        let pool = CaptureSessionPool<DummySession> { _ in
            builds += 1
            return DummySession()
        }
        let print = fingerprint("instructions v1")
        pool.prepare(context: TriageContext(), fingerprint: print)
        #expect(builds == 1)

        let receipt = pool.takeTimed(context: TriageContext(), fingerprint: print)
        #expect(receipt.poolHit)
        #expect(pool.hits == 1)
        #expect(pool.misses == 0)
        // Spare consumed, replacement built — exactly one build, same as take.
        #expect(builds == 2)
        // And the re-prepare landed under the right fingerprint: the next take hits.
        _ = pool.take(context: TriageContext(), fingerprint: print)
        #expect(pool.hits == 2)
    }

    @Test("takeTimed's miss path builds cold + prepare, exactly like take")
    func takeTimedMissMatchesTake() {
        var builds = 0
        let pool = CaptureSessionPool<DummySession> { _ in
            builds += 1
            return DummySession()
        }
        let receipt = pool.takeTimed(
            context: TriageContext(), fingerprint: fingerprint("instructions v1"))
        #expect(!receipt.poolHit)
        #expect(pool.misses == 1)
        #expect(pool.hits == 0)
        // Cold build + the prepared next spare = two builds, same as take on empty.
        #expect(builds == 2)
    }

    @Test("Interleaving take and takeTimed never serves a stale fingerprint")
    func interleavingStaysFingerprintSafe() {
        var builds = 0
        let pool = CaptureSessionPool<DummySession> { _ in
            builds += 1
            return DummySession()
        }
        let v1 = fingerprint("instructions v1")
        let v2 = fingerprint("instructions v2")
        _ = pool.take(context: TriageContext(), fingerprint: v1)  // miss, prepares v1
        let receipt = pool.takeTimed(context: TriageContext(), fingerprint: v2)
        // The v1 spare must not be served for a v2 request.
        #expect(!receipt.poolHit)
        #expect(pool.misses == 2)
        // And takeTimed's re-prepare is v2, so a v2 take now hits.
        _ = pool.take(context: TriageContext(), fingerprint: v2)
        #expect(pool.hits == 1)
    }
}
