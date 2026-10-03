//
//  ModelErrorLabelTests.swift
//  Project-EzraTests
//
//  `AppBrain.errorLabel` is the key every model-failure counter and eval histogram is
//  bucketed by, so its vocabulary is a contract: iOS 27 split the 26-era
//  `GenerationError` across three enums, and a label that followed the enum would have
//  split every series in two at the OS boundary. These pin one name per meaning, the
//  three GA cases the 27.0 SDK added, and the detail channel that carries what a name
//  cannot (the throttle's reset date, the overflow's token counts).
//

import Foundation
import FoundationModels
import Testing

@testable import Project_Ezra

@MainActor
struct ModelErrorLabelTests {

    @Test func gaModelErrorsCarryTheirCaseName() {
        let overflow = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long"))
        #expect(AppBrain.errorLabel(overflow) == "contextSizeExceeded")
        #expect(AppBrain.errorDetail(overflow) == "9000 tok in a 8192 window")

        let timeout = LanguageModelError.timeout(.init(debugDescription: "slow"))
        #expect(AppBrain.errorLabel(timeout) == "modelTimeout")
        #expect(AppBrain.errorDetail(timeout) == nil)
    }

    @Test func rateLimitedNamesItsResetInTheDetailNeverTheLabel() {
        let throttled = LanguageModelError.rateLimited(
            .init(resetDate: Date().addingTimeInterval(90), debugDescription: "background"))
        #expect(AppBrain.errorLabel(throttled) == "rateLimited")
        let detail = try! #require(AppBrain.errorDetail(throttled))
        #expect(detail.hasPrefix("reset in "))
        #expect(detail.hasSuffix("background"))
        #expect(AppBrain.errorLine(throttled).hasPrefix("rateLimited (reset in "))
    }

    @Test func sessionAndAssetErrorsKeepTheirTwentySixNames() {
        #expect(AppBrain.errorLabel(LanguageModelSession.Error.concurrentRequests) == "concurrentRequests")
        #expect(
            AppBrain.errorLabel(LanguageModelSession.Error.transcriptMutationWhileResponding)
                == "transcriptMutationWhileResponding")
        let parsing = GeneratedContent.ParsingError(rawContent: "{", debugDescription: "cut off")
        #expect(AppBrain.errorLabel(parsing) == "decodingFailure")
    }

    @Test func modelTimeoutIsNotTheDeadline() {
        // `ModelDeadline.Exceeded` is OUR clock and reads `timedOut`; the model's own
        // timeout is a different fact and must not fold into it.
        #expect(AppBrain.errorLabel(ModelUnavailableError.timedOut) == "timedOut")
        #expect(AppBrain.errorLabel(LanguageModelError.timeout(.init(debugDescription: ""))) != "timedOut")
    }

    @Test func runStampNamesTheOSBuildAndTellsSimulatorFromDevice() {
        let stamp = Instrument.runStamp(model: "m", configuration: "c")
        #expect(stamp.contains("(\(Instrument.osBuild))"))
        #expect(Instrument.osBuild != "?")
        #if targetEnvironment(simulator)
        #expect(Instrument.deviceIdentity.hasPrefix("sim:"))
        #else
        #expect(!Instrument.deviceIdentity.hasPrefix("sim:"))
        #endif
    }
}
