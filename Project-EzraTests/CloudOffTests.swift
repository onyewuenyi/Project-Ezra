//
//  CloudOffTests.swift
//  Project-EzraTests
//
//  The product reads on the device only (2026-10-04) — it is free, and a free product
//  cannot carry a per-call bill. The property is "no path can reach a server", which is
//  the ABSENCE of something, so it is pinned at the one gate everything reads
//  (`CloudModel.isAvailable`) and at the one place the network stack would be started
//  (`AppDelegate`), not at the many call sites behind them.
//

import Foundation
import FoundationModels
import Testing

@testable import Project_Ezra

@MainActor
@Suite("The cloud rung is off — nothing can reach a server")
struct CloudOffTests {

    /// A provider that claims to be ready — the case a missing-plist check could never
    /// see. If the gate trusted the provider, this would turn the cloud on.
    private enum EagerProvider: CloudModelProvider {
        static let identifier = "eager"
        static var isAvailable: Bool { true }
        static let capabilities = LanguageModelCapabilities([])
        static func session(
            instructions: String, config: CapabilityProfiles.Config
        ) throws -> LanguageModelSession {
            throw ModelUnavailableError.unavailable
        }
    }

    @Test("A provider that says it is available still cannot turn the cloud on")
    func theGateDoesNotTrustTheProvider() {
        let original = CloudModel.provider
        CloudModel.provider = EagerProvider.self
        defer { CloudModel.provider = original }

        #expect(CloudModel.isEnabled == false)
        #expect(CloudModel.isAvailable == false)
        #expect(CloudModel.isReachable == false)
        for workload in IntelligenceWorkload.allCases {
            #expect(!CloudModel.isReachable(for: workload), "\(workload) must not reach the cloud")
        }
    }

    @Test("The privacy sentence is the true one while the cloud is off")
    func theCopyFollowsTheGate() {
        let sentence = DataBoundary.captureShortNow
        #expect(sentence.contains("not sent anywhere"))
        #expect(!sentence.contains("cloud"), "no promise of a cloud read the build cannot make")
    }

    @Test("Firebase is configured only behind the gate, so no token is ever requested")
    func firebaseSitsBehindTheGate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra/AppDelegate.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = source.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        .joined(separator: "\n")
        #expect(code.contains("if CloudModel.isEnabled, FirebaseOptions.defaultOptions() != nil"))
        // Exactly one configure call, and it is the guarded one.
        #expect(code.components(separatedBy: "FirebaseApp.configure()").count == 2)
        #expect(code.components(separatedBy: "AppCheckSetup.install()").count == 2)
    }
}
