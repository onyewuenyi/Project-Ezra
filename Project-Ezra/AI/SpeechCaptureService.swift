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
        /// Voice cannot run right now. `retryable` separates "this phone will never do
        /// it" from "this attempt did not work" — a first-use model download that fails
        /// because the person is on a train is the second kind, and used to be presented
        /// as the first (see `sentence(for:)`).
        case unavailable(String, retryable: Bool)
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

    /// Bumped by every `stop()`. An in-flight `start()` carries the value it began with
    /// and abandons itself the moment the two disagree.
    ///
    /// **Why a token and not a cancelled `Task` (2026-09-20).** `start()` suspends twice
    /// — on the permission prompt, and inside `beginTranscribing` on the first-run speech
    /// model, which can DOWNLOAD — and `stop()` did nothing about either. So a stop that
    /// landed during warm-up tore down an engine that was not running yet, and the
    /// suspended `start()` then resumed, installed the tap, activated the session and set
    /// `.listening` on top of it. The result is the one state this app must never reach:
    /// a live microphone with no orb, no listening surface and nothing on screen saying
    /// so, on a sheet the person had already left. "Getting the mic ready…" appears at
    /// two seconds and invites exactly that tap. Cancellation alone would not fix it,
    /// because neither `AVAudioApplication.requestRecordPermission` nor the model
    /// download honours it — the only reliable answer is to let the work finish and then
    /// refuse its result.
    private var startToken = 0

    func start() async {
        guard !isActive else { return }
        finalizedText = ""
        volatileText = ""
        audioLevel.reset()
        let token = startToken

        // `.preparing` BEFORE the permission await: on first run the system prompt
        // suspends this function mid-await, and a surface keyed on the state would
        // otherwise say "Listening" over a mic that is not running yet.
        state = .preparing
        let granted = await requestMicPermission()
        // A stop landed while the prompt was up. Say nothing and touch no state: the
        // surface has already settled somewhere else, and `.denied` here would put an
        // explanation under a control the person is no longer looking at.
        guard token == startToken else { return }
        guard granted else { state = .denied; return }

        do {
            try await beginTranscribing()
            // The expensive await is the one that matters: the model can take tens of
            // seconds on first use, and the tap is live by the time we get here. If the
            // person left in the meantime, give the microphone straight back.
            guard token == startToken else {
                stop()
                return
            }
            state = .listening
        } catch {
            teardownAudio()
            // The calm copy is for the user; the REAL error must never be discarded —
            // this catch swallowed an AVFoundation NSError on the first device run and
            // the only symptom was the generic sentence, which diagnoses nothing.
            #if DEBUG
            print("SpeechCapture: \(setupStage) failed — \(error)")
            #endif
            state = .unavailable(Self.sentence(for: error), retryable: Self.isRetryable(error))
        }
    }

    /// Which `beginTranscribing` stage was in flight when a throw escaped — DEBUG
    /// diagnosis only, never user-facing.
    private var setupStage = "start"

    /// What the person reads when voice will not start. **Always one of ours (2026-09-20).**
    ///
    /// This used to be `(error as? LocalizedError)?.errorDescription`, and `NSError`
    /// conforms to `LocalizedError` — so the canvas rendered whatever AVFoundation or
    /// Speech happened to say, verbatim, under the composer. On a real device that reads
    /// "The operation couldn't be completed. (com.apple.coreaudio.avfaudio error
    /// 561145187.)". A framework's sentence on a customer's screen is the same rule break
    /// as a vendor name: it names our internals, it cannot be acted on, and it is the
    /// opposite of the calm this surface is for. The error still reaches the DEBUG log,
    /// where a diagnosis belongs.
    static func sentence(for error: Error) -> String {
        switch error as? SpeechCaptureError {
        case .localeUnsupported?, .unsupported?:
            return (error as? SpeechCaptureError)?.errorDescription ?? Self.genericSentence
        case nil:
            return isRetryable(error)
                ? "Couldn't get the microphone ready. Check your connection and try again."
                : Self.genericSentence
        }
    }

    private static let genericSentence = "Voice capture isn't available here."

    /// Whether trying again could plausibly work. The two `SpeechCaptureError` cases are
    /// facts about the device and the person's language, so they are not; everything else
    /// is a condition — a first-use model download on a bad connection, an audio session
    /// another app was holding — and used to be presented as permanent, greying out Speak
    /// for the rest of the sheet with no way back except closing and reopening it.
    static func isRetryable(_ error: Error) -> Bool {
        error as? SpeechCaptureError == nil
    }

    /// Try the microphone again after a retryable failure, from the same sheet.
    func retry() async {
        guard case .unavailable(_, retryable: true) = state else { return }
        state = .idle
        await start()
    }

    func stop() {
        // Invalidate any `start()` still suspended on the permission prompt or the
        // model download. Without this the mic comes back up after the person asked
        // for it to go away — see `startToken`.
        startToken += 1
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
        setupStage = "locale"
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        guard
            let locale = Self.resolveLocale(
                preferred: Locale.current, supported: supported, installed: installed)
        else { throw SpeechCaptureError.localeUnsupported }

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

    /// Which supported locale should actually transcribe for someone whose device is set
    /// to `preferred`. Nil only when the person's LANGUAGE is not supported at all.
    ///
    /// **Why a fallback exists (2026-09-20).** This matched the full BCP-47 identifier
    /// exactly, and Apple ships regional English but not all of it — `en-US`, `en-GB`,
    /// `en-IN` and friends, but not `en-NG`, `en-PH`, `en-KE`. An English speaker in Lagos
    /// therefore got the flagship surface of a voice-first app switched off permanently,
    /// under a sentence — "Voice capture isn't available for your language yet" — that was
    /// not even true: their language is supported, their REGION is not. A regional variant
    /// is an accent model, not a different language, so falling back to a sibling gives a
    /// slightly worse transcript instead of no transcript, which is the right trade every
    /// time.
    ///
    /// Order: the exact match, then a sibling already INSTALLED (no download, and whatever
    /// the phone already has is what it was set up with), then any sibling, picked by
    /// sorted identifier so the choice is deterministic rather than dictionary order.
    /// Pure, so `SpeechLocaleTests` can exercise the shapes no simulator offers.
    static func resolveLocale(
        preferred: Locale, supported: [Locale], installed: [Locale]
    ) -> Locale? {
        let target = preferred.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == target }) { return exact }

        guard let language = preferred.language.languageCode?.identifier else { return nil }
        let siblings = supported.filter { $0.language.languageCode?.identifier == language }
        guard !siblings.isEmpty else { return nil }

        let installedIDs = Set(installed.map { $0.identifier(.bcp47) })
        let ready = siblings.filter { installedIDs.contains($0.identifier(.bcp47)) }
        let pool = ready.isEmpty ? siblings : ready
        return pool.min { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
    }

    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let target = locale.identifier(.bcp47)
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
