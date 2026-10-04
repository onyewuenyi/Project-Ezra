//
//  OnboardingView.swift
//  Project-Ezra
//
//  The one screen that earns dramatic, extended motion. The user pastes their
//  existing mess and watches it collapse into a handful of honest, actionable
//  areas — the content hook, the onboarding aha, and the model for the daily
//  brief's generation moment, one piece of craft paying off in three places.
//

import CoreData
import PhotosUI
import SwiftUI

struct OnboardingView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(AppBrain.self) private var brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onComplete: () -> Void

    private enum Phase { case welcome, intro, settling, result }
    @State private var phase: Phase = .welcome
    @State private var text = ""
    @State private var name = ""
    @State private var drafts: [TaskDraft] = []
    /// Lines of the first capture the judge read as nothing to do — a pasted email's
    /// greeting and sign-off. Shown under the areas, one tap from being a task, never
    /// dropped (`CaptureJudge`).
    @State private var leftOut: [String] = []
    /// Set when a transform came back with nothing. The first impression of the product
    /// is this one button; bouncing silently back to the editor reads as a broken app,
    /// not as "there was nothing to find".
    @State private var foundNothing = false
    /// Set when the person gave up on the settling screen and went back to their text.
    /// A separate flag from `foundNothing` because they are different facts and deserve
    /// different sentences: one says the read found nothing, the other says nobody waited.
    @State private var tookTooLong = false
    /// Reveals the settling screen's way out. See `settlingEscapeSeconds`.
    @State private var showSettlingEscape = false
    @FocusState private var focused: Bool
    @FocusState private var nameFocused: Bool
    /// Set when `brain.commit`'s own save reports a dropped write — this is the
    /// very first save a new install performs, with no back edge and no skip, so
    /// silently proceeding to `onComplete()` would land a brand-new co-parent on
    /// an empty app with their first ten tasks gone.
    @State private var showSaveFailedAlert = false
    /// Guards "Manage these for me" against a double-tap calling `brain.commit`
    /// twice on the same drafts — each call mints a fresh `TaskItem` per draft, so
    /// a second firing would duplicate the whole onboarding set, not just fail to
    /// save it.
    @State private var isCommitting = false
    /// The parse receipt for the onboarding capture, held between `transform` and
    /// `commit` so the first capture in the store carries provenance like every other.
    @State private var onboardingReceipt: CaptureRunTelemetry?
    /// The screenshot input (2026-09-12): the launch plan's first screen asks for ONE real
    /// input — a forwarded school email, pasted text, or a screenshot — and the board is
    /// born populated. Text was the only door here; the OCR path the composer already has
    /// (`ImageTextExtractor`) now opens on the first screen too. The bytes are not kept:
    /// onboarding's capture is text, and the composer's `CaptureImageStore` provenance is
    /// for captures a person may want to look back at.
    @State private var screenshotItem: PhotosPickerItem?
    @State private var readingScreenshot = false
    @State private var screenshotFailed = false

    private let sample = """
        renew my passport
        book flights for the trip after passport is done
        oil change is overdue
        should I keep paying for the gym I never use
        call mom back
        daycare enrollment forms due Friday
        finish the Q3 deck
        return the amazon package
        figure out if the side project is still worth it
        pay the water bill
        """

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            switch phase {
            case .welcome: welcome.transition(.opacity)
            case .intro: intro.transition(.opacity)
            case .settling: settling.transition(.opacity)
            case .result: result.transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        // Success notification on the chaos→clarity reveal — a capstone moment.
        .sensoryFeedback(.success, trigger: phase == .result)
        .preferredColorScheme(.dark)
        .task { jumpToResultIfRequested() }
        .alert("Couldn't save", isPresented: $showSaveFailedAlert) {
            Button("Try Again") { retrySave() }
        } message: {
            Text("Your tasks didn't save. Check your storage and try again.")
        }
    }

    /// `-OnboardingResult` jumps straight to the reveal with the sample dump parsed.
    /// The result scene is the product's first impression AND the only screen no
    /// launch arg could reach — every other surface has one, and synthetic taps are
    /// blocked on this host, so it was the one redesign that could only be eyeballed
    /// in code. No effect in a normal run.
    private func jumpToResultIfRequested() {
        #if DEBUG
        // `-OnboardingIntro` stops on the PASTE screen — the one that asks for everything
        // on your mind, and the one that now states where those words are read. It had no
        // seam, so the only way to see it was to type a name and tap Continue, which
        // Accessibility blocks on this host; its layout at accessibility sizes was
        // therefore unreviewable, on the screen with a 220-point editor and two buttons
        // competing for the same room.
        if ProcessInfo.processInfo.arguments.contains("-OnboardingIntro"), phase == .welcome {
            phase = .intro
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("-OnboardingResult"),
            phase == .welcome
        else { return }
        // `-OnboardingResult "text"` reads that text instead of the sample, so a pasted
        // email's left-out lines can be looked at.
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-OnboardingResult"), flag + 1 < args.count,
            !args[flag + 1].hasPrefix("-")
        {
            text = args[flag + 1]
        } else {
            text = sample
        }
        let input = text
        Task {
            await readFirstCapture(input)
            guard !drafts.isEmpty || !leftOut.isEmpty else { return }
            withAnimation(Motion.onboardReveal) { phase = .result }
        }
        #endif
    }

    // MARK: - Welcome
    //
    // Ask for one thing. A consumer app should ask for almost nothing up front — the
    // household, photos, and everyone else are inferred or added later, so this never
    // competes with the chaos→clarity moment that follows it.

    /// **Scrolls, and both answers stay reachable (2026-09-20).** Same shape as the paste
    /// screen next door, same two failures: at accessibility-extra-large with the
    /// keyboard up — which is this screen's RESTING state, because it raises the keyboard
    /// deliberately — "Skip for now" sat against the top edge of the keyboard, and the
    /// subtitle silently truncated to one line for want of a `fixedSize`. The landscape
    /// case is worse still and cannot be rehearsed on this host (no Simulator.app), which
    /// is the other reason the fixed layout had to go: a column that scrolls and a
    /// decision that pins is correct at every height without anybody measuring.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView { welcomeBody }
                .scrollBounceBehavior(.basedOnSize)
            welcomeActions
        }
        .padding(Spacing.lg)
        // **The app's first screen asks one question; the keyboard answers it.**
        // `nameFocused` existed with only its dismiss half wired — it was set false in
        // `finishWelcome` and true nowhere — so a single-field form made every new user
        // tap the field before they could answer it. The composer's rule is that every
        // keyboard raise is a DELIBERATE decision; this is one. After the entrance fade,
        // so the field is settled in place before the keyboard slides under it rather
        // than both moving at once.
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            guard phase == .welcome else { return }
            nameFocused = true
        }
    }

    private var welcomeBody: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("What should I\ncall you?")
                    .heroLargeStyle()
                    .fixedSize(horizontal: false, vertical: true)
                Text("A first name is plenty. You can add your family whenever you like.")
                    .supportingStyle()
                    // Without this it clipped to "A first name is plenty. You…" at
                    // accessibility sizes — the half of the sentence that does the
                    // reassuring is the half that was cut.
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Your name", text: $name)
                .font(.bodyInput)
                .foregroundStyle(Palette.primaryText)
                .textInputAutocapitalization(.words)
                .focused($nameFocused)
                .submitLabel(.continue)
                .onSubmit { finishWelcome() }
                .padding(Spacing.md)
                .background(
                    Palette.primarySurface,
                    in: RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                }

        }
    }

    private var welcomeActions: some View {
        VStack(spacing: Spacing.sm) {
            Group {
                Button {
                    finishWelcome()
                } label: {
                    Text("Continue")
                        .font(.ctaLabel)
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            hasName
                                ? AnyShapeStyle(Palette.accentGradient)
                                : AnyShapeStyle(Palette.secondarySurface),
                            in: Capsule()
                        )
                }
                .buttonStyle(.pressableProminent)
                .disabled(!hasName)

                Button("Skip for now") { finishWelcome() }
                    .font(.ctaCompact.weight(.regular))
                    .foregroundStyle(Palette.secondaryText)
                    .buttonStyle(.pressableLink)
            }
        }
        .padding(.top, Spacing.md)
    }

    private var hasName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Persist the name immediately on leaving this phase, so it survives every exit
    /// from here — Continue, Skip, or "Start empty" further along.
    private func finishWelcome() {
        nameFocused = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let profile = UserProfile.current(in: context)
            profile.displayName = trimmed
            // Ensure the "you" household member exists and carries the entered name, so
            // tasks captured in this same onboarding land owned by a correctly-named you.
            profile.syncIdentity(to: UserProfile.bootstrapIdentity(in: context))
            context.saveChanges()
        }
        withAnimation(.easeInOut(duration: 0.3)) { phase = .intro }
    }

    // MARK: - Intro

    /// **Scrolls, and the two buttons never leave the screen (2026-09-20).** This was one
    /// fixed `VStack` with a `Spacer` at each end and a 220-point editor in the middle.
    /// At accessibility-extra-large it overflowed both ways at once: the hero title ran up
    /// under the status bar and the clock, and "Start empty" — the only way past this
    /// screen for someone with nothing to paste — was off the bottom of the display
    /// entirely, unreachable on the app's second screen. The fix is the ordinary one:
    /// the reading column scrolls, the decision stays pinned to the bottom, and the
    /// editor gives up height at accessibility sizes, where a 220-point box holds barely
    /// two lines anyway and the keyboard covers most of it.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView { introBody }
                .scrollBounceBehavior(.basedOnSize)
            introActions
        }
        .padding(Spacing.lg)
    }

    private var screenshotLink: some View {
        PhotosPicker(selection: $screenshotItem, matching: .images) {
            Label(readingScreenshot ? "Reading…" : "Add a screenshot", systemImage: "photo")
                .font(.supporting.weight(.medium))
                .foregroundStyle(Palette.accentFlat)
        }
        .buttonStyle(.pressableLink)
        .disabled(readingScreenshot)
        .onChange(of: screenshotItem) { _, item in
            guard let item else { return }
            Task {
                await ingestScreenshot(item)
                screenshotItem = nil
            }
        }
    }

    private var sampleLink: some View {
        Button("Use a sample list") { text = sample }
            .font(.supporting.weight(.medium))
            .foregroundStyle(Palette.accentFlat)
            .buttonStyle(.pressableLink)
    }

    /// How tall the paste box should be. At accessibility sizes the screen's scarce
    /// resource is vertical room for TEXT, not for an empty box.
    private var editorHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 132 : 220 }

    private var introBody: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Managing chaos,\neffortlessly")
                    .heroLargeStyle()
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Paste your running mental list — notes, texts to self, that pile of someday-tasks. In one pass it becomes a short, honest set you can actually act on."
                )
                .supportingStyle()
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                    .fill(Palette.primarySurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    }
                if text.isEmpty {
                    Text("Type or paste everything on your mind…")
                        .foregroundStyle(Palette.mutedText)
                        .font(.bodyInput)
                        .padding(.horizontal, Spacing.md + 4)
                        .padding(.vertical, Spacing.md + 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.bodyInput)
                    .foregroundStyle(Palette.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.md)
            }
            .frame(height: editorHeight)

            if tookTooLong {
                Text(
                    "That was taking longer than it should. Your list is still here — try again, or start empty and add things as they come."
                )
                .font(.supporting)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }

            if foundNothing {
                Text(
                    "I couldn't find anything to act on in that. Try listing things as you'd say them — “call mom back”, “pay the water bill” — one per line."
                )
                .font(.supporting)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }

            // Two links, side by side until they cannot be. At accessibility-extra-large
            // the row squeezed "Add a screenshot" into a three-line column that broke the
            // word itself ("screensh / ot"); each link gets the full width instead, which
            // is the same answer `ParkedCapturesRow` and the composer's control row give.
            let secondaryInputs = ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.lg) {
                    screenshotLink; sampleLink
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    screenshotLink; sampleLink
                }
            }
            secondaryInputs
                .frame(maxWidth: .infinity, alignment: .leading)

            if screenshotFailed {
                Text("I couldn't read any text in that image. Try a screenshot of the message itself.")
                    .font(.supporting)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            // **Where these words are read, said here (2026-09-20).** This screen asks
            // for "everything on your mind" and is the single largest block of raw
            // personal text the product will ever receive — and it is pasted by someone
            // who has been using the app for ninety seconds. An unstructured paste is
            // exactly the shape the router escalates, so on a reachable build this is
            // also the first thing that leaves the device. Every other capture surface
            // already states the boundary: Settings carries these sentences in full.
            // Onboarding carried nothing.
            //
            // One sentence, not a control: `DataBoundary.capture` is already the
            // product's approved wording, already names no vendor, and already tells the
            // truth in both directions — on a build with no cloud reachable it says
            // nothing is sent, so nobody is alarmed about something that is not
            // happening. A privacy PICKER here would be a decision asked at the worst
            // possible moment, before the person knows what the app does.
            Text(DataBoundary.captureShort(cloudReachable: CloudModel.isAvailable))
                .font(.metadata)
                .foregroundStyle(Palette.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var introActions: some View {
        VStack(spacing: Spacing.sm) {
            Group {
                Button {
                    Task { await transform() }
                } label: {
                    // Muted while there is nothing to show (2026-09-26): disabled over a
                    // grey capsule, the label stayed full white and read as tappable.
                    Text("Show me")
                        .font(.ctaLabel)
                        .foregroundStyle(canTransform ? Palette.onAccent : Palette.mutedText)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 54)
                        .background(
                            canTransform
                                ? AnyShapeStyle(Palette.accentGradient)
                                : AnyShapeStyle(Palette.secondarySurface),
                            in: Capsule()
                        )
                }
                .buttonStyle(.pressableProminent)
                .disabled(!canTransform)

                Button("Start empty") { onComplete() }
                    .font(.ctaCompact.weight(.regular))
                    .foregroundStyle(Palette.secondaryText)
                    .buttonStyle(.pressableLink)
            }
        }
        .padding(.top, Spacing.md)
    }

    private var canTransform: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The composer's photo path, minus the stored image: OCR the picked screenshot and
    /// land its lines in the editor, where they are the person's to edit before "Show me".
    private func ingestScreenshot(_ item: PhotosPickerItem) async {
        readingScreenshot = true
        screenshotFailed = false
        defer { readingScreenshot = false }
        do {
            let data = try await ModelDeadline.race(timeout: ModelDeadline.photoImportSeconds) {
                try await item.loadTransferable(type: Data.self)
            }
            guard let data, let cgImage = UIImage(data: data)?.cgImage else {
                screenshotFailed = true
                return
            }
            let recognized = try await ModelDeadline.race(timeout: ModelDeadline.photoImportSeconds) {
                try await ImageTextExtractor.text(from: cgImage)
            }
            guard !recognized.isEmpty else {
                screenshotFailed = true
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                text = text.isEmpty ? recognized : text + "\n" + recognized
            }
        } catch {
            screenshotFailed = true
        }
    }

    // MARK: - Settling (the signature precipitation)

    private var settling: some View {
        VStack(spacing: Spacing.lg) {
            SettlingField(animated: !reduceMotion)
                .frame(height: 220)
            Text("Sorting the chaos…")
                .sectionHeaderStyle()
            // **The engine readout was HERE, on screen two (fixed 2026-09-20).** It
            // rendered `brain.status.description` — "Apple Intelligence · on-device", or
            // on an ineligible phone "Rules engine · device not eligible" — to every new
            // user who did not skip. That is the same string Settings removed for
            // breaking the rule that outranks every other line of copy in this product:
            // the customer never hears "AI" or a vendor name. Worse here than there,
            // because it is the opening sentence of the relationship, it names a
            // capability the person has no way to act on, and on the phones that need
            // the most grace it says the device is not good enough. Which engine
            // answered is a developer's question; it is answered in the DEBUG
            // diagnostics card. Nothing replaces it — the wait already has a heading and
            // the settling field, and a second line here would only be filling space.
            #if DEBUG
            Text(brain.status.description)
                .metadataStyle()
            #endif

            // **A way out of the longest wait in the product (2026-09-20).** This screen
            // had no back edge at all, and the budget behind it is the full 30 seconds
            // for an escalated first paste (`ModelDeadline.captureSeconds`). Airplane
            // mode fails fast and is fine; a captive Wi-Fi or a stalled tunnel — the
            // documented bad case — is half a minute of no-exit spinner on the second
            // screen a person ever sees, with their whole mental list inside it. The
            // escape appears late enough that a normal read never shows it, returns to
            // the editor with every word intact, and says which of the two things
            // happened. It does not cancel the read; a late result simply finds the
            // phase moved and lands nowhere, the same guard the microphone uses.
            if showSettlingEscape {
                Button("This is taking a while — go back") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .intro
                        tookTooLong = true
                    }
                }
                .font(.ctaCompact.weight(.regular))
                .foregroundStyle(Palette.secondaryText)
                .buttonStyle(.pressableLink)
                .transition(.opacity)
            }
        }
        .padding(Spacing.xl)
        .task(id: phase) {
            guard phase == .settling else { return }
            showSettlingEscape = false
            try? await Task.sleep(for: .seconds(Self.settlingEscapeSeconds))
            guard phase == .settling else { return }
            withAnimation(Motion.fade) { showSettlingEscape = true }
        }
    }

    /// How long the settling screen waits before offering a way back. Long enough that a
    /// deterministic read (2 ms) and an ordinary escalated one never reach it, short
    /// enough that nobody sits through the 30-second budget with no exit.
    private static let settlingEscapeSeconds = 9.0

    // MARK: - Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header follows the CTA into the emptied state: "I found 0 areas. From
            // 0 items. 0 I'm leaving for you to decide." is technically true and reads
            // like a bug, on the one screen where the user has just deliberately said
            // no to everything.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(
                    drafts.isEmpty
                        ? "Nothing to bring in" : "I found \(areaCount) area\(areaCount == 1 ? "" : "s")"
                )
                .screenTitleStyle()
                Text(resultSubtitle)
                    .supportingStyle()
            }
            .padding(Spacing.lg)

            // The first-ever confirm is a CONFIRM now, not a reveal: every row's title
            // is editable in place, its category is one menu away, and a mis-parse is
            // one ✕ from gone — the minimum viable version of the composer's card
            // contract ("inferred values become visible and editable"). It used to be
            // read-only Text, which meant the single highest-signal batch the learning
            // loop will ever see produced zero Corrections, and the user's first
            // impression of the AI was that it couldn't be corrected at all.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(groupedDrafts, id: \.0) { category, items in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            // A kicker, not a headline (2026-09-26, the importance audit):
                            // the areas were 17pt blue headers over 14pt tasks, so the
                            // grouping outranked the things a parent has to do. The row's
                            // own chip still names and edits the area.
                            HStack(spacing: Spacing.xxs) {
                                Image(systemName: TaskCategory.symbol(for: category))
                                    .font(.glyphCaption())
                                Text(category.uppercased())
                                    .font(.metadata)
                                    .tracking(0.6)
                            }
                            .foregroundStyle(Palette.mutedText)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(items) { draft in
                                if let binding = binding(for: draft) {
                                    resultRow(binding)
                                }
                            }
                        }
                    }
                    leftOutSection
                }
                .padding(.horizontal, Spacing.lg)
            }

            // The CTA changes identity rather than going dead. Every row here is one ✕
            // from gone, and this scene has no other control — no back edge, no skip,
            // and it sits in a `fullScreenCover` with no interactive dismissal. So
            // removing the last row used to leave a first-run user staring at "I found
            // 0 areas" and a greyed-out button, with no way forward OR back.
            //
            // `.intro` already solved this: its disabled "Show me" is always paired with
            // a live "Start empty". Here there is only one slot, so the slot moves.
            VStack(spacing: Spacing.xs) {
                Button {
                    if drafts.isEmpty { onComplete() } else { commit() }
                } label: {
                    Text(drafts.isEmpty ? "Start empty" : "Manage these for me")
                        .font(.ctaLabel)
                        .foregroundStyle(
                            drafts.isEmpty ? Palette.secondaryText : Palette.onAccent
                        )
                        // Inset from the capsule and allowed to shrink a little
                        // (2026-09-26): at accessibility sizes the label ran to the
                        // capsule's edges. The capsule grows to a second line after that.
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 54)
                        .background(
                            drafts.isEmpty
                                ? AnyShapeStyle(Palette.secondarySurface)
                                : AnyShapeStyle(Palette.accentGradient),
                            in: Capsule()
                        )
                }
                .buttonStyle(.pressableProminent)
                .disabled(isCommitting)
            }
            .padding(Spacing.lg)
        }
    }

    /// One editable result row: category menu (the chip), inline title, judgment
    /// chip, remove. Edits diff against `aiOriginal` at commit exactly like the
    /// composer's card — the corrections loop now starts at minute one.
    private func resultRow(_ draft: Binding<TaskDraft>) -> some View {
        // First-baseline alignment, not top: the chips carry an invisible 44pt touch
        // region that centers their capsule, so `.top` left the glyph hanging half a
        // line below the title it belongs to.
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Menu {
                ForEach(TaskCategory.all, id: \.self) { category in
                    Button {
                        draft.wrappedValue.category = category
                        draft.wrappedValue.markEdited(.category)
                    } label: {
                        Label(category, systemImage: TaskCategory.symbol(for: category))
                    }
                }
            } label: {
                MetadataChip(density: .compact) {
                    Image(systemName: TaskCategory.symbol(for: draft.wrappedValue.category))
                        .font(.glyphCaption())
                }
                .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityLabel("Category, \(draft.wrappedValue.category)")

            // Title takes the full row width; the flag sits UNDER it. Side by side,
            // the chip squeezed a long title into a narrow three-line column — the
            // judgment calls are exactly the longest titles ("figure out if the side
            // project is still worth it"), so the two fought hardest precisely where
            // legibility mattered most.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                TextField(
                    "Task",
                    text: Binding(
                        get: { draft.wrappedValue.title },
                        set: {
                            draft.wrappedValue.title = $0
                            draft.wrappedValue.markEdited(.title)
                        }),
                    axis: .vertical
                )
                .font(.taskTitle)
                .foregroundStyle(Palette.primaryText)

                if draft.wrappedValue.isJudgmentCall {
                    AssessmentChip(
                        assessment: TaskAssessment(
                            needsDecision: .humanJudgment, isBlocked: false,
                            isUnowned: false, isStale: false, tier: .ask))
                }
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(Motion.respecting(Motion.decide)) {
                    drafts.removeAll { $0.id == draft.wrappedValue.id }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.glyphCaption(.semibold))
                    .foregroundStyle(Palette.mutedText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel("Remove \(draft.wrappedValue.title)")
        }
    }

    private func binding(for draft: TaskDraft) -> Binding<TaskDraft>? {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return nil }
        return $drafts[index]
    }

    private var groupedDrafts: [(String, [TaskDraft])] {
        Dictionary(grouping: drafts, by: \.category)
            .map { ($0.key, $0.value) }
            .sorted { $0.1.count > $1.1.count }
    }
    private var areaCount: Int { Set(drafts.map(\.category)).count }

    private var resultSubtitle: String {
        // "0 I'm leaving for you to decide" is true and reads like a bug.
        let decide = judgmentCount == 0 ? "" : " \(judgmentCount) I'm leaving for you to decide."
        let aside =
            leftOut.isEmpty ? "" : " \(leftOut.count) line\(leftOut.count == 1 ? "" : "s") left out, below."
        if drafts.isEmpty {
            return leftOut.isEmpty
                ? "You cleared them all. You can start from an empty slate and capture as things come up."
                : "Nothing in that reads like a to-do.\(aside) Tap one to keep it."
        }
        return
            "From \(drafts.count) item\(drafts.count == 1 ? "" : "s").\(decide)\(aside)"
    }

    /// The first capture's left-out lines, kept in sight with a one-tap way back — the
    /// composer's row, in onboarding's register.
    @ViewBuilder private var leftOutSection: some View {
        if !leftOut.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("LEFT OUT")
                    .font(.metadata)
                    .tracking(0.6)
                    .foregroundStyle(Palette.mutedText)
                    .accessibilityAddTraits(.isHeader)
                ForEach(leftOut, id: \.self) { line in
                    Button {
                        guard let draft = CaptureFlow.keepAsOneTask(text: line) else { return }
                        withAnimation(Motion.respecting(Motion.settle)) {
                            leftOut.removeAll { $0 == line }
                            drafts.append(draft)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            Image(systemName: "plus.circle")
                                .font(.glyphCaption())
                                .foregroundStyle(Palette.accentFlat)
                            Text("“\(line)”")
                                .font(.supporting)
                                .foregroundStyle(Palette.secondaryText)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: LayoutMetrics.hitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Left out: \(line)")
                    .accessibilityHint("Adds it as a task")
                }
            }
        }
    }
    private var judgmentCount: Int { drafts.filter(\.isJudgmentCall).count }

    // MARK: - Flow

    /// The seam's path to the same read `transform` uses.
    private func readFirstCapture(_ input: String) async {
        let reading = await CaptureJudge.readCapture(
            input, modelAvailable: PrivateCaptureEngine.modelAvailable())
        apply(reading, for: input)
    }

    /// Hold the reading and its receipt — the first capture in the store carries
    /// provenance like every other.
    private func apply(_ reading: CaptureJudge.CaptureReading, for input: String) {
        drafts = reading.drafts
        leftOut = reading.leftOut
        var receipt = CaptureRunTelemetry.local(
            segmentation: Segmentation.structure(of: input).label, cloudAvailable: false)
        receipt.engineName = reading.engineName
        receipt.rung =
            (reading.engineName == "deterministic" ? IntelligenceRung.facts : .onDevice).rawValue
        onboardingReceipt = receipt
    }

    private func transform() async {
        focused = false
        foundNothing = false
        tookTooLong = false
        withAnimation(.easeInOut(duration: 0.3)) { phase = .settling }
        // The same on-device read the composer gives (`CaptureJudge.readCapture`): the
        // read makes the pieces, the judge says what each doubtful one is, and a pasted
        // email's greeting and sign-off are set aside instead of becoming a new user's
        // first tasks. Nothing leaves the device.
        Telemetry.log(.captureStarted(channel: .onboarding))
        let reading = await CaptureJudge.readCapture(
            text, modelAvailable: PrivateCaptureEngine.modelAvailable())
        // The person stopped waiting and went back to their text. Their words are on
        // screen and theirs to edit; revealing a result over the top of that now would
        // take the screen back off them.
        guard phase == .settling else { return }
        apply(reading, for: text)
        // Nothing actionable found: return to the editor with the text intact rather
        // than revealing an empty "0 areas" result (input is never discarded) — and SAY
        // so, because an unexplained bounce back to the same screen is indistinguishable
        // from the button not working.
        guard !drafts.isEmpty || !leftOut.isEmpty else {
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = .intro
                foundNothing = true
            }
            return
        }
        // Hold the settle beat briefly so the motion reads (this is the earned moment).
        try? await Task.sleep(nanoseconds: reduceMotion ? 200_000_000 : 1_400_000_000)
        withAnimation(Motion.onboardReveal) { phase = .result }
    }

    private func commit() {
        guard !isCommitting else { return }
        isCommitting = true
        brain.commit(drafts, rawCapture: text, telemetry: onboardingReceipt, into: context)
        // The onboarding reveal ("here.s your mess, sorted") doubles as the
        // Confirm-Creation glance — the user saw the set and tapped through, and
        // `commit` is what brings the tasks into existence.
        finishCommit()
    }

    /// `commit` already saves internally — see `AppBrain.commit`. This checks
    /// that save's own outcome (`saveFailed`) rather than proceeding regardless,
    /// since this screen has no back edge: a dropped save here would otherwise
    /// hand a brand-new user an empty app with no sign their tasks never landed.
    private func finishCommit() {
        guard brain.lastCommitSummary?.saveFailed != true else {
            showSaveFailedAlert = true
            return
        }
        onComplete()
    }

    /// "Try Again" on the save-failed alert. `context.saveChanges()` never rolls
    /// back on failure, so the drafts committed above are still pending — this
    /// just asks the store to try the same write again.
    private func retrySave() {
        let saved = context.saveChanges()
        brain.lastCommitSummary?.saveFailed = !saved
        finishCommit()
    }
}

/// The chaos→clarity precipitation: a diffuse field condenses and settles. Uses
/// onboarding-tier spring values; this is the one animation worth obsessing over.
private struct SettlingField: View {
    let animated: Bool
    @State private var settled = false

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                Circle()
                    .fill(i.isMultiple(of: 2) ? Palette.accentStart : Palette.accentEnd)
                    .frame(width: 14, height: 14)
                    .blur(radius: settled ? 0.5 : 6)
                    .opacity(settled ? 0.9 : 0.4)
                    .offset(
                        x: settled ? CGFloat((i % 5) - 2) * 40 : CGFloat((i * 37) % 200 - 100),
                        y: settled ? CGFloat((i / 5) - 1) * 46 : CGFloat((i * 53) % 200 - 100)
                    )
                    .animation(
                        Motion.onboardSettle.delay(Double(i) * Motion.onboardStaggerStep),
                        value: settled
                    )
            }
        }
        .onAppear {
            guard animated else { settled = true; return }
            withAnimation { settled = true }
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
