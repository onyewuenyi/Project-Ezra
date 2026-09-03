//
//  ChatComponents.swift
//  Project-Ezra
//
//  The pieces both chats are made of — the task chat (a sheet over one task) and the
//  household chat (the Ask tab). One vocabulary, so a person who has used one has
//  used the other:
//
//  - The person's lines sit in a bubble, trailing (`elevatedSurface`, the composer
//    radius). Ezra's lines are CONTAINERLESS — the reading's rule, carried over: no
//    bubble, no avatar, no name, no badge saying a model wrote it. Whose turn a line
//    is needs one cue, and the bubble is it.
//  - A reply in flight is the `ThinkingLine` — the mark for a wait the person asked
//    for. Never a typing ellipsis, never a spinner.
//  - A reply that cites tasks renders them as rows UNDER the sentence, tappable into
//    the task: the answer is the navigation.
//  - Failure is one quiet line and a way back. `.unavailable` reads as absence.
//  - The composer is the pinned-CTA pattern: solid surface, hairline, rides the
//    keyboard. Send is the surface's one primary action and wears the gradient.
//

import SwiftUI

// MARK: - Lines

struct ChatUserLine: View {
    let text: String

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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(text)")
    }
}

struct ChatAdvisorLine: View {
    let message: ChatMessage
    /// The cited tasks, resolved by the surface (the store holds ids, never objects).
    var citedTasks: [TaskItem] = []
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
                            ChatCitedTaskRow(task: task) { onOpenTask(task) }
                        }
                    }
                }

            case .failed(let retryable):
                Text(retryable ? "That didn't come through." : "Not available on this device.")
                    .supportingStyle()
                if retryable {
                    Button("Try again", action: onRetry)
                        .font(.controlLabel)
                        .foregroundStyle(Palette.accentFlat)
                        .buttonStyle(.pressableLink)
                        .minimumHitTarget()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
        if let due = task.dueDate, let days = TaskItem.daysUntil(due, now: Date()) {
            parts.append(
                days < 0
                    ? "\(-days)d over" : days == 0 ? "Today" : "in \(days)d")
        }
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
        .accessibilityLabel(task.title + (placing.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens the task")
    }
}

// MARK: - Empty state

struct ChatStarterChips: View {
    let questions: [String]
    let onPick: (String) -> Void

    var body: some View {
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

// MARK: - Composer

struct ChatComposerBar: View {
    @Binding var draft: String
    let placeholder: String
    let isReplying: Bool
    let onSend: (String) -> Void
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
            .minimumHitTarget(around: 36)
            .accessibilityLabel("Send")
            .accessibilityHint(isReplying ? "Waiting for the last answer" : "Asks Ezra")
        }
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
