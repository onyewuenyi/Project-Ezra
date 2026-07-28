//
//  HouseholdView.swift
//  Project-Ezra
//
//  The Household surface — "mission control", not a shared task list. Now answers
//  "what should I do?" (personal execution). Household answers "how are we
//  operating together?" (shared execution). It is the declarative render of what
//  `HouseholdEngine` computes — a health glance, a coordination feed, ownership by
//  person, and a shared timeline — deliberately awareness over density.
//
//  Identity/roster editing (photos, adding people, relationships) lives one tap
//  away in `HouseholdRosterView`, reached from the "Manage" button — the best
//  settings screens are almost empty, and this one wants to stay a status board.
//

import CoreData
import SwiftUI

struct HouseholdView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppBrain.self) private var brain
    @FetchRequest(sortDescriptors: []) private var tasksResults: FetchedResults<TaskItem>
    @FetchRequest(sortDescriptors: []) private var changesResults: FetchedResults<ChangeLogEntry>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>
    @FetchRequest(sortDescriptors: []) private var householdsResults: FetchedResults<Household>

    private var tasks: [TaskItem] { Array(tasksResults) }
    private var changes: [ChangeLogEntry] { Array(changesResults) }
    private var members: [FamilyMember] { Array(membersResults) }
    private var profiles: [UserProfile] { Array(profilesResults) }
    private var households: [Household] { Array(householdsResults) }

    @State private var appeared = false
    @State private var selectedTask: TaskItem?
    /// The row order the open task came from — the detail pages through it. Set alongside
    /// `selectedTask` because Household's two feeds (coordination, timeline) list
    /// different work.
    @State private var peers: [TaskItem] = []
    @State private var showRoster = false
    @State private var narrative = ""

    /// The device user's linked member id — separates the `.you` load from members.
    private var currentUserID: UUID? { profiles.first?.linkedMemberID }

    /// The whole surface, computed fresh — Household never stores state.
    private var snapshot: HouseholdSnapshot {
        HouseholdEngine.compute(
            tasks: tasks.map { $0 }, changes: changes.map { $0 }, members: members.map { $0 },
            currentUserID: currentUserID)
    }

    /// The Sendable facts the narrative layer rephrases.
    private var facts: HouseholdFacts { HouseholdEngine.facts(from: snapshot) }

    private var householdName: String {
        households.first?.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Your household"
    }

    var body: some View {
        let snap = snapshot
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if snap.hasHousehold {
                        healthHero(snap)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 8)
                            .animation(reduceMotion ? nil : Motion.settle, value: appeared)

                        if !snap.coordination.isEmpty {
                            coordinationSection(snap.coordination)
                        }
                        ownershipSection(snap.members)
                        if !snap.timeline.isEmpty {
                            timelineSection(snap.timeline)
                        }
                    } else {
                        soloState
                    }
                }
                .padding(Spacing.lg)
            }
            .background(Palette.background)
            .navigationTitle("Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showRoster = true
                    } label: {
                        Image(systemName: "person.2")
                    }
                    .accessibilityLabel("Manage household")
                }
            }
            .navigationDestination(isPresented: $showRoster) {
                HouseholdRosterView()
            }
            .taskDetailSheet($selectedTask, peers: peers)
        }
        // Recompute the narrative whenever the facts change (device → LLM, sim →
        // deterministic template). Never blocks the render; the banner shows the
        // headline + highlights immediately and the sentence fills in.
        .task(id: facts) {
            narrative = await brain.householdNarrative(facts)
        }
        .task {
            Motion.withMotion(Motion.settle) { appeared = true }
        }
    }

    // MARK: - Health hero (the single-glance status)

    private func healthHero(_ snap: HouseholdSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: statusGlyph(snap.status))
                    .font(.glyphDisplay())
                    .foregroundStyle(statusTint(snap.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(householdName)
                        .metadataStyle()
                        .textCase(.uppercase)
                        .tracking(0.8)
                    Text(snap.headline)
                        .font(.screenTitle)
                        .tracking(-0.4)
                        .foregroundStyle(Palette.primaryText)
                }
            }
            if !narrative.isEmpty {
                Text(narrative)
                    .supportingStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !snap.highlights.isEmpty {
                Text(snap.highlights.joined(separator: "  ·  "))
                    .metadataStyle()
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Palette.primarySurface,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(householdName). \(snap.headline). \(narrative) \(snap.highlights.joined(separator: ", "))")
    }

    private func statusGlyph(_ status: HouseholdStatus) -> String {
        switch status {
        case .operatingSmoothly: return "checkmark.seal.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .quiet: return "moon.stars.fill"
        }
    }

    private func statusTint(_ status: HouseholdStatus) -> Color {
        switch status {
        case .operatingSmoothly: return Palette.success
        case .needsAttention: return Palette.householdAttention
        case .quiet: return Palette.secondaryText
        }
    }

    // MARK: - Coordination feed ("what's happening with us?")

    private func coordinationSection(_ events: [CoordinationEvent]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("What's happening")
            ForEach(events) { event in
                eventRow(event, within: events.map(\.taskID))
            }
        }
    }

    private func eventRow(_ event: CoordinationEvent, within peerIDs: [UUID?]) -> some View {
        Button {
            open(event.taskID, within: peerIDs)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: eventGlyph(event.kind))
                    .font(.glyphCaption(.semibold))
                    .foregroundStyle(eventTint(event.kind))
                    .frame(width: 20)
                Text(event.sentence)
                    .font(.supporting)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .whyAmISeeingThis(event.reasons)
        .accessibilityLabel(event.sentence)
    }

    private func eventGlyph(_ kind: CoordinationEvent.Kind) -> String {
        switch kind {
        case .completed: return "checkmark.circle"
        case .assigned: return "person.crop.circle.badge.checkmark"
        case .waiting: return "hourglass"
        case .upForGrabs: return "person.fill.questionmark"
        case .decision: return "hand.raised"
        case .aiMove: return "sparkles"
        }
    }

    private func eventTint(_ kind: CoordinationEvent.Kind) -> Color {
        switch kind {
        case .completed: return Palette.success
        case .decision: return Palette.decisionAccent
        case .waiting, .upForGrabs: return Palette.mutedText
        case .assigned, .aiMove: return Palette.accentFlat
        }
    }

    // MARK: - Ownership (workload by person — balance, not a scoreboard)

    private func ownershipSection(_ loads: [MemberLoad]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Who owns what")
            VStack(spacing: 0) {
                ForEach(Array(loads.enumerated()), id: \.element.id) { index, load in
                    if index > 0 { rowDivider }
                    memberRow(load)
                }
            }
            .background(
                Palette.primarySurface,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 0.5)
            }
        }
    }

    private func memberRow(_ load: MemberLoad) -> some View {
        HStack(spacing: Spacing.sm) {
            avatar(for: load.kind, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(load.name)
                    .font(.supporting.weight(.medium))
                    .foregroundStyle(Palette.primaryText)
                Text(subtitle(for: load))
                    .font(.metadata)
                    .foregroundStyle(subtitleTint(for: load))
            }
            Spacer(minLength: 0)
            if load.activeCount > 0 {
                Text("\(load.activeCount)")
                    .font(.sectionHeader)
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(load.name), \(subtitle(for: load))")
    }

    /// The one-line read on a person's plate: flags win (they're the signal), then
    /// due-today, then a calm resting state.
    private func subtitle(for load: MemberLoad) -> String {
        if case .shared = load.kind {
            return load.activeCount == 0 ? "Nothing unowned" : "Up for grabs"
        }
        if !load.flags.isEmpty { return load.flags.joined(separator: " · ") }
        if load.dueTodayCount > 0 {
            return "\(load.dueTodayCount) due today"
        }
        return load.activeCount == 0 ? "All clear" : "On track"
    }

    private func subtitleTint(for load: MemberLoad) -> Color {
        if load.isOverloaded || load.overdueCount > 0 { return Palette.householdAttention }
        if !load.flags.isEmpty { return Palette.secondaryText }
        return Palette.mutedText
    }

    // MARK: - Shared timeline (the household's operational horizon)

    private func timelineSection(_ entries: [TimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("This week")
            ForEach(entries) { entry in
                Button {
                    open(entry.taskID, within: entries.map(\.taskID))
                } label: {
                    HStack(spacing: Spacing.sm) {
                        avatar(for: entry.ownerKind, size: 24)
                        Text(entry.title)
                            .font(.supporting)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(entry.dayLabel)
                            .metadataStyle()
                    }
                    .padding(.vertical, Spacing.xxs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("\(entry.title), \(entry.dayLabel)")
            }
        }
    }

    // MARK: - Solo / empty state

    private var soloState: some View {
        EmptyStateView(
            symbol: "person.2",
            tint: Palette.accentFlat,
            title: "Just you for now",
            message:
                "Add the people you share a life with, and Household becomes your shared operating picture — who owns what, what's coordinated, and what's slipping.",
            actionTitle: "Add someone",
            action: { showRoster = true }
        )
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(title)
                .sectionHeaderStyle()
            if let detail {
                Text(detail)
                    .metadataStyle()
            }
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 0.5)
            .padding(.leading, Spacing.md)
    }

    /// Resolve a workload bucket to its avatar: the profile for "you", the roster
    /// entry for a member, the household glyph for shared/unowned work.
    @ViewBuilder
    private func avatar(for kind: MemberLoad.Kind, size: CGFloat) -> some View {
        switch kind {
        case .you:
            AvatarView(profile: profiles.first, size: size)
        case .member(let uuid):
            if let member = members.first(where: { $0.uuid == uuid && !$0.isRemoved }) {
                AvatarView(member: member, size: size)
            } else {
                AvatarView(source: .person, size: size)
            }
        case .shared:
            AvatarView(source: .family(nil, name: nil), size: size)
        }
    }

    /// Open a task full-screen, carrying the list it was rendered in so the detail can
    /// page to the neighbouring row. `peerIDs` is that section's on-screen order; ids that
    /// no longer resolve to a task are simply skipped.
    private func open(_ taskID: UUID?, within peerIDs: [UUID?]) {
        guard let taskID, let task = tasks.first(where: { $0.uuid == taskID }) else { return }
        peers = peerIDs.compactMap { id in id.flatMap { wanted in tasks.first { $0.uuid == wanted } } }
        selectedTask = task
    }
}

// MARK: - Small helpers

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    HouseholdView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
