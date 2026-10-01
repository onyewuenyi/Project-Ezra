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
    /// The home's ask, so a row can put a question about itself to the household chat —
    /// "Why this first?" on the hero (2026-09-25). Nil where rows cannot ask.
    var onAsk: ((String) -> Void)? = nil
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
    /// The home's day answer (2026-09-23, the calm home): the first row is the HERO —
    /// larger, with the page's one verb — and the rest are quiet rows under a "then, in
    /// order" kicker. Off everywhere else, where rows are references.
    var heroFirst = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far a row rises into place.
    static let riseOffset: CGFloat = 6

    /// A row that arrives rises into place; one that leaves fades. Reduce Motion: fades.
    static func rowTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: riseOffset)), removal: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            switch message.state {
            case .pending:
                ThinkingLine()
                    .padding(.vertical, Spacing.xxs)

            case .sent:
                if !message.text.isEmpty {
                    // Over a hero the sentence is the lead, not the headline: supporting
                    // weight, so the hero's title is the biggest thing under the date.
                    Text(message.text)
                        .font(heroFirst && !citedTasks.isEmpty ? .supporting : .bodyInput)
                        .foregroundStyle(
                            heroFirst && !citedTasks.isEmpty ? Palette.secondaryText : Palette.primaryText
                        )
                        // "4 things" becomes "3 things" by rolling the digit, not by
                        // swapping the sentence — the count is the pace of the morning.
                        .contentTransition(.numericText(countsDown: true))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.trailing, Spacing.xl)
                        .accessibilityLabel("Ezra: \(message.text)")
                }
                if !citedTasks.isEmpty {
                    VStack(alignment: .leading, spacing: heroFirst ? 0 : Spacing.xxs) {
                        ForEach(Array(citedTasks.enumerated()), id: \.element.id) { index, task in
                            let reason = task.uuid.flatMap { message.reasons[$0] }
                            let style: ChatCitedTaskRow.Style =
                                heroFirst ? (index == 0 ? .hero : .quiet) : .reference
                            if heroFirst, index == 1 {
                                Text("Then, in order")
                                    .metadataStyle()
                                    .accessibilityAddTraits(.isHeader)
                                    .padding(.top, Spacing.lg)
                                    .padding(.bottom, Spacing.xs)
                                    .padding(.leading, Spacing.xxs)
                                    .transition(.opacity)
                            }
                            Group {
                                if let gestures {
                                    ChatCitedTaskRow(
                                        task: task, reason: reason, style: style, gestures: gestures,
                                        onOpen: { onOpenTask(task) }
                                    )
                                    .taskSwipeActions(
                                        task: task, allTasks: gestures.allTasks,
                                        currentUserID: gestures.currentUserID, notice: gestures.notice)
                                } else {
                                    ChatCitedTaskRow(task: task, reason: reason, style: style) {
                                        onOpenTask(task)
                                    }
                                }
                            }
                            // The ADVANCE (2026-09-25): a row that leaves fades; a row that
                            // arrives rises 6pt into place; a row that stays slides, because
                            // its identity is its task. Reduce Motion keeps the fade alone.
                            //
                            // The launch stagger rides the SAME insertion, each row's carrying
                            // its own delayed animation (2026-09-26). It used to be an opacity
                            // gate flipped by `onAppear`, and on an iPad whose home first
                            // appeared under a presented sheet the flag never flipped: the lead
                            // and the kicker drew, the hero and every row stayed at zero. A
                            // transition always ends visible, whatever appearance does.
                            .transition(
                                Self.rowTransition(reduceMotion: reduceMotion)
                                    .animation(
                                        heroFirst
                                            ? Motion.settle.delay(Double(index) * Motion.staggerStep)
                                            : Motion.settle))
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
    /// Why this row is in this answer (`ChatMessage.reasons`, 2026-09-23). When present
    /// it is the row's second line — the owner's name still leads it on someone else's
    /// task — and the due label yields to it, because the reason already says when.
    var reason: String? = nil
    /// How the row sits in its answer (2026-09-23, the calm home). `.reference` is the
    /// plain cited row: title, placing, chevron. `.hero` is the day answer's first row —
    /// larger title, the reason at supporting weight, and the page's ONE verb in the
    /// trailing slot. `.quiet` is the rows under it: the reference row with its reason.
    enum Style {
        case reference
        case hero
        case quiet
    }
    var style: Style = .reference
    /// When present, a long-press offers the household's hand-off, and the hero row's
    /// trailing slot is its VERB — the recommended action, run in place. One verb on
    /// the page; "Decide" opens it.
    var gestures: ChatRowGestures? = nil
    let onOpen: () -> Void

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

    private var me: UUID? { profilesResults.first?.linkedMemberID }
    /// The hero's completion beat: the glyph fills, the row dims, the hand feels it,
    /// and only then does the store move — the list row's own choreography.
    @State private var completing = false
    /// Lit while a task that just arrived from capture is on screen (`TaskRow.arrivalWash`).
    @State private var arrivalWash = false

    /// The other live members — the hand-off targets.
    private var others: [FamilyMember] {
        familyMembersResults.filter { !$0.isRemoved && $0.uuid != me }
    }

    /// The owner's name when it is not the person reading — nil for "You", because on
    /// a solo household every row is yours and the caption is noise, and on a shared one
    /// the rows without a name are yours by default (the list's roster-conditional rule).
    private var ownerName: String? {
        guard let owner = task.ownerID, owner != me else { return nil }
        return familyMembersResults.first(where: { $0.uuid == owner })?.name
    }

    private var placing: String? {
        var parts: [String] = []
        if let ownerName {
            parts.append(ownerName)
        } else if task.ownerID != nil, task.ownerID == me, !others.isEmpty, reason == nil {
            parts.append("You")
        }
        if let reason {
            parts.append(reason)
        } else {
            // The ONE due vocabulary, at the row's density — and nil for resolved work,
            // which is what stops a finished task reading "You · in 2d · Done"
            // (2026-09-18): a resolved row is a record, and its due is over.
            if let due = DueLabel.make(for: task, style: .compact) { parts.append(due.text) }
        }
        if task.status.isResolved { parts.append("Done") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The verb the trailing slot shows, when this row carries gestures and the task is
    /// the reader's to advance. A decision's Start reads "Decide" and OPENS the page —
    /// the same carve-out the detail makes — because deciding happens there.
    private var verb: (title: String, symbol: String, action: RecommendedAction?)? {
        guard style == .hero, let gestures, !task.status.isResolved,
            let action = task.recommendedAction(
                among: gestures.allTasks, currentUserID: gestures.currentUserID)
        else { return nil }
        if task.needsDecision, action == .start || action == .resume { return ("Decide", "hand.raised", nil) }
        return (action.title, action.symbol, action)
    }

    var body: some View {
        // Two siblings, not a button in a button: the row opens, the verb acts, and
        // neither steals the other's tap.
        HStack(spacing: Spacing.xs) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.xs) {
                    if completing {
                        Image(systemName: TaskStatus.done.symbol)
                            .font(.glyph(IconSize.action))
                            .foregroundStyle(TaskStatus.done.tint)
                            .glyphColumn(relativeTo: .body)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        // The hero's glyph keeps up with its title (control size, 22pt). Its
                        // column scales along the same curve: a fixed 28pt column let the
                        // grown glyph spill over the title at accessibility sizes. Scoped to
                        // the home's rows — in the Tasks list a wider column starved a title
                        // that shares its line with the marker and the due label.
                        StatusGlyphView(
                            task: task, interactive: false,
                            size: style == .hero ? IconSize.control : IconSize.action
                        )
                        .glyphColumn(relativeTo: style == .hero ? .title2 : .title3)
                    }
                    VStack(alignment: .leading, spacing: style == .hero ? Spacing.xxs : 1) {
                        Text(task.title)
                            .font(style == .hero ? .heroTitle : .taskTitle)
                            // No crossfade when a row becomes the hero: the size steps and
                            // the position slides — two copies of the title for two frames
                            // read worse than one that grows late (frame sheet, 2026-09-25).
                            .contentTransition(.identity)
                            .foregroundStyle(Palette.primaryText)
                            // The list's own rule: one line at reading sizes, two at
                            // accessibility sizes — never fewer than two here, where
                            // the row is an answer and the title is the answer's noun.
                            .lineLimit(
                                max(
                                    style == .hero ? 3 : 2, LayoutMetrics.listTitleLines(for: dynamicTypeSize)
                                ))
                        if let placing {
                            Group {
                                if style == .hero {
                                    Text(placing).supportingStyle()
                                } else {
                                    Text(placing).metadataStyle()
                                }
                            }
                            .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if verb == nil {
                        Image(systemName: "chevron.right")
                            .font(.glyphCaption())
                            .foregroundStyle(Palette.mutedText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(task.title + (placing.map { ", \($0)" } ?? ""))
            .accessibilityHint("Opens the task")
            if let verb {
                verbButton(verb.title, symbol: verb.symbol, action: verb.action)
            }
        }
        .padding(.horizontal, style == .hero ? Spacing.md : Spacing.sm)
        .padding(.vertical, style == .hero ? Spacing.md : Spacing.sm)
        // ONE card on the page (2026-09-25): the hero is contained, the quiet rows and
        // the references are not — the list's own register, where the row's rhythm is
        // its height. Hierarchy by weight and geometry, not by four equal boxes.
        .background(
            ZStack {
                // The one card on the page wears the card radius; the wash under a quiet
                // row keeps the row's smaller one.
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.secondarySurface)
                    .opacity(style == .hero ? 1 : 0)
                // The arrival wash: a task that just landed from capture is lit for the
                // list's own hold, then fades — "see where it landed", never a badge.
                RoundedRectangle(
                    cornerRadius: style == .hero ? Radius.card : Radius.small, style: .continuous
                )
                .fill(Palette.accentSoft)
                .opacity(arrivalWash ? 1 : 0)
            }
        )
        .opacity(completing ? 0.35 : 1)
        .contextMenu {
            if gestures != nil, !task.status.isResolved {
                handOffMenu
            }
        }
        .onAppear {
            guard TaskRow.isFreshArrival(confirmedAt: task.confirmedAt) else { return }
            arrivalWash = true
            withAnimation(Motion.arrivalWashFade.delay(Motion.arrivalWashHold)) { arrivalWash = false }
        }
        .sensoryFeedback(.success, trigger: completing) { _, now in now }
        // A row whose task has since been finished recedes rather than vanishing: the
        // answer stays a record of what was asked, and the row says what happened.
        .recessed(task.status.isResolved)
    }

    /// The verb, as a small capsule inside the row. Tapping it runs the action the
    /// leading swipe runs (`performRecommended`), with the same undo pill; the row's own
    /// tap still opens. Never the gradient: one primary CTA per screen, and the home's
    /// is Send.
    ///
    /// Glyph-only at accessibility sizes: "Mark done" at accessibility-extra-large wrapped
    /// to two lines and squeezed "Pay the water bill" into two and "Cancel unused…" into
    /// an ellipsis — the reveal's add-more row made the same move for the same reason.
    /// The label stays the verb, for VoiceOver.
    private func verbButton(_ title: String, symbol: String, action: RecommendedAction?) -> some View {
        Button {
            guard let gestures else { return }
            guard let action else {
                Telemetry.log(.homeRowActed(verb: .decide))
                onOpen()
                return
            }
            Telemetry.log(.homeRowActed(verb: Self.telemetryVerb(for: action)))
            guard action == .resolve, !completing else {
                performRecommended(
                    action, on: task, in: context, tasks: gestures.allTasks, notice: gestures.notice)
                return
            }
            // Mark done holds a beat so the completion reads before the answer advances.
            withAnimation(Motion.complete) { completing = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Motion.completeHold))
                performRecommended(
                    action, on: task, in: context, tasks: gestures.allTasks, notice: gestures.notice)
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: symbol)
                        .font(.glyphAction(.semibold))
                        .frame(width: LayoutMetrics.hitTarget, height: LayoutMetrics.hitTarget)
                } else {
                    // Rank 1's action, at the compact CTA size with a 36pt capsule
                    // (2026-09-25): it was a 13pt label, smaller than the reason under
                    // the title it acts on.
                    Text(title)
                        .font(.ctaCompact)
                        .fixedSize()
                        .padding(.horizontal, Spacing.md)
                        .frame(minHeight: LayoutMetrics.composerInnerControl)
                }
            }
            .foregroundStyle(Palette.accentFlat)
            .background(Palette.elevatedSurface, in: Capsule())
            .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
        }
        .buttonStyle(.pressableLink)
        .minimumHitTarget()
        .accessibilityLabel(title)
        .accessibilityHint(action == nil ? "Opens the task to decide" : "Runs this now")
    }

    private static func telemetryVerb(for action: RecommendedAction) -> TelemetryRowVerb {
        switch action {
        case .start: return .start
        case .resume: return .resume
        case .resolve: return .markDone
        case .unblock: return .unblock
        case .claim: return .claim
        case .reopen: return .start
        }
    }

    /// The household negotiates here (2026-09-23): "Hand to Maya" for each other member,
    /// or back to the household, through the same logged seam the detail's owner picker
    /// uses — a reversible "assigned" entry, and a pill with the way back.
    @ViewBuilder
    private var handOffMenu: some View {
        // The hero's reason is the AI's judgment in one clause; the whole of it is one
        // question away, and the answer arrives in the thread under the answer it is
        // about. A reasoning question, so the model speaks, with this task in the slice.
        if style == .hero, let ask = gestures?.onAsk {
            Button {
                ask("Why does “\(task.title)” deserve me first?")
            } label: {
                Label("Why this first?", systemImage: "questionmark.circle")
            }
        }
        ForEach(others, id: \.uuid) { member in
            if task.ownerID != member.uuid {
                Button {
                    hand(to: member.uuid, name: member.name)
                } label: {
                    Label("Hand to \(member.name)", systemImage: "arrow.turn.up.right")
                }
            }
        }
        if task.ownerID != nil, task.ownerID != me, me != nil {
            Button {
                hand(to: me, name: "you")
            } label: {
                Label("That's mine", systemImage: "person.crop.circle")
            }
        }
    }

    private func hand(to newOwner: UUID?, name: String) {
        guard let gestures else { return }
        let previous = task.ownerID
        Motion.withMotion(Motion.decide) {
            task.claimAndLog(ownerID: newOwner, among: gestures.allTasks, in: context)
        }
        context.saveChanges()
        let title = task.title
        gestures.notice.wrappedValue = UndoNotice(
            message: name == "you" ? "Took “\(title)”" : "Handed “\(title)” to \(name)",
            undoAction: {
                task.claimAndLog(ownerID: previous, among: gestures.allTasks, in: context)
                context.saveChanges()
            })
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
                        // Wraps when the layout offers less than its ideal width (the
                        // accessibility-size chip); a capsule around two lines still reads.
                        .multilineTextAlignment(.leading)
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
/// compact counts, each the Tasks sheet one tap away, already filtered to that subset
/// (2026-09-23). A number you notice is a number you can open, and "which ones?" is
/// the list's vocabulary, so the strip opens the list; the chips under the day answer
/// stay questions only a judgment answers.
struct ChatSummaryStrip: View {
    let items: [HouseholdChatPrompt.SummaryItem]
    /// A count opens the LIST on its subset (2026-09-23) — never a question.
    let onPick: (HouseholdChatPrompt.SummaryItem) -> Void

    /// A glance is a handful, not a roster: past this the strip stops being one look.
    /// Fewer at accessibility sizes, where six capsules ran to four lines.
    static let cap = 6
    static let accessibilityCap = 4
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var cap: Int { dynamicTypeSize.isAccessibilitySize ? Self.accessibilityCap : Self.cap }

    var body: some View {
        // Wraps, never scrolls: a horizontal strip clipped at the trailing edge showed
        // "29" cut in half and hid the rest (the home, 2026-09-23). Every count on the
        // screen is a count you can read.
        FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
            ForEach(items.prefix(cap), id: \.label) { item in
                Button {
                    onPick(item)
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
                // A 24pt capsule is a count to read; the tap target grows to the
                // HIG minimum without moving a pixel.
                .minimumHitTarget(around: Self.chipHeight)
                .accessibilityLabel(item.label)
                .accessibilityHint("Shows \(item.opens)")
            }
        }
    }

    /// The visual height of one count capsule at the default text size.
    private static let chipHeight: CGFloat = 24
}

// MARK: - The capture offer

/// The line that reads like a to-do, offered back before it is sent anywhere: the
/// words, one sentence, two verbs. Never a guess — both doors stay one tap away.
struct ChatCaptureOffer: View {
    let text: String
    let onAdd: () -> Void
    let onAsk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("“\(text)” reads like something to do, not a question.")
                .font(.bodyInput)
                .foregroundStyle(Palette.primaryText)
            // Side by side while both fit on one line each; stacked at accessibility
            // sizes, where two capsules in a row folded "Add it as a task" into three.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    addButton.fixedSize(); askButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    addButton; askButton
                }
            }
        }
        .padding(Spacing.md)
        .background(
            Palette.secondarySurface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Label("Add it as a task", systemImage: "plus")
                .font(.controlLabel)
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: LayoutMetrics.hitTarget)
                .background(Palette.accentGradient, in: Capsule())
        }
        .buttonStyle(.pressableProminent)
    }

    private var askButton: some View {
        Button(action: onAsk) {
            Text("Ask it anyway")
                .font(.controlLabel)
                .foregroundStyle(Palette.primaryText)
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: LayoutMetrics.hitTarget)
                .background(Palette.elevatedSurface, in: Capsule())
                .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 0.5) }
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Reply landing (announce + feel)

