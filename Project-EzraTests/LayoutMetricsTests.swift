//
//  LayoutMetricsTests.swift
//  Project-EzraTests
//
//  The two line-count rules the 2026-09-17/18 screenshot passes produced, pinned so a
//  drive-by "make it one line" is visible: list rows get a second title line only at
//  the accessibility sizes, and the detail's related rows always get two.
//

import SwiftUI
import Testing

@testable import Project_Ezra

@Suite("Layout metrics — line counts")
struct LayoutMetricsTests {

    @Test("A list row's title is one line at every reading size")
    func readingSizesAreOneLine() {
        for size in [DynamicTypeSize.xSmall, .medium, .large, .xxxLarge] {
            #expect(LayoutMetrics.listTitleLines(for: size) == 1)
        }
    }

    @Test("A list row's title is two lines at every accessibility size")
    func accessibilitySizesAreTwoLines() {
        for size in [
            DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4,
            .accessibility5,
        ] {
            #expect(LayoutMetrics.listTitleLines(for: size) == 2)
        }
    }

    @Test("The detail's related rows wrap to two lines, and never fewer")
    func relatedRowsAreTwoLines() {
        #expect(LayoutMetrics.relatedTitleLines == 2)
    }

    @Test("The readable column is wider than every phone and narrower than an iPad")
    func readableColumnSitsBetweenPhoneAndPad() {
        // The widest phone (Pro Max, 440pt) must never be constrained; the narrowest
        // iPad in portrait (mini, 744pt) must be.
        #expect(LayoutMetrics.readableWidth > 440)
        #expect(LayoutMetrics.readableWidth < 744)
    }
}
