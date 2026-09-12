//
//  TelemetryAllowlistTests.swift
//  Project-EzraTests
//
//  The product-telemetry boundary (`Models/Telemetry.swift`): user data is local-first,
//  product telemetry is not — and the thing that keeps those two apart is a TYPE, not a
//  review. These tests pin the type's shape (no free-text parameter can exist), the
//  wire vocabulary (every value is a raw value of a closed enum), the opt-out (checked
//  in front of the vendor), the kill switches (fail closed as "not killed"), and that
//  exactly one file in the app knows the vendor exists.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Telemetry — the allowlist is a type")
struct TelemetryAllowlistTests {

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Project-Ezra")

    private func source(_ file: String) throws -> String {
        try String(contentsOf: Self.sourceRoot.appendingPathComponent(file), encoding: .utf8)
    }

    @Test("Every event's name and every metadata value is a closed-vocabulary token")
    func wireVocabularyIsClosed() throws {
        let name = try Regex("^[a-z]+(_[a-z]+)*$")
        let token = try Regex("^[A-Za-z0-9_.+<>-]+$")
        for event in TelemetryEvent.exemplars {
            #expect(event.name.wholeMatch(of: name) != nil, "\(event.name) is not snake_case")
            for (key, value) in event.metadata {
                #expect(key.wholeMatch(of: name) != nil, "\(key) is not a snake_case key")
                #expect(value.wholeMatch(of: token) != nil, "\(event.name).\(key) = \(value) is not a token")
                #expect(value.count <= 24, "\(event.name).\(key) = \(value) is long enough to carry text")
            }
        }
    }

    @Test("No case of TelemetryEvent carries a String, Int, Double, Date or UUID payload — structurally")
    func noFreeTextParameter() throws {
        // The allowlist's whole strength is that a task title has no parameter to go
        // into. Grep the enum body for a raw-typed associated value, because a type
        // system permits `case x(title: String)` and a review might not notice it.
        let content = try source("Models/Telemetry.swift")
        guard let start = content.range(of: "enum TelemetryEvent"),
            let end = content.range(of: "var name: String", range: start.upperBound..<content.endIndex)
        else {
            Issue.record("TelemetryEvent's case block was not found")
            return
        }
        let cases = content[start.upperBound..<end.lowerBound]
        for raw in [": String", ": Int", ": Double", ": Date", ": UUID", ": [String", ": Any"] {
            #expect(
                !cases.contains(raw),
                "TelemetryEvent declares a raw \(raw) payload — add an enum or a bucket instead")
        }
    }

    @Test("Exactly one file imports the vendor, and the domain never names it")
    func vendorIsOneConformance() throws {
        let fm = FileManager.default
        var importers: [String] = []
        if let files = fm.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                let content = try String(contentsOf: url, encoding: .utf8)
                if content.contains("import Statsig") || content.contains("Statsig.") {
                    importers.append(url.lastPathComponent)
                }
            }
        }
        #expect(importers == ["StatsigSink.swift"], "the vendor leaked into: \(importers)")
    }

    @Test("Opt-out is honoured in front of the sink, and the install id is a UUID")
    func optOutAndInstallID() {
        let defaults = UserDefaults(suiteName: "TelemetryAllowlistTests.\(UUID())")!
        let sink = RecordingTelemetrySink()
        let previous = Telemetry.sink
        Telemetry.sink = sink
        defer { Telemetry.sink = previous }

        Telemetry.log(.taskCompleted, defaults: defaults)
        #expect(sink.events.count == 1)
        Telemetry.setEnabled(false, defaults: defaults)
        Telemetry.log(.taskCompleted, defaults: defaults)
        #expect(sink.events.count == 1, "an opted-out install still logged")

        let id = Telemetry.installID(defaults: defaults)
        #expect(UUID(uuidString: id) != nil)
        #expect(Telemetry.installID(defaults: defaults) == id, "the install id must be stable")
    }

    @Test("Kill switches fail closed: no sink, unknown gate and opted-out all read not-killed")
    func killSwitchesFailClosed() {
        let defaults = UserDefaults(suiteName: "TelemetryAllowlistTests.kill.\(UUID())")!
        let previous = Telemetry.sink
        defer { Telemetry.sink = previous }

        Telemetry.sink = nil
        #expect(!Telemetry.isKilled(.killCloudCapture, defaults: defaults))

        let sink = RecordingTelemetrySink(killed: [TelemetryGate.killCloudCapture.rawValue])
        Telemetry.sink = sink
        #expect(Telemetry.isKilled(.killCloudCapture, defaults: defaults))
        #expect(!Telemetry.isKilled(.killCloudAdvisor, defaults: defaults))

        Telemetry.setEnabled(false, defaults: defaults)
        #expect(
            !Telemetry.isKilled(.killCloudCapture, defaults: defaults),
            "opting out of telemetry must not engage a kill switch")
    }

    @Test("Buckets cover the launch plan's targets and never leak the raw number")
    func bucketsAreCoarse() {
        #expect(DurationBucket(seconds: 240) == .oneToFiveMinutes)
        #expect(DurationBucket(seconds: 301) == .fiveToThirtyMinutes)
        #expect(DurationBucket(seconds: 0.4) == .underOneSecond)
        #expect(CountBucket(0) == .zero)
        #expect(CountBucket(3) == .twoToThree)
        #expect(CountBucket(47) == .thirteenPlus)
        #expect(Set(CountBucket.allCases.map(\.rawValue)).count == CountBucket.allCases.count)
    }

    @Test("The boundary sentence names no vendor and leads with what is NOT sent")
    func boundarySentence() {
        let sentence = Telemetry.boundarySentence
        for vendor in ["Statsig", "Firebase", "Google", "Apple", "analytics", "SDK"] {
            #expect(!sentence.localizedCaseInsensitiveContains(vendor), "names \(vendor)")
        }
        #expect(sentence.hasPrefix("Ezra never sends"))
        let live = DataBoundary.current(cloudReachable: false, telemetry: true, syncLive: false)
        #expect(live.sentences.count == 4)
        let quiet = DataBoundary.current(cloudReachable: false, telemetry: false, syncLive: false)
        #expect(quiet.sentences.count == 3, "no telemetry → no sentence about it")
    }
}
