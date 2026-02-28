import Foundation

/// Plays TTS audio using ffplay (same approach as Loqui).
///
/// Takes raw PCM s16le audio data at 24kHz and plays it via ffplay.
/// Supports interruption (for barge-in).
final class AudioPlayer {
    
    private var currentProcess: Process?
    private let lock = NSLock()
    
    /// Whether audio is currently playing.
    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentProcess?.isRunning ?? false
    }
    
    /// Play raw PCM audio data (s16le, 24kHz, mono).
    /// Blocks until playback completes or is interrupted.
    func play(audioData: Data) async throws {
        guard let ffplayPath = findFFPlay() else {
            throw PlayerError.ffplayNotFound
        }
        
        // Write audio to temp file
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
                self?.lock.unlock()
                continuation.resume()
            }
        }
    }
    
    /// Stop current playback immediately (for barge-in).
    func stop() {
        lock.lock()
        let process = currentProcess
        currentProcess = nil
        lock.unlock()
        
        if let process = process, process.isRunning {
            process.terminate()
        }
    }
    
    // MARK: - Private
    
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
        
        // Try which
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
    
    enum PlayerError: Error, LocalizedError {
        case ffplayNotFound
        
        var errorDescription: String? {
            "ffplay not found. Install with: brew install ffmpeg"
        }
    }
}
