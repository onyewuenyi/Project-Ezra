//
//  OwnerAvatarBadgeTests.swift
//  Project-EzraTests
//
//  Covers the pure helper behind the delegated-task owner avatar: initials extraction
//  for the squircle's fallback tile (single vs. full name, whitespace, empty-safe).
//

import SwiftUI
import Testing

@testable import Project_Ezra

@Suite("OwnerAvatarBadge")
struct OwnerAvatarBadgeTests {

    // MARK: - Initials

    @Test("Single first name yields one uppercased letter")
    func singleName() {
        #expect(OwnerAvatarBadge.initials(for: "Sarah") == "S")
        #expect(OwnerAvatarBadge.initials(for: "ana") == "A")
    }

    @Test("Full name yields first and last initials")
    func fullName() {
        #expect(OwnerAvatarBadge.initials(for: "Marcus King") == "MK")
        #expect(OwnerAvatarBadge.initials(for: "dev patel") == "DP")
    }

    @Test("Extra whitespace and hyphens are handled")
    func messyNames() {
        #expect(OwnerAvatarBadge.initials(for: "  Jo  ") == "J")
        #expect(OwnerAvatarBadge.initials(for: "Mary-Jane") == "MJ")
        #expect(OwnerAvatarBadge.initials(for: "Ana   Maria   Lopez") == "AL")
    }

    @Test("Empty or whitespace-only name is safe")
    func emptyName() {
        #expect(OwnerAvatarBadge.initials(for: "") == "?")
        #expect(OwnerAvatarBadge.initials(for: "   ") == "?")
    }
}
