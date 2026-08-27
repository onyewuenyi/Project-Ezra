//
//  SpeechCaptureService.swift
//  Project-Ezra
//
//  Real, fully on-device dictation for the composer, via iOS 26's SpeechAnalyzer /
//  SpeechTranscriber. Nothing about the user's messy life leaves the device — the
//  same privacy stance as FoundationModelsEngine. The service owns the audio session
//  (active only while listening), the transcriber lifecycle, and a small state
//  machine the composer renders. It degrades gracefully: no permission → `.denied`
//  with a recoverable hint; simulator / missing assets → `.unavailable`, never a crash.
//

import Foundation
import AVFoundation
import Speech
import Observation

@MainActor
@Observable
final class SpeechCaptureService {

    enum State: Equatable {
        case idle
        case preparing  // asset download / session warm-up (one-time, shown as a pulse)
        case listening
        case denied
        case unavailable(String)
    }

    private(set) var state: State = .idle
    /// Settled transcript for this dictation session.
    private(set) var finalizedText = ""
    /// The in-flight hypothesis, replaced as the model refines it.
    private(set) var volatileText = ""
    /// Live mic level for the listening UI. A separate observable ON PURPOSE — it
    /// updates at buffer cadence, and only the leaf view that renders it (the
    /// listening orb) should re-render at that rate (see `AudioLevelMonitor`).
    let audioLevel = AudioLevelMonitor()

    /// The full editable transcript so far (settled + in-flight).
    var transcript: String { finalizedText + volatileText }

    var isActive: Bool { state == .listening || state == .preparing }

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        // A phone call or Siri kills the audio engine while `state` stays
        // `.listening` — the surface would keep listening to a dead tap forever
        // (the silence finish only arms on transcript deltas, and a dead tap
        // produces none). Fold the interruption into an ordinary stop; the
        // composer's lifecycle rule treats any non-user-initiated drop as
        // "settle to the canvas with the words so far".
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.stop()
            }
        }
    }

    // MARK: - Control

    func toggle() {
        if isActive {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isActive else { return }
        finalizedText = ""
        volatileText = ""
        audioLevel.reset()

        // `.preparing` BEFORE the permission await: on first run the system prompt
        // suspends this function mid-await, and a surface keyed on the state would
        // otherwise say "Listening" over a mic that is not running yet.
        state = .preparing
        let granted = await requestMicPermission()
        guard granted else { state = .denied; return }

        do {
            try await beginTranscribing()
            state = .listening
        } catch {
            teardownAudio()
            // The calm copy is for the user; the REAL error must never be discarded —
            // this catch swallowed an AVFoundation NSError on the first device run and
            // the only symptom was the generic sentence, which diagnoses nothing.
            #if DEBUG
            print("SpeechCapture: \(setupStage) failed — \(error)")
            #endif
            let message =
                (error as? LocalizedError)?.errorDescription ?? "Voice capture isn't available here."
            state = .unavailable(message)
        }
    }

    /// Which `beginTranscribing` stage was in flight when a throw escaped — DEBUG
    /// diagnosis only, never user-facing.
    private var setupStage = "start"

    func stop() {
        teardownAudio()
        inputBuilder?.finish()
        inputBuilder = nil
        recognizerTask?.cancel()
        recognizerTask = nil
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        analyzer = nil
        transcriber = nil
        // Fold the last in-flight hypothesis into the committed transcript so the
        // text the user sees stays put after they stop.
        if !volatileText.isEmpty {
            finalizedText += volatileText
            volatileText = ""
        }
        audioLevel.reset()
        state = .idle
    }

    // MARK: - Transcription setup

    private func beginTranscribing() async throws {
        let locale = Locale.current
        setupStage = "transcriber"
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        setupStage = "assets"
        try await ensureModel(for: transcriber, locale: locale)

        setupStage = "analyzer"
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else {
            throw SpeechCaptureError.unsupported
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        // Consume results as they stream in — volatile refines, final commits. The
        // Task inherits the main actor, so `ingest` is a plain (non-awaited) call.
        recognizerTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    self?.ingest(piece, isFinal: result.isFinal)
                }
            } catch {
                // Stream ended or errored — keep whatever was transcribed.
            }
        }

        setupStage = "analyzer-start"
        try await analyzer.start(inputSequence: inputSequence)

        // Audio session is activated only for the duration of listening.
        // `.playAndRecord` + `.spokenAudio` is the pairing Apple's SpeechAnalyzer
        // sample ships. `.record` + `.spokenAudio` was the first version here, and it
        // is the sim-vs-hardware trap in miniature: `.spokenAudio` is a playback-family
        // mode, the simulator's stub session accepted the pairing, and the first real
        // device run threw out of `setCategory` — surfacing as the generic
        // "isn't available here" because the NSError matched no typed arm.
        setupStage = "audio-session"
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        setupStage = "engine"
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)

        // The tap fires off the main actor. It captures only the (thread-safe) stream
        // continuation, the pure converter, and the level monitor reference — never
        // `self` — so the analyzer path has no isolation hop. `AVAudioPCMBuffer`
        // isn't Sendable (warning-only in Swift 5 mode).
        let monitor = audioLevel
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // Level metering rides the buffer we already hold — RMS via vDSP before
            // the yield, one main-actor hop per buffer (~12/s), nothing added to the
            // analyzer path itself.
            if let rms = AudioLevelMonitor.rms(of: buffer) {
                let normalized = AudioLevelMonitor.normalizedLevel(rms: rms)
                Task { @MainActor in monitor.ingest(rawLevel: normalized) }
            }
            guard let converter,
                let converted = Self.convert(buffer, using: converter, to: analyzerFormat)
            else { return }
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func ingest(_ piece: String, isFinal: Bool) {
        if isFinal {
            finalizedText += piece
            volatileText = ""
        } else {
            volatileText = piece
        }
    }

    // MARK: - Assets & permission

    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let target = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == target }) else {
            throw SpeechCaptureError.localeUnsupported
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == target }) { return }
        // First-use download — happens while the composer shows the `.preparing` pulse.
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Teardown

    private func teardownAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Format conversion (pure, callable from the audio thread)

    nonisolated private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

enum SpeechCaptureError: LocalizedError {
    case localeUnsupported
    case unsupported

    var errorDescription: String? {
        switch self {
        case .localeUnsupported: return "Voice capture isn't available for your language yet."
        case .unsupported: return "On-device voice capture isn't available on this device."
        }
    }
}
