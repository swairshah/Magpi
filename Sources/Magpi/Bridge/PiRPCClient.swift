import Foundation

/// Manages a Pi subprocess in RPC mode (`pi --mode rpc`).
///
/// This is the "conversation agent" — Magpi's own Pi session that receives
/// transcribed speech as prompts and streams responses back. The pi-talk
/// extension (loaded in this session) handles voice tag parsing and sends
/// speak commands to Magpi's broker for TTS playback.
///
/// Communication is NDJSON over stdin/stdout per Pi's RPC protocol.
final class PiRPCClient {

    // MARK: - Types

    /// Events emitted by the Pi RPC subprocess.
    enum Event {
        case agentStart
        case agentEnd
        case textDelta(String)
        case textEnd(String)
        case toolStart(name: String, id: String)
        case toolEnd(name: String, id: String)
        case stateResponse(isStreaming: Bool, sessionId: String?)
        case response(command: String, success: Bool, error: String?)
        case error(String)
        case processExited(Int32)
    }

    /// Callback for events from the Pi subprocess.
    var onEvent: ((Event) -> Void)?

    /// Whether the Pi subprocess is currently running.
    private(set) var isRunning = false

    /// Whether the Pi agent is currently streaming a response.
    private(set) var isStreaming = false

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let queue = DispatchQueue(label: "magpi.rpc", qos: .userInitiated)
    private var nextRequestId = 1

    // Accumulate partial lines from stdout
    private var stdoutBuffer = ""

