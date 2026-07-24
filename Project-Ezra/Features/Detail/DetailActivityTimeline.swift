//
//  DetailActivityTimeline.swift
//  Project-Ezra
//
//  The per-task Activity timeline on the full-screen detail — a Linear-style vertical
//  rail: connected avatar/glyph dots read top-down oldest → newest, each row an
//  actor · change · relative-time line. This is the detail's OWN surface: it shows manual
//  field edits (the "edited" entries the Inbox deliberately hides) alongside AI actions
//  and human resolutions, and it's the only place those edits can be undone (via a
//  per-row context menu), since the Inbox never lists them.
//
//  It differs from the Inbox's `ActivityRow` on purpose: the Inbox is a newest-first FEED
//  (a glanceable log with swipe-Undo); this is a STORY (created → edited → done), grounded
//  by a creation anchor so it's never empty and always starts somewhere.
//

import CoreData
import SwiftUI

struct DetailActivityTimeline: View {
    /// A synthesized "created this task" row, shown first when the feed has no real
    /// capture ("filed"/"confirmed") entry to anchor on. Not a stored `ChangeLogEntry`.
    struct Creation {
        let date: Date
        let actorID: UUID?
    }

    /// The entries to show, already sliced and ordered **oldest → newest** by the caller.
    let entries: [ChangeLogEntry]
    var creation: Creation? = nil
    var members: [FamilyMember] = []
    var currentUserID: UUID? = nil
    var profile: UserProfile? = nil
    /// Invoked when a row's context-menu "Undo" is chosen (reversible "edited" entries).
    var onUndo: (ChangeLogEntry) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let models = rowModels
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                row(model, isLast: index == models.count - 1)
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: entries.count)
    }

    // MARK: - Row model (unifies the synthesized creation anchor + real entries)

    private struct RowModel: Identifiable {
        let id: String
        /// The backing entry, or nil for the synthesized creation anchor.
        let entry: ChangeLogEntry?
        let summary: String
        let bylineLead: String
        let timestamp: Date
        let glyph: String
        let tint: Color
        let isAI: Bool
        let actorID: UUID?
        let undone: Bool
        /// Whether this row offers a context-menu Undo (reversible, not-yet-undone edits
        /// — the entries the Inbox can't reach).
        let canUndo: Bool
    }

    private var rowModels: [RowModel] {
        var models: [RowModel] = []
        if let creation {
            models.append(
                RowModel(
                    id: "creation", entry: nil, summary: "Created this task",
                    bylineLead: "Created", timestamp: creation.date, glyph: "plus",
                    tint: Palette.secondaryText, isAI: false, actorID: creation.actorID,
                    undone: false, canUndo: false))
        }
        for entry in entries {
            models.append(
                RowModel(
                    id: entry.uuid?.uuidString ?? entry.objectID.uriRepresentation().absoluteString,
                    entry: entry,
                    summary: entry.summary,
                    bylineLead: entry.detail ?? ActivityVocab.word(entry.action),
                    timestamp: entry.timestamp,
                    glyph: ActivityVocab.glyph(entry.action),
                    tint: ActivityVocab.tint(entry.action),
                    isAI: entry.initiatedBy == .ai,
                    actorID: entry.actorID,
                    undone: entry.undone,
                    canUndo: entry.action == ChangeLogEntry.editedAction && entry.isReversible
                        && !entry.undone))
        }
        return models
    }

    // MARK: - Row

    private func row(_ model: RowModel, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            railColumn(model, isLast: isLast)
            content(model, isLast: isLast)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .modifier(UndoContextMenu(entry: model.canUndo ? model.entry : nil, onUndo: onUndo))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(model))
    }

    /// The connecting rail: a 1pt line that starts just below this row's dot and fills the
    /// rest of the row height, so it meets the next row's dot (hidden on the last row). The
    /// dot sits on top. Vertical breathing room lives in the content's bottom padding, so
    /// the line spans it and stays continuous.
    private func railColumn(_ model: RowModel, isLast: Bool) -> some View {
        ZStack(alignment: .top) {
            if !isLast {
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, Self.dotSize)
            }
            dot(model)
        }
        .frame(width: Self.dotSize)
    }

    private func dot(_ model: RowModel) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ActorAvatar(
                isAI: model.isAI, actorID: model.actorID, members: members,
                currentUserID: currentUserID, profile: profile, size: Self.dotSize)
            Image(systemName: model.glyph)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 12, height: 12)
                .background(Circle().fill(model.tint))
                .overlay { Circle().strokeBorder(Palette.background, lineWidth: 1.5) }
                .offset(x: 2, y: 2)
        }
        .frame(width: Self.dotSize, height: Self.dotSize)
    }

    private func content(_ model: RowModel, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.summary)
                .font(.supporting)
                .foregroundStyle(model.undone ? Palette.mutedText : Palette.primaryText)
                .strikethrough(model.undone)
            Text("\(model.bylineLead) · \(model.timestamp.formatted(.relative(presentation: .named)))")
                .metadataStyle()
        }
        .padding(.top, 2)  // nudge the text baseline toward the dot's center
        .padding(.bottom, isLast ? 0 : Spacing.md)  // rail spans this → continuous line
    }

    private func accessibilityLabel(_ model: RowModel) -> String {
        "\(model.summary), \(model.bylineLead), \(model.timestamp.formatted(.relative(presentation: .named)))"
            + (model.undone ? ", undone" : "")
    }

    private static let dotSize: CGFloat = 24
}

/// The per-row Undo affordance, applied only when `entry` is non-nil (a reversible
/// "edited" row). A `ViewModifier` so the row builder stays flat and the context menu +
/// VoiceOver action share one gate. VoiceOver reaches it through `.accessibilityAction`.
private struct UndoContextMenu: ViewModifier {
    let entry: ChangeLogEntry?
    let onUndo: (ChangeLogEntry) -> Void

    func body(content: Content) -> some View {
        if let entry {
            content
                .contextMenu {
                    Button {
                        onUndo(entry)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                }
                .accessibilityAction(named: "Undo") { onUndo(entry) }
        } else {
            content
        }
    }
}
