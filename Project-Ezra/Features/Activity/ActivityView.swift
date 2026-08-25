//
//  ActivityView.swift
//  Project-Ezra
//
//  The Activity screen — a Linear-style feed of everything that has happened in the
//  household, AI and human alike: ALL change-log entries, each with a leading avatar
//  (the human actor, or a gradient sparkles tile for the AI), a small action-glyph
//  badge, an unread dot, and an action-aware Undo.
//
//  It was Activity TAB until the v2 collapse (2026-08-18). A demoted screen, not a
//  demoted system: the guardrails require that every AI action can be understood and
//  undone, and merged-pair entries have no other home. What it stopped being is a
//  destination — a feed that mostly narrates things you already did should not hold a
//  fifth of the tab bar, and its unread badge was asking to be visited. It is now a
//  sheet the shell owns, reached from the Tasks "…" menu and the Brief's held-depth
//  tile.
//
//  Diagnostics deliberately do NOT live here any more. `SettingsView.diagnosticsCard`
//  already carried a strict superset (plan tier + model metrics + advisor metrics +
//  progression + coverage), so the DEBUG footer this screen used to pin was a second,
//  poorer copy of one readout — and it painted over the Capture button.
//

import CoreData
import SwiftUI

struct ActivityView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openCapture) private var openCapture
    // Manual per-task field edits ("edited") live only in the task's own Activity
    // timeline, never this feed — excluded via the shared visibility seam.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)],
        predicate: ChangeLogEntry.activityVisiblePredicate)
    private var entriesResults: FetchedResults<ChangeLogEntry>
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

    /// The last time the user looked at Activity — entries newer than this read as
    /// unread (the accent dot). Written on disappear.
    ///
    /// The KEY keeps its old name on purpose. Renaming it to match the screen would
    /// reset every installed store's watermark to zero and mark the entire change log
    /// unread exactly once — a cosmetic rename buying a real (if small) lie about what
    /// the user has seen.
    @AppStorage("lastInboxSeenAt") private var lastSeen: Double = 0
    @State private var undoCount = 0
    /// The row whose provenance is open. Selection state rather than a `NavigationLink`
    /// per row — see `row(_:)` for why the link shape doesn't work here.
    @State private var selected: ChangeLogEntry?

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
            .sensoryFeedback(.impact(flexibility: .soft), trigger: undoCount)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { ActivityDetailView(entry: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Mark everything up to now as seen when the user closes the screen, so the
        // unread dots clear.
        .onDisappear { lastSeen = Date().timeIntervalSinceReferenceDate }
        .onAppear { openDetailIfRequested() }
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

    /// One feed row: state and action SIDE BY SIDE, never one instead of the other.
    ///
    /// They used to be an `if/else` — the unread dot took the trailing slot and Undo
    /// only appeared once the entry had been seen, reachable meanwhile by swipe. That
    /// was defensible while this was a badged tab you passed through: the dot was the
    /// point, and the tab badge had already told you something was new.
    ///
    /// Demoting it to a deliberately-opened screen inverts the argument. Nobody opens
    /// Activity to learn that something happened; they open it to undo something — and
    /// the entries most likely to need undoing are precisely the newest ones, i.e. the
    /// ones the `else` was hiding the button on. A screen whose whole job is "every AI
    /// action is reversible" must not put its verb behind a swipe.
    ///
    /// **The row opens its provenance on tap** (`ActivityDetailView`): what the system did
    /// to turn a capture into N tasks. That is deliberately a tap and nothing else — no
    /// disclosure chevron competing with the trailing slot, no summary line in the feed —
    /// because the feed's job is still "glance and undo", and the run detail is for
    /// someone who came looking.
    ///
    /// It is a tap GESTURE rather than a `NavigationLink` on purpose: the row already
    /// carries an Undo `Button`, and a button nested in a link's label fights it for the
    /// touch. A `Button` takes priority over a row-level gesture, so this ordering keeps
    /// Undo working and makes the rest of the row the target.
    @ViewBuilder private func row(_ entry: ChangeLogEntry) -> some View {
        let unread = entry.timestamp.timeIntervalSinceReferenceDate > lastSeen
        let reversible = entry.isReversible && !entry.undone
        ActivityRow(
            entry: entry, members: members, currentUserID: currentUserID,
            profile: profilesResults.first
        ) {
            HStack(spacing: Spacing.xs) {
                if unread && !entry.undone {
                    Circle()
                        .fill(Palette.accentFlat)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("New")
                }
                if reversible {
                    Button("Undo") { undo(entry) }
                        .font(.controlLabel)
                        .foregroundStyle(Palette.accentFlat)
                        .buttonStyle(.pressableLink)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { selected = entry }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Palette.border)
        // Kept as a second path, not the only one — a swipe is a shortcut for someone
        // who already knows it is there.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if reversible {
                Button("Undo") { undo(entry) }
                    .tint(Palette.accentFlat)
            }
        }
    }

    // MARK: - Verification seam

    /// `-OpenActivityDetail [N]` — push the Nth row's provenance detail at launch.
    ///
    /// The detail is reachable only by TAPPING a row, and synthetic taps are blocked by
    /// Accessibility on this host, so without this the one screen that explains how a
    /// capture became N tasks could never be looked at outside a human holding the
    /// device — the same argument that produced `-OpenActivity` itself. Never fires in
    /// normal runs.
    private func openDetailIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-OpenActivityDetail") else { return }
        let index = args.indices.contains(flag + 1) ? Int(args[flag + 1]) ?? 0 : 0
        guard entries.indices.contains(index) else { return }
        selected = entries[index]
        #endif
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

}

#Preview {
    ActivityView()
        .environment(AppBrain())
        .environment(\.managedObjectContext, PersistenceStack.scratch)
}
