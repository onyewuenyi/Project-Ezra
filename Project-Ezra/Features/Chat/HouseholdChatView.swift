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
        NavigationStack {
            thread
                .safeAreaInset(edge: .bottom) {
                    ChatComposerBar(
                        draft: $draft, placeholder: "Ask about anything you've got on",
                        isReplying: store.isReplying, onSend: send, focus: $composing)
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
                .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
                .onAppear {
                    // The person SUMMONED this (F-12: Ask is a sheet, not a tab), so the
                    // keyboard rises with it — the same rule as the task chat with no
                    // reading to read — and the household session warms on the picture
                    // as it stands. The starter chips sit above the keyboard either way.
                    let scope = HouseholdInquiryScope(facts: facts)
                    InquiryService.shared.prewarm(scope)
                    // The unasked turn: Ask opens with the day answer as its first line —
                    // the Brief's job, in the place orientation now lives (G2 · F-11).
                    store.open(scope: scope)
                    composing = true
                    #if DEBUG
                    // Verification seam: `-FocusAsk` raises the keyboard so the bar and
                    // the orb can be checked against it headlessly.
                    if ProcessInfo.processInfo.arguments.contains("-FocusAsk") { composing = true }
                    #endif
                }
        }
    }

    // MARK: - The thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    if store.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.messages) { message in
                            line(message)
                        }
                        // The opener alone is not a conversation yet: keep the chips —
                        // they teach what the floor answers — until the first question.
                        if !store.messages.contains(where: { $0.role == .user }) {
                            ChatStarterChips(questions: HouseholdChatPrompt.starterQuestions(for: facts)) {
                                send($0)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.messages) { _, _ in
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: composing) { _, focused in
                guard focused else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
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

    @ViewBuilder
    private func line(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            ChatUserLine(text: message.text)
                .transition(reduceMotion ? .opacity : Motion.cardEntry)
        case .advisor:
            let cited = citedTasks(message)
            ChatAdvisorLine(
                message: message,
                citedTasks: cited,
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
