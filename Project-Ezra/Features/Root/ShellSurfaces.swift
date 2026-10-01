//
//  ShellSurfaces.swift
//  Project-Ezra
//
//  The shell's surfaces — the composer, Activity, Settings, the commit receipt and the
//  capture orb — as ONE host that a presentation context mounts once. There are two
//  contexts since Tasks became a sheet over the Ask home (2026-09-23): the root, and the
//  Tasks sheet. A sheet cannot be presented over another sheet from the same presenter
//  (SwiftUI queues it: "only presenting a single sheet is supported"), so the orb over
//  the list has to present ITS composer from inside the Tasks sheet, and the home's bar
//  presents its own from the root. Same definition, one instance per context, each
//  with its own `ShellSurfaceController` — the mount-once rule (`MyTasksHeader`, a
//  surface deleted for three weeks inside a conditional container) is kept per
//  context: nothing here is conditional, and the environment actions every deep view
//  uses (`\.openCapture`, `\.openActivity`, `\.openSettings`, `\.openRoster`,
//  `\.openTasks`) resolve to the context the view is actually in.
//

import CoreData
import SwiftUI

/// One presentation of the capture composer. Fresh id per open — every open is a new
/// session by construction, and `sheet(item:)` hands this value to the content
/// closure directly (see `ShellSurfaceController.presentComposer` for why that's
/// load-bearing).
struct ComposerSession: Identifiable {
    let id = UUID()
    let resuming: Capture?
    var autoSubmit = false
}

/// The presented state of one context's surfaces. A class, not view state, so the
/// shell's launch seams and the Siri hand-off can reach the ROOT context's surfaces
/// from `RootTabView` while the host owns the presentation.
@Observable
final class ShellSurfaceController {
    /// The presented composer session, item-based ON PURPOSE: with the paired
    /// `isPresented` + `resumingCapture` shape, SwiftUI evaluated the sheet's content
    /// closure once with the STALE nil resume target and re-evaluated with the real
    /// one only after `ComposerView` had already mounted and run its restore — so a
    /// resume silently opened a fresh composer (verified via the `-OpenCapture`
    /// console seam). `sheet(item:)` hands the closure the value itself; the race is
    /// unrepresentable. `resuming` nil = a fresh capture — opening the composer always
    /// starts a NEW one, so being interrupted twice never overwrites the first thought.
    var composerSession: ComposerSession?
    /// The Activity screen. Deliberately not badged: the trust surface is something you
    /// go to when you want to check or undo, never something that asks to be visited
    /// (guardrail 1 — the unread TAB BADGE died with the tab; the per-row unread dots
    /// survive inside, where they answer "what's new since I looked" for someone who
    /// already chose to look).
    var showActivity = false
    var showSettings = false
    /// The transient receipt shown after the composer closes — ONLY about a merge.
    var commitNotice: UndoNotice?

    /// The one way the composer is presented in this context. Every entry point (the
    /// orb, `\.openCapture`, `\.resumeCapture`, the seams, Siri) warms the substrate,
    /// sets the resume target explicitly — a stale one must never leak into a fresh
    /// capture — and clears any unconsumed commit summary, so a seed-path commit can't
    /// fire a receipt on a later dismiss.
    func presentComposer(
        resuming capture: Capture?, autoSubmit: Bool = false, brain: AppBrain,
        in context: NSManagedObjectContext
    ) {
        // Warm the model + retrieval substrate NOW: the sheet-presentation animation
        // absorbs the cost, so the first parse doesn't pay it against the user's pause.
        AppBrain.prewarmCapture(in: context)
        brain.lastCommitSummary = nil
        composerSession = ComposerSession(resuming: capture, autoSubmit: autoSubmit)
    }

    /// Speak for a confirm that just happened, once — and ONLY about a MERGE.
    ///
    /// This used to be justified as "what the composer's ✓ receipt couldn't say", the
    /// receipt having delivered the count. That receipt was removed on 2026-08-30 (it read
    /// as an extra screen), so this pill is now the ONLY thing that speaks after a commit —
    /// and it still deliberately says nothing about the count. The list the user just
    /// landed on shows the new tasks; a merge is the one outcome it cannot show, because
    /// the merged capture is folded into a task that was already there.
    ///
    /// Deliberately no Undo button: undoing a batch means deleting the created tasks AND
    /// reversing each merge AND unwinding the blocker edges commit wrote onto OTHER
    /// tasks — a half-honest version of that is worse than none, so per-item Undo stays
    /// in Activity where it already works, and this notice claims nothing about it.
    func presentCommitNotice(brain: AppBrain) {
        guard let summary = brain.lastCommitSummary, !summary.isEmpty else { return }
        brain.lastCommitSummary = nil  // consumed — a dismiss reports its own commit only
        guard let message = summary.messageBeyondReceipt else { return }
        commitNotice = UndoNotice(message: message)
    }
}

