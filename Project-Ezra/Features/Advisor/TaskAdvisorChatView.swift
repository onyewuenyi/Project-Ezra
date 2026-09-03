//
//  TaskAdvisorChatView.swift
//  Project-Ezra
//
//  The Advisor chat — a sheet over the task detail where the person asks the Advisor
//  about THIS task and gets a grounded answer. Reached from the pager's toolbar (the
//  "Ask" bubble beside "…") and from the bar's advisor line, never from the page
//  body: the page's one slot below the rule belongs to the obligation block, and
//  the pinned CTA owns the lifecycle.
//
//  **The reading is the conversation's OPENER (2026-09-02).** The ambient judgment
//  used to render as a paragraph in the page body, arriving whenever the model
//  finished — "info that pops up out of nowhere". Now the page carries one line of
//  it in the bar, and the whole reading lives here as Ezra's first turn: the
//  observation, the guidance, "Why this?", and the MOVE with its controls — the
//  options with Choose, the steps with Create, the blocker row. Acting on it runs
//  the same `AdvisorActions` the page would have, and the page underneath re-judges
//  through its `updatedAt` hook, so the opener updates itself the moment the person
//  acts. The reading is not a message the person sent, so it never scrolls away:
//  it sits above the thread, and the thread continues under it.
//
//  Built from the shared chat vocabulary (`ChatComponents.swift`) so it reads exactly
//  like the household chat one tab over.
//

import CoreData
import SwiftUI

struct TaskAdvisorChatView: View {
    @ObservedObject var task: TaskItem
    /// The pager's Undo pill — a resolution or a split made from here owes the same
    /// way back as one made on the page.
    @Binding var notice: UndoNotice?
    /// The task left the working set from inside the chat (done / let go).
    var onResolved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The whole set, for the facts (blockers, dependents, steps are graph questions)
    /// — the same idiom every detail surface uses.
    @FetchRequest(sortDescriptors: []) private var allTasksResults: FetchedResults<TaskItem>
    private var allTasks: [TaskItem] { Array(allTasksResults) }

    @State private var store = TaskAdvisorChatStore.shared
    @ObservedObject private var advisorStore = TaskAdvisorStore.shared
    @State private var draft = ""
    @State private var sendPulse = 0
    @State private var actionPulse = 0
    @State private var openedRelated: TaskItem?
    @State private var showDecisionPrompt = false
    @State private var decisionChoice = ""
    @FocusState private var composing: Bool

    private var messages: [ChatMessage] { store.messages(for: task.uuid) }
    private var isReplying: Bool { store.isReplying(for: task.uuid) }
    private var facts: TaskAdvisorFacts { TaskAdvisorFacts.make(task: task, among: allTasks) }
    private var shape: TaskShape { TaskShape.of(task, among: allTasks) }

    private var actions: AdvisorActions {
        AdvisorActions(
            task: task, allTasks: allTasks, context: context, notice: $notice,
            onResolved: onResolved, pulse: { actionPulse += 1 })
    }

    /// Whether the opener has anything to say: a revealed reading, or a floor reading
    /// with content. A diagnosed stall counts (the fallback template speaks).
    private var hasOpener: Bool {
        AdvisorView.isVisible(
            state: advisorStore.state(for: task), flagged: false,
            diagnosis: StallDetector.diagnose(task, among: allTasks))
    }

    private var citedTasks: [TaskItem] {
        let ids: [UUID]
        switch advisorStore.state(for: task) {
        case .revealed(let reading): ids = reading.citedTaskIDs
        case .fallback(let reading): ids = reading?.citedTaskIDs ?? []
        default: ids = []
        }
        return ids.compactMap { id in allTasks.first { $0.uuid == id } }
    }

    private static let bottomAnchor = "bottom"

