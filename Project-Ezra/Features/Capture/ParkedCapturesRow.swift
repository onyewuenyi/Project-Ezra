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
//  Two things a place-to-look owes the person (2026-09-04): WHEN the words were left
//  (a row that says only "unfinished capture" is a row you have to open to recognise),
//  and a way to let one go WITHOUT opening it — a parked thought you have already
//  decided against, dismissable only by resuming it and finding Discard, is a row that
//  nags by construction. Long-press → Discard, behind the same confirmation the
//  composer's own Discard wears.
//

import CoreData
import SwiftUI

struct ParkedCapturesRow: View {
    @Environment(\.resumeCapture) private var resumeCapture
    @Environment(\.managedObjectContext) private var context
    /// The parked capture a long-press asked to let go of; the dialog confirms.
    @State private var discardCandidate: Capture?
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
        Group {
            if unfinished.count == 1, let only = unfinished.first {
                Button {
                    resumeCapture(only)
                } label: {
                    label(for: only)
                }
                .buttonStyle(.pressableLink)
                .contextMenu {
                    Button("Resume") { resumeCapture(only) }
                    Button("Discard", systemImage: "trash", role: .destructive) {
                        discardCandidate = only
                    }
                }
                .accessibilityLabel(
                    "Unfinished capture, \(Self.age(of: only.createdAt)): \(Self.excerpt(only.rawText))"
                )
                .accessibilityHint("Resumes it")
                .accessibilityAction(named: "Discard") { discardCandidate = only }
            } else if unfinished.count > 1 {
                Menu {
                    ForEach(unfinished, id: \.objectID) { capture in
                        Button {
                            resumeCapture(capture)
                        } label: {
                            Text(Self.excerpt(capture.rawText))
                            Text(Self.age(of: capture.createdAt))
                        }
                    }
                    Divider()
                    Menu("Discard…") {
                        ForEach(unfinished, id: \.objectID) { capture in
                            Button(Self.excerpt(capture.rawText), role: .destructive) {
                                discardCandidate = capture
                            }
                        }
                    }
                } label: {
                    row(
                        text: "\(unfinished.count) unfinished captures",
                        detail: Self.excerpt(unfinished[0].rawText),
                        age: Self.age(of: unfinished[0].createdAt))
                }
                .accessibilityLabel("\(unfinished.count) unfinished captures")
            }
        }
        .confirmationDialog(
            "Discard this capture?", isPresented: discardPresented, titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if let discardCandidate { AppBrain.discard(discardCandidate, in: context) }
                discardCandidate = nil
            }
            Button("Keep it", role: .cancel) { discardCandidate = nil }
        } message: {
            if let discardCandidate {
                Text("“\(Self.excerpt(discardCandidate.rawText, words: 12))” will be deleted.")
            }
        }
    }

    private var discardPresented: Binding<Bool> {
        Binding(
            get: { discardCandidate != nil },
            set: { if !$0 { discardCandidate = nil } })
    }

    private func label(for capture: Capture) -> some View {
        row(
            text: "Unfinished capture", detail: Self.excerpt(capture.rawText),
            age: Self.age(of: capture.createdAt))
    }

    private func row(text: String, detail: String, age: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: "text.quote")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
            // The label is the fixed part and the excerpt is the flexible one: without
            // saying so, the HStack let the excerpt keep its single line and broke "2
            // unfinished captures" over two, so the row read as a wrapped caption with
            // a quote beside it. Priority, not `fixedSize`: the label is served first
            // and the excerpt takes what is left, but at an accessibility size where the
            // label alone outgrows the row it still truncates instead of overflowing.
            Text(text)
                .supportingStyle()
                .lineLimit(1)
                .layoutPriority(1)
            Text("“\(detail)”")
                .supportingStyle()
                .foregroundStyle(Palette.mutedText)
                .lineLimit(1)
            Spacer(minLength: Spacing.xs)
            // WHEN, in the row's quietest register: "2h ago" is what lets the person
            // recognise the thought without opening it.
            Text(age)
                .font(.chipLabel)
                .foregroundStyle(Palette.mutedText)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.glyphCaption())
                .foregroundStyle(Palette.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// How long ago the words were left — `RelativeAge`'s vocabulary, shared with the
    /// resolved task row so the two captions can't drift.
    static func age(of date: Date, now: Date = Date()) -> String {
        RelativeAge.compact(date, now: now)
    }

    /// The first few words — enough to recognise, never the whole dump.
    static func excerpt(_ text: String, words: Int = 6) -> String {
        let all = text.split(whereSeparator: \.isWhitespace)
        let head = all.prefix(words).joined(separator: " ")
        return all.count > words ? head + "…" : head
    }
}
