//
//  Instrument.swift
//  Project-Ezra
//
//  **The bracket every measurement carries, built once.** (P-04)
//
//  §11's own headline lesson: in the week the confidence gate was built and deleted,
//  seven of the nine bugs found were in the MEASUREMENT code — including a scorer whose
//  ground truth asked the wrong question and would have produced a never-firing gate
//  with data appearing to justify it. The lesson was written down as three rules:
//
//    1. **Bracket every new metric** — a known-perfect input must score clean and a
//       known-reckless one must be caught, or a clean report is indistinguishable from a
//       blind scorer.
//    2. **Prove a served call.** Availability is a claim that a model EXISTS; only a
//       served call is evidence one ANSWERED. Any harness attributing results to a
//       model arm must take a `ModelMetrics` delta and report an arm that served fewer
//       than 90% of its calls as DEGRADED — a ratio, not a zero test, because an arm
//       serving 2 of 52 once printed "ALL FLOORS HELD".
//    3. **Integrity first.** A run that touched a rung it promised not to (a provider
//       call on a zero-cloud campaign) is INVALID, whatever else it printed.
//
//  …and then applied by hand in every new harness, nine times, each re-implementing
//  the served ratio, the DEGRADED banner, the file tee and the end marker. A rule that
//  has to be remembered at each new instrument is exactly what structure is for. This
//  file makes the rules the shape of the tool: an arm cannot report a pass without a
//  served ratio, and a report cannot close without its marker.
//
//  Deliberately small. It does not own corpora or floors — `RambleEval.Floors` and the
//  labeled sets stay where their fixtures are — it owns the parts every harness copied.
//

import Foundation

enum Instrument {

    // MARK: - Served ratio (rule 2)

    /// Below this share of served calls an arm's numbers describe the fallback, not the
    /// arm. The RambleEval rule, shared.
    static let servedFloor = 0.9

    /// What a model arm actually did across a run: a `ModelMetrics.Stats` delta.
    struct ArmDelta: Equatable, Sendable {
        let served: Int
        let attempted: Int
        let lastError: String?

        var share: Double { attempted > 0 ? Double(served) / Double(attempted) : 0 }
        /// True when the arm answered often enough for its rows to mean anything.
        var isCredible: Bool { attempted > 0 && share >= servedFloor }

        static func between(_ before: ModelMetrics.Stats, _ after: ModelMetrics.Stats) -> ArmDelta {
            let served = (after.successes + after.salvaged) - (before.successes + before.salvaged)
            let attempted =
                served + (after.timeouts - before.timeouts) + (after.failures - before.failures)
            return ArmDelta(served: served, attempted: attempted, lastError: after.lastError)
        }
    }

    /// The banner an incredible arm prints, or nil when the arm is credible. Names the
    /// recorded error so the report can say WHY, not only how often.
    static func degradedBanner(_ delta: ArmDelta, arm: String) -> String? {
        guard !delta.isCredible else { return nil }
        let reason = oneLine(delta.lastError ?? "no error recorded")
        if delta.attempted == 0 {
            return
                "DEGRADED: the \(arm) arm attempted no calls — nothing above was measured on it (\(reason))"
        }
        return
            "DEGRADED: the \(arm) arm served \(Int(delta.share * 100))% of its calls — "
            + "read the last error in Settings ▸ diagnostics before believing any row above (\(reason))"
    }

    /// The one summary line every arm prints.
    static func armLine(_ arm: String, delta: ArmDelta, latenciesMs: [Double], suffix: String = "") -> String
    {
        String(
            format: "%@ arm: served %d/%d · p50 %.0fms · p90 %.0fms%@",
            arm, delta.served, delta.attempted, percentile(latenciesMs, 0.5), percentile(latenciesMs, 0.9),
            suffix.isEmpty ? "" : " · " + suffix)
    }

    // MARK: - Integrity (rule 3)

