import Foundation

/// Reads Pi agent session JSONL files to extract conversation history.
enum SessionReader {

    struct SessionMessage: Identifiable {
        let id: String
        let timestamp: Date
        let role: Role
        let text: String
        let toolCalls: [ToolCall]

        enum Role: String {
            case user
            case assistant
            case system
        }
    }

    struct ToolCall {
        let name: String
        let resultPreview: String?
    }

    /// Find the latest session file for a given working directory.
    static func latestSessionFile(cwd: String) -> URL? {
        let dirName = cwdToSessionDirName(cwd)
        let sessionsDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pi/agent/sessions/\(dirName)")

        guard FileManager.default.fileExists(atPath: sessionsDir) else { return nil }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else {
            return nil
        }

        // Session files are named with ISO timestamps, sort descending for latest
        let jsonlFiles = files
            .filter { $0.hasSuffix(".jsonl") }
            .sorted(by: >)

        guard let latest = jsonlFiles.first else { return nil }
        return URL(fileURLWithPath: sessionsDir).appendingPathComponent(latest)
    }

    /// Read messages from a session JSONL file.
    /// Returns the last N messages for display.
    static func readMessages(from url: URL, maxMessages: Int = 50) -> [SessionMessage] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var messages: [SessionMessage] = []

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            guard let type = obj["type"] as? String else { continue }

            if type == "message" {
                if let msg = parseMessage(obj) {
                    messages.append(msg)
                }
            }
        }

        // Return last N messages
        if messages.count > maxMessages {
            return Array(messages.suffix(maxMessages))
        }
        return messages
    }

    // MARK: - Private

    private static func parseMessage(_ obj: [String: Any]) -> SessionMessage? {
        guard let message = obj["message"] as? [String: Any],
              let roleStr = message["role"] as? String,
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }

        let role: SessionMessage.Role
        switch roleStr {
        case "user": role = .user
        case "assistant": role = .assistant
        default: role = .system
        }

        let id = obj["id"] as? String ?? UUID().uuidString
        let timestamp = parseTimestamp(obj["timestamp"])

        // Extract text blocks
        var textParts: [String] = []
        var toolCalls: [ToolCall] = []

        for block in content {
            let blockType = block["type"] as? String ?? ""

            if blockType == "text", let text = block["text"] as? String {
                textParts.append(text)
            } else if blockType == "tool_use" {
                let name = block["name"] as? String ?? "tool"
                toolCalls.append(ToolCall(name: name, resultPreview: nil))
            } else if blockType == "tool_result" {
                let resultContent = block["content"] as? [[String: Any]]
                let resultText = resultContent?.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let preview = resultText.map { String($0.prefix(200)) }
                let name = block["tool_use_id"] as? String ?? "tool"
                toolCalls.append(ToolCall(name: name, resultPreview: preview))
            }
        }

        let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty messages (e.g. pure tool_use with no text)
        if text.isEmpty && toolCalls.isEmpty { return nil }

        return SessionMessage(
            id: id,
            timestamp: timestamp,
            role: role,
            text: text,
            toolCalls: toolCalls
        )
    }

    private static func parseTimestamp(_ value: Any?) -> Date {
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) { return date }
        }
        return Date()
    }

    /// Convert a cwd path to the session directory name format.
    /// e.g. "/Users/swair/work/projects/Magpi" → "--Users-swair-work-projects-Magpi--"
    static func cwdToSessionDirName(_ cwd: String) -> String {
        var name = cwd
        if name.hasPrefix("/") { name = String(name.dropFirst()) }
        name = name.replacingOccurrences(of: "/", with: "-")
        return "--\(name)--"
    }
}
