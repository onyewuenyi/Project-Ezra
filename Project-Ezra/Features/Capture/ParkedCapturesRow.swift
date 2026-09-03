//
//  ParkedCapturesRow.swift
//  Project-Ezra
//
//  **The captures you parked are findable.** (F-04)
//
//  Leaving the composer parks the words; only Discard destroys them. Until now the only
//  pointer to a parked capture was the Brief's resting line, and the Brief was cut — so
//  words the person gave Ezra were words Ezra then hid, findable only by reopening the
//  composer and hoping. For the pillar whose whole promise is "give me whatever is in
//  your head", that is the worst possible outcome.
//
//  This is a place to LOOK, never a thing that asks to be visited: no badge, no colour,
//  no count in the tab bar, no notification. One quiet row at the top of Tasks while
//  anything is parked, gone the moment nothing is. Tapping resumes the capture in the
//  composer exactly as leaving it left it.
//

import CoreData
import SwiftUI

struct ParkedCapturesRow: View {
    @Environment(\.resumeCapture) private var resumeCapture
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Capture.createdAt, order: .reverse)],
        predicate: NSPredicate(format: "committedAt == nil AND draftsData != nil")
    ) private var parked: FetchedResults<Capture>

    /// The captures worth resuming: parked, with words. An empty parked row (a composer
    /// opened and closed) is not unfinished work.
    private var unfinished: [Capture] {
        parked.filter { !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        if unfinished.count == 1, let only = unfinished.first {
            Button {
                resumeCapture(only)
            } label: {
                label(for: only)
            }
            .buttonStyle(.pressableLink)
            .accessibilityLabel("Unfinished capture: \(Self.excerpt(only.rawText))")
            .accessibilityHint("Resumes it")
        } else if unfinished.count > 1 {
            Menu {
                ForEach(unfinished, id: \.objectID) { capture in
                    Button(Self.excerpt(capture.rawText)) { resumeCapture(capture) }
                }
            } label: {
                row(
                    text: "\(unfinished.count) unfinished captures",
                    detail: Self.excerpt(unfinished[0].rawText))
            }
            .accessibilityLabel("\(unfinished.count) unfinished captures")
        }
    }

    private func label(for capture: Capture) -> some View {
        row(text: "Unfinished capture", detail: Self.excerpt(capture.rawText))
    }

    private func row(text: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: "text.quote")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
            Text(text)
                .supportingStyle()
            Text("“\(detail)”")
                .supportingStyle()
                .foregroundStyle(Palette.mutedText)
                .lineLimit(1)
            Spacer(minLength: Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The first few words — enough to recognise, never the whole dump.
    static func excerpt(_ text: String, words: Int = 6) -> String {
        let all = text.split(whereSeparator: \.isWhitespace)
        let head = all.prefix(words).joined(separator: " ")
        return all.count > words ? head + "…" : head
    }
}