    /// A zero-provider campaign that recorded a provider call is invalid, whatever else
    /// it printed. Returns the stamp, or nil when clean.
    static func zeroCloudViolation(providerCallsBefore: Int, providerCallsAfter: Int) -> String? {
        let delta = providerCallsAfter - providerCallsBefore
        guard delta > 0 else { return nil }
        return
            "RUN INVALID: \(delta) provider call\(delta == 1 ? "" : "s") on a zero-cloud run — every verdict above is withdrawn"
    }

    // MARK: - Bracket (rule 1)

    /// Run a scorer against a known-clean input and a known-reckless one. True only when
    /// the clean input scores clean AND the reckless one is caught — a scorer that
    /// passes both or fails both is blind.
    static func bracketHolds(cleanFlags: Int, recklessFlags: Int) -> Bool {
        cleanFlags == 0 && recklessFlags > 0
    }

    // MARK: - Report plumbing

    /// Tee stdout into a Documents file for the rest of the process — the `-EvalToFile`
    /// dance every device harness copied. The console tunnel drops mid-run routinely; a
    /// file survives every drop. Line-buffered so a poll mid-run sees real progress.
    static func teeStdoutToDocuments(_ fileName: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let report = documents.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: report)
        FileManager.default.createFile(atPath: report.path, contents: nil)
        freopen(report.path, "a", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    // MARK: - The run stamp (economics invariant 4)

    /// **Every eval report carries the run stamp**, so a number can never be quoted
    /// without the runtime it was measured on. That rule was written down on 2026-09-04
    /// and applied by hand — which is to say, not applied: the beta-8 FM rows in
    /// `docs/capture.md` carry their stamp because someone typed it, and the day someone
    /// forgets, a GA number and a beta number sit in the same table looking comparable.
    ///
    /// `configuration` is the workload-specific half — the instructions, the schema, the
    /// thresholds this particular arm ran with. It is fingerprinted rather than printed:
    /// the point is to notice that it MOVED between two runs, and a hash does that in a
    /// table cell where 1,861 tokens of instructions cannot.
    static func runStamp(model: String, configuration: String) -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return
            "run stamp: app \(short) (\(build)) · OS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) "
            + "(\(osBuild)) · device \(deviceIdentity) · model \(model) · "
            + "config \(fingerprint(configuration)) · \(ISO8601DateFormatter().string(from: Date()))"
    }

    /// The OS BUILD (`24A437`), beside the version. The on-device model changed at 26.4
    /// and again at 27.0 with no version API of its own (`SystemLanguageModel` exposes
    /// `contextSize` and `tokenCount`, nothing that names the weights), so the OS build
    /// is the only fingerprint of WHICH model answered — and two 27.0 runs on different
    /// builds are not the same runtime.
    static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// `iPhone16,2` on a phone; `sim:iPhone18,1` on the simulator. `utsname.machine` on
    /// the simulator is the host Mac's `arm64`, which stamped a simulator run as a device
    /// run on 2026-09-17 — the simulator now runs the real on-device model, so the two
    /// produce numbers that look comparable and are not (Mac silicon vs phone).
    static var deviceIdentity: String {
        let env = ProcessInfo.processInfo.environment
        if let simulated = env["SIMULATOR_MODEL_IDENTIFIER"] { return "sim:\(simulated)" }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// A short, stable fingerprint of a configuration string. Not cryptographic — it only
    /// has to change when the configuration does, and fit in a cell.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash % 0xffff_ffff, radix: 16)
    }

    /// The pair of markers a report opens and closes with. A poller keys on the end
    /// marker; a report that returns early must still print it, which is why it is a
    /// value and not a string literal at each exit.
    struct Markers {
        let name: String
        var begin: String { "=== \(name) ===" }
        var end: String { "=== END \(name) ===" }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// Collapse an error string to one line for a table cell.
    static func oneLine(_ label: String) -> String {
        let collapsed = label.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count > 140 ? String(collapsed.prefix(137)) + "…" : collapsed
    }
}
