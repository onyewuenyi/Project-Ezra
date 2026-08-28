//
//  Theme.swift
//  Project-Ezra
//
//  Design system — color, typography, spacing, radius.
//  Source of truth: docs/design-system-managing-chaos.md
//

import SwiftUI

// MARK: - Hex helper

extension Color {
    /// Create a color from a hex string like "#1E5EFF" or "1E5EFF".
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        switch cleaned.count {
        case 8:  // RRGGBBAA
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        default:  // RRGGBB
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Adaptive color that resolves differently in light and dark mode.
    static func adaptive(light: String, dark: String) -> Color {
        Color(
            uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(Color(hex: hex))
            })
    }
}

// MARK: - Palette

/// The app's semantic color tokens. Dark-first per the design system.
enum Palette {
    // Surfaces
    static let background = Color.adaptive(light: "FAFAFA", dark: "111111")
    static let primarySurface = Color.adaptive(light: "FFFFFF", dark: "181818")
    static let secondarySurface = Color.adaptive(light: "F5F5F5", dark: "202020")
    static let elevatedSurface = Color.adaptive(light: "FFFFFF", dark: "262626")
    static let border = Color.adaptive(light: "E5E5E5", dark: "303030")

    // Text
    static let primaryText = Color.adaptive(light: "1A1A1A", dark: "F5F5F5")
    static let secondaryText = Color.adaptive(light: "6B6B6B", dark: "A1A1A1")
    static let mutedText = Color.adaptive(light: "9A9A9A", dark: "6B6B6B")

    // Accent — cobalt → cyan. Gradient is reserved for high-signal moments only.
    static let accentStart = Color(hex: "1E5EFF")  // electric cobalt
    static let accentEnd = Color(hex: "22D3EE")  // bright cyan
    static let accentFlat = Color(hex: "2F6BFF")  // single-color fallback (<24px)
    static let accentSoft = Color(hex: "1E5EFF").opacity(0.15)
    /// The single "judgment / your-call-to-make" blue — the `hand.raised` decision sites
    /// (ConfidenceRow `.ask`, AssessmentChip Needs-Decision, the confirm-card judgment flag,
    /// the detail decision banner). Flat, not gradient: these icons render below 24px. Split
    /// out so one semantic idea is one token instead of forking accentStart↔accentFlat.
    static let decisionAccent = accentFlat
    /// AI-processing soft-glow shadow color — used only for the composer's "thinking" halo.
    static let accentGlow = Color(hex: "1E5EFF").opacity(0.35)
    /// The Today backdrop's drifting cobalt glow — a soft accent-family radial over the
    /// background (on-brand; NOT a new hue). Gated off under Reduce Transparency.
    static let backdropGlow = Color(hex: "1E5EFF").opacity(0.16)

    /// White-on-gradient foreground. The one sanctioned literal color, tokenized so
    /// the seven `.white` call sites on the accent gradient route through the system.
    static let onAccent = Color.white

    /// The signature gradient. Use only at ≥24px: the AI tag, the primary confirm
    /// button, the Needs-Decision edge stroke, the composer's processing border, and
    /// the Today plan's hero-action edge (the day's one payoff moment). Everywhere else
    /// use `accentFlat` — including the active tab, which renders flat via `.tint`.
    static let accentGradient = LinearGradient(
        colors: [accentStart, accentEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Semantic
    static let success = Color(hex: "34C759")  // transient completion motion only
    static let warning = Color(hex: "F59E0B")
    static let error = Color(hex: "EF4444")

    // Attention hues — split out of `warning` so a single row never shows the same
    // color for three unrelated meanings (the Urgent mark, the In-Progress status
    // glyph, and an Overdue marker previously all rendered `warning`). One meaning,
    // one token.
    /// The user's Urgent priority signal (`SignalMarker`, the detail toggle, the
    /// confirm-card pill). Red — the hottest attention mark, distinct from status.
    static let priorityUrgent = Color(hex: "EF4444")
    /// The `.doing` status-glyph tint. Amber — Linear-authentic half-filled amber.
    /// Tokenized so it's semantically separate from Urgent/Overdue even though it
    /// shares amber's value.
    static let statusInProgress = Color(hex: "F59E0B")
    /// The overdue / past-due time-risk marker (Today rows, task cards). Orange —
    /// distinct from both Urgent-red and the amber status glyph.
    static let overdue = Color(hex: "F97316")
    /// Household needs-attention / member-overload tint. Amber, isolated to the
    /// Household surfaces where it doesn't collide with a task's own marks.
    static let householdAttention = Color(hex: "F59E0B")
}

// MARK: - Spacing (8pt grid)

enum Spacing {
    static let xxs: CGFloat = 4
    /// Sanctioned off-grid gap for icon↔text pairings (Label internals, chip rows).
    static let inline: CGFloat = 6
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64
}

// MARK: - Corner radius

enum Radius {
    /// Micro-chip corner (AI tag, small state pills).
    static let chip: CGFloat = 5
    static let small: CGFloat = 8
    static let card: CGFloat = 14
    static let composer: CGFloat = 20
    static let sheet: CGFloat = 24
}
