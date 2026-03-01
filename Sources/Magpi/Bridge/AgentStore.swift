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

        // From pi-report
        var lastStatusType: String?
        var lastStatusSummary: String?
        var lastStatusTime: Date?

        var id: Int32 { pid }

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

    private static let reportsDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".pi/agent/magpi-reports")

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
        let statusdAgents = fetchStatusdAgents()
        let reports = readAllReports()
        mergeAgents(statusd: statusdAgents, reports: reports)
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

    // MARK: - StatusD

    private func fetchStatusdAgents() -> [DaemonClient.AgentState] {
        guard let response = DaemonClient.status() else {
            isDaemonRunning = false
            return []
        }
        isDaemonRunning = response.ok
        return response.agents ?? []
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

    /// Read the last report entry for each PID
    private func readAllReports() -> [Int32: ReportEntry] {
        let dir = Self.reportsDir
        guard FileManager.default.fileExists(atPath: dir) else { return [:] }

        var latestByPid: [Int32: ReportEntry] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return [:]
        }

        for file in files where file.hasSuffix(".jsonl") {
            let filePath = (dir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

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

    private func mergeAgents(statusd: [DaemonClient.AgentState], reports: [Int32: ReportEntry]) {
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
                terminalApp: agent.terminalApp
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

        // Sort: running first, then waiting, then by project name
        merged.sort { a, b in
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
