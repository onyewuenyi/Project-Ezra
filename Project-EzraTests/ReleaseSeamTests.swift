//
//  ReleaseSeamTests.swift
//  Project-EzraTests
//
//  **A verification seam must not exist in the shipped binary.**
//
//  The seams that reach the user's store were guarded on their own argument name and
//  nothing else, which made them safe only for as long as "nobody passes launch
//  arguments to a shipped app" stayed true — a property of how the app is usually
//  started, not of the binary. `-ResetAndSeedEvalCorpus` DESTROYS the store, and it was
//  compiled into Release, so the one path that can wipe a cohort member's real work was
//  reachable in principle and had to be reasoned about rather than ruled out.
//
//  Fenced 2026-09-11 (`docs/cohort0-checklist.md` §7). This pins the fence the way the
//  privacy guarantees next door are pinned — a grep over the source, because the ABSENCE
//  of a compiled path is what a grep can assert and a type system cannot. A test that
//  called the seam would prove nothing: it would run in DEBUG, where the seam is meant
//  to work.
//

import Foundation
import Testing

@Suite("Release hygiene · verification seams are compiled out")
struct ReleaseSeamTests {

    private func shellSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        return try String(
            contentsOf: root.appendingPathComponent("Features/Root/RootTabView.swift"),
            encoding: .utf8)
    }

    /// Every line of a source file, paired with whether it compiles ONLY in DEBUG.
    ///
    /// A stack rather than a counter, because the arms matter: inside `#if DEBUG` the
    /// `#else` half is the RELEASE half, and an unrelated conditional
    /// (`#if targetEnvironment(simulator)`) must neither grant nor revoke the fence. So a
    /// frame is `true` (a DEBUG arm), `false` (an explicit non-DEBUG arm) or nil
    /// (unrelated), and a line is debug-only when some frame says DEBUG and none says
    /// otherwise. The first shape of this counted `#if DEBUG` against `#endif` and got
    /// the answer wrong the moment a `#if !DEBUG` closed a fence it never opened.
    private func debugOnlyByLine(_ source: String) -> [(line: Int, text: String, debugOnly: Bool)] {
        var stack: [Bool?] = []
        var out: [(Int, String, Bool)] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                stack.append(line == "#if DEBUG" ? true : (line == "#if !DEBUG" ? false : nil))
                continue
            }
            if line.hasPrefix("#elseif ") { continue }
            if line == "#else" {
                if let top = stack.popLast() { stack.append(top.map { !$0 }) }
                continue
            }
            if line == "#endif" {
                _ = stack.popLast()
                continue
            }
            let debugOnly = stack.contains(where: { $0 == true }) && !stack.contains(where: { $0 == false })
            out.append((index + 1, line, debugOnly))
        }
        return out
    }

    /// Every launch-argument literal in the shell must sit inside a `#if DEBUG` region.
    ///
    /// Walked over the whole file rather than matched per seam, so a NEW seam is covered
    /// the day it is written instead of the day someone remembers to list it here — which
    /// is the failure mode this test exists for.
    @Test("No launch argument is read outside a DEBUG fence")
    func everyLaunchArgumentIsFenced() throws {
        let leaked = debugOnlyByLine(try shellSource())
            .filter { !$0.debugOnly }
            .filter { $0.text.contains("\"-") && !$0.text.hasPrefix("//") }
            .map { "line \($0.line): \($0.text)" }

        #expect(
            leaked.isEmpty,
            """
            A launch argument is readable in a Release build of RootTabView. Put the seam \
            behind `#if DEBUG` — a seam guarded only on its own name ships:
            \(leaked.joined(separator: "\n"))
            """)
    }

    /// The destructive seam specifically, named — because this is the one whose failure
    /// mode is a cohort member losing their work rather than a screenshot looking wrong.
    @Test("The store-destroying seed is named only inside a DEBUG fence")
    func theDestructiveSeedIsFenced() throws {
        let source = try shellSource()
        // Prose may NAME the seam; code may not READ it — the same distinction
        // `PrivateCaptureEngineTests` draws about the cloud, and for the same reason: the
        // doc comment explaining why the fence exists must sit outside it.
        let mentions = debugOnlyByLine(source)
            .filter { $0.text.contains("\"-ResetAndSeedEvalCorpus\"") }
        // Removing the seam outright also satisfies the guarantee, so absence is a pass.
        for mention in mentions {
            #expect(
                mention.debugOnly,
                "line \(mention.line) names the store-destroying seed outside a DEBUG fence")
        }
        if !mentions.isEmpty {
            #expect(
                source.contains("DataReset.clear"),
                "the seam must keep routing through the backed-up, receipted wipe")
        }
    }
}
