import Foundation

/// The main conversation state machine.
///
/// Orchestrates the full voice loop:
///   mic → VAD → Smart Turn → STT → Pi RPC → (streaming) → TTS → speaker
///
/// The Pi conversation agent runs as a subprocess in RPC mode.
/// Voice input goes to it as prompts; it responds with <voice> tags
/// which the pi-talk extension routes through the broker to TTS.
///
/// State transitions:
///   IDLE → LISTENING (VAD detects speech)
///   LISTENING → TURN_CHECK (VAD detects sustained silence)
///   TURN_CHECK → TRANSCRIBING (Smart Turn confirms turn complete)
///   TURN_CHECK → LISTENING (Smart Turn says "not done yet")
///   TRANSCRIBING → WAITING (text sent to Pi via RPC)
///   WAITING → SPEAKING (broker receives speak command from pi-talk ext)
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
    @Published private(set) var isAgentRunning = false
    @Published var isEnabled = true

    /// When true, VAD detects speech during TTS playback and interrupts it.
    /// Turn off when not wearing headphones (TTS bleeds into mic).
    @Published var bargeInEnabled = true

    // Components
    private let audioCapture = AudioCaptureSession()
    private let audioBuffer = AudioBuffer()
    private let audioPlayer = AudioPlayer()
    private var sileroVAD: SileroVAD?
    private var smartTurn: SmartTurnDetector?
    private var transcriber: Transcriber?
    private let ttsEngine = TTSEngine()
    private let piBridge = PiBridge()
    private let piRPC = PiRPCClient()

    // Transcript for UI
    let transcript = TranscriptStore()

    // Turn check state
    private var turnCheckRetries = 0

    // Barge-in detection during playback
    private var bargeInChunkCount = 0

    // Debug logging (set MAGPI_LOG_LEVEL=debug to enable)
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

    /// Initialize models, start Pi RPC agent, and begin the conversation loop.
    func start() async {
        do {
            // Initialize VAD models
            print("Magpi: Loading Silero VAD...")
            sileroVAD = try SileroVAD()

            // Smart Turn disabled — model expects mel spectrogram input (input_features [B,80,800])
            // not raw audio. Need to implement mel spectrogram extraction first.
            // For now, rely on VAD silence detection + timeout for turn detection.
            // print("Magpi: Loading Smart Turn...")
            // smartTurn = try SmartTurnDetector()
            print("Magpi: Smart Turn disabled (needs mel spectrogram preprocessing)")

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

            // Start broker (receives speak commands from pi-talk extension)
            try piBridge.startBroker()

            // Start Pi RPC conversation agent
            try startConversationAgent()

            // Start audio capture
            guard await AudioCaptureSession.checkPermission() else {
                state = .error("Microphone permission denied")
                return
            }

            // Start audio capture
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
        audioPlayer.stop()
        audioCapture.stop()
        ttsEngine.stopServer()
        piBridge.stopBroker()
        piRPC.stop()
        sileroVAD?.reset()
        audioBuffer.reset()
        isAgentRunning = false
        state = .idle
        print("Magpi: Conversation loop stopped")
    }

    // MARK: - Pi RPC Agent

    private func startConversationAgent() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let systemPrompt = """
        You are Magpi, a voice conversation assistant. The user is speaking to you through \
        a microphone — their speech is transcribed and sent to you as text.

        You manage multiple Pi coding agents running in the background. You can:
        1. Answer questions directly (about code, projects, general topics)
        2. Check what other Pi agents are doing
        3. Dispatch commands to specific agents
        4. Summarize agent activity

        ## Discovering Running Pi Agents

        Use pi-statusd via socat to discover agents:
        ```
        echo 'status' | socat - UNIX-CONNECT:\(home)/.pi/agent/statusd.sock
        ```
        This returns JSON with an `agents` array. Each agent has:
        - `pid`: process ID
        - `cwd`: working directory (tells you which project)
        - `activity`: what it's doing ("running", "waiting_input", etc.)
        - `model_id`: which LLM model it's using
        - `session_name`: optional name
        - `context_percent`: how full its context window is

        ## Sending Commands to Pi Agents

        Write a JSON file to the agent's inbox directory:
        ```
        echo '{"text":"your message here","source":"magpi","deliverAs":"followUp","timestamp":'$(date +%s000)'}' > \(home)/.pi/agent/pitalk-inbox/<PID>/$(date +%s%3N).json
        ```
        The pi-talk extension watches this directory and injects the message into the Pi session.
        The PID must match a running agent from the status command.

        The `deliverAs` field controls how the message is delivered:
        - `"followUp"` (preferred) — waits until the agent finishes its current task, then delivers. Non-disruptive.
        - `"steer"` — interrupts the agent mid-task. Use only when the user explicitly wants to interrupt or redirect.
        - `"nextTurn"` — queued silently, delivered on the agent's next user prompt.
        
        Default to `"followUp"` unless the user says something like "stop it", "interrupt", or "cancel".

        ## Important Guidelines
        - Keep responses concise and conversational — the user is LISTENING, not reading
        - Use <voice> tags for all spoken content
        - When the user asks about "the agent" or "Pi", check which agents are running first
        - When dispatching, confirm what you sent and to which agent
        """

        try piRPC.start(
            systemPrompt: systemPrompt,
            workingDirectory: home
        )
        isAgentRunning = true
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

        // Broker callbacks (speak commands from pi-talk extension)
        piBridge.onSpeakRequest = { [weak self] request in
            self?.handleSpeakRequest(request)
        }

        piBridge.onStopRequest = { [weak self] in
            self?.handleStopRequest()
        }

        // Pi RPC event callbacks
        piRPC.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleRPCEvent(event)
            }
        }
    }

    // MARK: - RPC Event Handling

    private func handleRPCEvent(_ event: PiRPCClient.Event) {
        switch event {
        case .agentStart:
            transcript.beginAssistantMessage()
            transcript.addLog("Agent started processing")

        case .agentEnd:
            transcript.endAssistantMessage()
            transcript.addLog("Agent finished")
            // If we're still waiting and nothing was queued to speak,
            // go back to idle (the response might have had no voice tags)
            if state == .waiting {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    if state == .waiting {
                        transcript.addLog("No speech queued → idle")
                        state = .idle
                    }
                }
            }

        case .textDelta(let text):
            transcript.appendAssistantDelta(text)

        case .textEnd(let fullText):
            transcript.addLog("Text block complete (\(fullText.count) chars)")

        case .toolStart(let name, _):
            transcript.addLog("Tool: \(name)")

        case .toolEnd(let name, _):
            transcript.addLog("Tool done: \(name)")

        case .response(let command, let success, let error):
            if !success {
                let msg = "Command '\(command)' failed: \(error ?? "unknown")"
                transcript.addLog("ERROR: \(msg)")
                print("Magpi: [rpc] \(msg)")
            }

        case .stateResponse(let streaming, let sessionId):
            transcript.addLog("State: streaming=\(streaming) session=\(sessionId ?? "nil")")

        case .error(let msg):
            transcript.addLog("ERROR: \(msg)")
            print("Magpi: [rpc] Error: \(msg)")

        case .processExited(let code):
            transcript.addLog("Pi RPC process exited (code \(code))")
            print("Magpi: Pi RPC process exited (\(code))")
            isAgentRunning = false
            if state != .error("") {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    transcript.addLog("Restarting Pi RPC agent...")
                    try? startConversationAgent()
                }
            }
        }
    }

    // MARK: - Audio Processing

    // MARK: - Push-to-Talk

    /// Interrupt TTS and start listening immediately.
    /// Use when barge-in is disabled (no headphones).
    func pushToTalk() {
        if state == .speaking {
            audioPlayer.stop()
            clearSpeechQueue()
            if piRPC.isStreaming {
                piRPC.abort()
            }
        }

        sileroVAD?.reset()
        audioBuffer.reset()
        bargeInChunkCount = 0
        state = .listening
        print("Magpi: → LISTENING (push-to-talk)")
        transcript.addLog("Push-to-talk activated")
    }

    // MARK: - Audio Processing

    private func processAudioFrame(_ samples: [Float]) {
        guard isEnabled, let vad = sileroVAD else { return }

        frameCount += 1

        // When barge-in is disabled, skip VAD during TTS playback
        // to prevent the speaker audio from triggering false detection.
        if state == .speaking && !bargeInEnabled {
            return
        }

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

        // Periodic debug logging
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
                audioBuffer.reset()
                audioBuffer.append(samples)
                state = .listening
                print("Magpi: → LISTENING")
            }

        case .listening:
            if event == .turnSilence {
                state = .turnCheck
                turnCheckRetries = 0
                print("Magpi: → TURN_CHECK")
                Task { await checkTurn() }
            }

        case .speaking:
            // Barge-in (only when enabled — requires headphones)
            if bargeInEnabled, event == .speechContinue {
                bargeInChunkCount += 1
                if bargeInChunkCount >= Constants.bargeInMinChunks {
                    print("Magpi: Barge-in detected!")
                    audioPlayer.stop()
                    clearSpeechQueue()
                    if piRPC.isStreaming {
                        piRPC.abort()
                    }
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
                    print("Magpi: User speaking while waiting — interrupting")
                    clearSpeechQueue()
                    if piRPC.isStreaming {
                        piRPC.abort()
                    }
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
                    print("Magpi: Turn not complete (retry \(turnCheckRetries)/\(Constants.smartTurnMaxRetries))")
                    state = .listening
                    sileroVAD?.resetIterator()
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
            try audioBuffer.saveToWAV(url: audioURL)

            let text = try await transcriber.transcribe(audioURL: audioURL)

            try? FileManager.default.removeItem(at: audioURL)
            audioBuffer.reset()
            sileroVAD?.reset()

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("Magpi: Empty transcription, returning to idle")
                state = .idle
                return
            }

            // Add to transcript
            transcript.addUserMessage(text)

            // Send to Pi conversation agent via RPC
            print("Magpi: Sending to Pi: \"\(text.prefix(80))\"")
            transcript.addLog("Sending: \"\(text.prefix(120))\"")

            if piRPC.isRunning {
                if piRPC.isStreaming {
                    piRPC.steer(text)
                    transcript.addLog("Steered agent with new input")
                } else {
                    piRPC.sendPrompt(text)
                }
            } else {
                print("Magpi: RPC not running, falling back to inbox")
                transcript.addLog("WARNING: RPC not running, using inbox fallback")
                piBridge.sendToPi(text: text)
            }

            state = .waiting
            print("Magpi: → WAITING")

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s for RPC (may use tools)
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
                // Reset VAD after speaking — its state may be contaminated
                // from TTS bleed that occurred before we started skipping frames
                sileroVAD?.reset()
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

            guard state == .speaking else { return }

            try await audioPlayer.play(audioData: audioData)

            if state == .speaking {
                await processNextSpeech()
            }
        } catch {
            print("Magpi: TTS playback error: \(error)")
            if state == .speaking {
                await processNextSpeech()
            }
        }
    }

    private func clearSpeechQueue() {
        speechQueueLock.lock()
        speechQueue.removeAll()
        speechQueueLock.unlock()
    }
}
