import Foundation

/// The main conversation state machine.
///
/// Orchestrates the full voice loop:
///   mic → VAD → Smart Turn → STT → Pi bridge → (wait) → TTS → speaker
///
/// State transitions:
///   IDLE → LISTENING (VAD detects speech)
///   LISTENING → TURN_CHECK (VAD detects sustained silence)
///   TURN_CHECK → TRANSCRIBING (Smart Turn confirms turn complete)
///   TURN_CHECK → LISTENING (Smart Turn says "not done yet")
///   TRANSCRIBING → WAITING (text sent to Pi)
///   WAITING → SPEAKING (broker receives speak command)
///   WAITING → IDLE (timeout)
///   SPEAKING → IDLE (playback done)
///   SPEAKING → LISTENING (barge-in: user speaks during playback)
///   Any → IDLE (error/reset)
@MainActor
final class ConversationLoop: ObservableObject {
    
    enum State: Equatable {
        case idle
        case listening
        case turnCheck
        case transcribing
        case waiting
        case speaking
        case error(String)
        
        var displayName: String {
            switch self {
            case .idle: return "Idle"
            case .listening: return "Listening..."
            case .turnCheck: return "Thinking..."
            case .transcribing: return "Transcribing..."
            case .waiting: return "Waiting for Pi..."
            case .speaking: return "Speaking..."
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }
    
    @Published private(set) var state: State = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published var isEnabled = true
    
    // Components
    private let audioCapture = AudioCaptureSession()
    private let audioBuffer = AudioBuffer()
    private let audioPlayer = AudioPlayer()
    private var sileroVAD: SileroVAD?
    private var smartTurn: SmartTurnDetector?
    private var transcriber: Transcriber?
    private let ttsEngine = TTSEngine()
    private let piBridge = PiBridge()
    
    // Turn check state
    private var turnCheckRetries = 0
    
    // Barge-in detection during playback
    private var bargeInChunkCount = 0
    
    // Debug: frame counter for periodic logging (set MAGPI_LOG_LEVEL=debug to enable)
    private var frameCount = 0
    private var lastDebugLog = Date()
    private let verboseLogging = ProcessInfo.processInfo.environment["MAGPI_LOG_LEVEL"] == "debug"
    
    // Speech queue from broker
    private var speechQueue: [(text: String, voice: String?)] = []
    private let speechQueueLock = NSLock()
    
    init() {
        setupCallbacks()
    }
    
    // MARK: - Lifecycle
    
    /// Initialize models and start the conversation loop.
    func start() async {
        do {
            // Initialize VAD models
            print("Magpi: Loading Silero VAD...")
            sileroVAD = try SileroVAD()
            
            print("Magpi: Loading Smart Turn...")
            smartTurn = try SmartTurnDetector()
            
            // Find STT model
            if let modelPath = Transcriber.findModelPath() {
                transcriber = Transcriber(modelPath: modelPath)
                print("Magpi: STT model: \(modelPath)")
            } else {
                print("Magpi: Warning — no STT model found")
            }
            
            // Start TTS server (if not already running via Loqui)
            if !(await ttsEngine.checkHealth()) {
                print("Magpi: Starting TTS server...")
                try await ttsEngine.startServer()
            } else {
                ttsEngine.isServerRunning = true
                print("Magpi: TTS server already running (Loqui?)")
            }
            
            // Start broker
            try piBridge.startBroker()
            
            // Start audio capture
            guard await AudioCaptureSession.checkPermission() else {
                state = .error("Microphone permission denied")
                return
            }
            
            try audioCapture.start()
            state = .idle
            
            print("Magpi: Conversation loop started ✓")
        } catch {
            state = .error(error.localizedDescription)
            print("Magpi: Failed to start: \(error)")
        }
    }
    
    /// Stop the conversation loop.
    func stop() {
        audioCapture.stop()
        audioPlayer.stop()
        ttsEngine.stopServer()
        piBridge.stopBroker()
        sileroVAD?.reset()
        audioBuffer.reset()
        state = .idle
        print("Magpi: Conversation loop stopped")
    }
    
    // MARK: - Setup
    
    private func setupCallbacks() {
        // Audio capture → VAD processing
        audioCapture.onAudioFrame = { [weak self] samples in
            Task { @MainActor [weak self] in
                self?.processAudioFrame(samples)
            }
        }
        
        audioCapture.onAudioLevel = { [weak self] level in
            self?.audioLevel = level
        }
        
        // Broker callbacks
        piBridge.onSpeakRequest = { [weak self] request in
            self?.handleSpeakRequest(request)
        }
        
        piBridge.onStopRequest = { [weak self] in
            self?.handleStopRequest()
        }
    }
    
    // MARK: - Audio Processing
    
    private func processAudioFrame(_ samples: [Float]) {
        guard isEnabled, let vad = sileroVAD else { return }
        
        frameCount += 1
        
        // Always accumulate audio when listening
        if state == .listening || state == .turnCheck {
            audioBuffer.append(samples)
        }
        
        // Process through VAD
        let prob: Float
        do {
            prob = try vad.processBuffer(samples)
        } catch {
            print("Magpi: VAD error: \(error)")
            return
        }
        
        // Periodic debug logging (only with MAGPI_LOG_LEVEL=debug)
        if verboseLogging {
            let now = Date()
            if now.timeIntervalSince(lastDebugLog) >= 2.0 {
                print("Magpi: [vad] prob=\(String(format: "%.3f", prob)) state=\(state.displayName)")
                lastDebugLog = now
            }
        }
        
        let event = vad.currentEvent
        
        switch state {
        case .idle:
            if event == .speechContinue {
                // Speech detected! Start listening.
                audioBuffer.reset()
                audioBuffer.append(samples)
                state = .listening
                print("Magpi: → LISTENING")
            }
            
        case .listening:
            if event == .turnSilence {
                // Sustained silence — check if turn is complete
                state = .turnCheck
                turnCheckRetries = 0
                print("Magpi: → TURN_CHECK")
                Task { await checkTurn() }
            }
            
        case .speaking:
            // Barge-in detection
            if event == .speechContinue {
                bargeInChunkCount += 1
                if bargeInChunkCount >= Constants.bargeInMinChunks {
                    print("Magpi: Barge-in detected!")
                    audioPlayer.stop()
                    clearSpeechQueue()
                    sileroVAD?.resetIterator()
                    bargeInChunkCount = 0
                    audioBuffer.reset()
                    audioBuffer.append(samples)
                    state = .listening
                    print("Magpi: → LISTENING (barge-in)")
                }
            } else {
                bargeInChunkCount = 0
            }
            
        case .waiting:
            // User might speak again while waiting for Pi response
            if event == .speechContinue {
                bargeInChunkCount += 1
                if bargeInChunkCount >= Constants.bargeInMinChunks {
                    print("Magpi: User speaking while waiting — cancelling")
                    clearSpeechQueue()
                    sileroVAD?.resetIterator()
                    bargeInChunkCount = 0
                    audioBuffer.reset()
                    audioBuffer.append(samples)
                    state = .listening
                }
            } else {
                bargeInChunkCount = 0
            }
            
        default:
            break
        }
    }
    
    // MARK: - Turn Detection
    
    private func checkTurn() async {
        guard let smartTurn = smartTurn else {
            // No Smart Turn model — just proceed to transcription
            await transcribe()
            return
        }
        
        let audio = audioBuffer.getLast(seconds: 8)
        
        do {
            let isComplete = try smartTurn.isTurnComplete(audio: audio)
            
            if isComplete {
                print("Magpi: Turn complete → transcribing")
                await transcribe()
            } else {
                turnCheckRetries += 1
                if turnCheckRetries >= Constants.smartTurnMaxRetries {
                    print("Magpi: Turn check max retries → transcribing anyway")
                    await transcribe()
                } else {
                    // Not done yet — go back to listening
                    print("Magpi: Turn not complete (retry \(turnCheckRetries)/\(Constants.smartTurnMaxRetries))")
                    state = .listening
                    sileroVAD?.resetIterator()
                    
                    // Wait a bit, then if still silence, check again
                    try? await Task.sleep(nanoseconds: UInt64(Constants.smartTurnRetryDelayMs) * 1_000_000)
                }
            }
        } catch {
            print("Magpi: Smart Turn error: \(error) — transcribing anyway")
            await transcribe()
        }
    }
    
    // MARK: - Transcription
    
    private func transcribe() async {
        guard let transcriber = transcriber else {
            state = .error("No STT model")
            return
        }
        
        state = .transcribing
        print("Magpi: → TRANSCRIBING (\(String(format: "%.1f", audioBuffer.duration))s of audio)")
        
        let audioURL = Constants.tempAudioURL
        
        do {
            // Save audio buffer to WAV
            try audioBuffer.saveToWAV(url: audioURL)
            
            // Transcribe
            let text = try await transcriber.transcribe(audioURL: audioURL)
            
            // Clean up
            try? FileManager.default.removeItem(at: audioURL)
            audioBuffer.reset()
            sileroVAD?.reset()
            
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("Magpi: Empty transcription, returning to idle")
                state = .idle
                return
            }
            
            // Send to Pi
            print("Magpi: Sending to Pi: \"\(text.prefix(80))\"")
            piBridge.sendToPi(text: text)
            
            state = .waiting
            print("Magpi: → WAITING")
            
            // Timeout: if no response after 30s, go back to idle
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if state == .waiting {
                    print("Magpi: Response timeout, returning to idle")
                    state = .idle
                }
            }
            
        } catch {
            print("Magpi: Transcription failed: \(error)")
            state = .idle
            audioBuffer.reset()
            sileroVAD?.reset()
        }
    }
    
