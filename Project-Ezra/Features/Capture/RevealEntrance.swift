//
//  RevealEntrance.swift
//  Project-Ezra
//
//  The reveal's arrival. "Here's what I understood" is the emotional peak of the whole
//  product, and it used to be a cut: the cards were simply present on the next frame.
//
//  The list already carried a `.transition` with a stagger, and it never ran — the whole
//  confirm surface swaps in through the phase switch, and SwiftUI does not play a child's
//  insertion transition when the child arrives as part of a subtree that is itself being
//  inserted. Rather than fight that, the entrance is driven explicitly off a timestamp:
//  each card starts settled-out and animates in on a per-index delay. That works the same
//  way for the first reveal and for a restructure (where the set genuinely changes under
//  the user and deserves a real arrival rather than a cross-fade), because both just stamp
//  a new `revealedAt`.
//
//  Deliberately NOT a per-card entrance that runs forever after: the animation is keyed to
//  the reveal timestamp, so a card edited ten seconds later doesn't re-enter. The cascade
//  is the composition arriving once, not cards behaving like cards.
//

import SwiftUI

extension View {
    /// Ride the reveal's stagger. `index` is the card's place in the composition and
    /// `revealedAt` is the moment the set arrived; a nil timestamp means "already here"
    /// (a resumed capture, a preview) and renders settled with no animation.
    func revealEntrance(index: Int, revealedAt: Date?) -> some View {
        modifier(RevealEntrance(index: index, revealedAt: revealedAt))
    }
}

private struct RevealEntrance: ViewModifier {
    let index: Int
    let revealedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    /// After this many cards the delay stops growing. A six-card ramble should feel like
    /// one composition with a rhythm; a twenty-card one must not take a second and a half
    /// to finish arriving.
    private static let maxStaggeredCards = 5

    private var delay: Double {
        Double(min(index, Self.maxStaggeredCards)) * Motion.staggerStep
    }

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 10)
            .blur(radius: arrived ? 0 : 2)
            .task(id: revealedAt) {
                guard revealedAt != nil else {
                    arrived = true
                    return
                }
                guard !reduceMotion else {
                    // Still a state change, so the content is never left invisible —
                    // just no motion and no cascade.
                    withAnimation(Motion.fade) { arrived = true }
                    return
                }
                // NOTE: no `arrived = false` reset first. Setting it false and true in
                // the same async turn coalesces into a single transaction — SwiftUI sees
                // only the final value and the animation never plays. It also isn't
                // needed: `arrived` starts false, and on a restructure the cards that are
                // genuinely new get fresh state (so they cascade) while survivors stay
                // put — which is the better behaviour anyway. Only what changed moves.
                withAnimation(Motion.heroSettle.delay(delay)) { arrived = true }
            }
    }
}
