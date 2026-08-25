//
//  TaskAdvisorSessionPool.swift
//  Project-Ezra
//
//  A prewarmed, single-use session for the Task Advisor — the `CaptureSessionPool` shape,
//  applied to the surface that needed it more. It is `TaskAdvisor*` on purpose: the v2
//  naming rule is that "Advisor" names the PER-TASK layer only, and this pool has never
//  had any other consumer.
//
//  The Advisor built a fresh `CapabilityProfiles.session` inside every read, so its
//  ~2KB instruction block was prefilled cold on every single reading. Two things made
//  that worth fixing rather than tolerating:
//
//  1. **The loading state renders as nothing** (`AdvisorView` draws `Color.clear` — no
//     spinner, by design, because the user should experience a conclusion arriving
//     rather than a machine working). There is therefore no affordance absorbing the
//     wait: latency IS the felt quality of this feature.
//  2. **The prompt got longer.** Adding worked contrast pairs took device latency from
//     ~4–7s to ~6–12s and pushed one eval fixture past the 20s card deadline — 1 in 6
//     timing out, against the ">5% on device" tripwire recorded for exactly this. The
//     accuracy was worth buying (agreement 5/8 → 7/8); the prefill is what pays for it.
//
//  What was there before was worse than nothing: `TaskDetailView` warmed
//  `ModelWarmup.prewarmSharedSession()`, an ANONYMOUS session, so the cost was paid and
//  the Advisor's actual prefix stayed cold — the same mistake CLAUDE.md already records
//  for capture ("`ModelWarmup`'s anonymous session never covered it").
//
//  Fingerprinted on the instruction text because that IS the prefix being warmed: if the
//  instructions change, the spare is worthless and must be rebuilt rather than served.
//

import Foundation

@MainActor
final class TaskAdvisorSessionPool<Session> {

    /// What makes a prepared session reusable. The Advisor's instructions are static
    /// today, so this is effectively a single-valued key — it exists so that a future
    /// personalized instruction block (the capture path already has one) cannot silently
    /// serve a spare built for someone else's prefix.
    struct Fingerprint: Equatable {
        let instructions: String
    }

    private let build: (String) -> Session
    private var spare: (session: Session, fingerprint: Fingerprint)?
    /// DEBUG evidence for the diagnostics footer: how often the pool actually serves.
    private(set) var hits = 0
    private(set) var misses = 0

    init(build: @escaping (String) -> Session) {
        self.build = build
    }

    /// The session for this reading — the warm spare when its fingerprint matches, a cold
    /// build otherwise. Either way the NEXT spare starts warming immediately, so a pager
    /// swipe onto the following task lands on a hot prefix.
    func take(instructions: String) -> Session {
        let fingerprint = Fingerprint(instructions: instructions)
        defer { prepare(instructions: instructions) }
        if let spare, spare.fingerprint == fingerprint {
            self.spare = nil
            hits += 1
            return spare.session
        }
        misses += 1
        return build(instructions)
    }

    /// Build and warm the spare if one isn't already waiting. Called when a detail page
    /// becomes active, so the page-settling animation absorbs the prefill.
    func prepare(instructions: String) {
        let fingerprint = Fingerprint(instructions: instructions)
        guard spare?.fingerprint != fingerprint else { return }
        spare = (build(instructions), fingerprint)
    }

    /// Test seam / availability-change reset.
    func drain() {
        spare = nil
        hits = 0
        misses = 0
    }
}
