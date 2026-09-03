//
//  IntelligenceLedger.swift
//  Project-Ezra
//
//  How many intelligent moments resolved at each rung, per workload — the instrument
//  the cloud rung's economics are decided on.
//
//  **Why this exists before any budget governor.** The product analysis proposed an
//  eligibility → recency → rate governor for cloud spend. This codebase has a named
//  precedent against building that: the capture deadline was tuned on device evidence,
//  not argument, and the fingerprint cache plus the plays-once Brief already remove the
//  two biggest cost drivers structurally. So: **meter first, cap second, govern on
//  evidence.** This file is the meter. The cap reads `cloudCallsToday`.
//
//  **The number that matters is cloud calls per user per day AFTER routing — not AI
//  interactions per day.** Twenty-five Advisor encounters resolving as 15 facts/cache +
//  8 on-device + 2 cloud is twenty-five intelligent experiences for two paid
//  generations. A metric that counted "AI interactions" would report 25 and imply a
//  bill that does not exist, which is exactly the confusion this ledger is shaped to
//  prevent: the rung is the unit, not the encounter.
//
//  **Local only, never transmitted**, same charter as `ModelMetrics` and
//  `AdvisorMetrics`. It measures this device's routing, and shipping per-workload
//  routing telemetry off-device would be a product-posture change deserving its own
//  decision rather than a ride-along inside a counter.
//
//  It does NOT replace `ModelMetrics` (per-capability call outcomes: latency, timeouts,
//  salvage) or `PlanMetrics` (the Brief's own tier history). Those answer *did the model
//  work*; this answers *how often did we have to ask one*.
//

import Foundation
import Observation

/// A step on the intelligence ladder, cheapest first. The names are the ladder's, so a
/// counter can be read against the design doc without translation.
enum IntelligenceRung: String, CaseIterable, Sendable {
    /// Rung 0 — deterministic, no generation. Sensors, gates, rankings, fact lines,
    /// template fallbacks. Free, instant, offline.
    case facts
    /// Rung 1 — cached judgment re-served without generating: the facts fingerprint
    /// answering "same task, same meaningful context, same reading".
    case memory
    /// Rung 2 — Apple's on-device model through `ModelRun`. Free, private, bounded.
    case onDevice
    /// Rung 3 — the one paid rung, through `CloudModelProvider`.
    case cloud

    /// Short DEBUG-footer label. Never user-facing.
    var label: String {
        switch self {
        case .facts: return "facts"
        case .memory: return "mem"
        case .onDevice: return "dev"
        case .cloud: return "cloud"
        }
    }
}

/// Which system asked. Routing policy is decided per workload (one function each), so
/// the counters are per workload too — an aggregate would hide the only interesting
/// question, which is *which* workload is climbing the ladder.
enum IntelligenceWorkload: String, CaseIterable, Sendable {
    case ramble
    case advisor
    case brief
    case sweeps
    /// The Advisor chat — the one workload the PERSON initiates, counted apart from
    /// the ambient Advisor so a chatty afternoon cannot read as the ambient layer
    /// climbing the ladder. On-device only, so it can never write `.cloud`.
    case chat
}

@MainActor
@Observable
final class IntelligenceLedger {
    static let shared = IntelligenceLedger()

    private let defaults: UserDefaults
    private let calendar: Calendar

    /// Lifetime tallies, `[workload][rung]`.
    private(set) var counts: [IntelligenceWorkload: [IntelligenceRung: Int]] = [:]

