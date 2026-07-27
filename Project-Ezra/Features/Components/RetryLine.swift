//
//  RetryLine.swift
//  Project-Ezra
//
//  What a capability card shows when an attempt didn't produce anything usable.
//
//  It replaces an `EmptyView()` that used to make the card silently collapse — the user
//  tapped a button and it vanished, which reads as the app breaking rather than as one
//  attempt failing.
//
//  The wording is deliberate. "Couldn't work out the steps" indicts the model as
//  incapable; "That didn't finish" describes THIS attempt, which is both more accurate
//  (usually a timeout or a cold model) and leaves the retry looking worth taking. No
//  alert, no error code on screen — the typed label goes to the DEBUG diagnostics footer,
//  which is where it is useful.
//

import SwiftUI

struct RetryLine: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(message)
                .supportingStyle()
            Button("Try again", action: retry)
                .font(.controlLabel)
                .foregroundStyle(Palette.accentFlat)
                .buttonStyle(.pressableLink)
            Spacer(minLength: 0)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ask again")
    }
}
