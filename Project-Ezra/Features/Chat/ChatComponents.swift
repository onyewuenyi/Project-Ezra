//
//  ChatComponents.swift
//  Project-Ezra
//
//  The pieces both chats are made of — the task chat (a sheet over one task) and the
//  household chat (the Ask sheet). One vocabulary, so a person who has used one has
//  used the other:
//
//  - The person's lines sit in a bubble, trailing (`elevatedSurface`, the composer
//    radius). Ezra's lines are CONTAINERLESS — the reading's rule, carried over: no
//    bubble, no avatar, no name, no badge saying a model wrote it. Whose turn a line
//    is needs one cue, and the bubble is it.
//  - A reply in flight is the `ThinkingLine` — the mark for a wait the person asked
//    for. Never a typing ellipsis, never a spinner. While it runs, Send becomes STOP:
//    a wait the person asked for is a wait the person may end.
//  - A reply that cites tasks renders them as rows UNDER the sentence, tappable into
//    the task: the answer is the navigation.
//  - Under the latest answer, FOLLOW-UPS: two chips the scope shaped to what was just
//    answered, so the conversation keeps moving without typing.
//  - Failure is one quiet line and a way back. Stopped is not failure and says so.
//    `.unavailable` reads as absence.
//  - A new sitting gets a quiet time divider; a question can be asked again or copied
//    from its bubble.
//  - The composer is the pinned-CTA pattern: solid surface, hairline, rides the
//    keyboard. Send is the surface's one primary action and wears the gradient.
//

import SwiftUI

// MARK: - Lines

struct ChatUserLine: View {
    let text: String
    /// "Ask again" — re-sends this question. Nil hides the item (a reply in flight).
    var onAskAgain: (() -> Void)? = nil

    var body: some View {
        HStack {
            Spacer(minLength: Spacing.xxl)
            Text(text)
                .font(.bodyInput)
                .foregroundStyle(Palette.primaryText)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs + 2)
                .background(
                    Palette.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                )
                .fixedSize(horizontal: false, vertical: true)
                .contextMenu {
                    if let onAskAgain {
                        Button {
                            onAskAgain()
                        } label: {
                            Label("Ask again", systemImage: "arrow.counterclockwise")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(text)")
    }
}

/// What a cited row needs to carry the list's own swipes: the set the recommended
/// action is derived against, who is asking, and the pill a resolution owes.
struct ChatRowGestures {
    let allTasks: [TaskItem]
    let currentUserID: UUID?
    let notice: Binding<UndoNotice?>
}

struct ChatAdvisorLine: View {
    let message: ChatMessage
    /// The cited tasks, resolved by the surface (the store holds ids, never objects).
    var citedTasks: [TaskItem] = []
    /// When present, cited rows carry the record surface's two swipes — the same
    /// channel, the same meaning (`TaskSwipeActions`): leading advances the lifecycle
    /// through the task's own recommended action, trailing cancels. "What's due
    /// today?" becomes a list you can work, not only read.
    var gestures: ChatRowGestures? = nil
    var onOpenTask: (TaskItem) -> Void = { _ in }
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            switch message.state {
            case .pending:
                ThinkingLine()
                    .padding(.vertical, Spacing.xxs)

            case .sent:
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.bodyInput)
                        .foregroundStyle(Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.trailing, Spacing.xl)
                        .accessibilityLabel("Ezra: \(message.text)")
                }
                if !citedTasks.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        ForEach(citedTasks) { task in
                            if let gestures {
                                ChatCitedTaskRow(task: task) { onOpenTask(task) }
                                    .taskSwipeActions(
                                        task: task, allTasks: gestures.allTasks,
                                        currentUserID: gestures.currentUserID, notice: gestures.notice)
                            } else {
                                ChatCitedTaskRow(task: task) { onOpenTask(task) }
                            }
                        }
                    }
                }