/// The moment an answer lands: VoiceOver hears it, the hand feels it. Attached to the
/// thread by both chats so a reply arriving off-screen or behind the keyboard is
/// never silent for someone who cannot see it land.
private struct ReplyLandingModifier: ViewModifier {
    let messages: [ChatMessage]

    /// The id of the latest SENT advisor line that ANSWERS a question — the value whose
    /// change means "landed". The openers do not count: since Ask became the home
    /// (2026-09-23) they seat at every launch and re-seat whenever the household moves,
    /// each time with fresh ids, and a home that buzzed and announced "Ezra: …" on every
    /// open and every task someone else finished was noise wearing a reply's clothes.
    /// A line only lands when a person asked for it.
    private var latestAnsweredID: UUID? {
        guard let asked = messages.lastIndex(where: { $0.role == .user }) else { return nil }
        return messages[asked...].last { $0.role == .advisor && $0.state == .sent }?.id
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
    /// The capture door, when this bar is the HOME's (2026-09-23). Non-nil renders the
    /// orb as the bar's trailing control — the same `CaptureOrbButton` the shell parks
    /// over the list, at the hit-target size — so the home's two verbs sit in one row:
    /// the field asks, the orb captures, and neither is ever guessed from the other.
    /// The task chat passes nothing and keeps the field alone.
    var onCapture: (() -> Void)? = nil
    /// Quiet suggestions under the field (2026-09-23, the calm home): the questions the
    /// chips used to offer as a section of the thread, now one line of muted text inside
    /// the bar — the way a search field suggests. Empty hides the line.
    var suggestions: [String] = []
    var onSuggestion: (String) -> Void = { _ in }
    var focus: FocusState<Bool>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isReplying
    }

