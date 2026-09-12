import Foundation
import Testing

@testable import Project_Ezra

/// **A field nothing writes must not decide anything.**
///
/// Three of the four defects found on 2026-09-12 were one bug wearing three hats: the Brief
/// was cut on 2026-09-02, `deferralCount`'s only writer went with it, and the field kept
/// being READ — by the Advisor's depth router, by the stall sensor's avoidance arm, by the
/// `.dying` headline. Each one silently became a branch that could not fire. The code, the
/// docs and `-AdvisorBenchmark`'s own report all went on describing behaviour the app no
/// longer had, for ten days, with every test green.
///
/// They stayed green because **the tests set the field directly.** A stall test that writes
/// `task.deferralCount = 3` proves the sensor reacts to a number; it says nothing about
/// whether anything in the app can ever produce that number. That is the gap this suite
/// closes: a grep, in the same idiom as the privacy pins, that fails when a field with no
/// writer gains a reader.
///
/// It is deliberately a LIST rather than a clever derivation. "Which fields have no writer"
/// cannot be computed from Swift source without a real index, and a half-working detector
/// here would be one more instrument nobody can trust. A curated table with a reason per
/// entry is honest, and the failure message tells the next person what decision they are
/// actually making.
@Suite("inert signals — fields nothing writes")
struct InertSignalTests {

    /// One field the app can no longer produce a value for, and every file allowed to
    /// mention it.
    private struct InertField {
        let name: String
        /// Why it has no writer.
        let reason: String
        /// Files that may mention it, each for a stated reason: storage, export, the
        /// clearer, and display sites that render it only when non-zero (harmless: the
        /// branch simply never renders). A behavioural READER — anything that changes what
        /// the product decides — does not belong here.
        let allowed: Set<String>
    }

    private let fields: [InertField] = [
        InertField(
            name: "deferralCount",
            reason:
                "its only writer was the Brief's day-rollover; the Brief was cut 2026-09-02. "
                + "The live replacement is TaskItem.recentAbandonedStarts(within:now:).",
            allowed: [
                // Storage and the schema's honest record of it.
                "Models/TaskItem.swift",
                "Models/DataExport.swift",
                // The clearer. Harmless: it sets zero on a field that is already zero.
                "Models/TaskMutations.swift",
                // Carried into the facts and rendered ONLY when non-zero, so these branches
                // are unreachable rather than wrong. They stay because the field is still
                // in the schema and removing it is a schema decision, not a router one.
                "AI/TaskAdvisorFacts.swift",
                "Models/StallDiagnosis.swift",
                "Features/Components/AdvisorView.swift",
                "Features/Detail/TaskDetailView.swift",
                "Features/Advisor/TaskAdvisorChatView.swift",
            ]),
        InertField(
            name: "carriedOverCount",
            reason:
                "the worked-but-unfinished counter, also written only by the Brief's rollover. "
                + "Unlike deferralCount it never had a behavioural reader, so it went inert "
                + "without breaking anything — which is exactly why nobody would notice one "
                + "being added.",
            allowed: ["Models/TaskItem.swift", "Models/DataExport.swift"]),
    ]

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
    }

    /// Comments removed. **Prose may NAME a dead field; code may not read one.** The first
    /// shape of this test matched raw text and duly flagged four files whose only mention
    /// was a doc comment explaining that the field is dead — including this fix's own
    /// explanation of it. `PrivateCaptureEngineTests` records the identical lesson about
    /// its cloud grep, which is a good sign the rule is real and a bad sign about how
    /// easily it is forgotten.
    static func strippingComments(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var blockDepth = 0
        while index < source.endIndex {
            let rest = source[index...]
            if blockDepth > 0 {
                if rest.hasPrefix("/*") {
                    blockDepth += 1
                    index = source.index(index, offsetBy: 2)
                } else if rest.hasPrefix("*/") {
                    blockDepth -= 1
                    index = source.index(index, offsetBy: 2)
                } else {
                    index = source.index(after: index)
                }
                continue
            }
            if rest.hasPrefix("/*") {
                blockDepth = 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            output.append(source[index])
            index = source.index(after: index)
        }
        return output
    }

    private func swiftFiles() throws -> [(path: String, contents: String)] {
        let root = sourceRoot
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var found: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            found.append(
                (relative, Self.strippingComments((try? String(contentsOf: url, encoding: .utf8)) ?? "")))
        }
        return found
    }

    @Test("no new reader appears for a field the app cannot write")
    func inertFieldsGainNoReaders() throws {
        for field in fields {
            let readers = try swiftFiles()
                .filter { $0.contents.contains(field.name) }
                .map(\.path)
            let unexpected = Set(readers).subtracting(field.allowed)
            #expect(
                unexpected.isEmpty,
                """
                `\(field.name)` is INERT — \(field.reason)
                New mention(s) in: \(unexpected.sorted().joined(separator: ", "))
                Reading it will silently do nothing. Either give the field a writer, or read \
                the live signal instead, or add the file here with the reason it is harmless.
                """)
        }
    }

    @Test("the table describes reality — every allowlisted file still mentions its field")
    func allowlistDoesNotRot() throws {
        // The mirror check. Without it the table becomes a graveyard of files that stopped
        // touching the field years ago, and a stale allowlist is a guard with holes in it
        // that nobody can see.
        let files = try swiftFiles()
        for field in fields {
            for allowed in field.allowed {
                let contents = files.first { $0.path == allowed }?.contents
                #expect(
                    contents?.contains(field.name) == true,
                    "\(allowed) no longer mentions `\(field.name)` — drop it from the allowlist")
            }
        }
    }

    @Test("the live replacement is reachable from the app, not just from a test")
    func theReplacementHasAWriter() {
        // The property the dead field lost. `recentAbandonedStarts` derives from
        // `stateTimeline`, which `TaskItem.transition(to:now:)` writes on EVERY status
        // change — so the signal cannot be orphaned the way a standalone counter was,
        // short of the lifecycle itself being removed.
        let task = TaskItem(title: "Sort the loft", status: .todo)
        task.status = .doing
        task.status = .todo
        #expect(
            task.recentAbandonedStarts(within: StallDetector.quietThreshold) == 1,
            "the replacement signal is not being produced by an ordinary status change")
    }
}
