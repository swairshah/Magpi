import Foundation

enum Constants {
    // MARK: - Audio
    static let sampleRate: Double = 16_000         // 16 kHz for VAD + STT
    static let ttsSampleRate: Double = 24_000      // 24 kHz from pocket-tts (s16le)
    static let audioChannels: Int = 1              // Mono
    
    // MARK: - VAD (Silero)
    /// Silero VAD processes audio in 512-sample chunks (32ms at 16kHz)
    static let vadChunkSize: Int = 512
    /// Speech probability threshold to trigger "speech detected"
    static let vadSpeechThreshold: Float = 0.5
    /// Minimum consecutive speech chunks before we consider it real speech (debounce)
    static let vadSpeechMinChunks: Int = 4         // ~128ms
    /// Silence duration (ms) before triggering turn check
    static let vadSilenceDurationMs: Int = 600
    /// Number of silence chunks = silenceDurationMs / (chunkSize/sampleRate*1000)
    static var vadSilenceChunks: Int {
        let chunkDurationMs = Double(vadChunkSize) / sampleRate * 1000
        return Int(Double(vadSilenceDurationMs) / chunkDurationMs)
    }
    
    // MARK: - Smart Turn
    /// Smart Turn analyzes up to 8 seconds of audio (128,000 samples at 16kHz)
    static let smartTurnMaxSamples: Int = 128_000
    /// Probability threshold for "turn is complete"
    static let smartTurnThreshold: Float = 0.5
    /// Maximum retries if Smart Turn says "not done" before forcing transcription
    static let smartTurnMaxRetries: Int = 3
    /// Additional silence (ms) to wait between Smart Turn retries
    static let smartTurnRetryDelayMs: Int = 400
    
    // MARK: - STT
    static let tempAudioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("magpi-recording.wav")
    
    // MARK: - TTS
    static let ttsHost = "127.0.0.1"
    static let ttsPort = 18080
    
    // MARK: - Broker (Loqui-compatible)
    static let brokerHost = "127.0.0.1"
    static let brokerPort = 18081
    
    // MARK: - Pi Bridge
    static let piInboxBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/pitalk-inbox")
    
    // MARK: - Paths
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Magpi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    static let modelsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    // MARK: - Model files
    /// Bundled model paths (in app Resources) — setup.sh downloads these
    static func bundledModelPath(_ name: String) -> URL {
        // When running from swift build, Resources are at the executable's directory
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        
        // Try bundle resources first
        if let resourcePath = Bundle.main.resourcePath {
            let path = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("models/\(name)")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        
        // Fallback: look relative to the package root (development)
        if let execDir = execDir {
            // .build/debug/Magpi → go up to package root
            var dir = execDir
            for _ in 0..<5 {
                let candidate = dir.appendingPathComponent("Resources/models/\(name)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        
        // Last resort: Application Support
        return modelsDir.appendingPathComponent(name)
    }
    
    static var sileroVADModelPath: URL { bundledModelPath("silero_vad.onnx") }
    static var smartTurnModelPath: URL { bundledModelPath("smart-turn-v3.2-cpu.onnx") }
    
    // MARK: - Barge-in
    /// Minimum speech probability during TTS playback to trigger barge-in
    static let bargeInThreshold: Float = 0.6
    /// Minimum consecutive speech chunks during playback to confirm barge-in
    static let bargeInMinChunks: Int = 6  // ~192ms — avoid false triggers from TTS bleed
}