    /// Cloud calls counted so far, and the day they belong to. Stored as a pair rather
    /// than a rolling history: the cap Challenge 4 sanctions is "one dumb daily cap",
    /// and a per-day history would be a spend log — more data about the user's usage
    /// than the decision it feeds actually needs.
    private(set) var cloudCallsCounted: Int
    private(set) var cloudDay: Date

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: Date = Date()) {
        self.defaults = defaults
        self.calendar = calendar
        // Built locally and assigned once: under `@Observable` a subscript write goes
        // through the registrar, i.e. through `self`, which the compiler rejects before
        // every stored property is initialized.
        var loaded: [IntelligenceWorkload: [IntelligenceRung: Int]] = [:]
        for workload in IntelligenceWorkload.allCases {
            var byRung: [IntelligenceRung: Int] = [:]
            for rung in IntelligenceRung.allCases {
                byRung[rung] = defaults.integer(forKey: Key.count(workload, rung))
            }
            loaded[workload] = byRung
        }
        self.cloudCallsCounted = defaults.integer(forKey: Key.cloudCount)
        self.cloudDay =
            defaults.object(forKey: Key.cloudDay) as? Date ?? calendar.startOfDay(for: now)
        self.counts = loaded
    }

    /// One intelligent moment resolved at `rung`.
    ///
    /// Call this where the routing DECISION lands, not where a model returns: a gate
    /// skip and a cache hit are outcomes with no call attached, and they are the two the
    /// ledger exists to make visible. Recording only what generated would reproduce the
    /// "AI interactions per day" number this file's header rejects.
    func record(_ rung: IntelligenceRung, for workload: IntelligenceWorkload, now: Date = Date()) {
        counts[workload, default: [:]][rung, default: 0] += 1
        defaults.set(counts[workload]?[rung] ?? 0, forKey: Key.count(workload, rung))
        guard rung == .cloud else { return }
        // Roll over lazily, on write. Reads stay pure (see `cloudCallsToday`) so the
        // footer and a future cap can ask without mutating.
        let today = calendar.startOfDay(for: now)
        if !calendar.isDate(cloudDay, inSameDayAs: today) {
            cloudDay = today
            cloudCallsCounted = 0
            defaults.set(today, forKey: Key.cloudDay)
        }
        cloudCallsCounted += 1
        defaults.set(cloudCallsCounted, forKey: Key.cloudCount)
    }

    /// Cloud calls made today. **The** number: the daily cap reads this, and so does any
    /// argument about what the cloud rung costs.
    ///
    /// A pure read that rolls the day over in its ANSWER rather than its state — asking
    /// the question after midnight must report 0, and must not be the thing that
    /// discards yesterday's count on a screen nobody looked at.
    func cloudCallsToday(now: Date = Date()) -> Int {
        calendar.isDate(cloudDay, inSameDayAs: now) ? cloudCallsCounted : 0
    }

    /// One DEBUG-footer line per workload that has actually resolved something:
    /// `rungs advisor: facts 12 · mem 6 · dev 4`. Workloads with no activity are
    /// omitted — an all-zero grid is noise, not information (same rule as
    /// `ModelMetrics.footerLines`).
    func footerLines(now: Date = Date()) -> [String] {
        var lines = IntelligenceWorkload.allCases.compactMap { workload -> String? in
            let byRung = counts[workload] ?? [:]
            let parts = IntelligenceRung.allCases.compactMap { rung -> String? in
                let n = byRung[rung] ?? 0
                return n > 0 ? "\(rung.label) \(n)" : nil
            }
            guard !parts.isEmpty else { return nil }
            return "rungs \(workload.rawValue): " + parts.joined(separator: " · ")
        }
        // The daily cloud number gets its own line even at zero, once anything has been
        // routed at all: "how many paid calls today" is the question you come to this
        // footer to answer, and a missing line reads as missing instrumentation rather
        // than as zero.
        if !lines.isEmpty { lines.append("cloud today: \(cloudCallsToday(now: now))") }
        return lines
    }

    /// Wipe every tally (Settings ▸ Reset everything) — same reason `ModelMetrics.reset`
    /// does: the routing recorded here was routing for work that is now gone.
    func reset(now: Date = Date()) {
        for workload in IntelligenceWorkload.allCases {
            var byRung: [IntelligenceRung: Int] = [:]
            for rung in IntelligenceRung.allCases {
                byRung[rung] = 0
                defaults.removeObject(forKey: Key.count(workload, rung))
            }
            counts[workload] = byRung
        }
        cloudCallsCounted = 0
        cloudDay = calendar.startOfDay(for: now)
        defaults.removeObject(forKey: Key.cloudCount)
        defaults.removeObject(forKey: Key.cloudDay)
    }

    private enum Key {
        static func count(_ w: IntelligenceWorkload, _ r: IntelligenceRung) -> String {
            "rung.\(w.rawValue).\(r.rawValue)"
        }
        static let cloudCount = "rung.cloud.today.count"
        static let cloudDay = "rung.cloud.today.day"
    }
}
