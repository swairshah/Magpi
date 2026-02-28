import AVFoundation

/// Plays TTS audio through an AVAudioPlayerNode for echo cancellation.
///
/// By playing TTS through the same AVAudioEngine that captures the mic,
/// macOS voice processing can use the playback as a reference signal
/// and cancel it from the mic input (acoustic echo cancellation).
final class AudioPlayer {

    private var playerNode: AVAudioPlayerNode?
    private weak var engine: AVAudioEngine?
    /// The format the player node is connected with — all scheduled buffers must match this.
    private var playerFormat: AVAudioFormat?
    private let lock = NSLock()
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Whether audio is currently playing.
    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playerNode?.isPlaying ?? false
    }

    /// Attach this player to an AVAudioEngine.
    /// Must be called BEFORE engine.start().
    func attach(to engine: AVAudioEngine) {
        let node = AVAudioPlayerNode()
        engine.attach(node)

        // Use mainMixerNode's output format for connection.
        // This ensures compatibility with the engine's output chain.
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        // If the mixer format looks bad (0Hz, 0ch), fall back to a standard format
        let connectFormat: AVAudioFormat
        if mixerFormat.sampleRate > 0 && mixerFormat.channelCount > 0 && mixerFormat.channelCount <= 2 {
            connectFormat = mixerFormat
        } else {
            // Safe default: 48kHz stereo float32
            connectFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 2,
                interleaved: false
            )!
        }

        engine.connect(node, to: engine.mainMixerNode, format: connectFormat)

        self.playerNode = node
        self.engine = engine
        self.playerFormat = connectFormat

        print("Magpi: AudioPlayer attached (format: \(Int(connectFormat.sampleRate))Hz, \(connectFormat.channelCount)ch)")
    }

    /// Play raw PCM audio data (s16le, 24kHz, mono).
    /// Blocks until playback completes or is interrupted.
    func play(audioData: Data) async throws {
        guard let playerNode = playerNode, let _ = engine, let playerFormat = playerFormat else {
            throw PlayerError.notAttached
        }

        guard !audioData.isEmpty else { return }

        // Source: s16le 24kHz mono
        let sourceSampleRate: Double = 24000
        let sourceFrameCount = audioData.count / 2

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PlayerError.formatError("Could not create source format")
        }

        // Convert s16le → float32 source buffer
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFrameCount)
        ) else {
            throw PlayerError.formatError("Could not create source buffer")
        }
        sourceBuffer.frameLength = AVAudioFrameCount(sourceFrameCount)

        guard let floatData = sourceBuffer.floatChannelData?[0] else {
            throw PlayerError.formatError("Could not access float buffer")
        }

        audioData.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sourceFrameCount {
                floatData[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        // Convert to the player node's connected format (must match exactly)
        let playBuffer: AVAudioPCMBuffer

        if abs(sourceSampleRate - playerFormat.sampleRate) < 1.0
            && playerFormat.channelCount == 1 {
            // Formats match, use source directly
            playBuffer = sourceBuffer
        } else {
            // Convert sample rate and/or channel count
            guard let converter = AVAudioConverter(from: sourceFormat, to: playerFormat) else {
                throw PlayerError.formatError(
                    "Cannot convert \(Int(sourceSampleRate))Hz/1ch → \(Int(playerFormat.sampleRate))Hz/\(playerFormat.channelCount)ch"
                )
            }

            let outputFrameCount = AVAudioFrameCount(
                Double(sourceFrameCount) * playerFormat.sampleRate / sourceSampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: playerFormat,
                frameCapacity: outputFrameCount
            ) else {
                throw PlayerError.formatError("Could not create output buffer")
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if let error = error {
                throw PlayerError.formatError("Conversion failed: \(error)")
            }

            playBuffer = convertedBuffer
        }

        // Schedule and play
        if !playerNode.isPlaying {
            playerNode.play()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            playbackContinuation = continuation
            lock.unlock()

            playerNode.scheduleBuffer(playBuffer) { [weak self] in
                self?.lock.lock()
                let cont = self?.playbackContinuation
                self?.playbackContinuation = nil
                self?.lock.unlock()
                cont?.resume()
            }
        }
    }

    /// Stop current playback immediately (for barge-in).
    func stop() {
        lock.lock()
        let cont = playbackContinuation
        playbackContinuation = nil
        lock.unlock()

        playerNode?.stop()
        cont?.resume()
    }

    /// Detach from engine (cleanup).
    func detach() {
        stop()
        if let node = playerNode, let engine = engine {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        playerNode = nil
        playerFormat = nil
        self.engine = nil
    }

    enum PlayerError: Error, LocalizedError {
        case notAttached
        case formatError(String)

        var errorDescription: String? {
            switch self {
            case .notAttached:
                return "AudioPlayer not attached to engine. Call attach(to:) first."
            case .formatError(let msg):
                return "Audio format error: \(msg)"
            }
        }
    }
}
