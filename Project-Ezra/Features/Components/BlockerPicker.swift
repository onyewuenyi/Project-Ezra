//
//  BlockerPicker.swift
//  Project-Ezra
//
//  The one way to say what a task is waiting on. A menu of eligible tasks (already
//  cycle-filtered by the caller via `TaskItem.eligibleBlockerCandidates`) plus
//  "Something else…" for an untracked wait in the user's own words. Shared by the
//  Inbox decision bar and the detail sheet's "Waiting on" row so blocking reads and
//  behaves identically wherever it's offered — and so every block names its cause.
//

import SwiftUI

struct BlockerPicker<Label: View>: View {
    /// Eligible tracked tasks — caller pre-filters (not done, not self, not already a
    /// blocker, cycle-safe).
    let candidates: [TaskItem]
    let onPickTask: (TaskItem) -> Void
    /// `nil` note = "something else"; a trimmed phrase otherwise.
    let onPickExternal: (String?) -> Void
    @ViewBuilder var label: Label

    @State private var showExternalAlert = false
    @State private var externalText = ""

    var body: some View {
        Menu {
            if candidates.isEmpty {
                Text("No other open tasks")
            } else {
                ForEach(candidates) { candidate in
                    Button(candidate.title) { onPickTask(candidate) }
                }
            }
            Divider()
            Button {
                showExternalAlert = true
            } label: {
                SwiftUI.Label("Something else…", systemImage: "questionmark.circle")
            }
        } label: {
            label
        }
        .alert("Waiting on", isPresented: $showExternalAlert) {
            TextField("The contractor, a delivery, a reply…", text: $externalText)
            Button("Add") {
                onPickExternal(externalText)
                externalText = ""
            }
            Button("Cancel", role: .cancel) { externalText = "" }
        } message: {
            Text("Name what this is waiting on. It stays Blocked until you clear it.")
        }
    }
}
