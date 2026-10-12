import AVFoundation
import Foundation
import Speech

/// Microphone → Apple's on-device dictation (SpeechAnalyzer + DictationTranscriber, macOS 26).
/// Streams the transcript as it forms and the input level for a waveform. Private: no audio or
/// text leaves the Mac.
@MainActor
final class SpeechEngine {
    enum EngineError: LocalizedError {
        case microphoneDenied, unsupportedLanguage, noInput
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Lizard can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
            case .unsupportedLanguage: "Voice typing isn't available for your language yet."
            case .noInput: "No microphone found."
            }
        }
    }

    /// Text so far and whether that part is final.
    var onText: ((String, Bool) -> Void)?
    /// 0…1 loudness, about 20 times a second.
    var onLevel: ((Float) -> Void)?
    /// Model download progress the first time (0…1).
    var onPreparing: ((Double) -> Void)?

    private let audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    /// The tap runs on Core Audio's own queue, so its block must not be main-actor isolated
    /// (a closure written inside this @MainActor class would be, and Swift traps when it runs).
    nonisolated private static func installTap(
        on node: AVAudioInputNode, format: AVAudioFormat, converter: BufferConverter,
        audio: AsyncStream<AnalyzerInput>.Continuation, levels: AsyncStream<Float>.Continuation
    ) {
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            levels.yield(BufferConverter.level(of: buffer))
            if let converted = converter.convert(buffer) { audio.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(locale: Locale = .current) async throws {
        guard await Self.requestMicrophone() else { throw EngineError.microphoneDenied }
        var supported = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        if supported == nil { supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let supported else { throw EngineError.unsupportedLanguage }

        let transcriber = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
        // First use per language: macOS downloads the speech model once.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let report = onPreparing
            let watcher = Task { @MainActor in
                while !Task.isCancelled, !progress.isFinished {
                    report?(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            try await request.downloadAndInstall()
            watcher.cancel()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let inputNode = audio.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.channelCount > 0 else { throw EngineError.noInput }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: micFormat) else {
            throw EngineError.unsupportedLanguage
        }
        try await analyzer.prepareToAnalyze(in: format, withProgressReadyHandler: nil)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let (levels, levelSink) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(4))
        levelContinuation = levelSink
        Self.installTap(on: inputNode, format: micFormat, converter: BufferConverter(from: micFormat, to: format), audio: continuation, levels: levelSink)
        let levelHandler = onLevel
        levelTask = Task { @MainActor in
            for await level in levels { levelHandler?(level) }
        }
        audio.prepare()
        try audio.start()

        let textHandler = onText
        resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.resultsFinalizationTime >= result.range.end
                    textHandler?(text, isFinal)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Stops listening and waits for the last words to be finalized.
    func finish() async {
        stopAudio()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        analyzer = nil
    }

    func cancel() async {
        stopAudio()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
    }

    private func stopAudio() {
        if audio.isRunning {
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
        }
        input?.finish()
        input = nil
        levelContinuation?.finish()
        levelContinuation = nil
        levelTask?.cancel()
    }
}

/// Converts microphone buffers to the analyzer's format; used from the audio thread.
final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let output: AVAudioFormat

    init(from input: AVAudioFormat, to output: AVAudioFormat) {
        self.output = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && converted.frameLength > 0 ? converted : nil
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // Speech sits around -40…-10 dB; map that onto 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 40))
    }
}
