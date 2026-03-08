import Foundation
import Combine

/// Maintains a live list of running Pi agents by reading pi-telemetry
/// instance snapshots and merging with pi-report JSONL status files.
@MainActor
final class AgentStore: ObservableObject {

    /// Agent info parsed from pi-telemetry snapshots + pi-report data
    struct AgentInfo: Identifiable {
        let pid: Int32
        let ppid: Int32
        let cwd: String
        let projectName: String
        let activity: String
        let model: String?
        let mux: String?
        let muxSession: String?
        let terminalApp: String?
        let terminalPid: Int32?
        /// TTY or mux session name for disambiguation
        let disambiguationLabel: String?
        /// Process parent is launchd (pid 1) or dead
        let isOrphaned: Bool
        /// Git branch from telemetry
        let gitBranch: String?
        /// Context usage percent from telemetry
        let contextPercent: Double?
        /// Session name from telemetry
        let sessionName: String?

        // From pi-report
        var lastStatusType: String?
        var lastStatusSummary: String?
        var lastStatusTime: Date?

        // From session file — first user message as a label
        var sessionTitle: String?

        var id: Int32 { pid }

        /// Display name: session title > session name > project name
        var displayName: String {
            if let title = sessionTitle, !title.isEmpty {
                return title
            }
            if let name = sessionName, !name.isEmpty {
                return name
            }
            return projectName
        }

        var activityColor: String {
            switch activity {
            case "running", "working": return "red"
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
    @Published private(set) var isTelemetryAvailable = false

    private var pollTimer: Timer?
    private var reportWatcher: DispatchSourceFileSystemObject?
    private var reportWatcherFD: Int32 = -1

    /// Cache: PID → session title (stable across polls, cleared when PID disappears)
    private var sessionTitleCache: [Int32: String?] = [:]
    /// Cache: PID → matched session file URL
    private var sessionFileCache: [Int32: URL] = [:]

    /// Max age in seconds for a telemetry snapshot to be considered alive.
    /// pi-telemetry heartbeats every 1.5s, so 5s gives a comfortable margin.
    private nonisolated static let maxSnapshotAgeSec: TimeInterval = 5.0

    private nonisolated static var telemetryDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pi/agent/telemetry/instances")
    }

    private nonisolated static var reportsDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pi/agent/magpi-reports")
    }

    // MARK: - Lifecycle

    func start(pollInterval: TimeInterval = 3.0) {
        refresh()

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        startReportWatcher()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopReportWatcher()
    }

