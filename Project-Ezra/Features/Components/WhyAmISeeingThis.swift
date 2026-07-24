//
//  WhyAmISeeingThis.swift
//  Project-Ezra
//
//  Trust without exposing AI internals: a long-press reveals the observable facts
//  behind why something is surfaced — verbatim, no separate explanation system.
//  Relocated out of the (retired) Now surface because it is a general affordance:
//  the Today plan rows and the Household coordination feed both attach it.
//

import SwiftUI

extension View {
    /// Attach the given reasons as a long-press "Why am I seeing this?" explanation.
    func whyAmISeeingThis(_ reasons: [String]) -> some View {
        contextMenu {
            Section("Why am I seeing this") {
                ForEach(reasons, id: \.self) { reason in
                    Button(reason) {}
                }
            }
        }
    }
}
