import Foundation
import Darwin

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

    /// Find the session file for a specific PID in a given working directory.
    /// Uses the process start time to match against session file timestamps.
    /// Falls back to the latest session file if PID matching fails.
    static func sessionFile(cwd: String, pid: Int32) -> URL? {
        let dirName = cwdToSessionDirName(cwd)
        let sessionsDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pi/agent/sessions/\(dirName)")

        guard FileManager.default.fileExists(atPath: sessionsDir) else { return nil }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else {
            return nil
        }

        let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }
        guard !jsonlFiles.isEmpty else { return nil }

        // Try to match by process start time
        if let processStart = getProcessStartTime(pid: pid) {
            let sessionDir = URL(fileURLWithPath: sessionsDir)
            var bestMatch: (file: String, delta: TimeInterval)?

            for file in jsonlFiles {
                // Session filenames: 2026-02-28T08-43-01-970Z_UUID.jsonl
                // Extract the ISO timestamp portion before the underscore
                if let sessionDate = parseSessionFilenameDate(file) {
                    let delta = abs(sessionDate.timeIntervalSince(processStart))
                    if bestMatch == nil || delta < bestMatch!.delta {
                        bestMatch = (file, delta)
                    }
                }
            }

            // Accept if within 5 seconds (process start vs session create are very close)
            if let match = bestMatch, match.delta < 5.0 {
                return sessionDir.appendingPathComponent(match.file)
            }
        }

        // Fallback: return the latest session file
        let sorted = jsonlFiles.sorted(by: >)
        return URL(fileURLWithPath: sessionsDir).appendingPathComponent(sorted[0])
    }

    /// Find the latest session file for a given working directory (no PID matching).
    static func latestSessionFile(cwd: String) -> URL? {
        let dirName = cwdToSessionDirName(cwd)
        let sessionsDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pi/agent/sessions/\(dirName)")

        guard FileManager.default.fileExists(atPath: sessionsDir) else { return nil }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else {
            return nil
        }

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

    // MARK: - Process Start Time

    /// Get the start time of a process using sysctl.
    static func getProcessStartTime(pid: Int32) -> Date? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }

        let startTime = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(startTime.tv_sec) + Double(startTime.tv_usec) / 1_000_000)
    }

    // MARK: - Private

    /// Parse the date from a session filename.
    /// Format: "2026-02-28T08-43-01-970Z_UUID.jsonl"
    private static func parseSessionFilenameDate(_ filename: String) -> Date? {
        // Extract timestamp portion before the UUID
        guard let underscoreIndex = filename.firstIndex(of: "_") else { return nil }
        var tsStr = String(filename[filename.startIndex..<underscoreIndex])

        // Convert from filename format "2026-02-28T08-43-01-970Z" to ISO8601 "2026-02-28T08:43:01.970Z"
        // The hours-minutes-seconds use dashes instead of colons (filesystem safe)
        // And the fractional seconds use a dash instead of a dot
        guard tsStr.hasSuffix("Z") else { return nil }
        tsStr.removeLast() // Remove Z

        let parts = tsStr.split(separator: "T")
        guard parts.count == 2 else { return nil }

        let datePart = parts[0] // "2026-02-28"
        let timePart = parts[1] // "08-43-01-970"
        let timeComponents = timePart.split(separator: "-")
        guard timeComponents.count >= 3 else { return nil }

        let hours = timeComponents[0]
        let minutes = timeComponents[1]
        let seconds = timeComponents[2]
        let millis = timeComponents.count > 3 ? timeComponents[3] : "000"

        let isoString = "\(datePart)T\(hours):\(minutes):\(seconds).\(millis)Z"

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: isoString)
    }

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