    init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start the Pi subprocess in RPC mode.
    ///
    /// - Parameters:
    ///   - provider: LLM provider (e.g. "anthropic", "google")
    ///   - model: Model ID (e.g. "claude-sonnet-4-20250514")
    ///   - systemPrompt: Optional additional system prompt text
    ///   - workingDirectory: Working directory for the Pi session
    func start(
        provider: String? = nil,
        model: String? = nil,
        systemPrompt: String? = nil,
        workingDirectory: String? = nil
    ) throws {
        guard !isRunning else { return }

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        // Find pi binary
        guard let piPath = findPiBinary() else {
            throw RPCError.piNotFound
        }

        proc.executableURL = URL(fileURLWithPath: piPath)

        var args = ["--mode", "rpc"]

        if let provider = provider {
            args += ["--provider", provider]
        }
        if let model = model {
            args += ["--model", model]
        }
        if let systemPrompt = systemPrompt {
            args += ["--append-system-prompt", systemPrompt]
        }

        proc.arguments = args

        if let cwd = workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        // Inherit environment (API keys, PATH, etc.)
        var env = ProcessInfo.processInfo.environment
        // Ensure pi can find node modules
        if let path = env["PATH"] {
            env["PATH"] = path
        }
        proc.environment = env

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Handle stdout — NDJSON events
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                self?.handleStdoutData(text)
            }
        }

        // Handle stderr — log warnings/errors
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            // Only log non-empty stderr (pi prints startup info here)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("Magpi: [pi-rpc stderr] \(trimmed)")
            }
        }

        proc.terminationHandler = { [weak self] proc in
            self?.queue.async {
                self?.isRunning = false
                self?.isStreaming = false
                let code = proc.terminationStatus
                print("Magpi: Pi RPC process exited with code \(code)")
                self?.onEvent?(.processExited(code))
            }
        }

        try proc.run()
        isRunning = true
        print("Magpi: Pi RPC started (pid=\(proc.processIdentifier))")
    }

    /// Stop the Pi subprocess.
    func stop() {
        guard isRunning else { return }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            // Give it a moment to clean up
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                if let proc = self?.process, proc.isRunning {
                    proc.interrupt()
                }
            }
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
        isStreaming = false
        stdoutBuffer = ""
    }

    // MARK: - Commands

    /// Send a user prompt to the conversation agent.
    func sendPrompt(_ text: String) {
        let id = nextId()
        let command: [String: Any] = [
            "id": id,
            "type": "prompt",
            "message": text,
        ]
        sendCommand(command)
        isStreaming = true
    }

    /// Steer the agent mid-response (interrupt with new input).
    func steer(_ text: String) {
        let command: [String: Any] = [
            "type": "steer",
            "message": text,
        ]
        sendCommand(command)
    }

    /// Queue a follow-up for after the agent finishes.
    func followUp(_ text: String) {
        let command: [String: Any] = [
            "type": "follow_up",
            "message": text,
        ]
        sendCommand(command)
    }

    /// Abort the current operation.
    func abort() {
        let command: [String: Any] = [
            "type": "abort",
        ]
        sendCommand(command)
    }

    /// Get current session state.
    func getState() {
        let id = nextId()
        let command: [String: Any] = [
            "id": id,
            "type": "get_state",
        ]
        sendCommand(command)
    }

    /// Start a new session.
    func newSession() {
        let command: [String: Any] = [
            "type": "new_session",
        ]
        sendCommand(command)
    }

    // MARK: - Private

    private func nextId() -> String {
        let id = "magpi-\(nextRequestId)"
        nextRequestId += 1
        return id
    }

    private func sendCommand(_ command: [String: Any]) {
        guard isRunning, let pipe = stdinPipe else {
            print("Magpi: Cannot send RPC command — process not running")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: command)
            var line = data
            line.append(0x0A) // newline
            pipe.fileHandleForWriting.write(line)
        } catch {
            print("Magpi: Failed to serialize RPC command: \(error)")
        }
    }

    private func handleStdoutData(_ text: String) {
        stdoutBuffer += text

        // Process complete lines
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineRange.lowerBound])
            stdoutBuffer = String(stdoutBuffer[newlineRange.upperBound...])

            if !line.isEmpty {
                parseEvent(line)
            }
        }
    }

    private func parseEvent(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "response":
            let command = json["command"] as? String ?? "unknown"
            let success = json["success"] as? Bool ?? false
            let error = json["error"] as? String

            if command == "get_state", success, let stateData = json["data"] as? [String: Any] {
                let streaming = stateData["isStreaming"] as? Bool ?? false
                let sessionId = stateData["sessionId"] as? String
                isStreaming = streaming
                onEvent?(.stateResponse(isStreaming: streaming, sessionId: sessionId))
            } else {
                onEvent?(.response(command: command, success: success, error: error))
            }

        case "agent_start":
            isStreaming = true
            onEvent?(.agentStart)

        case "agent_end":
            isStreaming = false
            onEvent?(.agentEnd)

        case "message_update":
            if let delta = json["assistantMessageEvent"] as? [String: Any] {
                let deltaType = delta["type"] as? String ?? ""

                switch deltaType {
                case "text_delta":
                    if let text = delta["delta"] as? String {
                        onEvent?(.textDelta(text))
                    }
                case "text_end":
                    if let content = delta["content"] as? String {
                        onEvent?(.textEnd(content))
                    }
                default:
                    break
                }
            }

        case "tool_execution_start":
            let name = json["toolName"] as? String ?? "unknown"
            let id = json["toolCallId"] as? String ?? ""
            onEvent?(.toolStart(name: name, id: id))

        case "tool_execution_end":
            let name = json["toolName"] as? String ?? "unknown"
            let id = json["toolCallId"] as? String ?? ""
            onEvent?(.toolEnd(name: name, id: id))

        case "extension_ui_request":
            handleExtensionUIRequest(json)

        case "extension_error":
            let error = json["error"] as? String ?? "unknown error"
            print("Magpi: [pi-rpc] Extension error: \(error)")

        default:
            break
        }
    }

    /// Handle extension UI requests (e.g. confirm dialogs from pi-talk).
    /// For now, auto-confirm/cancel since we're headless.
    private func handleExtensionUIRequest(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let method = json["method"] as? String else { return }

        switch method {
        case "select", "input", "editor":
            // Auto-cancel dialog requests
            let response: [String: Any] = [
                "type": "extension_ui_response",
                "id": id,
                "cancelled": true,
            ]
            sendCommand(response)

        case "confirm":
            // Auto-confirm
            let response: [String: Any] = [
                "type": "extension_ui_response",
                "id": id,
                "confirmed": true,
            ]
            sendCommand(response)

        case "notify":
            if let message = json["message"] as? String {
                print("Magpi: [pi-rpc notify] \(message)")
            }

        case "setStatus", "setWidget", "setTitle", "set_editor_text":
            // Fire-and-forget, no response needed
            break

        default:
            break
        }
    }

    /// Find the pi binary on the system.
    private func findPiBinary() -> String? {
        // Check common locations
        let candidates = [
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.nvm/versions/node/v22.16.0/bin/pi" },
            "/usr/local/bin/pi",
            "/opt/homebrew/bin/pi",
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try which
        let which = Process()
        let pipe = Pipe()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["pi"]
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let path = output, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    // MARK: - Errors

    enum RPCError: LocalizedError {
        case piNotFound

        var errorDescription: String? {
            switch self {
            case .piNotFound:
                return "Could not find 'pi' binary. Is it installed?"
            }
        }
    }
}
