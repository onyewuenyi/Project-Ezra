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
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    private var currentUserID: UUID? { profilesResults.first?.linkedMemberID }

    @State private var store = TaskAdvisorChatStore.shared
    @ObservedObject private var advisorStore = TaskAdvisorStore.shared
    @State private var draft = ""
    @State private var sendPulse = 0
    @State private var actionPulse = 0
    @State private var openedRelated: TaskItem?
    /// An answer's rows become the opened task's peers, so "what's blocking this?"
    /// pages through exactly those — the same move the Ask sheet makes.
    @State private var openedPeers: [TaskItem] = []
    /// The pill for a row swiped HERE. Deliberately not the pager's `notice`: that one
    /// is rendered by the page underneath this sheet, so a cancel swiped on a cited row
    /// would post a way back the person cannot see until they close the chat. Same rule
    /// the Ask sheet follows — the pill belongs to the surface the gesture happened on.
    @State private var rowNotice: UndoNotice?
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

    /// The OPENER's citations — the reading's "frees up" rows.
    private var readingCitedTasks: [TaskItem] {
        switch advisorStore.state(for: task) {
        case .revealed(let reading): resolve(reading.citedTaskIDs)
        case .fallback(let reading): resolve(reading?.citedTaskIDs ?? [])
        default: []
        }
    }

    /// Resolve citation ids to live tasks, in the answer's order. A task that has since
    /// been deleted simply drops out of the rows.
    private func resolve(_ ids: [UUID]) -> [TaskItem] {
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(
            allTasks.compactMap { task in task.uuid.map { ($0, task) } },
            uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    private static let bottomAnchor = "bottom"

    var body: some View {
        NavigationStack {
            thread
                .safeAreaInset(edge: .bottom) {
                    ChatComposerBar(
                        draft: $draft, placeholder: "Ask about this task",
                        isReplying: isReplying, onSend: send,
                        onStop: {
                            actionPulse += 1
                            store.cancel(taskID: task.uuid)
                        },
                        focus: $composing)
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
                .taskDetailSheet($openedRelated, peers: openedPeers)
                .undoNotice($rowNotice)
                .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
                .sensoryFeedback(.impact(flexibility: .soft), trigger: actionPulse)
                .chatReplyLanding(messages)
                // The title answers the button that opened it, and the confirm names what the
                // tap actually DOES — "Decided" would sit one letter from the pinned CTA's
                // "Decide", and "Done" would read as completing the task, which this never does.
                .alert("I've decided", isPresented: $showDecisionPrompt) {
                    TextField("What did you decide? (optional)", text: $decisionChoice)
                    Button("Record") {
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
        // Build the lookup once per render so `line()` doesn't rebuild it per message.
        let byID = Dictionary(
            allTasks.compactMap { t in t.uuid.map { ($0, t) } },
            uniquingKeysWith: { a, _ in a })
        return ScrollViewReader { proxy in
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
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if ChatThreadRhythm.needsDivider(
                                before: message, after: index > 0 ? messages[index - 1] : nil)
                            {
                                ChatTimeDivider(date: message.sentAt)
                            }
                            line(message, byID: byID)
                        }
                        if !followUps.isEmpty {
                            ChatStarterChips(questions: followUps) { send($0) }
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
            // The list's swipes on cited rows need this OUTSIDE a `List` (iOS 27) —
            // without it the gestures are wired and inert, which is the same silent
            // failure as not passing them at all.
            .swipeActionsContainer()
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
        // Captured at render-time so the pager's peers match what was shown, even if the
        // Advisor regenerates between when the row renders and when the person taps it.
        let peers = readingCitedTasks
        return AdvisorView(
            state: advisorStore.state(for: task),
            flagged: task.needsDecision && !task.status.isResolved,
            isJudgmentCall: task.isJudgmentCall,
            deferralCount: Int(task.deferralCount),
            diagnosis: StallDetector.diagnose(task, among: allTasks),
            blockers: task.activeBlockerTasks(among: allTasks),
            // The page's waiting spine is under the sheet, not on it: the rows belong
            // here too.
            blockersRenderedElsewhere: false,
            citedTasks: peers,
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
                openedPeers = []
                openedRelated = blocker
            },
            onDoItNow: { actions.setStatus(.doing) },
            onDefer: { actions.deferWeek() },
            onKill: { actions.setStatus(.canceled) },
            onDismiss: { advisorStore.dismiss(taskID: task.uuid) },
            onOpenCited: { cited in
                actions.followed(.advise)
                openedPeers = peers
                openedRelated = cited
            }
        )
    }

    /// The scope's follow-ups for the latest answered question — nothing while a reply
    /// is in flight, nothing already asked.
    private var followUps: [String] {
        guard !isReplying, let last = messages.last, last.role == .advisor, last.state == .sent,
            let question = messages.last(where: { $0.role == .user })?.text
        else { return [] }
        let asked = messages.filter { $0.role == .user }.map(\.text)
        return TaskInquiryScope(facts: facts)?.followUps(after: question, asked: asked) ?? []
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
    private func line(_ message: ChatMessage, byID: [UUID: TaskItem]) -> some View {
        switch message.role {
        case .user:
            ChatUserLine(text: message.text, onAskAgain: isReplying ? nil : { send(message.text) })
                .transition(reduceMotion ? .opacity : Motion.cardEntry)
        case .advisor:
            let cited = message.citedTaskIDs.compactMap { byID[$0] }
            ChatAdvisorLine(
                message: message,
                citedTasks: cited,
                gestures: ChatRowGestures(
                    allTasks: allTasks, currentUserID: currentUserID, notice: $rowNotice),
                onOpenTask: { related in
                    openedPeers = cited
                    openedRelated = related
                },
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
