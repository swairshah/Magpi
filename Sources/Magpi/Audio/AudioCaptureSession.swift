import AVFoundation
import Accelerate

/// Continuous microphone capture at 16kHz mono.
///
/// Unlike Hearsay's AudioRecorder (start/stop per recording), this runs
/// continuously and delivers audio frames via a callback. The conversation
/// loop feeds these frames to the VAD.
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
    /// Called on the audio processing queue (not main thread).
    var onAudioFrame: (([Float]) -> Void)?
    
    /// Called with RMS audio level (0-1) for UI visualization.
    var onAudioLevel: ((Float) -> Void)?
    
    /// Called on error.
    var onError: ((String) -> Void)?
    
    private var audioEngine: AVAudioEngine?
    private var isRunning = false
    
    init() {}
    
    deinit {
        stop()
    }
    
    // MARK: - Lifecycle
    
    func start() throws {
        guard !isRunning else { return }
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Target format: 16kHz mono float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Constants.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.engineSetupFailed("Could not create target audio format")
        }
        
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        
        let bufferSize: AVAudioFrameCount = 4096
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            if let converter = converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * Constants.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCount
                ) else { return }
                
                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                if status == .haveData {
                    self.deliverBuffer(convertedBuffer)
                }
            } else {
                // Format already matches
                self.deliverBuffer(buffer)
            }
        }
        
        try engine.start()
        audioEngine = engine
        isRunning = true
        
        print("Magpi: Audio capture started (\(Int(inputFormat.sampleRate))Hz → 16kHz)")
    }
    
    func stop() {
        guard isRunning else { return }
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isRunning = false
        
        print("Magpi: Audio capture stopped")
    }
    
    var running: Bool { isRunning }
    
    // MARK: - Private
    
    private func deliverBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Copy samples to array
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
        
        // Deliver samples to the conversation loop
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