    /// The send / stop control lives INSIDE the field, at its trailing edge, and only
    /// while it has something to do — an empty field is a plain pill with a placeholder,
    /// and the arrow arrives with the first character (the home's bar used to hold a
    /// dimmed arrow beside the pill for the life of the screen).
    private var showsInnerControl: Bool { canSend || isReplying }

    var body: some View {
        // **No implicit `.animation(value:)` on this bar (2026-09-25).** It carried one
        // on `suggestions` and one on `isReplying`, and on every launch the first change
        // of each coincided with the bar's first layout — so the bar ANIMATED from a
        // pre-layout frame: it came up narrow and a third of the way up the screen and
        // slid to the bottom over four frames, on every frame sheet, until both were
        // removed. The inner Send/Stop swap keeps its own fade on the overlay alone.
        VStack(alignment: .leading, spacing: Spacing.xs) {
            fieldRow
            // Hidden while the person types: a suggestion under a half-written question
            // is noise, and the keyboard is already taking the room (2026-09-25).
            if !suggestions.isEmpty, !isReplying, draft.isEmpty {
                // One suggestion at accessibility sizes: two ran to three lines under
                // the field and pushed the answer off the screen.
                let shown = dynamicTypeSize.isAccessibilitySize ? Array(suggestions.prefix(1)) : suggestions
                // A plain stack, one suggestion per line — never `FlowLayout` here. Inside
                // the bottom safe-area inset the flow layout mis-measured on the first
                // pass of every launch: the bar came up a quarter of the screen tall with
                // the field at its top, and the labels were drawn once more at the window
                // origin, for six frames (2026-09-25, frame sheets). Two suggestions never
                // fit one line anyway.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { suggestion in
                        Button {
                            onSuggestion(suggestion)
                        } label: {
                            // A micro arrow says "this sends": muted text alone read as
                            // a caption, not a tap (2026-09-25).
                            // Rank 3 on the home (2026-09-25): body-adjacent, primary
                            // text, the arrow muted so the words carry it.
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.up.forward")
                                    .font(.glyphCaption(.semibold))
                                    .foregroundStyle(Palette.mutedText)
                                Text(suggestion)
                                    .font(.suggestion)
                                    .foregroundStyle(Palette.primaryText)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(minHeight: Self.suggestionHeight)
                        }
                        .buttonStyle(.pressableLink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityHint("Asks this")
                    }
                }
                .padding(.horizontal, Spacing.md)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Suggested questions")
                // A fade when they change inside a transaction (a sent question); never
                // an implicit animation — see the note on `body`.
                .id(shown)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.lg)
        // The field keeps the readable column on a wide screen (the home on iPad);
        // the background and hairline below stay full-bleed.
        .readableWidth()
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .background(Palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 0.5)
        }
    }

    /// The visual height of one suggestion line at the default size.
    /// One suggestion line is a full tap target: the words are the button.
    private static let suggestionHeight: CGFloat = LayoutMetrics.hitTarget

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: Spacing.sm) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(onCapture == nil ? .bodyInput : .composerInput)
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1...5)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit { send() }
                .padding(.leading, Spacing.md + Spacing.xxs)
                .padding(
                    .trailing,
                    showsInnerControl ? innerControlSize + Spacing.sm + Spacing.xs : Spacing.md
                )
                .padding(.vertical, Spacing.xs + 2)
                .frame(minHeight: fieldMinHeight)
                .background(
                    Palette.primarySurface,
                    in: RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsInnerControl {
                        innerControl
                            .padding(.trailing, Spacing.xs)
                            .padding(.bottom, (fieldMinHeight - innerControlSize) / 2)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(Motion.fade, value: showsInnerControl)
                .accessibilityLabel("Your question")

            if let onCapture {
                CaptureOrbButton(
                    diameter: LayoutMetrics.composerField, orbDiameter: LayoutMetrics.composerOrb,
                    action: onCapture
                )
            }
        }
    }

    @ViewBuilder
    private var innerControl: some View {
        if isReplying {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.glyphSmall(.semibold))
                    .foregroundStyle(Palette.primaryText)
                    .frame(width: innerControlSize, height: innerControlSize)
                    .background(Palette.elevatedSurface, in: Circle())
                    .overlay { Circle().strokeBorder(Palette.border, lineWidth: 0.5) }
            }
            .buttonStyle(.pressable)
            .minimumHitTarget(around: innerControlSize)
            .accessibilityLabel("Stop")
            .accessibilityHint("Stops the answer in progress")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.glyphAction(.semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: innerControlSize, height: innerControlSize)
                    .background(Palette.accentGradient, in: Circle())
            }
            .buttonStyle(.pressableProminent)
            .minimumHitTarget(around: innerControlSize)
            .accessibilityLabel("Send")
            .accessibilityHint("Asks Ezra")
        }
    }

    /// The send / stop disc, sized so it sits inside a one-line field with a hairline
    /// of pill around it.
    /// The home's bar (it carries the orb) is sized for rank 2; the task chat keeps the
    /// compact bar it always had.
    private var isHomeBar: Bool { onCapture != nil }
    private var innerControlSize: CGFloat {
        isHomeBar ? LayoutMetrics.composerInnerControl : Self.compactInnerControlSize
    }
    private var fieldMinHeight: CGFloat { isHomeBar ? LayoutMetrics.composerField : LayoutMetrics.hitTarget }
    private static let compactInnerControlSize: CGFloat = 32
    /// A one-line field's height: the pill the orb beside it is measured against, and
    /// the floor the inner control is centred on. Grows with the text, never shrinks.
    /// The orb inside the bar's 44pt disc — the shell's 62/40 bezel ratio, scaled.

    private func send() {
        guard canSend else { return }
        let question = draft
        draft = ""
        onSend(question)
    }
}
