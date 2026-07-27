//
//  OnboardingView.swift
//  Project-Ezra
//
//  The one screen that earns dramatic, extended motion. The user pastes their
//  existing mess and watches it collapse into a handful of honest, actionable
//  areas — the content hook, the onboarding aha, and the model for the daily
//  brief's generation moment, one piece of craft paying off in three places.
//

import SwiftUI
import CoreData

struct OnboardingView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(AppBrain.self) private var brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onComplete: () -> Void

    private enum Phase { case welcome, intro, settling, result }
    @State private var phase: Phase = .welcome
    @State private var text = ""
    @State private var name = ""
    @State private var drafts: [TaskDraft] = []
    /// Set when a transform came back with nothing. The first impression of the product
    /// is this one button; bouncing silently back to the editor reads as a broken app,
    /// not as "there was nothing to find".
    @State private var foundNothing = false
    @FocusState private var focused: Bool
    @FocusState private var nameFocused: Bool

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
    }

    // MARK: - Welcome
    //
    // Ask for one thing. A consumer app should ask for almost nothing up front — the
    // household, photos, and everyone else are inferred or added later, so this never
    // competes with the chaos→clarity moment that follows it.

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Spacer(minLength: Spacing.xl)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("What should I\ncall you?")
                    .heroLargeStyle()
                    .fixedSize(horizontal: false, vertical: true)
                Text("A first name is plenty. You can add your family whenever you like.")
                    .supportingStyle()
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

            Spacer()

            VStack(spacing: Spacing.sm) {
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
        .padding(Spacing.lg)
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

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Spacer(minLength: Spacing.xl)
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
            .frame(height: 220)

            if foundNothing {
                Text(
                    "I couldn't find anything to act on in that. Try listing things as you'd say them — “call mom back”, “pay the water bill” — one per line."
                )
                .font(.supporting)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }

            Button("Use a sample list") { text = sample }
                .font(.supporting.weight(.medium))
                .foregroundStyle(Palette.accentFlat)
                .buttonStyle(.pressableLink)

            Spacer()

            VStack(spacing: Spacing.sm) {
                Button {
                    Task { await transform() }
                } label: {
                    Text("Show me")
                        .font(.ctaLabel)
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
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
        .padding(Spacing.lg)
    }

    private var canTransform: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Settling (the signature precipitation)

    private var settling: some View {
        VStack(spacing: Spacing.lg) {
            SettlingField(animated: !reduceMotion)
                .frame(height: 220)
            Text("Sorting the chaos…")
                .sectionHeaderStyle()
            Text(brain.status.description)
                .metadataStyle()
        }
        .padding(Spacing.xl)
    }

    // MARK: - Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("I found \(areaCount) area\(areaCount == 1 ? "" : "s")")
                    .screenTitleStyle()
                Text(
                    "From \(drafts.count) item\(drafts.count == 1 ? "" : "s"). \(judgmentCount) I'm leaving for you to decide."
                )
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
                            HStack(spacing: Spacing.inline) {
                                Image(systemName: TaskCategory.symbol(for: category))
                                    .foregroundStyle(Palette.accentFlat)
                                Text(category).sectionHeaderStyle()
                            }
                            ForEach(items) { draft in
                                if let binding = binding(for: draft) {
                                    resultRow(binding)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }

            VStack(spacing: Spacing.xs) {
                Button {
                    commit()
                } label: {
                    Text("Manage these for me")
                        .font(.ctaLabel)
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Palette.accentGradient, in: Capsule())
                }
                .buttonStyle(.pressableProminent)
                .disabled(drafts.isEmpty)
            }
            .padding(Spacing.lg)
        }
    }

    /// One editable result row: category menu (the chip), inline title, judgment
    /// chip, remove. Edits diff against `aiOriginal` at commit exactly like the
    /// composer's card — the corrections loop now starts at minute one.
    private func resultRow(_ draft: Binding<TaskDraft>) -> some View {
        HStack(spacing: Spacing.sm) {
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
                        .font(.system(size: IconSize.caption))
                }
                .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityLabel("Category, \(draft.wrappedValue.category)")

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
            .font(.supporting)
            .foregroundStyle(Palette.primaryText)

            if draft.wrappedValue.isJudgmentCall {
                AssessmentChip(
                    assessment: TaskAssessment(
                        needsDecision: .humanJudgment, isBlocked: false,
                        isUnowned: false, isStale: false, tier: .ask))
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(Motion.respecting(Motion.decide)) {
                    drafts.removeAll { $0.id == draft.wrappedValue.id }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: IconSize.caption, weight: .semibold))
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
    private var judgmentCount: Int { drafts.filter(\.isJudgmentCall).count }

    // MARK: - Flow

    private func transform() async {
        focused = false
        foundNothing = false
        withAnimation(.easeInOut(duration: 0.3)) { phase = .settling }
        let result = await brain.triage(text)
        // Nothing actionable found: return to the editor with the text intact rather
        // than revealing an empty "0 areas" result (input is never discarded) — and SAY
        // so, because an unexplained bounce back to the same screen is indistinguishable
        // from the button not working.
        guard !result.isEmpty else {
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = .intro
                foundNothing = true
            }
            return
        }
        // Hold the settle beat briefly so the motion reads (this is the earned moment).
        try? await Task.sleep(nanoseconds: reduceMotion ? 200_000_000 : 1_400_000_000)
        drafts = result
        withAnimation(Motion.onboardReveal) { phase = .result }
    }

    private func commit() {
        brain.commit(drafts, rawCapture: text, into: context)
        // The onboarding reveal ("here.s your mess, sorted") doubles as the
        // Confirm-Creation glance — the user saw the set and tapped through, and
        // `commit` is what brings the tasks into existence.
        context.saveChanges()
        onComplete()
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
