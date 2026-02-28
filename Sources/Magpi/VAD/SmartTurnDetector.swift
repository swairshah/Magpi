import Foundation

/// Smart Turn v3.1 — semantic turn completion detection.
///
/// Unlike simple silence-based turn detection, Smart Turn analyzes prosody
/// and linguistic cues to determine if a speaker has actually finished their
/// turn (vs. just pausing mid-thought).
///
/// Model I/O:
///   Input:  "audio" [1, 128000] — up to 8 seconds of 16kHz audio
///   Output: probability (float32) — turn complete probability
///
/// Usage: Call `predict()` after Silero VAD detects sustained silence.
/// If probability ≥ 0.5, the turn is complete → proceed to STT.
/// If probability < 0.5, the speaker might continue → keep listening.
final class SmartTurnDetector {
    
    private let session: OnnxSession
    
    init(modelPath: String) throws {
        session = try OnnxSession(modelPath: modelPath, label: "smart-turn")
    }
    
    convenience init() throws {
        try self.init(modelPath: Constants.smartTurnModelPath.path)
    }
    
    /// Predict whether the speaker's turn is complete.
    ///
    /// - Parameter audio: Float32 audio samples at 16kHz. Can be up to 8 seconds
    ///   (128,000 samples). Shorter audio is zero-padded at the beginning.
    /// - Returns: Probability (0.0-1.0) that the turn is complete.
    func predict(audio: [Float]) throws -> Float {
        let maxSamples = Constants.smartTurnMaxSamples
        
        // Prepare input: pad or truncate to 128,000 samples
        var inputAudio: [Float]
        
        if audio.count > maxSamples {
            // Take the last 8 seconds
            inputAudio = Array(audio.suffix(maxSamples))
        } else if audio.count < maxSamples {
            // Zero-pad at the beginning (Smart Turn expects this)
            let padding = maxSamples - audio.count
            inputAudio = [Float](repeating: 0, count: padding) + audio
        } else {
            inputAudio = audio
        }
        
        // Create input tensor (ORT allocator owns the data)
        let inputTensor = try session.createFloatTensor(
            inputAudio,
            shape: [1, Int64(maxSamples)]
        )
        defer { session.releaseTensor(inputTensor) }
        
        // Run inference
        // Note: The actual input/output names may vary — check the model's metadata.
        // Common names: "audio"/"input" for input, "output"/"logits" for output.
        let outputs = try session.run(
            inputs: [("audio", inputTensor)],
            outputNames: ["output"]
        )
        
        defer { outputs.forEach { session.releaseTensor($0) } }
        
        guard let outputTensor = outputs.first else {
            throw OnnxSession.OnnxError.runtimeError("No output from Smart Turn model")
        }
        
        let result = try session.getFloatOutput(outputTensor)
        let probability = result.first ?? 0
        
        return probability
    }
    
    /// Check if the turn is complete based on the audio.
    func isTurnComplete(audio: [Float], threshold: Float = Constants.smartTurnThreshold) throws -> Bool {
        let prob = try predict(audio: audio)
        print("Magpi: Smart Turn probability: \(String(format: "%.3f", prob)) (threshold: \(threshold))")
        return prob >= threshold
    }
}
