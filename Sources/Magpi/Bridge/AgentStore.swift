import Foundation
import Combine

/// Maintains a live list of running Pi agents by merging data from
/// pi-statusd (PIDs, activity) and pi-report JSONL files (task status).
@MainActor
final class AgentStore: ObservableObject {

    /// Merged agent info combining statusd + reports data
    struct AgentInfo: Identifiable {
        let pid: Int32
        let cwd: String
        let projectName: String
        let activity: String
        let model: String?
        let mux: String?
        let muxSession: String?
        let terminalApp: String?
        /// TTY or mux session name for disambiguation
        let disambiguationLabel: String?
        /// Process parent is launchd (pid 1) — likely a leaked/orphaned process
        let isOrphaned: Bool

        // From pi-report
        var lastStatusType: String?
        var lastStatusSummary: String?
        var lastStatusTime: Date?

        // From session file — first user message as a label
        var sessionTitle: String?

        var id: Int32 { pid }

        /// Display name: project name + disambiguation if needed
        var displayName: String {
            if let title = sessionTitle, !title.isEmpty {
                return title
            }
            return projectName
        }

        var activityColor: String {
            switch activity {
            case "running": return "red"
            case "waiting_input": return "green"
            default: return "gray"
            }
        }
    }

    /// Summary counts
    struct Summary {
        var total: Int = 0
        var running: Int = 0
        var waitingInput: Int = 0
        var unknown: Int = 0
    }

    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var summary = Summary()
    @Published private(set) var isDaemonRunning = false

    private var pollTimer: Timer?
    private var reportWatcher: DispatchSourceFileSystemObject?
    private var reportWatcherFD: Int32 = -1

    /// Cache: PID → session title (stable across polls, cleared when PID disappears)
    private var sessionTitleCache: [Int32: String?] = [:]
    /// Cache: PID → matched session file URL
    private var sessionFileCache: [Int32: URL] = [:]

