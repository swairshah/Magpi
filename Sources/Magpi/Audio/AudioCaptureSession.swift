import AVFoundation
import Accelerate

/// Continuous microphone capture at 16kHz mono with echo cancellation.
///
/// Uses AVAudioEngine with voice processing enabled on both input and output
/// nodes. When TTS audio is played through an AVAudioPlayerNode attached to
/// the same engine, macOS automatically uses the playback as a reference
/// signal for acoustic echo cancellation (AEC).
final class AudioCaptureSession {

    enum CaptureError: Error, LocalizedError {
        case engineSetupFailed(String)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .engineSetupFailed(let msg): return "Audio engine setup failed: \(msg)"
            case .permissionDenied: return "Microphone permission denied"
            }
        }
    }

    /// Called with each chunk of float32 audio samples at 16kHz mono.
    var onAudioFrame: (([Float]) -> Void)?

    /// Called with RMS audio level (0-1) for UI visualization.
    var onAudioLevel: ((Float) -> Void)?

    /// Called on error.
    var onError: ((String) -> Void)?

    /// The shared audio engine. TTS playback nodes should be attached to this
    /// engine so voice processing can use them as AEC reference.
    private(set) var audioEngine: AVAudioEngine?
    private var isRunning = false

    /// Whether voice processing (AEC) is enabled.
    private(set) var voiceProcessingEnabled = false

    /// Called after voice processing is configured but BEFORE engine starts.
    /// Use this to attach player nodes to the engine.
    var onEngineReady: ((AVAudioEngine) -> Void)?

    init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start audio capture with echo cancellation.
    /// - Parameter enableVoiceProcessing: If true, enables AEC. Set to false to bypass.
    func start(enableVoiceProcessing: Bool = true) throws {
        guard !isRunning else { return }

        let engine = AVAudioEngine()

        // Step 1: Enable voice processing BEFORE anything else.
        // This reconfigures the internal Audio Unit graph.
        if enableVoiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                try engine.outputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
                print("Magpi: Voice processing (AEC) enabled ✓")
            } catch {
                print("Magpi: Warning — voice processing failed: \(error)")
                print("Magpi: Falling back to non-AEC mode")
                voiceProcessingEnabled = false
            }
        }

        // Step 2: Query format AFTER voice processing is configured.
        // Voice processing changes the format — we must query after enabling.
        let inputNode = engine.inputNode
        let vpFormat = inputNode.outputFormat(forBus: 0)
        print("Magpi: Input format (post-VP): \(Int(vpFormat.sampleRate))Hz, \(vpFormat.channelCount)ch, voiceProcessing=\(inputNode.isVoiceProcessingEnabled)")

        // Target format: 16kHz mono float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Constants.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.engineSetupFailed("Could not create target audio format")
        }

        // Step 3: Install tap using the format reported by the node.
        // Pass nil to let the system pick the right format.
        let bufferSize: AVAudioFrameCount = 4096
        var tapConverterCreated = false
        var tapConverter: AVAudioConverter?

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Lazily create converter on first callback (actual format)
            if !tapConverterCreated {
                tapConverterCreated = true
                let fmt = buffer.format
                let needsConv = abs(fmt.sampleRate - Constants.sampleRate) > 1.0
                    || fmt.channelCount != 1
                if needsConv {
                    tapConverter = AVAudioConverter(from: fmt, to: targetFormat)
                }
                print("Magpi: Tap delivering: \(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch, conversion=\(needsConv)")
            }

            if let conv = tapConverter {
                let bufferFormat = buffer.format
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * Constants.sampleRate / bufferFormat.sampleRate
                )
                guard frameCount > 0, let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                let status = conv.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData {
                    self.deliverBuffer(convertedBuffer)
                }
            } else {
                self.deliverBuffer(buffer)
            }
        }

        // Step 4: Let other components attach nodes BEFORE starting.
        // This is critical — player nodes must be in the graph before start().
        onEngineReady?(engine)

        // Step 5: Prepare and start.
        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRunning = true

        print("Magpi: Audio capture started (voiceProcessing=\(voiceProcessingEnabled))")
    }

    func stop() {
        guard isRunning else { return }

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isRunning = false
        voiceProcessingEnabled = false

        print("Magpi: Audio capture stopped")
    }

    var running: Bool { isRunning }

    // MARK: - Private

    private func deliverBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        // Calculate RMS for level meter
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

        let minDb: Float = -45
        let maxDb: Float = -5
        let db = 20 * log10(max(rms, 0.000001))
        let normalized = (db - minDb) / (maxDb - minDb)
        let level = max(0, min(1, normalized))

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
        }

        onAudioFrame?(samples)
    }

    // MARK: - Permissions

    static func checkPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