    // MARK: - Speech (TTS) Handling
    
    private func handleSpeakRequest(_ request: PiBridge.SpeakRequest) {
        speechQueueLock.lock()
        speechQueue.append((text: request.text, voice: request.voice))
        speechQueueLock.unlock()
        
        // If we're waiting or idle, start speaking
        if state == .waiting || state == .idle {
            Task { await processNextSpeech() }
        }
    }
    
    private func handleStopRequest() {
        audioPlayer.stop()
        clearSpeechQueue()
        if state == .speaking {
            state = .idle
        }
    }
    
    private func processNextSpeech() async {
        speechQueueLock.lock()
        guard !speechQueue.isEmpty else {
            speechQueueLock.unlock()
            if state == .speaking {
                state = .idle
                print("Magpi: → IDLE (speech queue empty)")
            }
            return
        }
        let item = speechQueue.removeFirst()
        speechQueueLock.unlock()
        
        state = .speaking
        bargeInChunkCount = 0
        print("Magpi: → SPEAKING: \"\(item.text.prefix(60))\"")
        
        do {
            let audioData = try await ttsEngine.synthesize(text: item.text, voice: item.voice)
            
            // Check if we were interrupted (barge-in may have changed state)
            guard state == .speaking else { return }
            
            try await audioPlayer.play(audioData: audioData)
            
            // Continue with next item in queue (if not interrupted)
            if state == .speaking {
                await processNextSpeech()
            }
        } catch {
            print("Magpi: TTS playback error: \(error)")
            if state == .speaking {
                await processNextSpeech() // Try next item
            }
        }
    }
    
    private func clearSpeechQueue() {
        speechQueueLock.lock()
        speechQueue.removeAll()
        speechQueueLock.unlock()
    }
}
