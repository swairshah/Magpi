import AVFoundation

/// Plays TTS audio through AVAudioPlayerNode on a shared AVAudioEngine.
///
/// By sharing the same engine as AudioCaptureSession (which has voice
/// processing enabled), macOS automatically applies acoustic echo
/// cancellation — the TTS output is subtracted from the mic input.
///
/// Takes raw PCM s16le audio data at 24kHz from pocket-tts and converts
/// it to the engine's output format for playback.
///
/// Falls back to ffplay if no engine is attached (e.g. AEC disabled).
final class AudioPlayer {

    enum PlayerError: Error, LocalizedError {
        case noPlaybackMethod
        case invalidAudioData

        var errorDescription: String? {
            switch self {
            case .noPlaybackMethod: return "No audio engine or ffplay available for playback"
            case .invalidAudioData: return "Could not create audio buffer from TTS data"
            }
        }
    }

    /// The AVAudioPlayerNode attached to the shared engine.
    private var playerNode: AVAudioPlayerNode?
    /// The engine this player is attached to (weak — owned by AudioCaptureSession).
    private weak var attachedEngine: AVAudioEngine?
    /// Converter from TTS format (24kHz s16le mono) to the engine's output format.
    private var converter: AVAudioConverter?
    /// The TTS source format: 24kHz, signed 16-bit integer, mono.
    private let ttsFormat: AVAudioFormat
    /// The mixer format we connect the player node to.
    private var outputFormat: AVAudioFormat?

    /// ffplay process for fallback playback.
    private var currentProcess: Process?
    private let lock = NSLock()
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Whether audio is currently playing.
    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let node = playerNode, node.isPlaying { return true }
        return currentProcess?.isRunning ?? false
    }

    init() {
        // TTS returns s16le at 24kHz mono
        ttsFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Constants.ttsSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    // MARK: - Engine Attachment

    /// Attach to a shared AVAudioEngine. Must be called before play().
    /// The engine should already be started (by AudioCaptureSession).
    func attach(to engine: AVAudioEngine) {
        lock.lock()
        defer { lock.unlock() }

        // Detach previous if any
        if let oldNode = playerNode, let oldEngine = attachedEngine {
            oldNode.stop()
            oldEngine.detach(oldNode)
        }

        let node = AVAudioPlayerNode()
        engine.attach(node)

        // Connect to the engine's main mixer so output goes through
        // the same path that voice processing monitors for AEC.
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(node, to: engine.mainMixerNode, format: mixerFormat)

        // Create converter from TTS format → mixer format
        converter = AVAudioConverter(from: ttsFormat, to: mixerFormat)
        outputFormat = mixerFormat

        playerNode = node
        attachedEngine = engine

        print("Magpi: AudioPlayer attached to engine (mixer: \(Int(mixerFormat.sampleRate))Hz, \(mixerFormat.channelCount)ch)")
    }

    /// Detach from the engine (called on shutdown).
    func detach() {
        lock.lock()
        defer { lock.unlock() }

        playerNode?.stop()
        if let node = playerNode, let engine = attachedEngine {
            engine.detach(node)
        }
        playerNode = nil
        attachedEngine = nil
        converter = nil
        outputFormat = nil
    }

    // MARK: - Playback

    /// Play raw PCM audio data (s16le, 24kHz, mono).
    /// Blocks until playback completes or is interrupted.
    /// Uses the shared AVAudioEngine if attached, otherwise falls back to ffplay.
    func play(audioData: Data) async throws {
        lock.lock()
        let hasEngine = playerNode != nil && converter != nil && outputFormat != nil
        lock.unlock()

        if hasEngine {
            try await playViaEngine(audioData: audioData)
        } else {
            try await playViaFFPlay(audioData: audioData)
        }
    }

    /// Stop current playback immediately (for barge-in or push-to-talk).
    func stop() {
        lock.lock()
        let node = playerNode
        let process = currentProcess
        let cont = playbackContinuation
        playbackContinuation = nil
        currentProcess = nil
        lock.unlock()

        node?.stop()
        if let process = process, process.isRunning {
            process.terminate()
        }
        cont?.resume()
    }

    // MARK: - Engine Playback (AEC path)

    private func playViaEngine(audioData: Data) async throws {
        lock.lock()
        guard let node = playerNode, let converter = converter,
              let outFormat = outputFormat else {
            lock.unlock()
            throw PlayerError.noPlaybackMethod
        }
        lock.unlock()

        // Wrap raw s16le bytes in an AVAudioPCMBuffer
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: ttsFormat,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ) else {
            throw PlayerError.invalidAudioData
        }

        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)
        audioData.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(inputBuffer.int16ChannelData![0], src, audioData.count)
        }

        // Convert to engine output format
        let outputFrameCount = AVAudioFrameCount(
            Double(sampleCount) * outFormat.sampleRate / Constants.ttsSampleRate
        )
        guard outputFrameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outFormat,
                  frameCapacity: outputFrameCount
              ) else {
            throw PlayerError.invalidAudioData
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status == .haveData else {
            if let err = conversionError {
                print("Magpi: Audio conversion error: \(err)")
            }
            throw PlayerError.invalidAudioData
        }

        // Schedule and play, waiting for completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            // Resume any leaked previous continuation before replacing
            let previousCont = playbackContinuation
            playbackContinuation = continuation
            lock.unlock()
            previousCont?.resume()

            node.stop()  // Stop any previous playback
            node.scheduleBuffer(outputBuffer) { [weak self] in
                self?.lock.lock()
                let cont = self?.playbackContinuation
                self?.playbackContinuation = nil
                self?.lock.unlock()
                cont?.resume()
            }
            node.play()
        }
    }

    // MARK: - ffplay Fallback

    private func playViaFFPlay(audioData: Data) async throws {
        guard let ffplayPath = findFFPlay() else {
            throw PlayerError.noPlaybackMethod
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpi-playback-\(UUID().uuidString).raw")
        try audioData.write(to: tempURL)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffplayPath)
        process.arguments = [
            "-f", "s16le",
            "-ar", "24000",
            "-ch_layout", "mono",
            "-nodisp",
            "-autoexit",
            "-loglevel", "quiet",
            tempURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        lock.lock()
        currentProcess = process
        lock.unlock()

        try process.run()

        await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] _ in
                self?.lock.lock()
                self?.currentProcess = nil
                self?.playbackContinuation = nil
                self?.lock.unlock()
                continuation.resume()
            }
        }
    }

    private func findFFPlay() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffplay",
            "/usr/local/bin/ffplay",
            "/usr/bin/ffplay",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffplay"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = path, !path.isEmpty {
                return path
            }
        } catch {}

        return nil
    }
}
