import Foundation

/// Manages the pocket-tts TTS server and provides speech synthesis.
/// Adapted from Loqui's server management and SpeechPlaybackCoordinator.
final class TTSEngine {
    
    enum TTSError: Error, LocalizedError {
        case binaryNotFound
        case serverNotRunning
        case synthesizeFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "pocket-tts-cli binary not found"
            case .serverNotRunning: return "TTS server is not running"
            case .synthesizeFailed(let msg): return "TTS synthesis failed: \(msg)"
            }
        }
    }
    
    private var serverProcess: Process?
    var isServerRunning = false
    
    let host = Constants.ttsHost
    let port = Constants.ttsPort
    var defaultVoice = "fantine"
    
    init() {}
    
    deinit {
        stopServer()
    }
    
    // MARK: - Server Lifecycle
    
    /// Start the pocket-tts-cli server.
    func startServer() async throws {
        guard let binary = findBinary() else {
            throw TTSError.binaryNotFound
        }
        
        stopServer()
        
        let process = Process()
        
        // Use bash wrapper for proper working directory (same as Loqui)
        if let resourcePath = findResourcePath() {
            let voicePath = "\(resourcePath)/models/embeddings/\(defaultVoice).safetensors"
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c",
                "cd '\(resourcePath)' && '\(binary.path)' serve --port \(port) --host \(host) --voice '\(voicePath)'"
            ]
            
            var env = ProcessInfo.processInfo.environment
            env["POCKET_TTS_VOICES_DIR"] = "\(resourcePath)/models/embeddings"
            if let hfHome = setupModelCache() {
                env["HF_HOME"] = hfHome
            }
            process.environment = env
        } else {
            // Fallback: run binary directly
            process.executableURL = binary
            process.arguments = [
                "serve",
                "--host", host,
                "--port", "\(port)",
                "--voice", defaultVoice,
            ]
        }
        
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        process.terminationHandler = { _ in
            DispatchQueue.main.async { [weak self] in
                self?.serverProcess = nil
                self?.isServerRunning = false
            }
            print("Magpi: TTS server stopped")
        }
        
        try process.run()
        
        serverProcess = process
        
        print("Magpi: TTS server starting on \(host):\(port)...")
        
        // Wait for server to be healthy
        for _ in 0..<50 {
            if await checkHealth() {
                isServerRunning = true
                print("Magpi: TTS server ready")
                return
            }
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        
        stopServer()
        throw TTSError.serverNotRunning
    }
    
    /// Stop the TTS server.
    func stopServer() {
        let process = serverProcess
        serverProcess = nil
        isServerRunning = false
        
        if let process = process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }
    
    // MARK: - Synthesis
    
    /// Synthesize text to raw PCM audio (s16le, 24kHz, mono).
    func synthesize(text: String, voice: String? = nil) async throws -> Data {
        guard isServerRunning else {
            throw TTSError.serverNotRunning
        }
        
        let url = URL(string: "http://\(host):\(port)/stream")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "text": text,
            "voice": voice ?? defaultVoice
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw TTSError.synthesizeFailed(msg)
        }
        
        return data
    }
    
    /// Send a stop request to the server.
    func stopSpeech() async {
        guard isServerRunning else { return }
        // The server doesn't have a stop endpoint, but we can stop the audio player
    }
    
    // MARK: - Health Check
    
    func checkHealth() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    // MARK: - Binary Discovery
    
    private func findBinary() -> URL? {
        // Check app bundle
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: resourcePath).appendingPathComponent("pocket-tts-cli")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        
        // Check common paths
        let candidates = [
            "/opt/homebrew/bin/pocket-tts-cli",
            "/usr/local/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.cargo/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.local/bin/pocket-tts-cli",
            NSHomeDirectory() + "/work/ml/pocket-tts/target/release/pocket-tts-cli",
        ]
        
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        return nil
    }
    
    private func findResourcePath() -> String? {
        // Check Loqui's resources (shared TTS models)
        let loquiApps = [
            "/Applications/Loqui.app/Contents/Resources",
            NSHomeDirectory() + "/Applications/Loqui.app/Contents/Resources",
        ]
        
        for path in loquiApps {
            let binary = path + "/pocket-tts-cli"
            let models = path + "/models/tts_b6369a24.safetensors"
            if FileManager.default.fileExists(atPath: binary),
               FileManager.default.fileExists(atPath: models) {
                return path
            }
        }
        
        return nil
    }
    
    private func setupModelCache() -> String? {
        let cacheDir = Constants.appSupportDir.appendingPathComponent("tts-cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.path
    }
}
