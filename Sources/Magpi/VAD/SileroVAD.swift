import Foundation

/// Silero VAD wrapper — frame-level voice activity detection.
///
/// Processes audio in 512-sample chunks (32ms at 16kHz) and returns a speech
/// probability for each chunk. Maintains internal LSTM state across calls.
///
/// IMPORTANT: Silero VAD requires a 64-sample context prefix prepended to each
/// 512-sample chunk, so the actual model input is 576 samples. The context is
/// the last 64 samples from the previous chunk (or zeros for the first call).
///
/// Model I/O (Silero VAD v5):
///   Inputs:  "input" [1, 576], "sr" [] (scalar int64), "state" [2, 1, 128]
///   Outputs: "output" [1, 1], "stateN" [2, 1, 128]
final class SileroVAD {
    
    private let session: OnnxSession
    
    // LSTM state (carried across calls) — single combined tensor
    private var state: [Float]
    
    // Context: last 64 samples from the previous chunk
    private let contextSize = 64
    private var context: [Float]
    
    // State dimensions: [2, 1, 128]
    private let stateShape: [Int64] = [2, 1, 128]
    private let stateSize = 2 * 1 * 128  // 256 elements
    
    /// VAD iterator state for turn detection
    private(set) var isTriggered = false
    private var speechChunkCount = 0
    private var silenceChunkCount = 0
    
    init(modelPath: String) throws {
        session = try OnnxSession(modelPath: modelPath, label: "silero-vad")
        
        // Initialize LSTM state to zeros
        state = [Float](repeating: 0, count: stateSize)
        // Initialize context to zeros
        context = [Float](repeating: 0, count: 64)
    }
    
    convenience init() throws {
        try self.init(modelPath: Constants.sileroVADModelPath.path)
    }
    
    /// Process a single chunk of audio (must be exactly 512 samples).
    /// Returns speech probability (0.0 - 1.0).
    func process(chunk: [Float]) throws -> Float {
        guard chunk.count == Constants.vadChunkSize else {
            throw OnnxSession.OnnxError.invalidInput(
                "Expected \(Constants.vadChunkSize) samples, got \(chunk.count)"
            )
        }
        
        // Prepend context (last 64 samples from previous chunk) to form 576-sample input
        let inputWithContext = context + chunk
        
        // Update context for next call
        context = Array(chunk.suffix(contextSize))
        
        // Create input tensors
        let inputTensor = try session.createFloatTensor(inputWithContext, shape: [1, Int64(inputWithContext.count)])
        let srTensor = try session.createInt64Tensor([Int64(Constants.sampleRate)], shape: [])
        let stateTensor = try session.createFloatTensor(state, shape: stateShape)
        
        defer {
            session.releaseTensor(inputTensor)
            session.releaseTensor(srTensor)
            session.releaseTensor(stateTensor)
        }
        
        // Run inference
        let outputs = try session.run(
            inputs: [
                ("input", inputTensor),
                ("sr", srTensor),
                ("state", stateTensor),
            ],
            outputNames: ["output", "stateN"]
        )
        
        defer { outputs.forEach { session.releaseTensor($0) } }
        
        guard outputs.count == 2 else {
            throw OnnxSession.OnnxError.runtimeError("Expected 2 outputs, got \(outputs.count)")
        }
        
        // Extract outputs
        let probability = try session.getFloatOutput(outputs[0])
        let newState = try session.getFloatOutput(outputs[1])
        
        // Update LSTM state
        state = newState
        
        let speechProb = probability.first ?? 0
        
        // Update iterator state
        updateIteratorState(speechProbability: speechProb)
        
        return speechProb
    }
    
    /// Process a buffer of audio samples (may contain multiple chunks).
    /// Returns the speech probability of the last chunk processed.
    func processBuffer(_ samples: [Float]) throws -> Float {
        var lastProb: Float = 0
        
        // Process complete 512-sample chunks
        var offset = 0
        while offset + Constants.vadChunkSize <= samples.count {
            let chunk = Array(samples[offset..<offset + Constants.vadChunkSize])
            lastProb = try process(chunk: chunk)
            offset += Constants.vadChunkSize
        }
        
        return lastProb
    }
    
    // MARK: - Iterator State Machine
    
    /// VAD event emitted by the iterator.
    enum VADEvent {
        case speechStart
        case speechContinue
        case silenceDetected    // Short silence (speech may continue)
        case turnSilence        // Sustained silence — ready for turn check
        case idle
    }
    
    /// Current event based on the iterator state.
    var currentEvent: VADEvent {
        if isTriggered {
            if silenceChunkCount >= Constants.vadSilenceChunks {
                return .turnSilence
            } else if silenceChunkCount > 0 {
                return .silenceDetected
            } else {
                return .speechContinue
            }
        } else {
            return .idle
        }
    }
    
    private func updateIteratorState(speechProbability: Float) {
        if speechProbability >= Constants.vadSpeechThreshold {
            speechChunkCount += 1
            silenceChunkCount = 0
            
            if !isTriggered && speechChunkCount >= Constants.vadSpeechMinChunks {
                isTriggered = true
                print("Magpi: VAD → speech start")
            }
        } else {
            if isTriggered {
                silenceChunkCount += 1
            } else {
                speechChunkCount = 0
            }
        }
    }
    
    /// Reset the VAD state (after a turn is processed).
    func reset() {
        state = [Float](repeating: 0, count: stateSize)
        context = [Float](repeating: 0, count: contextSize)
        isTriggered = false
        speechChunkCount = 0
        silenceChunkCount = 0
    }
    
    /// Reset just the iterator state (keep LSTM state and context).
    func resetIterator() {
        isTriggered = false
        speechChunkCount = 0
        silenceChunkCount = 0
    }
}
