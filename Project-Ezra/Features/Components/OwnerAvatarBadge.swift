//
//  OwnerAvatarBadge.swift
//  Project-Ezra
//
//  Thin compatibility shim over `AvatarView` — the single avatar pipeline. Task cards
//  and chips still say `OwnerAvatarBadge(name:photoData:isMe:size:)`; the Instants
//  squircle rendering itself lives once in `AvatarView`. Decorative by design
//  (accessibility-hidden there); the owner's name is spoken by the hosting surface.
//

import SwiftUI

struct OwnerAvatarBadge: View {
    let name: String
    /// The owner's photo when one exists (`FamilyMember.photoData`). Nil → initials.
    var photoData: Data? = nil
    /// True for the user's own tasks — a generic person glyph instead of initials.
    var isMe: Bool = false
    var size: CGFloat = 24

    var body: some View {
        AvatarView(name: name, photoData: photoData, isMe: isMe, size: size)
    }

    /// Kept for call sites/tests that read initials directly; delegates to the pipeline.
    static func initials(for name: String) -> String { AvatarView.initials(for: name) }
}
