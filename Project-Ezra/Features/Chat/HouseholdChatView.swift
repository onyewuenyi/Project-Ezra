//
//  HouseholdChatView.swift
//  Project-Ezra
//
//  Ask — the household you can ask, and the HOME since 2026-09-23. One conversation
//  over everything the household has on, answered on this device: the floor for the
//  closed questions (instant, exact, with the tasks as rows), the on-device model for
//  the open ones.
//
//  Its history is three reversals. A tab (2026-09-02, the one "third tab" the owner
//  allowed: asking is the third verb of the loop, capture → work → ask), a sheet the
//  same day (a tab is a place you go to talk, the condition of the scoped-conversation
//  fence closest to failing), and now the root — the owner's call over the argument
//  that the list answers a glance and the chat answers a question (`docs/decisions.md`,
//  2026-09-23). What made the swap tenable is that this screen opens ORIENTED, not
//  blank: the unasked turn seats the day answer as its first line, so the resting
//  state is the ranked rows, and the list is one push behind the header's button.
//
//  The surface: a large title, the thread, the starter chips when it is empty, the
//  composer pinned at the bottom with the capture orb as its trailing control (the
//  home's two verbs in one row — the field asks, the orb captures, and the product
//  never guesses which one a sentence was). Cited rows open the task in the same
//  full-screen pager the list uses, with the answer's rows as the peers — so "what's
//  overdue?" becomes a swipeable stack of exactly those tasks.
//
//  No `NavigationStack` of its own: the shell's stack is the one this is the root of,
//  and Tasks and the roster are its pushed destinations.
//

import CoreData
import SwiftUI