            case .failed(let retryable):
                // **The non-retryable arm is a dead end, so it has to point somewhere
                // (2026-09-20).** It read "Not available on this device." — which names
                // a capability the person cannot get, on a phone they already own, and
                // reads like a bug rather than an answer. It is also only half true:
                // every question the deterministic floor can answer — what is due, what
                // is blocked, who has what — is answered instantly on ANY phone, and
                // only an open-ended one ever reaches this line. So say which questions
                // work instead of which phone does.
                Text(
                    retryable
                        ? "That didn't come through."
                        : "I can't work that one out on this phone. Direct questions about your "
                            + "list — what's due, what's blocked, who has what — still work."
                )
                .supportingStyle()
                .fixedSize(horizontal: false, vertical: true)
                if retryable { retryButton }

            case .stopped:
                Text("Stopped.")
                    .supportingStyle()
                retryButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var retryButton: some View {
        Button("Try again", action: onRetry)
            .font(.controlLabel)
            .foregroundStyle(Palette.accentFlat)
            .buttonStyle(.pressableLink)
            .minimumHitTarget()
    }
}

/// A task an answer is about: title, the one fact that places it (owner or when),
/// a chevron. Tappable into the detail — the same vocabulary as the Advisor's
/// "frees up" rows, with a straight chevron because this is a plain reference,
/// not an edge.
struct ChatCitedTaskRow: View {
    @ObservedObject var task: TaskItem
    let onOpen: () -> Void

    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

    private var placing: String? {
        var parts: [String] = []
        if let owner = task.ownerID {
            if owner == profilesResults.first?.linkedMemberID {
                parts.append("You")
            } else if let name = familyMembersResults.first(where: { $0.uuid == owner })?.name {
                parts.append(name)
            }
        }
        // The ONE due vocabulary, at the row's density — and nil for resolved work, which
        // is what stops a finished task reading "You · in 2d · Done" (2026-09-18): a
        // resolved row is a record, and its due is over.
        if let due = DueLabel.make(for: task, style: .compact) { parts.append(due.text) }
        if task.status.isResolved { parts.append("Done") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.xs) {
                StatusGlyphView(task: task, interactive: false, size: IconSize.action)
                    .frame(width: LayoutMetrics.recordGlyphColumn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.taskTitle)
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(2)
                    if let placing {
                        Text(placing)
                            .metadataStyle()
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.glyphCaption())
                    .foregroundStyle(Palette.mutedText)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                Palette.secondarySurface,
                in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // A row whose task has since been finished recedes rather than vanishing: the
        // answer stays a record of what was asked, and the row says what happened.
        .recessed(task.status.isResolved)
        .accessibilityLabel(task.title + (placing.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens the task")
    }
}

// MARK: - Rhythm

/// A quiet timestamp between sittings — "Today 8:00 AM", "Yesterday 6:12 PM",
/// "Tue 2 Sep". Centred, metadata weight, never a card.
/// The day answer's date — "Friday, 4 September" — above the opener, so the first
/// line reads as today's page. Metadata weight, leading, no chrome.
struct ChatDayKicker: View {
    let date: Date

    var body: some View {
        Text(ChatThreadRhythm.dayLabel(for: date).uppercased())
            .font(.chipLabel)
            .tracking(0.6)
            .foregroundStyle(Palette.mutedText)
            .accessibilityLabel(ChatThreadRhythm.dayLabel(for: date))
    }
}

struct ChatTimeDivider: View {
    let date: Date

    var body: some View {
        Text(ChatThreadRhythm.dividerLabel(for: date))
            .metadataStyle()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xxs)
            .accessibilityLabel(ChatThreadRhythm.dividerLabel(for: date))
    }
}

// MARK: - Suggestions

/// Questions as chips — the empty state's starters and, under the latest answer, the
/// scope's follow-ups. Tapping one asks it.
struct ChatStarterChips: View {
    let questions: [String]
    let onPick: (String) -> Void
    /// What VoiceOver calls the group — "Suggested questions" by default.
    var groupLabel = "Suggested questions"

    var body: some View {
        chips
            .accessibilityElement(children: .contain)
            .accessibilityLabel(groupLabel)
    }

    private var chips: some View {
        FlowLayout {
            ForEach(questions, id: \.self) { question in
                Button {
                    onPick(question)
                } label: {
                    Text(question)
                        .font(.controlLabel)
                        .foregroundStyle(Palette.primaryText)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(Palette.secondarySurface, in: Capsule())
                        .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
                }
                .buttonStyle(.pressable)
                .accessibilityHint("Asks this question")
            }
        }
    }
}

/// The household at a glance — "2 overdue · 3 due today · 1 waiting" — as a row of
/// compact counts, each a floor question one tap away. The glance and the ask are the
/// same object, so a number you notice is a number you can open.
struct ChatSummaryStrip: View {
    let items: [HouseholdChatPrompt.SummaryItem]
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(items, id: \.label) { item in
                    Button {
                        onPick(item.question)
                    } label: {
                        Text(item.label)
                            .font(.chipLabel)
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.horizontal, Spacing.xs + 2)
                            .padding(.vertical, Spacing.xxs + 1)
                            .background(Palette.secondarySurface, in: Capsule())
                    }
                    .buttonStyle(.pressableLink)
                    .accessibilityLabel(item.label)
                    .accessibilityHint("Asks: \(item.question)")
                }
            }
        }
        .scrollClipDisabled()
    }
}

