//
//  GlyphColumnContractTests.swift
//  Project-EzraTests
//
//  A scaled glyph in a fixed column draws outside it (2026-09-29): the status glyph grows
//  along its text style at accessibility sizes, the 28pt frame around it did not, and on
//  the home's hero the half-filled "in progress" circle spilled out of the card and over
//  the title's first letter. The home's row column now scales with the glyph
//  (`glyphColumn`). Scaling the shared StatusGlyphView's column was tried and reverted: in
//  the Tasks list it starved titles that share their line with the marker and due label.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Glyph columns scale with their glyphs")
struct GlyphColumnContractTests {

    private func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Project-Ezra").appendingPathComponent(path),
            encoding: .utf8)
    }

    @Test(
        "No scaled glyph sits in a fixed 28pt frame",
        arguments: [
            "Features/Chat/ChatComponents.swift"
        ])
    func noFixedGlyphFrame(path: String) throws {
        // Whitespace-insensitive: swift-format breaks a long `.frame(` across lines.
        let flat = try code(path).filter { !$0.isWhitespace }
        #expect(!flat.contains("frame(width:LayoutMetrics.recordGlyphColumn"))
    }

    @Test("The home's row glyph sits in a column that scales along the glyph's own tier")
    func homeRowGlyphUsesScaledColumn() throws {
        // control → .title2 and action → .title3: the pairings `Font.glyphControl` and
        // `Font.glyphAction` declare. The list keeps its fixed column (see the comment at
        // the call site): widening it there starved the title at accessibility sizes.
        #expect(
            try code("Features/Chat/ChatComponents.swift").contains(
                ".glyphColumn(relativeTo: style == .hero ? .title2 : .title3)"))
    }
}
