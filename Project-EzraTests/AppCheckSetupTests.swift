//
//  AppCheckSetupTests.swift
//  Project-EzraTests
//
//  App Check's two failure modes are both SILENT, which is why they are pinned by grep
//  rather than by exercise. Installing the provider factory after `FirebaseApp.configure()`
//  is accepted without complaint and leaves the default in place; fencing the debug
//  provider on `#if DEBUG` instead of the simulator hands it to device runs, which are
//  Debug too. Neither shows up as a build error, a warning, or a failing call until the
//  moment enforcement is on — at which point it cannot be turned off again.
//
//  The suite cannot test the behaviour: `AppDelegate` deliberately returns before touching
//  Firebase under XCTest, and calling `install()` here would install a factory into a test
//  host that must never have Firebase configured at all. So what is asserted is the shape
//  of the code that runs on a real launch.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("App Check · the wiring that fails silently")
struct AppCheckSetupTests {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Trap one: `configure()` builds the App Check component and freezes its factory.
    @Test("The provider factory is installed BEFORE Firebase is configured")
    func installPrecedesConfigure() throws {
        // Comments stripped first: this file's own header explains the ordering and names
        // `FirebaseApp.configure()` while doing so, and the first shape of this test read
        // that sentence as the call. Prose may name it; the CALL is what is being ordered.
        let code = try source("AppDelegate.swift").split(separator: "\n").enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        guard let install = code.first(where: { $0.element.contains("AppCheckSetup.install()") }),
            let configure = code.first(where: { $0.element.contains("FirebaseApp.configure()") })
        else {
            Issue.record("AppDelegate no longer installs App Check or configures Firebase")
            return
        }
        #expect(
            install.offset < configure.offset,
            """
            AppCheckSetup.install() must run BEFORE FirebaseApp.configure(). Afterwards it \
            is a silent no-op: the default factory stays in place and the first token \
            request fails with nothing wrong in the code you are reading.
            """)
    }

    /// Trap two: a device run is a Debug run. The distinction is the hardware, so the
    /// condition has to be the hardware.
    @Test("The debug provider is fenced on the simulator, never on DEBUG")
    func theFenceIsHardwareNotConfiguration() throws {
        let setup = try source("AI/AppCheckSetup.swift")
        #expect(setup.contains("#if targetEnvironment(simulator)"))
        // `#if DEBUG` anywhere in this file would put the debug token on device runs,
        // which are built Debug by default and are the runs that must prove App Attest.
        let code = setup.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        #expect(
            !code.contains("#if DEBUG"),
            "the debug App Check provider must not be selected by build configuration")
    }

    /// A simulator run presents the console-registered debug token; hardware attests.
    @Test("The provider follows the hardware this build is running on")
    func providerFollowsHardware() {
        #if targetEnvironment(simulator)
        #expect(AppCheckSetup.provider == .debug)
        #else
        #expect(AppCheckSetup.provider == .appAttest)
        #endif
    }

    /// The stronger posture: a fresh single-use token per call rather than one cached
    /// token replayed for its lifetime.
    @Test("The AI instance asks for limited-use tokens")
    func limitedUseTokens() throws {
        #expect(try source("AI/GeminiProvider.swift").contains("useLimitedUseAppCheckTokens: true"))
    }

    /// The deadline is a value, not only prose — a date nobody can see is a date nobody
    /// meets, and this one is irreversible once passed.
    @Test("Enforcement day is 2026-11-02, in UTC")
    func enforcementDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: AppCheckSetup.enforcementBegins)
        #expect(parts.year == 2026)
        #expect(parts.month == 11)
        #expect(parts.day == 2)
    }

    /// The countdown, and the flip. "enforced in 52d" and "ENFORCED" are the two things
    /// the line has to be able to say; a line that only ever counts down would still read
    /// as a warning on the day it stopped being one.
    @Test("The diagnostics line counts down, then says it is enforced")
    func statusLineCountsDownThenFlips() {
        let before = AppCheckSetup.statusLine(
            now: AppCheckSetup.enforcementBegins.addingTimeInterval(-10 * 86_400))
        #expect(before.contains("enforced in 10d"))
        let after = AppCheckSetup.statusLine(
            now: AppCheckSetup.enforcementBegins.addingTimeInterval(86_400))
        #expect(after.contains("ENFORCED"))
        #expect(!after.contains("in "))
        // It names the mechanism and a date, so it must never be customer-facing copy.
        #expect(before.hasPrefix("app check:"))
    }
}