    // Compute on access to avoid MainActor isolation issues
    private nonisolated static var reportsDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/magpi-reports")
    }

    // MARK: - Lifecycle

    func start(pollInterval: TimeInterval = 5.0) {
        // Initial fetch
        refresh()

        // Periodic polling of statusd
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        // Watch reports directory for changes
        startReportWatcher()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopReportWatcher()
    }

    func refresh() {
        // Fetch statusd + reports on background thread, merge on main
        let currentTitleCache = sessionTitleCache
        let currentFileCache = sessionFileCache

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statusdAgents = Self.fetchStatusdAgentsSync()
            let reports = Self.readAllReportsSync()

            // Resolve session titles in background, using cache
            var newTitleCache: [Int32: String?] = [:]
            var newFileCache: [Int32: URL] = [:]

            for agent in statusdAgents {
                let pid = agent.pid
                let cwd = agent.cwd ?? ""

                // Use cached title if PID is known
                if let cached = currentTitleCache[pid] {
                    newTitleCache[pid] = cached
                    if let cachedFile = currentFileCache[pid] {
                        newFileCache[pid] = cachedFile
                    }
                } else {
                    // First time seeing this PID — resolve in background
                    if let url = SessionReader.sessionFile(cwd: cwd, pid: pid) {
                        newFileCache[pid] = url
                        newTitleCache[pid] = Self.readSessionTitleFast(from: url)
                    } else {
                        newTitleCache[pid] = nil as String?
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.sessionTitleCache = newTitleCache
                self.sessionFileCache = newFileCache
                self.mergeAgents(
                    statusd: statusdAgents,
                    reports: reports,
                    titles: newTitleCache
                )
            }
        }
    }

    // MARK: - Dispatch to Agent

    /// Send a message to an agent via pitalk-inbox
    func sendToAgent(pid: Int32, text: String, deliverAs: String = "followUp") {
        let inboxDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pi/agent/pitalk-inbox/\(pid)")

        // Create inbox directory if needed
        try? FileManager.default.createDirectory(
            atPath: inboxDir,
            withIntermediateDirectories: true
        )

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let message: [String: Any] = [
            "text": text,
            "source": "magpi",
            "deliverAs": deliverAs,
            "timestamp": timestamp
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        let filePath = "\(inboxDir)/\(timestamp).json"
        try? data.write(to: URL(fileURLWithPath: filePath))
        print("Magpi: Sent to agent \(pid): \"\(text.prefix(60))\"")
    }

    // MARK: - StatusD (sync, called from background)

    nonisolated private static func fetchStatusdAgentsSync() -> [DaemonClient.AgentState] {
        guard let response = DaemonClient.status() else {
            return []
        }
        return response.agents ?? []
    }

    // MARK: - Reports (sync, called from background)

    private struct ReportEntry: Decodable {
        let pid: Int?
        let cwd: String?
        let sessionId: String?
        let type: String?
        let summary: String?
        let timestamp: Int?
    }

    /// Read the last report entry for each PID
    nonisolated private static func readAllReportsSync() -> [Int32: ReportEntry] {
        let dir = reportsDir
        guard FileManager.default.fileExists(atPath: dir) else { return [:] }

        var latestByPid: [Int32: ReportEntry] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return [:]
        }

        for file in files where file.hasSuffix(".jsonl") {
            let filePath = (dir as NSString).appendingPathComponent(file)
            // Read only the last few KB of the file (the latest entry)
            guard let handle = FileHandle(forReadingAtPath: filePath) else { continue }
            defer { handle.closeFile() }

            let fileSize = handle.seekToEndOfFile()
            let readSize: UInt64 = min(fileSize, 2048)
            handle.seek(toFileOffset: fileSize - readSize)
            let tailData = handle.readDataToEndOfFile()

            guard let content = String(data: tailData, encoding: .utf8) else { continue }

            // Read the last non-empty line (most recent status)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let lastLine = lines.last,
                  let lineData = lastLine.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(ReportEntry.self, from: lineData),
                  let pid = entry.pid else {
                continue
            }

            latestByPid[Int32(pid)] = entry
        }

        return latestByPid
    }

    // MARK: - Merging

    private func mergeAgents(
        statusd: [DaemonClient.AgentState],
        reports: [Int32: ReportEntry],
        titles: [Int32: String?]
    ) {
        let daemonOk = !statusd.isEmpty || DaemonClient.isDaemonRunning()
        isDaemonRunning = daemonOk

        var merged: [AgentInfo] = []

        for agent in statusd {
            let report = reports[agent.pid]

            var info = AgentInfo(
                pid: agent.pid,
                cwd: agent.cwd ?? "unknown",
                projectName: agent.projectName,
                activity: agent.activity,
                model: nil,
                mux: agent.mux,
                muxSession: agent.muxSession,
                terminalApp: agent.terminalApp,
                disambiguationLabel: agent.disambiguationLabel,
                isOrphaned: agent.isOrphaned,
                sessionTitle: titles[agent.pid] ?? nil
            )

            if let report = report {
                info.lastStatusType = report.type
                info.lastStatusSummary = report.summary
                if let ts = report.timestamp {
                    info.lastStatusTime = Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0)
                }
            }

            merged.append(info)
        }

        // Sort: orphaned last, then running first, then waiting, then by project name
        merged.sort { a, b in
            if a.isOrphaned != b.isOrphaned { return !a.isOrphaned }
            let aOrder = activityOrder(a.activity)
            let bOrder = activityOrder(b.activity)
            if aOrder != bOrder { return aOrder < bOrder }
            return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
        }

        self.agents = merged
        self.summary = Summary(
            total: merged.count,
            running: merged.filter { $0.activity == "running" }.count,
            waitingInput: merged.filter { $0.activity == "waiting_input" }.count,
            unknown: merged.filter { $0.activity != "running" && $0.activity != "waiting_input" }.count
        )
    }

    private func activityOrder(_ activity: String) -> Int {
        switch activity {
        case "running": return 0
        case "waiting_input": return 1
        default: return 2
        }
    }

    // MARK: - Session Title (fast, streaming read)

    /// Read just the first user message from a session file.
    /// Uses streaming read — doesn't load entire file into memory.
    nonisolated private static func readSessionTitleFast(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        // Read first 32KB — the first user message is always near the top
        let chunk = handle.readData(ofLength: 32 * 1024)
        guard let content = String(data: chunk, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "message",
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "user",
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            for block in content {
                if let blockType = block["type"] as? String,
                   blockType == "text",
                   let text = block["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let maxLen = 50
                        return trimmed.count > maxLen
                            ? String(trimmed.prefix(maxLen)) + "…"
                            : trimmed
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Report Directory Watcher

    private func startReportWatcher() {
        let dir = Self.reportsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        reportWatcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        reportWatcher = source
    }

    private func stopReportWatcher() {
        reportWatcher?.cancel()
        reportWatcher = nil
        reportWatcherFD = -1
    }
}
