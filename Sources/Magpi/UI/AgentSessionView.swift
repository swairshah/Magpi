import SwiftUI

/// Shows a spoke agent's session as an event timeline.
/// Inspired by session replay UIs — timestamped events with colored icons.
struct AgentSessionView: View {
    let agent: AgentStore.AgentInfo
    let agentStore: AgentStore

    @State private var messages: [SessionReader.SessionMessage] = []
    @State private var isLoading = true
    @State private var inputText = ""
    @State private var sessionStartTime: Date?

    var body: some View {
        VStack(spacing: 0) {
            agentHeader
            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                Spacer()
            } else if messages.isEmpty {
                emptyState
            } else {
                eventTimeline
            }

            Divider()
            sendBar
        }
        .onAppear { loadMessages() }
        .onChange(of: agent.pid) { loadMessages() }
    }

    // MARK: - Header

    private var agentHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row
            HStack(spacing: 8) {
                Circle()
                    .fill(activityColor)
                    .frame(width: 8, height: 8)

                Text(agent.projectName)
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = DaemonClient.jump(pid: agent.pid)
                    }
                } label: {
                    Label("Jump", systemImage: "rectangle.portrait.and.arrow.forward")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    loadMessages()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reload")
            }

            // Tags row
            HStack(spacing: 6) {
                tagPill(agent.projectName, color: .blue)

                if agent.isOrphaned {
                    tagPill("orphan", color: .orange)
                }

                tagPill("PID \(agent.pid)", color: .secondary)

                if let mux = agent.mux, !mux.isEmpty {
                    tagPill(mux, color: .purple)
                }

                Spacer()

                // Stats
                HStack(spacing: 12) {
                    let userCount = messages.filter { $0.role == .user }.count
                    let assistantCount = messages.filter { $0.role == .assistant }.count
                    let toolCount = messages.flatMap { $0.toolCalls }.count

                    if userCount > 0 {
                        statBadge("person.fill", count: userCount)
                    }
                    if assistantCount > 0 {
                        statBadge("brain", count: assistantCount)
                    }
                    if toolCount > 0 {
                        statBadge("wrench.fill", count: toolCount)
                    }
                }
            }

            // Activity status
            HStack(spacing: 6) {
                Text(activityLabel)
                    .font(.caption.weight(.medium))
                    .foregroundColor(activityColor)

                if let status = agent.lastStatusSummary {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.5).opacity(0.04))
    }

    // MARK: - Event Timeline

    private var eventTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messages) { message in
                        eventRow(message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ message: SessionReader.SessionMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Timestamp column
            Text(relativeTime(message.timestamp))
                .font(.caption.monospaced())
                .foregroundColor(.secondary.opacity(0.6))
                .frame(width: 52, alignment: .trailing)
                .padding(.top, 2)

            // Timeline bar
            VStack(spacing: 0) {
                Rectangle()
                    .fill(timelineColor(message.role))
                    .frame(width: 2)
            }
            .padding(.horizontal, 8)

            // Icon
            eventIcon(message)
                .frame(width: 18)
                .padding(.top, 2)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Tool calls (shown before text, like the reference app)
                ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, tool in
                    HStack(spacing: 4) {
                        Text(toolLabel(tool.name))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(toolColor(tool.name))
                        if let preview = tool.resultPreview, !preview.isEmpty {
                            Text(preview.prefix(80))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                // Message text
                if !message.text.isEmpty {
                    Text(cleanText(message.text))
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundColor(message.role == .user ? .primary : .primary.opacity(0.85))
                        .lineLimit(message.role == .user ? nil : 4)
                }
            }
            .padding(.leading, 6)
            .padding(.vertical, 6)

            Spacer(minLength: 16)

            // Token count placeholder for assistant messages
            if message.role == .assistant && !message.text.isEmpty {
                Text("\(message.text.count)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary.opacity(0.3))
                    .padding(.top, 8)
                    .padding(.trailing, 16)
            }
        }
        .padding(.leading, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.title2)
                .foregroundColor(.secondary.opacity(0.3))
            Text("No session data")
                .foregroundColor(.secondary)
            Text("Session file may not exist yet")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Send Bar

    private var sendBar: some View {
        HStack(spacing: 8) {
            TextField("Send to \(agent.projectName)…", text: $inputText)
                .textFieldStyle(.plain)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.5).opacity(0.08))
                )
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(
                        inputText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? .secondary.opacity(0.3) : .accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.12))
            )
            .foregroundColor(color)
    }

    private func statBadge(_ icon: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
        }
        .foregroundColor(.secondary)
    }

    private func eventIcon(_ message: SessionReader.SessionMessage) -> some View {
        Group {
            switch message.role {
            case .user:
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundColor(.blue)
            case .assistant:
                if !message.toolCalls.isEmpty {
                    Image(systemName: "wrench.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else {
                    Image(systemName: "sparkle")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            case .system:
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func timelineColor(_ role: SessionReader.SessionMessage.Role) -> Color {
        switch role {
        case .user: return .blue.opacity(0.3)
        case .assistant: return .green.opacity(0.2)
        case .system: return .secondary.opacity(0.1)
        }
    }

    private func toolLabel(_ name: String) -> String {
        // Capitalize known tool names like the reference app
        switch name.lowercased() {
        case "read": return "Read"
        case "write": return "Write"
        case "edit": return "Edit"
        case "bash": return "Bash"
        case "web_search": return "Search"
        case "fetch_content": return "Fetch"
        default: return name
        }
    }

    private func toolColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "read": return .cyan
        case "write": return .green
        case "edit": return .yellow
        case "bash": return .orange
        case "web_search", "fetch_content": return .purple
        default: return .orange
        }
    }

    private func relativeTime(_ date: Date) -> String {
        guard let start = sessionStartTime else {
            let f = DateFormatter()
            f.dateFormat = "h:mm"
            return f.string(from: date)
        }
        let elapsed = date.timeIntervalSince(start)
        if elapsed < 0 { return "+0:00" }
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        if mins >= 60 {
            let hrs = mins / 60
            let m = mins % 60
            return "+\(hrs):\(String(format: "%02d", m)):\(String(format: "%02d", secs))"
        }
        return "+\(mins):\(String(format: "%02d", secs))"
    }

    private func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .replacingOccurrences(of: #"<status>[^<]*</status>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activityColor: Color {
        switch agent.activity {
        case "running": return .red
        case "waiting_input": return .green
        default: return .gray
        }
    }

    private var activityLabel: String {
        switch agent.activity {
        case "running": return "Running"
        case "waiting_input": return "Waiting"
        default: return agent.activity.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - Actions

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        agentStore.sendToAgent(pid: agent.pid, text: text)
        inputText = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { loadMessages() }
    }

    private func loadMessages() {
        isLoading = true
        let pid = agent.pid
        DispatchQueue.global(qos: .userInteractive).async {
            let cwd = agent.cwd
            let msgs: [SessionReader.SessionMessage]

            if let sessionURL = SessionReader.sessionFile(cwd: cwd, pid: pid) {
                msgs = SessionReader.readMessages(from: sessionURL, maxMessages: 80)
            } else {
                msgs = []
            }

            let startTime = msgs.first?.timestamp

            DispatchQueue.main.async {
                self.messages = msgs
                self.sessionStartTime = startTime
                self.isLoading = false
            }
        }
    }
}
