//
//  CloudCallerTests.swift
//  Project-EzraTests
//
//  **Exactly two things in this app may talk to the cloud provider, and the privacy
//  screen describes both of them.**
//
//  Settings makes two positive claims about what goes out: captures, when the device's
//  own read falls short, and — to prepare advice — structured task information only. A
//  THIRD cloud caller would be a transmission no sentence on that screen covers, and
//  nothing else in the build would mention it: `CloudModel.provider` is a static slot, so
//  reaching it is one line from anywhere in the target.
//
//  This is a grep because that is what the property is: the ABSENCE of a caller. It was
//  written on 2026-09-20 after the same class of bug was found twice in one afternoon —
//  first the claim that corrections never leave the device (they mirror to the person's
//  own iCloud), then the Advisor's cloud arm sending `NOTES:`, `THEY SAID:` and
//  `WHY IT EXISTS:` under a sentence promising it never sends raw notes. Both were
//  found by reading the code against the copy. Two in one day is a pattern, and a
//  pattern deserves a tripwire rather than another careful reading.
//
//  Eval and diagnostic files are excluded on purpose: each swaps `EvalQuotaGuard` into
//  the slot precisely so an eval cannot spend, and every one of them is DEBUG-fenced.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Privacy · only the two declared workloads reach the cloud")
struct CloudCallerTests {

    /// The two production callers, and the sentence each one is covered by.
    ///
    /// - `FoundationModelsEngine` — the capture arm. "Your words go to the cloud only
    ///   when that quick reading doesn't look good enough." The ONE sanctioned raw-text
    ///   transmission, declared in `PrivacyInfo.xcprivacy` as Other User Content.
    /// - `TaskAdvisorService` — the Advisor. "Only structured task information goes out —
    ///   titles, dates and flags, never your raw notes", which is why its cloud rung is
    ///   handed `.bare` facts (`AdvisorCloudBoundaryTests`).
    private static let declaredCallers = [
        "AI/FoundationModelsEngine.swift",
        "AI/TaskAdvisorService.swift",
    ]

    /// Files that may name the slot without being a caller: they REPLACE it with a guard
    /// so the eval cannot spend, or they only read its identifier for a report.
    private static let allowed = [
        "AI/AppBrain.swift",  // reads `.identifier` for the capture receipt
        "Features/Root/LaunchSeams.swift", "AI/FMDiagnostics.swift",
        "AI/DuplicateSweepEval.swift", "AI/FMPrimitives.swift", "AI/AdvisorBenchmark.swift",
        "AI/QuickCaptureDiagnostics.swift", "AI/AdvisorDiagnostics.swift",
        "AI/CloudModelProvider.swift",  // the slot itself
    ]

    @Test("No third workload opens a cloud session")
    func onlyTheDeclaredWorkloadsReachTheProvider() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        let files =
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

        var openers: [String] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
            // Comments may NAME the slot — the doc comments explaining this rule do.
            // Code may not OPEN a session on it.
            let opensSession = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
                .contains { $0.contains("CloudModel.provider.session(") }
            if opensSession { openers.append(path) }
        }

        let undeclared = openers.filter {
            !Self.declaredCallers.contains($0) && !Self.allowed.contains($0)
        }
        #expect(
            undeclared.isEmpty,
            """
            \(undeclared.joined(separator: ", ")) opens a cloud session, and the privacy \
            screen describes only two workloads that do. Either it is covered by an \
            existing sentence — say which, and add it here — or `DataBoundary` and \
            PrivacyInfo.xcprivacy need a new one before it ships.
            """)
        // And the two that should be there still are: a rename that quietly removed a
        // caller from this list would make the test vacuous.
        for declared in Self.declaredCallers {
            #expect(openers.contains(declared), "\(declared) no longer opens a session — has it moved?")
        }
    }
}
