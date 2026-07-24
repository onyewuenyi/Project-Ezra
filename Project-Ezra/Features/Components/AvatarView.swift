//
//  AvatarView.swift
//  Project-Ezra
//
//  The one avatar renderer. Every avatar in the app — task owners, "you", family
//  members, the household itself — routes through this so the Instagram-Instants
//  squircle look (rounded-square tile, thin outline, faint lift) is defined exactly
//  once and never duplicated. Callers hand it an `AvatarSource`, or use the typed
//  convenience initializers for a model.
//

import SwiftUI
import UIKit

/// What an avatar is made of. `photo` wins when present; the rest are fallbacks.
enum AvatarSource {
    case photo(Data)
    case initials(String)
    /// A distinct deterministic gradient keyed by a string — a photo-like placeholder.
    case gradient(seed: String)
    case emoji(String)
    /// The current user with no photo — a generic person glyph, never initials ("Me"
    /// would collide with any member whose name starts the same).
    case person
    /// The household tile: its photo, else a house glyph.
    case family(Data?, name: String?)
}

struct AvatarView: View {
    let source: AvatarSource
    var size: CGFloat = 24

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
    }

    var body: some View {
        ZStack { content }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay {
                // The Instants outline — a thin dark edge that lifts the tile off the card.
                shape.strokeBorder(Palette.border, lineWidth: max(0.5, size * 0.03))
            }
            .shadow(color: .black.opacity(0.22), radius: size * 0.06, y: size * 0.02)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch source {
        case .photo(let data):
            if let image = Self.image(from: data) {
                image.resizable().scaledToFill()
            } else {
                neutralTile { glyph("person.fill") }
            }
        case .initials(let name):
            neutralTile {
                Text(Self.initials(for: name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.secondaryText)
                    .minimumScaleFactor(0.6)
            }
        case .gradient(let seed):
            Self.gradient(for: seed)
        case .emoji(let emoji):
            neutralTile {
                Text(emoji).font(.system(size: size * 0.5))
            }
        case .person:
            neutralTile { glyph("person.fill") }
        case .family(let data, let name):
            if let data, let image = Self.image(from: data) {
                image.resizable().scaledToFill()
            } else if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                neutralTile {
                    Text(Self.initials(for: name))
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.secondaryText)
                        .minimumScaleFactor(0.6)
                }
            } else {
                neutralTile { glyph("house.fill") }
            }
        }
    }

    /// The neutral dark tile behind initials/glyphs — a slight vertical gradient for a
    /// little dimension without introducing per-person color.
    @ViewBuilder private func neutralTile<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        LinearGradient(
            colors: [Palette.elevatedSurface, Palette.secondarySurface],
            startPoint: .top, endPoint: .bottom
        )
        inner()
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Palette.secondaryText)
    }

    // MARK: - Helpers

    private static func image(from data: Data) -> Image? {
        UIImage(data: data).map(Image.init(uiImage:))
    }

    /// Up to two uppercased letters from a name: one for a single first name, first+last
    /// initial for a full name. Whitespace/empty-safe.
    static func initials(for name: String) -> String {
        let parts =
            name
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .filter { !$0.isEmpty }
        guard let first = parts.first?.first else { return "?" }
        if parts.count >= 2, let last = parts.last?.first {
            return (String(first) + String(last)).uppercased()
        }
        return String(first).uppercased()
    }

    /// A deterministic two-tone diagonal gradient keyed by a string (stable across
    /// launches). A photo-like placeholder distinct from the neutral initials tile.
    private static func gradient(for seed: String) -> LinearGradient {
        var hash: UInt64 = 5381
        for scalar in seed.lowercased().unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.5, brightness: 0.55),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.4),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: - Model → source factories (shared by the inits and by chip call sites)

extension AvatarSource {
    /// A family member: photo when present, else initials.
    static func member(_ member: FamilyMember) -> AvatarSource {
        member.photoData.map(AvatarSource.photo) ?? .initials(member.name)
    }

    /// The current user ("you"): photo → initials of the name → generic person glyph.
    static func profile(_ profile: UserProfile?) -> AvatarSource {
        if let data = profile?.photoData { return .photo(data) }
        if let name = profile?.displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return .initials(name)
        }
        return .person
    }

    /// name+photo call sites (see `OwnerAvatarBadge`): photo → person glyph → initials.
    static func owner(name: String, photoData: Data?, isMe: Bool) -> AvatarSource {
        photoData.map(AvatarSource.photo) ?? (isMe ? .person : .initials(name))
    }
}

// MARK: - Typed convenience initializers

extension AvatarView {
    init(member: FamilyMember, size: CGFloat = 24) {
        self.init(source: .member(member), size: size)
    }

    init(profile: UserProfile?, size: CGFloat = 24) {
        self.init(source: .profile(profile), size: size)
    }

    init(household: Household?, size: CGFloat = 24) {
        self.init(source: .family(household?.photoData, name: household?.name), size: size)
    }

    /// Compatibility entry for name+photo call sites (see `OwnerAvatarBadge`).
    init(name: String, photoData: Data? = nil, isMe: Bool = false, size: CGFloat = 24) {
        self.init(source: .owner(name: name, photoData: photoData, isMe: isMe), size: size)
    }
}
