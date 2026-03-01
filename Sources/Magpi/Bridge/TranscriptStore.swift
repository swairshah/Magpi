import Foundation

/// Stores the conversation transcript between the user and the Pi manager agent.
/// Used by the transcript UI panel.
@MainActor
final class TranscriptStore: ObservableObject {

    struct Message: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let role: Role
        var text: String
        let isComplete: Bool

        enum Role {
            case user
            case assistant
            case system  // status messages, errors
        }
    }

    @Published private(set) var messages: [Message] = []
    @Published var verboseLogging = false

    /// Log messages (errors, dispatch results, etc.)
    @Published private(set) var logs: [String] = []

    // Accumulator for streaming assistant text
    private var currentAssistantText = ""
    private var isAccumulating = false

    func addUserMessage(_ text: String) {
        // Finalize any incomplete assistant message first
        if isAccumulating { endAssistantMessage() }
        messages.append(Message(role: .user, text: text, isComplete: true))
        trimIfNeeded()
    }

    func beginAssistantMessage() {
        // Auto-finalize any previous incomplete message
        if isAccumulating {
            endAssistantMessage()
        }
        currentAssistantText = ""
        isAccumulating = true
        messages.append(Message(role: .assistant, text: "", isComplete: false))
    }

    func appendAssistantDelta(_ delta: String) {
        guard isAccumulating else { return }
        currentAssistantText += delta
        // Update the last message in place
        if let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant {
            messages[lastIndex] = Message(
                role: .assistant,
                text: currentAssistantText,
                isComplete: false
            )
        }
    }

    func endAssistantMessage() {
        guard isAccumulating else { return }
        isAccumulating = false
        // Finalize the last message
        if let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant {
            messages[lastIndex] = Message(
                role: .assistant,
                text: currentAssistantText,
                isComplete: true
            )
        }
        currentAssistantText = ""
    }

    func addSystemMessage(_ text: String) {
        messages.append(Message(role: .system, text: text, isComplete: true))
        trimIfNeeded()
    }

    func addLog(_ text: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(text)")
        trimLogs()
    }

    /// Log a full transcript turn with role prefix and separator
    func logTurn(role: String, text: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let cleaned = text
            .replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logs.append("[\(timestamp)] ── \(role) ──")
        // Split into lines for readability but keep as single entries
        for line in cleaned.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                logs.append("  \(trimmed)")
            }
        }
        logs.append("")  // blank line after turn
        trimLogs()
    }

    private func trimLogs() {
        if logs.count > 1000 {
            logs.removeFirst(logs.count - 1000)
        }
    }

    func clearMessages() {
        messages.removeAll()
        currentAssistantText = ""
        isAccumulating = false
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func trimIfNeeded() {
        // Keep last 100 messages
        if messages.count > 100 {
            messages.removeFirst(messages.count - 100)
        }
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
