import AVFoundation
import Accelerate

/// Continuous microphone capture at 16kHz mono with optional echo cancellation.
///
/// Runs continuously and delivers audio frames via a callback.
/// The conversation loop feeds these frames to the VAD.
///
/// When voice processing (AEC) is enabled, the shared AVAudioEngine's
/// VPIO unit subtracts output audio from the mic input, so TTS playback
/// doesn't trigger the VAD.
///
/// Set `MAGPI_NO_AEC=1` to disable voice processing entirely.
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

    /// The shared audio engine. Exposed so AudioPlayer can attach its
    /// AVAudioPlayerNode to the same engine for echo cancellation.
    private(set) var engine: AVAudioEngine?
    private var isRunning = false

    /// Whether voice processing (AEC) is active.
    let voiceProcessingEnabled: Bool

    private let verboseLogging = ProcessInfo.processInfo.environment["MAGPI_LOG_LEVEL"] == "debug"

    init(enableVoiceProcessing: Bool = true) {
        // Allow env override: MAGPI_NO_AEC=1 disables voice processing
        if ProcessInfo.processInfo.environment["MAGPI_NO_AEC"] == "1" {
            self.voiceProcessingEnabled = false
        } else {
            self.voiceProcessingEnabled = enableVoiceProcessing
        }
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        // Log the pre-VP format for comparison
        let preVPFormat = inputNode.outputFormat(forBus: 0)
        print("Magpi: Pre-VP input format: \(Int(preVPFormat.sampleRate))Hz, \(preVPFormat.channelCount)ch")

        // ── Step 1: Enable voice processing BEFORE querying formats ──
        if voiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                try audioEngine.outputNode.setVoiceProcessingEnabled(true)

                // Disable AGC — it aggressively ducks local speech
                inputNode.isVoiceProcessingAGCEnabled = false
                inputNode.isVoiceProcessingInputMuted = false
                inputNode.isVoiceProcessingBypassed = false

                // Disable "other audio ducking" (macOS 14+)
                if #available(macOS 14.0, *) {
                    var duckingConfig = inputNode.voiceProcessingOtherAudioDuckingConfiguration
                    duckingConfig.enableAdvancedDucking = false
                    duckingConfig.duckingLevel = .min
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration = duckingConfig
                }

                print("Magpi: Voice processing (AEC) enabled, AGC off, ducking minimized")
            } catch {
                print("Magpi: Warning — voice processing unavailable: \(error)")
            }
        }

        // ── Step 2: Query format AFTER VP is configured ──
        let vpioFormat = inputNode.outputFormat(forBus: 0)
        print("Magpi: Post-VP input format: \(Int(vpioFormat.sampleRate))Hz, \(vpioFormat.channelCount)ch")

        guard vpioFormat.sampleRate > 0, vpioFormat.channelCount > 0 else {
            throw CaptureError.engineSetupFailed(
                "Input node has invalid format after VP: \(vpioFormat)"
            )
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Constants.sampleRate,
            channels: 1,
            interleaved: false
        )!

        // VPIO may output multi-channel (e.g. 9ch on macOS).
        // Channel 0 = processed mic signal (echo-cancelled).
        // We need an intermediate mono format at the VPIO sample rate
        // to extract channel 0, then downsample to 16kHz.
        let vpioChannels = vpioFormat.channelCount
        let vpioRate = vpioFormat.sampleRate
        let needsChannelExtract = vpioChannels > 1

        // Mono format at VPIO sample rate — used for sample rate conversion
        let monoVpioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: vpioRate,
            channels: 1,
            interleaved: false
        )!

        // Sample rate converter: mono at VPIO rate → mono at 16kHz
        let rateConverter = AVAudioConverter(from: monoVpioFormat, to: targetFormat)

        // ── Step 3: Install tap ──
        let bufferSize: AVAudioFrameCount = 4096
        var tapCallCount = 0

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            tapCallCount += 1

            let frameLen = Int(buffer.frameLength)
            guard frameLen > 0 else { return }

            // ── Extract channel 0 (processed mic) from multi-channel VPIO ──
            guard let ch0Data = buffer.floatChannelData?[0] else { return }

            // Diagnostic logging for first 10 callbacks
            if tapCallCount <= 10 {
                var ch0RMS: Float = 0
                vDSP_rmsqv(ch0Data, 1, &ch0RMS, vDSP_Length(frameLen))
                print("Magpi: [tap #\(tapCallCount)] \(Int(buffer.format.sampleRate))Hz/\(buffer.format.channelCount)ch frames=\(frameLen) ch0_RMS=\(String(format: "%.6f", ch0RMS))")
            }

            if needsChannelExtract {
                // Create a mono buffer and copy channel 0 into it
                guard let monoBuffer = AVAudioPCMBuffer(
                    pcmFormat: monoVpioFormat,
                    frameCapacity: AVAudioFrameCount(frameLen)
                ) else { return }
                monoBuffer.frameLength = AVAudioFrameCount(frameLen)

                // Copy channel 0 data
                memcpy(monoBuffer.floatChannelData![0], ch0Data, frameLen * MemoryLayout<Float>.size)

                // Now downsample mono → 16kHz
                self.convertAndDeliver(
                    monoBuffer: monoBuffer,
                    converter: rateConverter,
                    targetFormat: targetFormat,
                    tapCount: tapCallCount
                )
            } else {
                // Already mono — just downsample
                self.convertAndDeliver(
                    monoBuffer: buffer,
                    converter: rateConverter,
                    targetFormat: targetFormat,
                    tapCount: tapCallCount
                )
            }
        }

        // ── Step 4: Start the engine ──
        try audioEngine.start()
        engine = audioEngine
        isRunning = true

        let aecStatus = voiceProcessingEnabled ? " [AEC on]" : ""
        let chInfo = needsChannelExtract ? " (extracting ch0 from \(vpioChannels)ch)" : ""
        print("Magpi: Audio capture started (\(Int(vpioRate))Hz → 16kHz)\(aecStatus)\(chInfo)")
    }

    /// Convert a mono buffer at VPIO rate to 16kHz and deliver.
    private func convertAndDeliver(
        monoBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat,
        tapCount: Int
    ) {
        guard let converter = converter else {
            deliverBuffer(monoBuffer)
            return
        }

        let ratio = targetFormat.sampleRate / monoBuffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(monoBuffer.frameLength) * ratio)
        guard outFrames > 0,
              let convertedBuffer = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: outFrames
              ) else { return }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return monoBuffer
        }

        if status == .haveData {
            if tapCount <= 5 {
                var outRMS: Float = 0
                if let cd = convertedBuffer.floatChannelData?[0], convertedBuffer.frameLength > 0 {
                    vDSP_rmsqv(cd, 1, &outRMS, vDSP_Length(convertedBuffer.frameLength))
                }
                print("Magpi: [tap #\(tapCount)] converted=\(convertedBuffer.frameLength)frames outRMS=\(String(format: "%.6f", outRMS))")
            }
            deliverBuffer(convertedBuffer)
        } else if tapCount <= 5 {
            print("Magpi: [tap #\(tapCount)] conversion failed: \(error?.localizedDescription ?? "unknown")")
        }
    }

    func stop() {
        guard isRunning else { return }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false

        print("Magpi: Audio capture stopped")
    }

    var running: Bool { isRunning }

    // MARK: - Private

    private func deliverBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

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
