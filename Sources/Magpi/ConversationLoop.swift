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

    /// When true (muted), mic is released entirely. Toggle with ⌘/.
    @Published var isMuted = true {
        didSet {
            guard oldValue != isMuted else { return }
            if isMuted {
                muteAudio()
            } else {
                unmuteAudio()
            }
        }
    }

    // Components
    private let audioCapture = AudioCaptureSession()
    private let audioBuffer = AudioBuffer()
    private let audioPlayer = AudioPlayer()
    private var sileroVAD: SileroVAD?
    private var smartTurn: SmartTurnDetector?
    private var transcriber: Transcriber?
    private let ttsEngine = TTSEngine()
    private let piBridge = PiBridge()
    let piRPC = PiRPCClient()

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
            print("Magpi: Smart Turn disabled (needs mel spectrogram preprocessing)")

            // Find STT model
            if let modelPath = Transcriber.findModelPath() {
                transcriber = Transcriber(modelPath: modelPath)
                print("Magpi: STT model: \(modelPath)")
            } else {
                print("Magpi: Warning — no STT model found")
            }

            // Start TTS + broker
            if !(await ttsEngine.checkHealth()) {
                print("Magpi: Starting TTS server...")
                try await ttsEngine.startServer()
            } else {
                ttsEngine.isServerRunning = true
                print("Magpi: TTS server already running (Loqui?)")
            }

            try piBridge.startBroker()

            // Start Pi RPC conversation agent
            try startConversationAgent()

            // Check mic permission before unmuting
            guard await AudioCaptureSession.checkPermission() else {
                state = .error("Microphone permission denied")
                return
            }

            state = .idle

            // Unmute — this starts audio capture and attaches the player for AEC
            isMuted = false

            print("Magpi: Conversation loop started ✓")
        } catch {
            state = .error(error.localizedDescription)
            print("Magpi: Failed to start: \(error)")
        }
    }

    /// Stop the conversation loop.
    func stop() {
        audioPlayer.stop()
        audioPlayer.detach()
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
        You are Magpi, a voice assistant that manages Pi coding agents.
        The user is talking to you via voice — keep responses SHORT and conversational.
        Use <voice>text</voice> tags for everything the user should hear spoken aloud.
        Don't use any other XML/HTML/SSML tags — only <voice>.

        ## Your Role

        You are the "manager" agent. You do NOT write code or edit files yourself.
        Instead, you discover running Pi coding sessions ("spoke" agents) and dispatch
        tasks to them. Think of yourself as a voice-activated team lead.

        The ONLY things you should do directly:
        - Answer quick conversational questions ("what time is it?", "how are you?")
        - Check agent status and report summaries
        - Tasks the user EXPLICITLY asks you to do ("Magpi, you do this", "do it yourself")
        - When NO agents are running, tell the user to start one

        ## Workflow

        When the user gives a task:
        1. Discover running agents via telemetry snapshots
        2. Pick the agent whose project/cwd matches the task
        3. Dispatch the task via inbox
        4. Confirm: "Sent that to the agent working on [project]"
        5. If the user asks for status later, check reports

        If multiple agents could handle it, pick the most relevant by cwd/project. \
        If unsure, ask: "I see agents on [project A] and [project B] — which one?"

        If no agents are running, say: "No agents running right now. Start a Pi session first."

        ## Discovering Running Pi Agents

        Each Pi session runs a pi-telemetry extension that writes a JSON snapshot to:
        ```
        \(home)/.pi/agent/telemetry/instances/<PID>.json
        ```
        List all live agents:
        ```
        for f in \(home)/.pi/agent/telemetry/instances/*.json; do cat "$f" | python3 -c "
        import json,sys,time; d=json.load(sys.stdin); age=time.time()*1000-d['process']['updatedAt']
        if age<5000: print(f\"PID={d['process']['pid']} cwd={d['workspace']['cwd']} activity={d['state']['activity']} model={d.get('model',{}).get('name','?')}\")
        " 2>/dev/null; done
        ```
        Each snapshot has: process.pid, workspace.cwd, state.activity, model.name, \
        session.name, context.percent, routing.terminalApp, and more.
        Files with updatedAt older than 5 seconds are stale (process died).

        ## Sending Commands to Pi Agents

        Write a JSON file to the agent's inbox directory:
        ```
        echo '{"text":"your message here","source":"magpi","deliverAs":"followUp","timestamp":'$(date +%s000)'}' > \(home)/.pi/agent/pitalk-inbox/<PID>/$(date +%s%3N).json
        ```
        The `deliverAs` field controls delivery:
        - `"followUp"` (default) — waits until agent finishes current task. Non-disruptive.
        - `"steer"` — interrupts mid-task. Use for "stop", "interrupt", "cancel".
        - `"nextTurn"` — queued silently for next prompt.

        ## Reading Agent Status Reports

        Each agent's pi-report extension writes to:
        ```
        \(home)/.pi/agent/magpi-reports/<PID>.jsonl
        ```
        Each line: {pid, cwd, sessionId, type, summary, timestamp}.
        Types: alive, started, progress, done, error, need-input, ended.
        ```
        tail -5 \(home)/.pi/agent/magpi-reports/<PID>.jsonl
        ```

        ## Important Guidelines
        - Keep responses **short and conversational** — the user is LISTENING
        - Use <voice> tags for ALL spoken content
        - Check telemetry snapshots first (fast), then reports for details
        - When dispatching, confirm what you sent and to which agent/project
        - Don't read or explore codebases yourself — spoke agents have that context
        - If a task is ambiguous about which agent, ask the user
        """

        // Persist sessions in a dedicated Magpi directory
        let sessionDir = Constants.appSupportDir.appendingPathComponent("sessions").path
        try? FileManager.default.createDirectory(
            atPath: sessionDir,
            withIntermediateDirectories: true
        )

        // Load history from previous session before starting new one
        transcript.loadHistory(fromSessionDir: sessionDir)

        try piRPC.start(
            systemPrompt: systemPrompt,
            workingDirectory: home,
            sessionDir: sessionDir,
            continueSession: true  // Resume last conversation
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
            transcript.addLog("⚡ Agent processing...")

        case .agentEnd:
            // Log full assistant response before finalizing
            if let last = transcript.messages.last, last.role == .assistant {
                transcript.logTurn(role: "ASSISTANT", text: last.text)
            }
            transcript.endAssistantMessage()
            // Wait briefly for speak requests to arrive via broker.
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

        case .textEnd(_):
            break  // Full text logged at agentEnd

        case .toolStart(let name, let id):
            transcript.addLog("🔧 Tool call: \(name) (\(id))")

        case .toolEnd(let name, _):
            transcript.addLog("🔧 Tool done: \(name)")

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

    // MARK: - Mute / Unmute

    /// Stop audio capture entirely — releases the mic so macOS
    /// removes the orange recording indicator.
    private func muteAudio() {
        audioPlayer.stop()
        clearSpeechQueue()
        audioCapture.stop()
        sileroVAD?.reset()
        audioBuffer.reset()
        audioLevel = 0
        if state == .listening || state == .turnCheck || state == .speaking {
            state = .idle
        }
        print("Magpi: 🔇 Muted — mic released")
        transcript.addLog("🔇 Muted (⌘/)")
    }

    /// Restart audio capture and re-attach the audio player for AEC.
    private func unmuteAudio() {
        do {
            try audioCapture.start()
            if let engine = audioCapture.engine {
                audioPlayer.attach(to: engine)
            }
            sileroVAD?.reset()
            audioBuffer.reset()
            bargeInChunkCount = 0
            print("Magpi: 🎙️ Unmuted — mic active")
            transcript.addLog("🎙️ Unmuted (⌘/)")
        } catch {
            print("Magpi: Failed to unmute: \(error)")
            isMuted = true
        }
    }

    // MARK: - Audio Processing

    private func processAudioFrame(_ samples: [Float]) {
        guard !isMuted, let vad = sileroVAD else { return }

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
            // Barge-in: user speaks during TTS → interrupt and listen
            if event == .speechContinue {
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
            // User speaks while waiting for Pi → interrupt and listen
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
                await transcribe()
            } else if turnCheckRetries < Constants.smartTurnMaxRetries {
                turnCheckRetries += 1
                state = .listening
                print("Magpi: Turn not complete, retry \(turnCheckRetries)")

                // Give a bit more silence, then re-check
                sileroVAD?.resetIterator()
                try? await Task.sleep(nanoseconds: UInt64(Constants.smartTurnRetryDelayMs) * 1_000_000)
            } else {
                print("Magpi: Max turn retries — transcribing anyway")
                await transcribe()
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
        let duration = String(format: "%.1f", audioBuffer.duration)
        print("Magpi: → TRANSCRIBING (\(duration)s of audio)")
        transcript.addLog("Transcribing \(duration)s of audio...")

        let audioURL = Constants.tempAudioURL

        do {
            try audioBuffer.saveToWAV(url: audioURL)

            let text = try await transcriber.transcribe(audioURL: audioURL)

            try? FileManager.default.removeItem(at: audioURL)
            audioBuffer.reset()
            sileroVAD?.reset()

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("Magpi: Empty transcription, returning to idle")
                transcript.addLog("Empty transcription — returning to idle")
                state = .idle
                return
            }

            // Add to transcript + log full turn
            transcript.addUserMessage(text)
            transcript.logTurn(role: "USER", text: text)

            // Send to Pi conversation agent via RPC
            print("Magpi: Sending to Pi: \"\(text.prefix(80))\"")

            if piRPC.isRunning {
                if piRPC.isStreaming {
                    piRPC.steer(text)
                    transcript.addLog("↪ Steered agent with new input")
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
            transcript.addLog("⏳ Waiting for response...")

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
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

    /// Stop all TTS playback and clear the speech queue. (Cmd+.)
    func stopSpeech() {
        audioPlayer.stop()
        clearSpeechQueue()
        if state == .speaking {
            state = .idle
        }
        if piRPC.isStreaming {
            piRPC.abort()
            transcript.addLog("⏹ Stopped (Cmd+.)")
        }
    }

    private func processNextSpeech() async {
        speechQueueLock.lock()
        guard !speechQueue.isEmpty else {
            speechQueueLock.unlock()
            if state == .speaking {
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
        transcript.addLog("🔊 Speaking: \"\(item.text)\"")

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
