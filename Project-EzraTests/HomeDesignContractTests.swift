//
//  HomeDesignContractTests.swift
//  Project-EzraTests
//
//  The calm home's design invariants, pinned by grep (2026-09-25): each is the shape of
//  a call site, and no unit test can reach a SwiftUI layout. A property that is the
//  ABSENCE of something — no verb on a quiet row, no container under it, no second
//  accent — has to be pinned this way or it quietly comes back.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("The calm home — design contract")
struct HomeDesignContractTests {

    private func code(_ path: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Project-Ezra").appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    @Test("The verb lives on the hero alone, and the hero is the page's only card")
    func heroOwnsTheVerbAndTheCard() throws {
        let rows = try code("Features/Chat/ChatComponents.swift")
        #expect(rows.contains { $0.contains("guard style == .hero, let gestures") })
        #expect(rows.contains { $0.contains(".opacity(style == .hero ? 1 : 0)") })
        #expect(rows.contains { $0.contains("cornerRadius: Radius.card") })
        #expect(rows.contains { $0.contains(".font(style == .hero ? .heroTitle : .taskTitle)") })
    }

    @Test("The way to the rest is muted: one accent on the page")
    func oneAccent() throws {
        let home = try code("Features/Chat/HouseholdChatView.swift")
        guard let link = home.firstIndex(where: { $0.contains("Text(more)") }) else {
            Issue.record("the more-link is gone")
            return
        }
        let window = home[link..<min(link + 4, home.count)].joined()
        #expect(window.contains("Palette.secondaryText"), "the link must not wear the accent")
        #expect(!window.contains("Palette.accentFlat"))
    }

    @Test("A re-seated opener keeps its id, so the answer animates instead of swapping")
    func stableOpenerIdentity() throws {
        let store = try code("AI/Inquiry.swift")
        #expect(store.contains { $0.contains("let keptID = previous.indices.contains(index)") })
    }

    @Test("The launch settles in order and the news never crossfades")
    func launchOrderAndNoCrossfade() throws {
        let home = try code("Features/Chat/HouseholdChatView.swift")
        #expect(home.contains { $0.contains("Double(message.citedTaskIDs.count + 1) * Motion.staggerStep") })
        #expect(home.contains { $0.contains(".contentTransition(.identity)") })
        let rows = try code("Features/Chat/ChatComponents.swift")
        #expect(rows.contains { $0.contains("? Motion.settle.delay(Double(index) * Motion.staggerStep)") })
        // Never an opacity gate flipped by `onAppear`: a missed appearance stranded the
        // rows invisible on iPad (2026-09-26).
        #expect(!rows.contains { $0.contains(".opacity(heroFirst && !revealed") })
    }

    @Test("Every rise is guarded by Reduce Motion; the fades are not")
    func reduceMotionGuardsEveryOffset() throws {
        for path in ["Features/Chat/ChatComponents.swift", "Features/Chat/HouseholdChatView.swift"] {
            let lines = try code(path)
            for (index, line) in lines.enumerated() where line.contains(".offset(y:") {
                let window = lines[max(0, index - 4)...index].joined()
                #expect(
                    window.contains("reduceMotion"),
                    "\(path):\(index + 1) moves without a Reduce Motion guard")
            }
        }
    }