struct HouseholdChatView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.openCapture) private var openCapture
    @Environment(\.resumeCapture) private var resumeCapture
    @Environment(\.openActivity) private var openActivity
    @Environment(\.openTasks) private var openTasks
    @Environment(\.openRoster) private var openRoster
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FetchRequest(sortDescriptors: []) private var allTasksResults: FetchedResults<TaskItem>
    private var allTasks: [TaskItem] { Array(allTasksResults) }
    @FetchRequest(sortDescriptors: []) private var familyMembersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: UserProfile.chosenOrder) private var profilesResults: FetchedResults<UserProfile>

    @State private var store = HouseholdChatStore.shared
    @State private var draft = ""
    @State private var sendPulse = 0
    @State private var opened: TaskItem?
    @State private var openedPeers: [TaskItem] = []
    /// The Undo pill for a row swiped from an answer — the same way back the list gives.
    @State private var notice: UndoNotice?
    @State private var stopPulse = 0
    @State private var todayPulse = 0
    /// When this LOOK began — the home's appearance, or the last return to the
    /// foreground. A task confirmed after it is one the person just captured, and the
    /// answer shows it under "Just added" even when rank seats it below the fold
    /// (2026-09-25): the loop is say it, SEE where it landed, done, and a count going
    /// from 19 to 20 is not seeing.
    @State private var lookStartedAt = Date()
    @FocusState private var composing: Bool
    /// When this person last LOOKED at the home — written as the app leaves the
    /// foreground, read on the next one, so "since you last looked" means exactly that.
    /// Per device, never synced: whose look it is, is the point.
    @AppStorage("home.lastLookedAt") private var lastLookedAt: Double = 0
    /// Activity's own watermark (its key keeps its old name on purpose — see
    /// `ActivityView`). Reading the feed IS looking: a person who just closed it does
    /// not need the same acts said again on the home.
    @AppStorage("lastInboxSeenAt") private var lastActivitySeenAt: Double = 0
    /// The second opener, from the change log (`HouseholdCatchUp`), rebuilt on every
    /// foreground and handed to the scope so `open` re-seats the thread with it.
    @State private var catchUp: InquiryAnswer?
    /// A line that read like a to-do, held back from the model until the person says
    /// which door it was for (`CaptureOffer`).
    @State private var captureOffer: String?

    private var currentUserID: UUID? { profilesResults.first?.linkedMemberID }

    /// Rebuilt per render from the live store: cheap (value mapping over the fetch),
    /// and it is what makes an answer always about the household as it is NOW.
    private var facts: HouseholdChatFacts {
        HouseholdChatFacts.make(
            tasks: allTasks, members: Array(familyMembersResults), currentUserID: currentUserID,
            now: Self.homeNow)
    }

    /// The home's clock. `-HomeHour N` (DEBUG) moves it to that hour today, so the
    /// evening voice, the evening recap and the night's quiet are screenshot-reachable
    /// — the simulator's date cannot be moved (2026-09-25). Every other build: now.
    private static var homeNow: Date {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-HomeHour"), args.indices.contains(flag + 1),
            let hour = Int(args[flag + 1]),
            let moved = Calendar.current.date(bySettingHour: hour, minute: 5, second: 0, of: Date())
        {
            return moved
        }
        #endif
        return Date()
    }

    private static let bottomAnchor = "bottom"
    private static let offerAnchor = "offer"
    private static let landedAnchor = "landed"

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
        return thread(facts)
            // The undo pill floats over the THREAD, above the bar: attached outside the
            // inset it landed on the suggestions (2026-09-25).
            .undoNotice($notice)
            .safeAreaInset(edge: .bottom) {
                ChatComposerBar(
                    draft: $draft, placeholder: "Ask about anything you've got on",
                    isReplying: store.isReplying, onSend: { send($0) },
                    onStop: {
                        stopPulse += 1
                        store.cancel(key: HouseholdInquiryScope.singletonKey)
                    },
                    onCapture: openCapture,
                    suggestions: suggestions(facts),
                    onSuggestion: { send($0) },
                    focus: $composing)
            }
            .background(Palette.background)
            .scrollDismissesKeyboard(.interactively)
            // The home carries the product's name, the way a home does; the verb lives in
            // the field's placeholder. "Ask" was the sheet's name (2026-09-02 → 23) and
            // read as a mislabel over the day answer. The date is the NAVIGATION
            // subtitle — native, under the title, one line the thread no longer spends.
            .navigationTitle("Ezra")
            .navigationSubtitle(ChatThreadRhythm.dayLabel(for: facts.now))
            // **Inline, by rank (2026-09-25, the importance audit).** The large title
            // made the brand the biggest text on the home — 34pt over a 22pt hero task —
            // and spent ~100pt of height the answer and the bar needed. The brand is the
            // least useful thing on the screen for a parent at 7am; it keeps its place
            // and its date, at the size a label deserves.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // **The way back to today (2026-09-25).** After one question the home's
                // answer was gone until relaunch, with Clear buried in the "…" menu. A
                // thread now carries a visible return: one word, leading, that clears the
                // thread and re-seats the answer with the same settle a landing uses.
                if hasAsked {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") {
                            todayPulse += 1
                            Telemetry.log(.homeReturned)
                            withAnimation(reduceMotion ? nil : Motion.settle) {
                                store.clear()
                                store.open(scope: HouseholdInquiryScope(facts: facts))
                            }
                        }
                        .accessibilityLabel("Back to today")
                        .accessibilityHint("Clears the conversation and shows what deserves you")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The list, one push away — the button the Ask bubble used to be
                    // in the Tasks header, swapped (2026-09-23). Logged HERE, on the
                    // person's tap, never in the shell's action (the seams push too).
                    Button {
                        Telemetry.log(.tasksOpened)
                        openTasks(.plain)
                    } label: {
                        // Titled, not a bare glyph: the list is the family's second
                        // surface, and a person who never read a HIG should not have to
                        // guess what a checklist icon opens. Text only — a toolbar
                        // renders a `Label` icon-only whatever its style (measured).
                        Text("Tasks")
                    }
                    .accessibilityLabel("Your tasks")

                    Menu {
                        // Only once someone has asked: the openers are not a
                        // conversation, and a home cleared to nothing is a blank home —
                        // so the openers are re-seated the moment the thread is gone.
                        if hasAsked {
                            Button(role: .destructive) {
                                store.clear()
                                store.open(scope: HouseholdInquiryScope(facts: facts))
                            } label: {
                                Label("Clear conversation", systemImage: "trash")
                            }
                        }
                        // The same three the Tasks "…" carries: a home has to reach
                        // Settings, and Activity leads because it is about what the
                        // SYSTEM did.
                        Button {
                            openActivity()
                        } label: {
                            Label("Activity", systemImage: "clock.arrow.circlepath")
                        }
                        Button {
                            openRoster()
                        } label: {
                            Label("Manage Household", systemImage: "person.2")
                        }
                        Button {
                            openSettings()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            .taskDetailSheet($opened, peers: openedPeers)
            .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
            .sensoryFeedback(.impact(flexibility: .rigid), trigger: stopPulse)
            .sensoryFeedback(.impact(weight: .light), trigger: todayPulse)
            .chatReplyLanding(store.messages)
            .onAppear {
                refreshCatchUp(facts: facts)
                let scope = HouseholdInquiryScope(facts: facts)
                InquiryService.shared.prewarm(scope)
                // The unasked turn: Ask opens with the day answer as its first line —
                // the Brief's job, in the place orientation now lives (G2 · F-11).
                store.open(scope: scope)
                // **The home never raises the keyboard at launch.** As a summoned sheet
                // this view rose ready to type when `open` had seated nothing; as the
                // ROOT it appears before a seed or a first sync lands, decided "nothing
                // to read" over an empty store, and the keyboard stood over the day
                // answer that arrived a moment later (fresh-install screenshot,
                // 2026-09-23). A home is a place you arrive at, not a prompt you were
                // handed; the field is one tap away, and `send` still drops the keyboard
                // after a floor answer with rows. `-FocusAsk` is the headless exception.
                composing = false
                #if DEBUG
                // Verification seams: `-FocusAsk` raises the keyboard so the bar and
                // the orb can be checked against it headlessly; `-DraftAsk "text"`
                // prefills the field, so the bar's typing state — Send inside the pill
                // beside the orb — is screenshot-reachable without a keyboard tap.
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-FocusAsk") { composing = true }
                if let flag = args.firstIndex(of: "-DraftAsk"), args.indices.contains(flag + 1) {
                    draft = args[flag + 1]
                    composing = true
                }
                // `-SendAsk "text"` sends through the PERSON's path (`send`), so the
                // capture offer — which `-AskHousehold`'s straight-to-store route never
                // meets — is screenshot-reachable.
                if let flag = args.firstIndex(of: "-SendAsk"), args.indices.contains(flag + 1) {
                    send(args[flag + 1])
                }
                // `-PressHomeVerb` completes the hero's task through the row's own seam a
                // beat after the answer seats (2026-09-25): the advance — the row leaving,
                // the next rising, the count rolling, the undo pill over the bar — is a
                // sequence no synthetic tap can reach.
                if args.contains("-PressHomeVerb") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard let first = store.messages.first?.citedTaskIDs.first,
                            let task = allTasks.first(where: { $0.uuid == first })
                        else { return }
                        withAnimation(Motion.settle) {
                            completeTask(task, in: context, tasks: allTasks, notice: $notice)
                        }
                    }
                }
                #endif
            }
            // **The home re-seats its opener when the household moves.** As a sheet
            // this view appeared after the store had loaded; as the ROOT it can
            // appear before a seed lands (the simulator's `-SeedFlowFixtures`) or
            // before a share's first import, and an opener computed over an empty
            // household stayed empty — the day answer never arrived (found on the
            // first screenshot of the swap, 2026-09-23). `open` already knows the
            // rule: replace the opener while nobody has asked, keep the thread once
            // someone has. The keyboard drops only on the arrival of something to
            // read, never on every later change.
            .onChange(of: facts.stableFingerprint) { _, _ in
                // The trail moved with the household — a seed, a sync, a member's act —
                // so the catch-up is rebuilt before the openers are re-seated.
                refreshCatchUp(facts: self.facts)
                // The answer re-seats with motion: a capture that just landed folds its
                // tasks into the rows in front of the person, settling rather than
                // snapping — see it land, done (2026-09-23).
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    store.open(scope: HouseholdInquiryScope(facts: self.facts))
                }
            }
            // A look ends when the app leaves the foreground, and the next one starts
            // with what happened meanwhile (2026-09-23).
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    lastLookedAt = Date().timeIntervalSinceReferenceDate
                case .active:
                    lookStartedAt = Date()
                    refreshCatchUp(facts: self.facts)
                    withAnimation(reduceMotion ? nil : Motion.settle) {
                        store.open(scope: HouseholdInquiryScope(facts: self.facts))
                    }
                default:
                    break
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
                        let thread = store.messages
                        // The divider reads the PREVIOUS line from the same snapshot the ForEach was
                        // built over, never the live store: the home re-seats its openers when the
                        // household moves (a clear, a sync), the list shrinks mid-render, and an
                        // index taken from the old snapshot trapped on the new list ("Index out of
                        // range", measured on the clear-all path, 2026-09-23).
                        ForEach(Array(thread.enumerated()), id: \.element.id) { index, message in
                            if ChatThreadRhythm.needsDivider(
                                before: message, after: index > 0 ? thread[index - 1] : nil)
                            {
                                ChatTimeDivider(date: message.sentAt)
                            }
                            line(message, hero: index == 0 && !hasAsked)
                                .id(message.id.uuidString)
                            // The way to the rest, in the answer's own words: "and 24
                            // more in Tasks" under the day answer's rows, the shape the
                            // catch-up already uses for Activity. Replaces the strip's
                            // "29 open", which was a total pretending to be a glance.
                            if index == 0, !hasAsked {
                                let below = Group {
                                    if let more = moreInTasks(facts, shown: message.citedTaskIDs.count) {
                                        // Muted, with a chevron: one accent on the page, and it
                                        // is the hero's verb (2026-09-25). The link still reads
                                        // as a way somewhere because it ends in the list's own
                                        // "opens" mark.
                                        Button {
                                            Telemetry.log(.tasksOpened)
                                            openTasks(.plain)
                                        } label: {
                                            HStack(spacing: Spacing.xxs) {
                                                Text(more)
                                                    .font(.controlLabel)
                                                    .foregroundStyle(Palette.secondaryText)
                                                    .contentTransition(.numericText(countsDown: true))
                                                Image(systemName: "chevron.right")
                                                    .font(.glyphMicro(.semibold))
                                                    .foregroundStyle(Palette.mutedText)
                                            }
                                        }
                                        .buttonStyle(.pressableLink)
                                        .minimumHitTarget()
                                        .padding(.leading, Spacing.sm)
                                        .padding(.top, Spacing.xxs)
                                        .accessibilityHint("Opens your tasks")
                                    }
                                    // What landed during this look and did not make the
                                    // rows: named, washed, one kicker, quiet rows with their
                                    // reasons — where the capture went, in the answer's own
                                    // register, until the next look.
                                    let landed = justAdded(facts, shown: Set(message.citedTaskIDs))
                                    if !landed.isEmpty {
                                        // Metered once per landing count, not per render
                                        // (`landedCount`'s change is the trigger below).

                                        Text("Just added")
                                            .metadataStyle()
                                            .accessibilityAddTraits(.isHeader)
                                            .padding(.top, Spacing.lg)
                                            .padding(.bottom, Spacing.xs)
                                            .padding(.leading, Spacing.xxs)
                                            .id(Self.landedAnchor)
                                        ForEach(landed, id: \.0.objectID) { task, reason in
                                            ChatCitedTaskRow(
                                                task: task, reason: reason, style: .quiet,
                                                gestures: ChatRowGestures(
                                                    allTasks: allTasks, currentUserID: currentUserID,
                                                    notice: $notice, onAsk: { send($0) }),
                                                onOpen: {
                                                    openedPeers = landed.map(\.0)
                                                    opened = task
                                                }
                                            )
                                            .taskSwipeActions(
                                                task: task, allTasks: allTasks, currentUserID: currentUserID,
                                                notice: $notice
                                            )
                                            .transition(reduceMotion ? .opacity : Motion.cardEntry)
                                        }
                                    }
                                    // Ezra's own questions — the capture someone left
                                    // unfinished, the grouping sweep's proposal — BELOW the
                                    // answer (2026-09-23, the calm home): worth asking, never
                                    // above the thing that deserves the person first. Each
                                    // renders nothing when there is nothing to ask.
                                    ParkedCapturesRow()
                                    GroupProposalRow(notice: $notice)
                                }
                                // A fade alone: rising as well doubled the text for a frame
                                // against the opener's own entry transition (frame sheet).
                                below
                                    .transition(
                                        .opacity.animation(
                                            Motion.settle.delay(
                                                Double(message.citedTaskIDs.count + 1) * Motion.staggerStep)))
                            }
                        }
                    }
                    if !hasAsked {
                        // The household's news, LAST among the openers (2026-09-26): it sat between
                        // the day answer and the person's own stall line, so a sentence about
                        // someone else outranked one about you. One muted sentence with no
                        // rows: what the others did since this person last
                        // looked, and in the evening what the day closed. Tap →
                        // Activity, where the rows live.
                        if let news = newsLine(facts) {
                            Button {
                                openActivity()
                            } label: {
                                Text(news)
                                    .supportingStyle()
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    // Never crossfaded: a text crossfade inside the
                                    // settle drew the sentence twice for two frames.
                                    .contentTransition(.identity)
                            }
                            .buttonStyle(.pressableLink)
                            .padding(.top, Spacing.sm)
                            .accessibilityHint("Opens Activity")
                            .transition(
                                .opacity.animation(Motion.settle.delay(Double(6) * Motion.staggerStep)))
                        }
                        // The starters and the follow-ups live INSIDE the composer bar now
                        // (`ChatComposerBar.suggestions`, 2026-09-23): one quiet line under
                        // the field instead of a section of the thread.
                    }
                    if let offer = captureOffer {
                        ChatCaptureOffer(
                            text: offer,
                            onAdd: {
                                Telemetry.log(.captureOffer(outcome: .added))
                                captureOffer = nil
                                // Parked as a `Capture` — the shape a dismissed composer
                                // leaves — and resumed, so the person lands on the
                                // reveal with nothing retyped.
                                let capture = Capture(rawText: offer, source: .text, in: context)
                                capture.parkedDrafts = []
                                context.insert(capture)
                                context.saveChanges()
                                resumeCapture(capture)
                            },
                            onAsk: {
                                Telemetry.log(.captureOffer(outcome: .askedAnyway))
                                captureOffer = nil
                                send(offer, force: true)
                            }
                        )
                        .id(Self.offerAnchor)
                        .transition(reduceMotion ? .opacity : Motion.cardEntry)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
                // A column, not a sheet of glass: the home is full-screen on iPad since
                // the swap (2026-09-23), and a day answer whose rows run 1300pt wide is
                // the list's 2026-09-18 defect in a new place.
                .readableWidth()
            }
            // Greedy from the first frame: without an explicit fill the bar pinned by the
            // inset below drew at the TOP of the screen for the first two or three frames
            // of every launch — the orb and the suggestions over the lead sentence, on
            // every frame sheet — while the scroll view was still sizing to its empty
            // content (2026-09-25).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The list's swipes on cited rows need this OUTSIDE a `List` (iOS 27).
            .swipeActionsContainer()
            .onChange(of: store.messages) { _, _ in
                guard let scrollTarget else { return }
                withAnimation(reduceMotion ? nil : Motion.settle) {
                    proxy.scrollTo(scrollTarget, anchor: scrollTarget == Self.bottomAnchor ? .bottom : .top)
                }
            }
            .onChange(of: composing) { _, focused in
                guard focused else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            // The offer lands at the thread's end, past a day answer that can fill the
            // screen exactly; it has to come into view or it was never made.
            // A landing below the fold is not seen: when something new lands, the thread
            // brings "Just added" into view, after the rows above it have settled.
            .onChange(of: landedCount) { before, after in
                guard after > before else { return }
                // How often a capture lands OFF the answer's rows: the number that says
                // whether "Just added" is a corner case or the common case.
                Telemetry.log(.captureLandedBelow(count: CountBucket(after)))
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(reduceMotion ? nil : Motion.settle) {
                        proxy.scrollTo(Self.landedAnchor, anchor: .center)
                    }
                }
            }
            .onChange(of: captureOffer) { _, offer in
                guard offer != nil else { return }
                // After the card AND the rows above it have laid out — a scroll issued
                // in the same pass found the card at zero height, and one 80 ms later
                // was pushed back below the fold by the day answer's rows settling
                // above it (measured at the default size, 2026-09-23).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(reduceMotion ? nil : Motion.settle) {
                        proxy.scrollTo(Self.offerAnchor, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var hasAsked: Bool { store.messages.contains { $0.role == .user } }

    /// What the composer suggests: the judgment questions under a seated day answer,
    /// the floor's starters over an empty thread, the scope's follow-ups after a
    /// question. Nothing while a reply is in flight, nothing when there is nothing to
    /// ask about.
    private func suggestions(_ facts: HouseholdChatFacts) -> [String] {
        if nothingToAsk(facts) { return [] }
        // The Today button already returns the day answer on a thread; offering the
        // same question as a suggestion beside it said one thing twice (2026-09-26).
        if hasAsked { return Array(followUps(facts).prefix(2)) }
        return Array(
            HouseholdChatPrompt.starterQuestions(for: facts, seated: !store.messages.isEmpty).prefix(2))
    }

    /// How many tasks have landed during this look — the trigger for the landing scroll.
    private var landedCount: Int {
        let shown = Set(store.messages.first?.citedTaskIDs ?? [])
        return DayAnswer.landed(among: allTasks, since: lookStartedAt, shown: shown).count
    }

    /// The live tasks confirmed since this look began that the answer did not seat,
    /// newest first, each with the same reason the answer would have given it. Capped
    /// like the answer, so a brain dump of twelve shows the four newest and the count.
    private func justAdded(_ facts: HouseholdChatFacts, shown: Set<UUID>) -> [(TaskItem, String)] {
        let candidates = facts.ranked(for: facts.members.first(where: \.isYou))
        let lines = Dictionary(facts.open.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return DayAnswer.landed(among: allTasks, since: lookStartedAt, shown: shown)
            .map { task in
                let reason = task.uuid.flatMap { lines[$0] }.map {
                    DayAnswer.reason(for: $0, facts: facts, candidates: candidates)
                }
                return (task, reason ?? "Just captured")
            }
    }

    /// The household's news, as one sentence: the catch-up, then in the evening what
    /// the day closed minus anything the catch-up already named. Nil when nothing moved.
    private func newsLine(_ facts: HouseholdChatFacts) -> String? {
        let caughtUp = Set(catchUp?.citedTaskIDs ?? [])
        let parts = [catchUp?.text, DayAnswer.eveningRecap(facts: facts, excluding: caughtUp)?.text]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "and N more in Tasks" — the open count the day answer did not show, for the
    /// person it is about (the opener asks for "me").
    private func moreInTasks(_ facts: HouseholdChatFacts, shown: Int) -> String? {
        DayAnswer.moreInTasks(facts: facts, person: facts.members.first(where: \.isYou), shown: shown)
    }

    /// What the OTHER caretakers did since this person last looked, from the change
    /// log: human acts by someone else, not undone, newest first, capped — and on a
    /// first-ever look, no older than a week. Nothing on a solo household.
    private func refreshCatchUp(facts: HouseholdChatFacts) {
        guard facts.members.count > 1, let me = currentUserID else {
            catchUp = nil
            return
        }
        let now = Date()
        let floor = max(
            lastLookedAt, lastActivitySeenAt,
            now.addingTimeInterval(-Double(HouseholdCatchUp.firstLookWindowDays) * 86_400)
                .timeIntervalSinceReferenceDate)
        // **Plain values, never managed objects (2026-09-26).** This fetched
        // `ChangeLogEntry` objects, read their strings into `catchUp`, and let the
        // objects go; when Core Data unregistered them the strings the state still held
        // pointed at freed snapshot storage, and the next body pass crashed in
        // `initializeWithCopy for InquiryAnswer` (three reports in one hour, plus one in
        // the unregister path itself) — the store's documented teardown-after-read
        // fault. A dictionary fetch creates no objects to tear down, and every string
        // is copied into native Swift storage before it leaves this function.
        let request = NSFetchRequest<NSDictionary>(entityName: "ChangeLogEntry")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["actorID", "action", "taskTitle", "taskUUID", "newValue"]
        request.predicate = NSPredicate(
            format: "timestamp > %@ AND undone == NO AND actorID != nil AND actorID != %@",
            Date(timeIntervalSinceReferenceDate: floor) as NSDate, me as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 20
        let names = Dictionary(facts.members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        func owned(_ value: Any?) -> String? {
            (value as? String).map { String(decoding: Array($0.utf8), as: UTF8.self) }
        }
        let rows = (try? context.fetch(request)) ?? []
        let changes = rows.compactMap { row -> HouseholdCatchUp.Change? in
            guard let actor = row["actorID"] as? UUID, let name = names[actor],
                let title = owned(row["taskTitle"])
            else { return nil }
            let action = owned(row["action"]) ?? ""
            let handed =
                action == "assigned"
                && owned(row["newValue"])?.split(separator: "|").first.map(String.init) == me.uuidString
            return HouseholdCatchUp.Change(
                actorName: name, action: action, taskTitle: title, taskID: row["taskUUID"] as? UUID,
                handedToYou: handed)
        }
        let answer = HouseholdCatchUp.answer(changes)
        if answer != nil, answer != catchUp {
            Telemetry.log(.catchUpSeated(changes: CountBucket(changes.count)))
        }
        catchUp = answer
    }

    /// Where the thread scrolls when a line lands. An answer with ROWS scrolls its
    /// QUESTION to the top so the sentence and the rows are read from the top down —
    /// scrolling a six-row answer to its bottom hid the sentence that explained it.
    /// Everything else settles to the bottom. **The opener scrolls nowhere** (nil): it
    /// has no question above it and the day kicker and glance strip sit above IT, so
    /// the home reads from its top as laid out. At accessibility sizes the day answer
    /// is taller than the screen, and a home that settled to its bottom hid "5 things
    /// deserve you first" and showed the fifth row; scrolling the opener's own line to
    /// the top hid the kicker and the strip instead (both found on the first
    /// accessibility pass of the swap, 2026-09-23).
    private var scrollTarget: String? {
        guard hasAsked else { return nil }
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
        // The Today button already returns the day answer on a thread, so its question
        // counts as asked: offered beside it, it said one thing twice (2026-09-26).
        let asked = store.messages.filter { $0.role == .user }.map(\.text) + ["What deserves me today?"]
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
            // **The empty home is about capture (2026-09-23).** A chat with nothing to
            // ask is the worst first screen a product whose first verb is "tell me" can
            // show; this one opens the relationship the way onboarding did — everything
            // on your mind, one tap, and where those words are read, in the boundary's
            // own words. The CTA wears the gradient because it is the screen's one
            // primary action; the orb stays in the bar, its one home placement.
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Tell me everything on your mind.")
                    .font(.screenTitle)
                    .foregroundStyle(Palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Say it or paste it, all at once. Ezra turns it into tasks you can sort, hand around and ask about."
                )
                .supportingStyle()
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    openCapture()
                } label: {
                    Label("Start talking", systemImage: "waveform")
                        .font(.ctaLabel)
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Spacing.lg)
                        .frame(minHeight: LayoutMetrics.hitTarget + Spacing.xs)
                        .background(Palette.accentGradient, in: Capsule())
                }
                .buttonStyle(.pressableProminent)
                .padding(.top, Spacing.xs)
                Text(DataBoundary.captureShortNow)
                    .metadataStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Spacing.xl)
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(
                    facts.members.count > 1
                        ? "Ask about the whole household." : "Ask about everything you've got on."
                )
                .sectionHeaderStyle()
                Text(
                    "What's due, what's stuck, who's carrying what. Everything you ask stays on this device."
                )
                .supportingStyle()
            }
            .padding(.top, Spacing.md)
        }
    }

    @ViewBuilder
    private func line(_ message: ChatMessage, hero: Bool = false) -> some View {
        switch message.role {
        case .user:
            ChatUserLine(text: message.text, onAskAgain: store.isReplying ? nil : { send(message.text) })
                .transition(reduceMotion ? .opacity : Motion.cardEntry)
        case .advisor:
            let cited = citedTasks(message)
            ChatAdvisorLine(
                message: message,
                citedTasks: cited,
                gestures: ChatRowGestures(
                    allTasks: allTasks, currentUserID: currentUserID, notice: $notice,
                    onAsk: { send($0) }),
                onOpenTask: { task in
                    openedPeers = cited
                    opened = task
                },
                onRetry: { store.retry(replyID: message.id, facts: facts) },
                // The day answer: a hero with the page's one verb, then quiet rows.
                heroFirst: hero
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

    private func send(_ question: String, force: Bool = false) {
        guard !store.isReplying,
            !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // The mode trap: a to-do typed into the question box is offered back, not
        // sent (`CaptureOffer`). `force` is the "ask it anyway" door.
        if !force, CaptureOffer.looksLikeCapture(question) {
            withAnimation(reduceMotion ? nil : Motion.settle) {
                captureOffer = question.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = ""
            }
            return
        }
        sendPulse += 1
        draft = ""
        withAnimation(reduceMotion ? nil : Motion.settle) {
            store.ask(question, facts: facts)
            // The question is the signal the home is judged on (2026-09-23): a home
            // people ask on, or one they pass through on the way to the list.
            Telemetry.log(.askAsked(scope: .household, route: store.lastRoute == .floor ? .floor : .model))
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
    NavigationStack { HouseholdChatView() }
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