struct ShellSurfaces<Content: View>: View {
    let controller: ShellSurfaceController
    /// Whether this context parks the 62pt orb bottom-trailing over its content. The
    /// Tasks sheet does; the root does not, because the Ask home's composer bar carries
    /// its own (`ChatComposerBar.onCapture`) inside the bar's row.
    var showsOrb: Bool
    /// What the OWNER draws over this context — the root passes onboarding and the
    /// Tasks sheet; the Tasks sheet passes nothing. Folded into `\.orbCovered` so a
    /// permanently-mounted orb animation runs only while it can actually be seen.
    var coveredAbove: Bool = false
    /// Manage Household is a PUSH on the context's own stack, so the owner supplies it.
    let openRoster: () -> Void
    /// The Tasks sheet, from the root, on a preset; a no-op from inside it.
    let openTasks: (TasksPreset) -> Void
    /// **Capture lands on the home (2026-09-23).** Set by the Tasks sheet: when the
    /// composer it presented closes on a COMMIT, the sheet closes too, so the person
    /// returns to the home with the new tasks already folded into the answer — say it,
    /// see where it landed, done. The commit summary is left unconsumed for the root's
    /// host to speak (a merge's pill), on the sheet's own dismiss. Nil at the root.
    var landsOnHome: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.managedObjectContext) private var context
    @Environment(AppBrain.self) private var brain
    @Environment(\.scenePhase) private var scenePhase
    /// Whether the keyboard is up. The orb hides under it: the composer's capture bar
    /// owns that space while a keyboard is showing. Both `.overlay` on the content and a
    /// ZStack sibling with `.ignoresSafeArea(.keyboard)` laid the orb out against the
    /// keyboard-reduced bounds — it rode up and sat on a composer's Send button (measured
    /// twice, 2026-09-02) — so the fix is explicit: hidden, and its timeline paused. An
    /// orb beside no bar means nothing; hiding it is the truthful state.
    @State private var keyboardUp = false

    /// The orb's diameter, grown from the retired FAB's 52pt on 2026-08-29 to the system
    /// tab bar capsule's measured height, and kept after the bar went.
    static var captureButtonDiameter: CGFloat { 62 }
    /// The orb inside it, preserving the 11pt glass bezel the old 52/30 pairing had.
    static var captureOrbDiameter: CGFloat { 40 }

    private var orbShown: Bool { showsOrb && !keyboardUp }

    /// **`.background`, not `!= .active`.** The stricter test also catches `.inactive`,
    /// which is not "nobody is looking": it fires for the app switcher, Control Centre, an
    /// incoming call — and, in the simulator, for the window merely not being key, which
    /// left the orb frozen in every headless check. Those states are brief and mostly
    /// still visible, so the saving was nil and the cost was an orb that looked dead.
    ///
    /// KNOWN GAP, pre-existing: this does not cover `taskDetailSheet`, a `fullScreenCover`
    /// presented by the list and the chat rather than by this host.
    private var covered: Bool {
        controller.composerSession != nil || controller.showActivity || controller.showSettings
            || coveredAbove || scenePhase == .background
    }

    var body: some View {
        @Bindable var controller = controller
        ZStack(alignment: .bottomTrailing) {
            content()
                // The tab bar used to supply the bottom inset the list scrolled clear of;
                // with the bar gone the orb would sit over the last row. One inset, sized
                // to the orb and its padding, so the content ends above it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: showsOrb ? Self.captureButtonDiameter + Spacing.md * 2 : 0)
                }
            if showsOrb {
                CaptureOrbButton(
                    diameter: Self.captureButtonDiameter, orbDiameter: Self.captureOrbDiameter,
                    paused: !orbShown
                ) {
                    present(resuming: nil)
                }
                .padding(.trailing, Spacing.md)
                .padding(.bottom, Spacing.md)
                .opacity(orbShown ? 1 : 0)
                .allowsHitTesting(orbShown)
                .animation(Motion.fade, value: orbShown)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in keyboardUp = true }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in keyboardUp = false }
        .undoNotice($controller.commitNotice, bottomInset: Spacing.xxl)
        .environment(\.orbCovered, covered)
        .environment(\.openCapture, { present(resuming: nil) })
        .environment(\.resumeCapture, { capture in present(resuming: capture) })
        .environment(\.openActivity, { controller.showActivity = true })
        .environment(\.openSettings, { controller.showSettings = true })
        .environment(\.openRoster, openRoster)
        .environment(\.openTasks, openTasks)
        // Item-based, so however the sheet closed (commit, discard, swipe) the session
        // clears with it — the next open starts fresh unless \.resumeCapture re-arms it.
        .sheet(
            item: $controller.composerSession,
            onDismiss: {
                if let landsOnHome, let summary = brain.lastCommitSummary, !summary.isEmpty {
                    landsOnHome()
                    return
                }
                controller.presentCommitNotice(brain: brain)
            }
        ) { session in
            ComposerView(resuming: session.resuming, autoSubmit: session.autoSubmit)
        }
        .sheet(isPresented: $controller.showActivity) { ActivityView() }
        .sheet(isPresented: $controller.showSettings) { SettingsView() }
    }

    private func present(resuming capture: Capture?) {
        controller.presentComposer(resuming: capture, brain: brain, in: context)
    }
}