    @Test("The composer bar carries no implicit animation on its containers")
    func barHasNoImplicitAnimation() throws {
        let rows = try code("Features/Chat/ChatComponents.swift")
        guard let start = rows.firstIndex(where: { $0.contains("struct ChatComposerBar: View") }) else {
            Issue.record("the bar is gone")
            return
        }
        // The struct's own body: up to the next top-level declaration.
        let end =
            rows[(start + 1)...].firstIndex {
                $0.hasPrefix("struct ") || $0.hasPrefix("enum ") || $0.hasPrefix("extension ")
                    || $0.hasPrefix("private struct ") || $0.hasPrefix("#Preview")
            } ?? rows.count
        // Code only: the comment above the body names the modifier it forbids.
        let bar = rows[start..<end].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // Exactly one, and it is the inner control's own fade.
        let animations = bar.components(separatedBy: ".animation(").count - 1
        #expect(animations == 1, "the bar's first layout animates from a pre-layout frame")
        #expect(bar.contains(".animation(Motion.fade, value: showsInnerControl)"))
        #expect(
            !bar.contains("FlowLayout("), "a flow layout in the inset drew its labels at the window origin")
    }

    @Test("Size follows importance: hero, then the bar and suggestions, then rows; the brand is a label")
    func sizeFollowsImportance() throws {
        // The bar is larger than a bare hit target and its orb and send disc scale with it.
        #expect(LayoutMetrics.composerField > LayoutMetrics.hitTarget)
        #expect(LayoutMetrics.composerInnerControl < LayoutMetrics.composerField)
        let rows = try code("Features/Chat/ChatComponents.swift")
        #expect(rows.contains { $0.contains(".font(.suggestion)") })
        #expect(rows.contains { $0.contains("onCapture == nil ? .bodyInput : .composerInput") })
        #expect(rows.contains { $0.contains(".font(.ctaCompact)") }, "the hero's verb is a CTA, not a label")
        let home = try code("Features/Chat/HouseholdChatView.swift")
        #expect(home.contains { $0.contains(".navigationBarTitleDisplayMode(.inline)") })
    }

    @Test(
        "The detail's chips read in importance order, set before empty; the list's counts cut across sections"
    )
    func otherScreensFollowImportance() throws {
        let detail = try code("Features/Detail/TaskDetailView.swift")
        guard let start = detail.firstIndex(where: { $0.contains("if task.dueDate != nil { dueChip }") })
        else {
            Issue.record("WHEN no longer leads the chips")
            return
        }
        let order = detail[start..<min(start + 14, detail.count)].joined(separator: "\n")
        #expect(
            order.contains("if task.dueDate == nil { dueChip }"), "an empty due chip must trail the set ones")
        let counts = try code("Models/TasksPreset.swift").joined(separator: "\n")
        #expect(!counts.contains("kind: .inProgress"), "the IN PROGRESS header already carries that count")
        #expect(!counts.contains("kind: .done"), "the ledger already carries that count")
        let activity = try code("Features/Components/ActivityRow.swift").joined(separator: "\n")
        #expect(
            !activity.contains(".fill(Palette.accentGradient)"),
            "a repeated feed tile is not a high-signal site")
        let chat = try code("Features/Advisor/TaskAdvisorChatView.swift")
        #expect(
            chat.contains { $0.contains("if case .loading = advisorStore.state(for: task) { return false }") }
        )
        // …and the keyboard still treats a loading reading as one on its way (2026-09-26).
        #expect(chat.contains { $0.contains("if !hasOpener && !readingIsLoading { composing = true }") })
        let settings = try code("Features/Settings/SettingsView.swift")
        #expect(settings.contains { $0.contains("AvatarView(profile: profile, size: 52)") })
        let card = try code("Features/Capture/ConfirmCreationCard.swift")
        #expect(card.contains { $0.contains(".font(presentation == .hero ? .navTitle : .sectionHeader)") })
    }

    /// At accessibility sizes a fixed-width neighbour must not squeeze the text that names
    /// the thing (2026-10-03, the /verify AX5 sheet): the list row's WHEN moves under the
    /// title ("Pay th…" beside "1d over"), and the profile photo stacks above the name (a
    /// one-word surname cannot wrap and read "Charles Onyewuen").
    @Test
    func accessibilitySizesGiveTheNameTheWidth() throws {
        let row = try code("Features/Tasks/TaskRow.swift")
        #expect(
            row.contains {
                $0.contains("private var whenStacked: Bool { dynamicTypeSize.isAccessibilitySize }")
            })
        #expect(
            row.contains { $0.contains("if whenStacked { whenLabel }") },
            "stacked, the WHEN reads under the title")
        #expect(row.contains { $0.contains("if !whenStacked { whenLabel") }, "and only there; never twice")
        let settings = try code("Features/Settings/SettingsView.swift").joined(separator: "\n")
        #expect(
            settings.contains("dynamicTypeSize.isAccessibilitySize")
                && settings.contains("AnyLayout(VStackLayout(alignment: .leading"),
            "the profile stacks at accessibility sizes")
    }

    @Test("A commit keeps the reveal on screen while the sheet leaves, and never parks a duplicate")
    func commitDoesNotFlashEmpty() throws {
        let composer = try code("Features/Capture/ComposerView.swift")
        #expect(composer.contains { $0.contains("guard !sessionCommitted else { return }") })
        guard let start = composer.firstIndex(where: { $0.contains("private func finishCommit(count: Int)") })
        else {
            Issue.record("finishCommit is gone")
            return
        }
        let body = composer[start..<min(start + 45, composer.count)].joined(separator: "\n")
        #expect(body.contains("sessionCommitted = true"))
        #expect(
            !body.contains("interpretation = Interpretation()"), "clearing drafts flashes the empty reveal")
    }

    @Test("The home's news line is the last opener, after the person's own lines")
    func newsIsLast() throws {
        let home = try code("Features/Chat/HouseholdChatView.swift")
        guard let news = home.firstIndex(where: { $0.contains("if let news = newsLine(facts)") }),
            let rows = home.firstIndex(where: { $0.contains("ForEach(Array(thread.enumerated())") })
        else {
            Issue.record("the thread or the news line is gone")
            return
        }
        #expect(news > rows, "the news must render after every opener in the thread")
    }

    @Test("The catch-up reads the change log as plain values, never as managed objects")
    func catchUpFetchesValues() throws {
        let home = try code("Features/Chat/HouseholdChatView.swift")
        #expect(home.contains { $0.contains("request.resultType = .dictionaryResultType") })
        #expect(
            !home.contains { $0.contains("NSFetchRequest<ChangeLogEntry>(entityName: \"ChangeLogEntry\")") },
            "strings read off a released managed object crashed the next body pass")
    }

    @Test("Undo is never clipped or covered: fixed-size label, and the list's pill rides above the orb")
    func undoIsReachable() throws {
        let pill = try code("Features/Components/UndoNoticeView.swift").joined(separator: "\n")
        #expect(pill.contains("Text(\"Undo\")"))
        #expect(pill.contains(".fixedSize()"))
        let list = try code("Features/Tasks/TasksHomeView.swift")
        #expect(list.contains { $0.contains("bottomInset: ShellSurfaces<EmptyView>.captureButtonDiameter") })
    }

    @Test("Mark done on the hero holds a beat before the store moves")
    func advanceHoldsABeat() throws {
        let rows = try code("Features/Chat/ChatComponents.swift")
        #expect(rows.contains { $0.contains("try? await Task.sleep(for: .seconds(Motion.completeHold))") })
        #expect(rows.contains { $0.contains("withAnimation(Motion.complete) { completing = true }") })
    }

    @Test("What lands during a look is shown, scrolled to, and metered")
    func landingIsSeen() throws {
        let home = try code("Features/Chat/HouseholdChatView.swift")
        #expect(home.contains { $0.contains("DayAnswer.landed(among: allTasks, since: lookStartedAt") })
        #expect(home.contains { $0.contains("proxy.scrollTo(Self.landedAnchor") })
        #expect(home.contains { $0.contains("Telemetry.log(.captureLandedBelow") })
        #expect(home.contains { $0.contains("lookStartedAt = Date()") })
    }

    /// Every undo marks the entry BEFORE reverting it. A write to a `ChangeLogEntry` after
    /// `ChangeLogUndo.revert` has read its strings snapshots them, the Core Data fault
    /// `TestStore` documents: `CaptureCommitTests.undoLinkedClearsUnblockStamp` crashed
    /// 3/3 in the other order, and `GroupProposalRow`'s undo had it too (2026-10-03).
    @Test
    func undoMarksBeforeItReverts() throws {
        let sites = [
            "Features/Activity/ActivityView.swift", "Features/Activity/ActivityDetailView.swift",
            "Features/Detail/TaskDetailView.swift", "Features/Tasks/GroupProposalRow.swift",
        ]
        for site in sites {
            let lines = try code(site)
            for (i, line) in lines.enumerated() where line.contains("ChangeLogUndo.revert(") {
                let after = lines[(i + 1)..<min(i + 3, lines.count)]
                #expect(
                    !after.contains { $0.contains(".undone = true") },
                    "\(site):\(i + 1) marks the entry undone after reverting it")
            }
        }
    }

}
