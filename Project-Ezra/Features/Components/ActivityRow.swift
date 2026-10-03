//
//  ActivityRow.swift
//  Project-Ezra
//
//  The one change-log row — a leading actor avatar with an action-glyph badge, a
//  summary line, and a byline. Shared by the Activity feed (global, with an unread dot /
//  Undo accessory) and the task detail's per-task Activity section (no accessory).
//  Lifted out of ActivityView so the two can't drift.
//

import SwiftUI

/// The loose action vocabulary → glyph / tint / word. A ChangeLogEntry's `action` is
/// a free string, so these fall back gracefully for unknown verbs.
enum ActivityVocab {
    static func glyph(_ action: String?) -> String {
        switch action {
        case "completed": return "checkmark"
        case "assigned": return "person.fill"
        case "filed": return "tray.and.arrow.down.fill"
        case "linked": return "link"
        case "grouped", "split": return "square.stack.3d.up"
        case "archived": return "archivebox.fill"
        case "planned": return "calendar"
        case "decided": return "checkmark.seal.fill"
        case "unblocked": return "lock.open.fill"
        case "killed": return "xmark"
        case "edited": return "pencil"
        case "suppressed", "rejectedGroup": return "hand.raised.slash"
        case "captured": return "tray.and.arrow.down"
        default: return "sparkle"
        }
    }

    static func tint(_ action: String?) -> Color {
        switch action {
        case "completed": return Palette.success
        // A rejection is a quiet "no", not an event — it reads with the receding verbs.
        case "killed", "archived", "suppressed", "rejectedGroup": return Palette.mutedText
        case "assigned", "linked", "decided", "unblocked", "captured", "grouped", "split":
            return Palette.accentFlat
        default: return Palette.secondaryText
        }
    }

    static func word(_ action: String?) -> String {
        switch action {
        case "completed": return "Completed"
        case "assigned": return "Assigned"
        case "filed": return "Filed"
        case "linked": return "Linked"
        // The two structural acts that make a group: the confirm card's "Group as one
        // outcome" and the Advisor's split. Both undo whole from here, and both read
        // as "Updated" before they had a word.
        case "grouped": return "Grouped"
        case "split": return "Split"
        case "archived": return "Archived"
        case "planned": return "Planned"
        case "decided": return "Decided"
        case "unblocked": return "Unblocked"
        case "killed": return "Canceled"
        case "edited": return "Updated"
        case "suppressed", "rejectedGroup": return "Kept apart"
        case "captured": return "Captured"
        default: return "Updated"
        }
    }
}

/// The leading actor tile — an AI gradient-sparkle square, the current user's avatar, a
/// family member's avatar, or a generic person. Lifted out of `ActivityRow` so Activity
/// feed and the detail's Activity timeline resolve the actor identically (no drift), and
/// so the timeline can render a synthesized creation row (no `ChangeLogEntry`) from a bare
/// `actorID`.
struct ActorAvatar: View {
    var isAI: Bool
    var actorID: UUID?
    var members: [FamilyMember] = []
    var currentUserID: UUID? = nil
    var profile: UserProfile? = nil
    var size: CGFloat = 32

    init(
        isAI: Bool, actorID: UUID?, members: [FamilyMember] = [], currentUserID: UUID? = nil,
        profile: UserProfile? = nil, size: CGFloat = 32
    ) {
        self.isAI = isAI
        self.actorID = actorID
        self.members = members
        self.currentUserID = currentUserID
        self.profile = profile
        self.size = size
    }

    /// Resolve directly from a change-log entry (Activity / timeline entry rows).
    init(
        entry: ChangeLogEntry, members: [FamilyMember] = [], currentUserID: UUID? = nil,
        profile: UserProfile? = nil, size: CGFloat = 32
    ) {
        self.init(
            isAI: entry.initiatedBy == .ai, actorID: entry.actorID, members: members,
            currentUserID: currentUserID, profile: profile, size: size)
    }

    var body: some View {
        if isAI {
            // Neutral tile, accent glyph (2026-09-25, the importance audit): a gradient
            // tile on every AI row made the feed's loudest element its most repeated
            // one, louder than the Undo each row exists to offer. The gradient is for
            // high-signal sites only.
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Palette.elevatedSurface)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(Palette.accentFlat)
                }
        } else if let actorID, actorID == currentUserID {
            AvatarView(profile: profile, size: size)
        } else if let actorID, let member = members.first(where: { $0.uuid == actorID }) {
            AvatarView(member: member, size: size)
        } else {
            AvatarView(source: .person, size: size)
        }
    }
}

struct ActivityRow<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: ChangeLogEntry
    var members: [FamilyMember] = []
    var currentUserID: UUID? = nil
    var profile: UserProfile? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            avatarWithBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                    .font(.supporting)
                    .foregroundStyle(entry.undone ? Palette.mutedText : Palette.primaryText)
                    .strikethrough(entry.undone)
                // The why and the when are secondary to what happened (2026-09-26): at
                // accessibility sizes this line ran to four lines under every row, so each
                // entry filled half the screen. Two lines, then it truncates; the entry's
                // detail page has the whole sentence.
                Text(byline)
                    .metadataStyle()
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : nil)
            }

            Spacer(minLength: 0)
            trailing()
        }
    }

    /// A 32pt leading avatar with a 14pt action-glyph badge.
    private var avatarWithBadge: some View {
        ZStack(alignment: .bottomTrailing) {
            ActorAvatar(
                entry: entry, members: members, currentUserID: currentUserID, profile: profile,
                size: 32)
            Image(systemName: ActivityVocab.glyph(entry.action))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 14, height: 14)
                .background(Circle().fill(ActivityVocab.tint(entry.action)))
                .overlay { Circle().strokeBorder(Palette.background, lineWidth: 1.5) }
                .offset(x: 3, y: 3)
        }
    }

    private var byline: String {
        let lead = entry.detail ?? ActivityVocab.word(entry.action)
        let when = entry.timestamp.formatted(.relative(presentation: .named))
        return "\(lead) · \(when)"
    }
}

extension ActivityRow where Trailing == EmptyView {
    /// Convenience for surfaces that need no trailing accessory (the detail feed).
    init(
        entry: ChangeLogEntry, members: [FamilyMember] = [], currentUserID: UUID? = nil,
        profile: UserProfile? = nil
    ) {
        self.init(
            entry: entry, members: members, currentUserID: currentUserID, profile: profile,
            trailing: { EmptyView() })
    }
}