// MARK: - Reply landing (announce + feel)

/// The moment an answer lands: VoiceOver hears it, the hand feels it. Attached to the
/// thread by both chats so a reply arriving off-screen or behind the keyboard is
/// never silent for someone who cannot see it land.
private struct ReplyLandingModifier: ViewModifier {
    let messages: [ChatMessage]

    /// The id of the latest SENT advisor line — the value whose change means "landed".
    private var latestAnsweredID: UUID? {
        messages.last { $0.role == .advisor && $0.state == .sent }?.id
    }

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.impact(weight: .light), trigger: latestAnsweredID)
            .onChange(of: latestAnsweredID) { _, id in
                guard let id, let message = messages.first(where: { $0.id == id }), !message.text.isEmpty
                else { return }
                AccessibilityNotification.Announcement("Ezra: \(message.text)").post()
            }
    }
}

extension View {
    func chatReplyLanding(_ messages: [ChatMessage]) -> some View {
        modifier(ReplyLandingModifier(messages: messages))
    }
}

// MARK: - Composer

struct ChatComposerBar: View {
    @Binding var draft: String
    let placeholder: String
    let isReplying: Bool
    let onSend: (String) -> Void
    /// Stop the reply in flight. While a reply is pending Send becomes Stop — the one
    /// control, two verbs, never both at once.
    var onStop: () -> Void = {}
    var focus: FocusState<Bool>.Binding

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isReplying
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.sm) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(.bodyInput)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1...5)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit { send() }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs + 2)
                .background(
                    Palette.primarySurface,
                    in: RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                }
                .accessibilityLabel("Your question")

            if isReplying {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.glyphSmall(.semibold))
                        .foregroundStyle(Palette.primaryText)
                        .frame(width: 36, height: 36)
                        .background(Palette.elevatedSurface, in: Circle())
                        .overlay { Circle().strokeBorder(Palette.border, lineWidth: 0.5) }
                }
                .buttonStyle(.pressable)
                .minimumHitTarget(around: 36)
                .accessibilityLabel("Stop")
                .accessibilityHint("Stops the answer in progress")
                .transition(.opacity)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.glyphAction(.semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Palette.accentGradient, in: Circle())
                }
                .buttonStyle(.pressableProminent)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .scaleEffect(canSend ? 1 : 0.92)
                .animation(Motion.fade, value: canSend)
                .minimumHitTarget(around: 36)
                .accessibilityLabel("Send")
                .accessibilityHint("Asks Ezra")
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: isReplying)
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .background(Palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 0.5)
        }
    }

    private func send() {
        guard canSend else { return }
        let question = draft
        draft = ""
        onSend(question)
    }
}
