import AVFoundation

/// Plays TTS audio through an AVAudioPlayerNode for echo cancellation.
///
/// By playing TTS through the same AVAudioEngine that captures the mic,
/// macOS voice processing can use the playback as a reference signal
/// and cancel it from the mic input (acoustic echo cancellation).
///
/// Replaces the previous ffplay-based approach which couldn't provide
/// the AEC reference since it was a separate process.
final class AudioPlayer {

    private var playerNode: AVAudioPlayerNode?
    private weak var engine: AVAudioEngine?
    private let lock = NSLock()
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Whether audio is currently playing.
    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playerNode?.isPlaying ?? false
    }

    /// Attach this player to an AVAudioEngine.
    /// Must be called BEFORE engine.start() so voice processing
    /// sees the player node in the graph.
    func attach(to engine: AVAudioEngine) {
        let node = AVAudioPlayerNode()
        engine.attach(node)

        // Connect to mainMixerNode using the input node's output format.
        // Per Apple docs: when voice processing is enabled, all nodes in the
        // chain must use the same format as the input node's output.
        let connectFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(node, to: engine.mainMixerNode, format: connectFormat)

        self.playerNode = node
        self.engine = engine

        print("Magpi: AudioPlayer attached (format: \(Int(connectFormat.sampleRate))Hz, \(connectFormat.channelCount)ch)")
    }

    /// Play raw PCM audio data (s16le, 24kHz, mono).
    /// Blocks until playback completes or is interrupted.
    func play(audioData: Data) async throws {
        guard let playerNode = playerNode, let engine = engine else {
            throw PlayerError.notAttached
        }

        guard !audioData.isEmpty else { return }

        // Convert s16le 24kHz mono → float32 PCM buffer at output sample rate
        let sourceSampleRate: Double = 24000
        let sourceFrameCount = audioData.count / 2  // 2 bytes per s16le sample

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PlayerError.formatError("Could not create source format")
        }

        // Create source buffer with float32 samples converted from s16le
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFrameCount)
        ) else {
            throw PlayerError.formatError("Could not create source buffer")
        }
        sourceBuffer.frameLength = AVAudioFrameCount(sourceFrameCount)

        // Convert s16le → float32
        guard let floatData = sourceBuffer.floatChannelData?[0] else {
            throw PlayerError.formatError("Could not access float buffer")
        }

        audioData.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sourceFrameCount {
                floatData[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        // Convert to output format if sample rates differ
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let playBuffer: AVAudioPCMBuffer

        if abs(sourceSampleRate - outputFormat.sampleRate) < 1.0 && outputFormat.channelCount == 1 {
            // Same rate, use directly
            playBuffer = sourceBuffer
        } else {
            // Need to convert
            guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                throw PlayerError.formatError("Could not create converter from \(Int(sourceSampleRate))Hz to \(Int(outputFormat.sampleRate))Hz")
            }

            let outputFrameCount = AVAudioFrameCount(
                Double(sourceFrameCount) * outputFormat.sampleRate / sourceSampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
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
        lock.lock()
        lock.unlock()

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

        // Resume any waiting continuation
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
