//
//  AppDelegate.swift
//  Project-Ezra
//
//  The one piece of UIKit in the app, and it exists for exactly one reason: Firebase
//  wants to be configured once, at launch, before anything asks it for a model.
//
//  **Why a delegate rather than `App.init()`.** Firebase's own AI Logic sample configures
//  from `init()`, and for `FirebaseApp.configure()` alone that would work and cost one
//  fewer type. The delegate is here because the Firebase project this app points at has
//  messaging enabled, and every one of those surfaces (push registration, the APNs token
//  callback, notification opens) arrives through `UIApplicationDelegate` and nowhere
//  else. Adding the seam now is cheap; retrofitting it under a half-built push feature is
//  the sort of thing that gets done badly at 1am. If messaging never ships, this type is
//  three lines of dead weight and can collapse back into `init()`.
//
//  **Nothing else belongs in here.** This is not a second composition root. State, model
//  wiring, and scene lifecycle all live in `Project_EzraApp` and stay there — a delegate
//  that grows becomes the file where startup order goes to hide.
//

import FirebaseCore
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The test host must not configure Firebase. `GeminiProvider.isAvailable` answers
        // "is Firebase configured", so configuring it here would flip the cloud rung ON
        // for the whole suite: routing tests that assert the chain falls through to the
        // deterministic tail would instead attempt live Gemini calls — slow, billable,
        // network-dependent, and green or red depending on the wifi. The suite wants the
        // rung dormant, which is exactly what not configuring gives it.
        guard !Project_EzraApp.isHostingUnitTests else { return true }

        // **App Check becomes mandatory on 2026-11-02.** Until then AI Logic accepts
        // unattested requests, and this build deliberately sends them — the fewest moving
        // parts between here and a working call. After that date, requests without a valid
        // App Check token are blocked outright and enforcement cannot be turned off, so
        // this is a hard deadline rather than a recommendation.
        //
        // When it is added: install the provider factory BEFORE `configure()`, because
        // `configure()` is what builds the App Check component — setting it afterwards
        // leaves the default in place and the first token request fails with nothing
        // obviously wrong in the code. `AppCheckDebugProviderFactory` behind `#if DEBUG`
        // for simulators (its printed token is a credential: register it once per
        // simulator in the console, never commit it), App Attest for anything shipping.

        FirebaseApp.configure()
        return true
    }
}