    var body: some View {
        NavigationStack {
            thread
                .safeAreaInset(edge: .bottom) {
                    ChatComposerBar(
                        draft: $draft, placeholder: "Ask about this task",
                        isReplying: isReplying, onSend: send, focus: $composing)
                }
                .background(Palette.background)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(task.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    if !messages.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                Button(role: .destructive) {
                                    store.clear(taskID: task.uuid)
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
                // Blocker and cited rows push the related task's own detail, over this
                // sheet — the same nested navigation the page's spine rows use.
                .taskDetailSheet($openedRelated)
                .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
                .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
                .alert("Mark decided", isPresented: $showDecisionPrompt) {
                    TextField("What did you decide? (optional)", text: $decisionChoice)
                    Button("Mark decided") {
                        let trimmed = decisionChoice.trimmingCharacters(in: .whitespacesAndNewlines)
                        actions.markDecided(choice: trimmed.isEmpty ? nil : trimmed)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The outcome goes on the record — notes and the activity trail.")
                }
                .onAppear {
                    // The keyboard rises only when there is nothing to read first: with a
                    // reading waiting, the person came to see it, and the keyboard would
                    // cover the move they came for.
                    if !hasOpener { composing = true }
                    // Warm the session on these facts while they read or type.
                    if let scope = TaskInquiryScope(facts: facts) { InquiryService.shared.prewarm(scope) }
                }
        }
    }

    // MARK: - The thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    if hasOpener {
                        opener
                        if !messages.isEmpty {
                            Rectangle().fill(Palette.border).frame(height: 0.5)
                                .padding(.vertical, Spacing.xs)
                        }
                    }
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { message in
                            line(message)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages) { _, _ in
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: composing) { _, focused in
                guard focused, !messages.isEmpty else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// Ezra's first turn: the reading in full, with its move. Containerless, like
    /// every Ezra line — the intelligence is the sentence being right.
    private var opener: some View {
        AdvisorView(
            state: advisorStore.state(for: task),
            flagged: task.needsDecision && !task.status.isResolved,
            isJudgmentCall: task.isJudgmentCall,
            deferralCount: Int(task.deferralCount),
            diagnosis: StallDetector.diagnose(task, among: allTasks),
            blockers: task.activeBlockerTasks(among: allTasks),
            // The page's waiting spine is under the sheet, not on it: the rows belong
            // here too.
            blockersRenderedElsewhere: false,
            citedTasks: citedTasks,
            showsObligation: false,
            onDecide: { choice in
                if let choice {
                    actions.markDecided(choice: choice)
                } else {
                    decisionChoice = ""
                    showDecisionPrompt = true
                }
            },
            onEscalate: { actions.escalate() },
            onCreateSteps: { accepted, proposed in
                actions.createSteps(accepted: accepted, proposed: proposed)
            },
            onOpenBlocker: { blocker in
                actions.followed(.openBlocker)
                openedRelated = blocker
            },
            onDoItNow: { actions.setStatus(.doing) },
            onDefer: { actions.deferWeek() },
            onKill: { actions.setStatus(.canceled) },
            onDismiss: { advisorStore.dismiss(taskID: task.uuid) },
            onOpenCited: { cited in
                actions.followed(.advise)
                openedRelated = cited
            }
        )
    }

    /// Where the conversation starts: three things worth asking about this task,
    /// from its shape. Under the opener when there is one; alone otherwise.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if !hasOpener {
                Text("Ask about this task.")
                    .sectionHeaderStyle()
                Text("Everything you ask stays on this device.")
                    .supportingStyle()
            }
            ChatStarterChips(questions: TaskAdvisorChatPrompt.starterQuestions(for: facts)) { question in
                send(question)
            }
            .padding(.top, Spacing.xs)
        }
        .padding(.top, hasOpener ? Spacing.xs : Spacing.md)
    }

    @ViewBuilder
    private func line(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            ChatUserLine(text: message.text)
                .transition(reduceMotion ? .opacity : Motion.cardEntry)
        case .advisor:
            ChatAdvisorLine(
                message: message,
                onRetry: { store.retry(replyID: message.id, task: task, among: allTasks) }
            )
            .transition(reduceMotion ? .opacity : Motion.cardEntry)
        }
    }

    private func send(_ question: String) {
        guard !isReplying,
            !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        sendPulse += 1
        draft = ""
        withAnimation(reduceMotion ? nil : Motion.settle) {
            store.ask(question, task: task, among: allTasks)
        }
    }
}

#Preview("Empty — starter questions") {
    @Previewable @State var notice: UndoNotice?
    let context = PersistenceStack.scratch
    let task = TaskItem(
        title: "Renew the car insurance", category: "Admin", status: .todo,
        rawCapture: "renew the car insurance before it lapses", in: context)
    return TaskAdvisorChatView(task: task, notice: $notice)
        .environment(\.managedObjectContext, context)
}
