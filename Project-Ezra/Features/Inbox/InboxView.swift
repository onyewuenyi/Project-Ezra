//
//  InboxView.swift
//  Project-Ezra
//
//  The Inbox tab — a Linear-style feed of everything that has happened in the
//  household, AI and human alike. It absorbs the old AI Activity Trail: where that
//  sheet showed only the AI's own actions, this shows ALL change-log entries, each
//  with a leading avatar (the human actor, or a gradient sparkles tile for the AI), a
//  small action-glyph badge, an unread dot, and an action-aware Undo. The trust
//  diagnostics that lived in the trail footer move to Settings; the dev-only plan-tier
//  readout rides along here in DEBUG.
//

import CoreData
import SwiftUI

struct InboxView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(AppBrain.self) private var brain
    @Environment(\.openCapture) private var openCapture
    // Manual per-task field edits ("edited") live only in the task's Activity timeline,
    // never this feed — excluded via the shared visibility seam (kept in sync with the tab
    // badge in `RootTabView`).
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)],
        predicate: ChangeLogEntry.inboxVisiblePredicate)
    private var entriesResults: FetchedResults<ChangeLogEntry>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

    /// The last time the user looked at the Inbox — entries newer than this read as
    /// unread (the accent dot + the tab badge). Written on disappear.
    @AppStorage("lastInboxSeenAt") private var lastSeen: Double = 0
    @State private var undoCount = 0

    private var entries: [ChangeLogEntry] { Array(entriesResults) }
    private var members: [FamilyMember] { Array(membersResults) }
    private var currentUserID: UUID? { profilesResults.first?.linkedMemberID }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    EmptyStateView(
                        symbol: "tray",
                        title: "Nothing here yet",
                        message:
                            "As you and Ezra move work along — completing, assigning, filing — it shows up here so you can glance and undo.",
                        actionTitle: "Capture something",
                        action: { openCapture() }
                    )
                    .transition(.opacity)
                } else {
                    List {
                        ForEach(groupedByDay, id: \.day) { group in
                            Section {
                                ForEach(group.items) { entry in
                                    row(entry)
                                }
                            } header: {
                                Text(dayLabel(group.day))
                                    .metadataStyle()
                                    .textCase(.uppercase)
                                    .tracking(0.6)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: entries.isEmpty)
            .background(Palette.background)
            // Dev-only, and the WHOLE inset is compiled out: the strip's opaque
            // background painted over the Capture FAB, so leaving an empty one in
            // release would keep the collision without the content that justified it.
            #if DEBUG
            .safeAreaInset(edge: .bottom) { diagnosticsFooter }
            #endif
            .sensoryFeedback(.impact(flexibility: .soft), trigger: undoCount)
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Mark everything up to now as seen when the user leaves the tab, so the badge
        // and unread dots clear.
        .onDisappear { lastSeen = Date().timeIntervalSinceReferenceDate }
    }

    // MARK: - Day grouping

    private var groupedByDay: [(day: Date, items: [ChangeLogEntry])] {
        let cal = Calendar.current
        return Dictionary(grouping: entries) { cal.startOfDay(for: $0.timestamp) }
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: - Row

    @ViewBuilder private func row(_ entry: ChangeLogEntry) -> some View {
        let unread = entry.timestamp.timeIntervalSinceReferenceDate > lastSeen
        ActivityRow(
            entry: entry, members: members, currentUserID: currentUserID,
            profile: profilesResults.first
        ) {
            if unread && !entry.undone {
                Circle()
                    .fill(Palette.accentFlat)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
            } else if entry.isReversible && !entry.undone {
                Button("Undo") { undo(entry) }
                    .font(.controlLabel)
                    .foregroundStyle(Palette.accentFlat)
                    .buttonStyle(.pressableLink)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Palette.border)
        // The Undo stays reachable even when the unread dot is showing, via a swipe.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if entry.isReversible && !entry.undone {
                Button("Undo") { undo(entry) }
                    .tint(Palette.accentFlat)
            }
        }
    }

    // MARK: - Undo (action-aware)

    private func undo(_ entry: ChangeLogEntry) {
        undoCount += 1
        Motion.withMotion(Motion.snap) {
            entry.undone = true
            ChangeLogUndo.revert(entry, in: context)
        }
        context.saveChanges()
    }

    // MARK: - Diagnostics footer (dev-only)

    #if DEBUG
    /// Which engine and which plan tier actually ran. Entirely dev-only — the engine
    /// line used to sit outside this guard, so a shipping user got a pinned strip
    /// reading `Rules engine · appleIntelligenceNotEnabled`: an internal enum
    /// description in production chrome, and AI branding the guardrails refuse.
    ///
    /// The user-facing half of this information is the Today briefing's
    /// deterministic-tier disclosure — the place the degradation is actually felt.
    private var diagnosticsFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(brain.status.description)
                .metadataStyle()
            Text(planDiagnosticsLine)
                .metadataStyle()
            // One line per capability that has actually run a model call — the evidence
            // behind `ModelDeadline.cardSeconds`. Silent until something has been called,
            // so this costs nothing on a fresh install.
            ForEach(ModelMetrics.shared.footerLines(), id: \.self) { line in
                Text(line)
                    .metadataStyle()
            }
            // Per-move Advisor outcomes (acted/offered, plus the silence count) —
            // whether the JUDGMENT worked, the half the model metrics can't see.
            // Silent until a reading has been judged.
            if let advisor = AdvisorMetrics.shared.footerLine {
                Text(advisor)
                    .metadataStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Palette.background.opacity(0.9))
        .accessibilityElement(children: .combine)
    }
    #endif

    #if DEBUG
    private var planDiagnosticsLine: String {
        let m = brain.planMetrics
        var parts = [
            "plan: on-device \(m.onDeviceCount) · pcc \(m.pccCount) · rules \(m.deterministicCount)"
        ]
        if m.lastLatencyMs >= 0 { parts.append("last \(m.lastLatencyMs)ms") }
        if m.lastPromptTokens >= 0 || m.lastOutputTokens >= 0 {
            parts.append("tok \(max(m.lastPromptTokens, 0))/\(max(m.lastOutputTokens, 0))")
        }
        if let tier = m.lastTier { parts.append("via \(tier)") }
        if m.lastTurn > 0 { parts.append("turn \(m.lastTurn) · tools \(m.lastToolCalls)") }
        if let err = m.lastError { parts.append("err \(err)") }
        if let avail = m.lastAvailability { parts.append("ai \(avail)") }
        return parts.joined(separator: " · ")
    }
    #endif
}

#Preview {
    InboxView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
