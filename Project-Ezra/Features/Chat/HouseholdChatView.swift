//
//  HouseholdChatView.swift
//  Project-Ezra
//
//  The Ask tab — the household you can ask. One conversation over everything the
//  household has on, answered on this device: the floor for the closed questions
//  (instant, exact, with the tasks as rows), the on-device model for the open ones.
//
//  Why a TAB, and the reversal it records: the shell's rule since 2026-08-29 was "the
//  system bar holds Brief · Tasks and never a third tab". The owner reversed that on
//  2026-09-02 for exactly one destination: asking is the third verb of the loop
//  (capture → work → ask), it is not a browsing surface (nothing here is a feed, a
//  badge or a score), and it needs the whole household in scope, which no sheet over
//  one task can hold. A fourth tab is still the wrong answer — see `RootTabView`.
//
//  The surface: a large title, the thread, the starter chips when it is empty, the
//  composer pinned above the bar. Cited rows open the task in the same full-screen
//  pager the list uses, with the answer's rows as the peers — so "what's overdue?"
//  becomes a swipeable stack of exactly those tasks.
//

import CoreData
import SwiftUI

struct HouseholdChatView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.openCapture) private var openCapture
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FetchRequest(sortDescriptors: []) private var allTasksResults: FetchedResults<TaskItem>
    private var allTasks: [TaskItem] { Array(allTasksResults) }
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

    @State private var store = HouseholdChatStore.shared
    @State private var draft = ""
    @State private var sendPulse = 0
    @State private var opened: TaskItem?
    @State private var openedPeers: [TaskItem] = []
    /// The Undo pill for a row swiped from an answer — the same way back the list gives.
    @State private var notice: UndoNotice?
    @State private var stopPulse = 0
    @FocusState private var composing: Bool

    private var currentUserID: UUID? { profilesResults.first?.linkedMemberID }

    /// Rebuilt per render from the live store: cheap (value mapping over the fetch),
    /// and it is what makes an answer always about the household as it is NOW.
    private var facts: HouseholdChatFacts {
        HouseholdChatFacts.make(
            tasks: allTasks, members: Array(familyMembersResults), currentUserID: currentUserID)
    }

    private static let bottomAnchor = "bottom"

    var body: some View {
        // **Built ONCE per render, and handed down.** `facts` is a computed property over
        // the whole fetch, and the render path read it four times — the glance strip, the
        // starter chips, the follow-ups and the empty state — so a full household
        // snapshot was constructed four times per body pass, and `draft` lives in this
        // view, so that happened on every keystroke while somebody typed a question.
        // Same move `TasksHomeView` already makes for its slice, and for the same reason.
        // Event handlers (`onAppear`, `send`, `onRetry`) deliberately keep reading the
        // property: they fire once and must see the household as it is at that moment.
        let facts = self.facts
        return NavigationStack {
            thread(facts)
                .safeAreaInset(edge: .bottom) {
                    ChatComposerBar(
                        draft: $draft, placeholder: "Ask about anything you've got on",
                        isReplying: store.isReplying, onSend: send,
                        onStop: {
                            stopPulse += 1
                            store.cancel(key: HouseholdInquiryScope.singletonKey)
                        },
                        focus: $composing)
                }
                .background(Palette.background)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Ask")
                .toolbar {
                    // A summoned sheet (F-12) closes like one.
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    if !store.messages.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button(role: .destructive) {
                                    store.clear()
                                } label: {
                                    Label("Clear conversation", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .accessibilityLabel("More")
                        }
                    }
                }
                .taskDetailSheet($opened, peers: openedPeers)
                .undoNotice($notice)
                .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
                .sensoryFeedback(.impact(flexibility: .rigid), trigger: stopPulse)
                .chatReplyLanding(store.messages)
                .onAppear {
                    let scope = HouseholdInquiryScope(facts: facts)
                    InquiryService.shared.prewarm(scope)
                    // The unasked turn: Ask opens with the day answer as its first line —
                    // the Brief's job, in the place orientation now lives (G2 · F-11).
                    store.open(scope: scope)
                    // **The keyboard rises only when `open` seated nothing to read.** It
                    // used to rise unconditionally, on the reasoning that a SUMMONED sheet
                    // should be ready to type into — written before the day answer became
                    // its opener, and left standing after. With the opener there it covered
                    // two of the five rows the sheet had just named as what deserves you
                    // first, which is the one thing the person opened it to see. This is
                    // the task chat's rule, and the rule `send` below already applies to
                    // every answer AFTER the first: a floor answer with rows is something
                    // to LOOK at. The starter chips sit above the keyboard either way, so
                    // the empty-household case still lands ready to type.
                    composing = store.messages.isEmpty
                    #if DEBUG
                    // Verification seam: `-FocusAsk` raises the keyboard so the bar and
                    // the orb can be checked against it headlessly.
                    if ProcessInfo.processInfo.arguments.contains("-FocusAsk") { composing = true }
                    #endif
                }
        }
    }

    // MARK: - The thread

    private func thread(_ facts: HouseholdChatFacts) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    if store.messages.isEmpty {
                        emptyState(facts)
                    } else {
                        // The glance: the household's counts as one-tap questions, above
                        // the day answer, until the first question is asked — under the
                        // page's date, so the opener reads as today's.
                        if !hasAsked {
                            ChatDayKicker(date: facts.now)
                            ChatSummaryStrip(items: HouseholdChatPrompt.summary(for: facts)) { send($0) }
                        }
                        ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                            if ChatThreadRhythm.needsDivider(
                                before: message, after: index > 0 ? store.messages[index - 1] : nil)
                            {
                                ChatTimeDivider(date: message.sentAt)
                            }
                            line(message)
                                .id(message.id.uuidString)
                        }
                        // The opener alone is not a conversation yet: keep the chips —
                        // they teach what the floor answers — until the first question.
                        // After one, the scope's FOLLOW-UPS take their place under the
                        // latest answer.
                        if !hasAsked {
                            ChatStarterChips(questions: HouseholdChatPrompt.starterQuestions(for: facts)) {
                                send($0)
                            }
                        } else if case let chips = followUps(facts), !chips.isEmpty {
                            ChatStarterChips(questions: chips) { send($0) }
                                .transition(.opacity)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The list's swipes on cited rows need this OUTSIDE a `List` (iOS 27).
            .swipeActionsContainer()
            .onChange(of: store.messages) { _, _ in
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    proxy.scrollTo(scrollTarget, anchor: scrollTarget == Self.bottomAnchor ? .bottom : .top)
                }
            }
            .onChange(of: composing) { _, focused in
                guard focused else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var hasAsked: Bool { store.messages.contains { $0.role == .user } }

    /// Where the thread scrolls when a line lands. An answer with ROWS scrolls its
    /// QUESTION to the top so the sentence and the rows are read from the top down —
    /// scrolling a six-row answer to its bottom hid the sentence that explained it.
    /// Everything else settles to the bottom.
    private var scrollTarget: String {
        guard let last = store.messages.last, last.role == .advisor, last.state == .sent,
            !last.citedTaskIDs.isEmpty,
            let question = store.messages.last(where: { $0.role == .user })
        else { return Self.bottomAnchor }
        return question.id.uuidString
    }

    /// The scope's follow-ups for the latest ANSWERED question — nothing while a reply
    /// is in flight, nothing that was already asked in this thread.
    private func followUps(_ facts: HouseholdChatFacts) -> [String] {
        guard !store.isReplying, let last = store.messages.last, last.role == .advisor, last.state == .sent,
            let question = store.messages.last(where: { $0.role == .user })?.text
        else { return [] }
        let asked = store.messages.filter { $0.role == .user }.map(\.text)
        return HouseholdInquiryScope(facts: facts).followUps(after: question, asked: asked)
    }

    /// Nothing open and nothing finished: there is nothing to ask about yet, and saying
    /// so with the way in beats three chips that all answer "nothing".
    private func nothingToAsk(_ facts: HouseholdChatFacts) -> Bool {
        facts.open.isEmpty && facts.done.isEmpty
    }

    @ViewBuilder
    private func emptyState(_ facts: HouseholdChatFacts) -> some View {
        if nothingToAsk(facts) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Nothing to ask about yet.")
                    .sectionHeaderStyle()
                Text("Capture something first — then ask what's due, what's stuck, who's carrying what.")
                    .supportingStyle()
                Button {
                    dismiss()
                    openCapture()
                } label: {
                    Label("Capture something", systemImage: "waveform")
                        .font(.controlLabel)
                        .foregroundStyle(Palette.accentFlat)
                        .padding(.horizontal, Spacing.md)
                        .frame(minHeight: LayoutMetrics.hitTarget)
                        .background(Palette.elevatedSurface, in: Capsule())
                        .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
                }
                .buttonStyle(.pressable)
            }
            .padding(.top, Spacing.md)
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(
                    facts.members.count > 1
                        ? "Ask about the whole household." : "Ask about everything you've got on."
                )
                .sectionHeaderStyle()
                Text("What's due, what's stuck, who's carrying what. Everything you ask stays on this device.")
                    .supportingStyle()
                ChatStarterChips(questions: HouseholdChatPrompt.starterQuestions(for: facts)) { question in
                    send(question)
                }
                .padding(.top, Spacing.xs)
            }
            .padding(.top, Spacing.md)
        }
    }

    @ViewBuilder
    private func line(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            ChatUserLine(text: message.text, onAskAgain: store.isReplying ? nil : { send(message.text) })
                .transition(reduceMotion ? .opacity : Motion.cardEntry)
        case .advisor:
            let cited = citedTasks(message)
            ChatAdvisorLine(
                message: message,
                citedTasks: cited,
                gestures: ChatRowGestures(allTasks: allTasks, currentUserID: currentUserID, notice: $notice),
                onOpenTask: { task in
                    openedPeers = cited
                    opened = task
                },
                onRetry: { store.retry(replyID: message.id, facts: facts) }
            )
            .transition(reduceMotion ? .opacity : Motion.cardEntry)
        }
    }

    /// Resolve an answer's citations to live tasks, in the answer's order. A task
    /// that has since been deleted simply drops out of the rows.
    private func citedTasks(_ message: ChatMessage) -> [TaskItem] {
        guard !message.citedTaskIDs.isEmpty else { return [] }
        let byID = Dictionary(
            allTasks.compactMap { task in task.uuid.map { ($0, task) } }, uniquingKeysWith: { a, _ in a })
        return message.citedTaskIDs.compactMap { byID[$0] }
    }

    private func send(_ question: String) {
        guard !store.isReplying,
            !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        sendPulse += 1
        draft = ""
        withAnimation(reduceMotion ? nil : Motion.settle) {
            store.ask(question, facts: facts)
            // An instant answer with rows is something to LOOK at; the keyboard drops
            // so the rows are not behind it. A model answer keeps the keyboard — the
            // person is likely to type the next question while it thinks.
            if store.lastRoute == .floor, store.messages.last?.citedTaskIDs.isEmpty == false {
                composing = false
            }
            // A floor answer SURFACED its rows — orientation's input (F-11). Stamped
            // here because the floor is pure over facts and cannot touch the store.
            if store.lastRoute == .floor, let answer = store.messages.last, answer.role == .advisor {
                let cited = Set(answer.citedTaskIDs)
                for task in allTasks where task.uuid.map(cited.contains) ?? false { task.markSurfaced() }
                if !cited.isEmpty { context.saveChanges() }
            }
        }
    }
}

#Preview("Empty — starter questions") {
    HouseholdChatView()
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
