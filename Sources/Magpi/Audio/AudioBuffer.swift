import Foundation

/// Accumulates audio samples during speech detection.
///
/// Thread-safe ring buffer that grows as needed. Stores float32 samples
/// at 16kHz for feeding to STT and Smart Turn.
final class AudioBuffer {
    
    private var samples: [Float] = []
    private let lock = NSLock()
    
    /// Maximum samples to retain (~60 seconds at 16kHz = 960,000 samples)
    private let maxSamples = 960_000
    
    init() {
        samples.reserveCapacity(Constants.smartTurnMaxSamples)
    }
    
    /// Append new audio samples.
    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        
        samples.append(contentsOf: newSamples)
        
        // Trim from front if we exceed max (keep recent audio)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
    
    /// Get all accumulated samples.
    func getAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
    
    /// Get the last N seconds of audio.
    func getLast(seconds: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        
        let count = Int(seconds * Constants.sampleRate)
        if samples.count <= count {
            return samples
        }
        return Array(samples.suffix(count))
    }
    
    /// Get the last N samples.
    func getLast(sampleCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        
        if samples.count <= sampleCount {
            return samples
        }
        return Array(samples.suffix(sampleCount))
    }
    
    /// Total number of accumulated samples.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
    
    /// Duration of accumulated audio in seconds.
    var duration: Double {
        Double(count) / Constants.sampleRate
    }
    
    /// Clear all accumulated samples.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }
    
    /// Save accumulated audio as a 16-bit PCM WAV file for STT.
    func saveToWAV(url: URL) throws {
        lock.lock()
        let currentSamples = samples
        lock.unlock()
        
        guard !currentSamples.isEmpty else {
            throw AudioBufferError.empty
        }
        
        // Convert float32 → int16
        let int16Samples = currentSamples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }
        
        // Build WAV header
        let sampleRate: UInt32 = UInt32(Constants.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize
        
        var header = Data(capacity: 44)
        
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)
        
        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // chunk size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // PCM
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        let blockAlign = channels * (bitsPerSample / 8)
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        // data chunk
        header.append(contentsOf: "data".utf8)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        
        // Write file
        var fileData = header
        int16Samples.withUnsafeBufferPointer { ptr in
            fileData.append(contentsOf: UnsafeRawBufferPointer(ptr))
        }
        
        try fileData.write(to: url)
    }
    
    enum AudioBufferError: Error, LocalizedError {
        case empty
        
        var errorDescription: String? {
            switch self {
            case .empty: return "Audio buffer is empty"
            }
        }
    }
}