    func refresh() {
        let currentTitleCache = sessionTitleCache
        let currentFileCache = sessionFileCache

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshots = Self.readTelemetrySnapshotsSync()
            let reports = Self.readAllReportsSync()

            // Resolve session titles in background
            var newTitleCache: [Int32: String?] = [:]
            var newFileCache: [Int32: URL] = [:]

            for snap in snapshots {
                let pid = snap.pid

                if let cached = currentTitleCache[pid] {
                    newTitleCache[pid] = cached
                    if let cachedFile = currentFileCache[pid] {
                        newFileCache[pid] = cachedFile
                    }
                } else {
                    // Try session file from telemetry data
                    if let sessionFile = snap.sessionFile,
                       let url = URL(string: "file://\(sessionFile)"),
                       FileManager.default.fileExists(atPath: sessionFile) {
                        newFileCache[pid] = url
                        newTitleCache[pid] = Self.readSessionTitleFast(from: url)
                    } else if let url = SessionReader.sessionFile(cwd: snap.cwd, pid: pid) {
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
                    snapshots: snapshots,
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

    // MARK: - Jump to Agent

    /// Focus the terminal window/tab containing an agent.
    /// Uses routing info from telemetry to activate the right app.
    func jumpToAgent(_ agent: AgentInfo) {
        guard let terminalApp = agent.terminalApp else {
            print("Magpi: Can't jump — no terminal app info for PID \(agent.pid)")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Activate the terminal application
            let script = """
            tell application "\(terminalApp)" to activate
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()

            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    print("Magpi: Jumped to \(terminalApp) for PID \(agent.pid)")
                } else {
                    print("Magpi: Jump failed for PID \(agent.pid)")
                }
            }
        }
    }

    // MARK: - Telemetry Snapshots

    /// Parsed telemetry snapshot (subset of fields we need)
    private struct TelemetrySnapshot {
        let pid: Int32
        let ppid: Int32
        let cwd: String
        let activity: String
        let modelName: String?
        let mux: String?
        let muxSession: String?
        let terminalApp: String?
        let terminalPid: Int32?
        let tty: String?
        let sessionName: String?
        let sessionFile: String?
        let gitBranch: String?
        let contextPercent: Double?
    }

    /// Read all live telemetry snapshots from disk
    nonisolated private static func readTelemetrySnapshotsSync() -> [TelemetrySnapshot] {
        let dir = telemetryDir
        guard FileManager.default.fileExists(atPath: dir) else { return [] }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }

        let nowMs = Date().timeIntervalSince1970 * 1000
        var snapshots: [TelemetrySnapshot] = []

        for file in files where file.hasSuffix(".json") {
            let filePath = (dir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Check staleness via heartbeat timestamp
            guard let process = json["process"] as? [String: Any],
                  let updatedAt = process["updatedAt"] as? Double else {
                continue
            }

            let ageMs = nowMs - updatedAt
            if ageMs > maxSnapshotAgeSec * 1000 {
                // Stale — process is dead, clean up the file
                try? FileManager.default.removeItem(atPath: filePath)
                continue
            }

            guard let pid = process["pid"] as? Int,
                  let ppid = process["ppid"] as? Int else {
                continue
            }

            let workspace = json["workspace"] as? [String: Any]
            let cwd = workspace?["cwd"] as? String ?? "unknown"
            let git = workspace?["git"] as? [String: Any]

            let state = json["state"] as? [String: Any]
            let activity = state?["activity"] as? String ?? "unknown"

            let model = json["model"] as? [String: Any]
            let routing = json["routing"] as? [String: Any]
            let session = json["session"] as? [String: Any]
            let context = json["context"] as? [String: Any]

            let terminalPidRaw = routing?["terminalPid"] as? Int

            snapshots.append(TelemetrySnapshot(
                pid: Int32(pid),
                ppid: Int32(ppid),
                cwd: cwd,
                activity: activity,
                modelName: model?["name"] as? String ?? model?["id"] as? String,
                mux: routing?["mux"] as? String,
                muxSession: routing?["muxSession"] as? String,
                terminalApp: routing?["terminalApp"] as? String,
                terminalPid: terminalPidRaw.map { Int32($0) },
                tty: routing?["tty"] as? String,
                sessionName: session?["name"] as? String,
                sessionFile: session?["file"] as? String,
                gitBranch: git?["branch"] as? String,
                contextPercent: context?["percent"] as? Double
            ))
        }

        return snapshots
    }

    // MARK: - Reports

    private struct ReportEntry: Decodable {
        let pid: Int?
        let cwd: String?
        let sessionId: String?
        let type: String?
        let summary: String?
        let timestamp: Int?
    }

    nonisolated private static func readAllReportsSync() -> [Int32: ReportEntry] {
        let dir = reportsDir
        guard FileManager.default.fileExists(atPath: dir) else { return [:] }

        var latestByPid: [Int32: ReportEntry] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return [:]
        }

        for file in files where file.hasSuffix(".jsonl") {
            let filePath = (dir as NSString).appendingPathComponent(file)
            guard let handle = FileHandle(forReadingAtPath: filePath) else { continue }
            defer { handle.closeFile() }

            let fileSize = handle.seekToEndOfFile()
            let readSize: UInt64 = min(fileSize, 2048)
            handle.seek(toFileOffset: fileSize - readSize)
            let tailData = handle.readDataToEndOfFile()

            guard let content = String(data: tailData, encoding: .utf8) else { continue }

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
        snapshots: [TelemetrySnapshot],
        reports: [Int32: ReportEntry],
        titles: [Int32: String?]
    ) {
        isTelemetryAvailable = FileManager.default.fileExists(atPath: Self.telemetryDir)

        var merged: [AgentInfo] = []

        for snap in snapshots {
            let report = reports[snap.pid]

            let home = NSHomeDirectory()
            let cwd = snap.cwd
            let display: String
            if cwd == home {
                display = "~"
            } else if cwd.hasPrefix(home) {
                display = "~" + cwd.dropFirst(home.count)
            } else {
                display = cwd
            }
            let projectName = display.split(separator: "/").suffix(2).joined(separator: "/")

            // Disambiguation label
            let disambiguationLabel: String? = {
                if let muxSession = snap.muxSession, !muxSession.isEmpty {
                    return muxSession
                }
                if let tty = snap.tty, !tty.isEmpty {
                    return tty.split(separator: "/").last.map(String.init) ?? tty
                }
                return nil
            }()

            // Orphan detection
            let isOrphaned = snap.ppid == 1 || kill(snap.ppid, 0) != 0

            var info = AgentInfo(
                pid: snap.pid,
                ppid: snap.ppid,
                cwd: cwd,
                projectName: projectName.isEmpty ? "~" : projectName,
                activity: snap.activity,
                model: snap.modelName,
                mux: snap.mux,
                muxSession: snap.muxSession,
                terminalApp: snap.terminalApp,
                terminalPid: snap.terminalPid,
                disambiguationLabel: disambiguationLabel,
                isOrphaned: isOrphaned,
                gitBranch: snap.gitBranch,
                contextPercent: snap.contextPercent,
                sessionName: snap.sessionName,
                sessionTitle: titles[snap.pid] ?? nil
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

        // Sort: orphaned last, then running first, then waiting, then by project
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
            running: merged.filter { $0.activity == "running" || $0.activity == "working" }.count,
            waitingInput: merged.filter { $0.activity == "waiting_input" }.count,
            unknown: merged.filter { $0.activity != "running" && $0.activity != "working" && $0.activity != "waiting_input" }.count
        )
    }

    private func activityOrder(_ activity: String) -> Int {
        switch activity {
        case "running", "working": return 0
        case "waiting_input": return 1
        default: return 2
        }
    }

    // MARK: - Session Title (fast, streaming read)

    nonisolated private static func readSessionTitleFast(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

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
