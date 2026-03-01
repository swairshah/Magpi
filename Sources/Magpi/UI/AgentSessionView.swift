import SwiftUI

/// Shows a spoke agent's session conversation history + send bar.
/// Reads the agent's JSONL session file and displays messages.
struct AgentSessionView: View {
    let agent: AgentStore.AgentInfo
    let agentStore: AgentStore

    @State private var messages: [SessionReader.SessionMessage] = []
    @State private var isLoading = true
    @State private var inputText = ""
    @State private var lastLoadTime = Date.distantPast

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            agentHeader
                .padding(12)
                .background(.bar)

            Divider()

            // Messages
            if isLoading {
                ProgressView("Loading session...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No messages in this session")
                        .foregroundColor(.secondary)
                    Text("Session file may not exist yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messageList
            }

            Divider()

            // Send bar
            sendBar
                .padding(12)
        }
        .onAppear { loadMessages() }
        .onChange(of: agent.pid) { loadMessages() }
    }

    // MARK: - Header

    private var agentHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(activityColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.projectName)
                        .font(.headline)
                    Text("PID \(agent.pid)")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text(activityLabel)
                        .font(.caption.weight(.medium))
                        .foregroundColor(activityColor)

                    if let mux = agent.mux, !mux.isEmpty {
                        Text(mux)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                    }

                    if let status = agent.lastStatusSummary {
                        Text("• \(status)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

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
            .help("Reload session")
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        sessionMessageRow(message)
                            .id(message.id)
                    }
                }
                .padding(16)
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
    private func sessionMessageRow(_ message: SessionReader.SessionMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: roleIcon(message.role))
                .foregroundColor(roleColor(message.role))
                .font(.caption)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                // Role + timestamp
                HStack(spacing: 4) {
                    Text(roleLabel(message.role))
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)

                    Text(timeString(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                }

                // Tool calls
                if !message.toolCalls.isEmpty {
                    ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, tool in
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            Text(tool.name)
                                .font(.caption.monospaced())
                                .foregroundColor(.orange)
                            if let preview = tool.resultPreview, !preview.isEmpty {
                                Text("→ \(preview.prefix(80))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // Message text
                if !message.text.isEmpty {
                    Text(cleanText(message.text))
                        .textSelection(.enabled)
                        .font(.body)
                        .foregroundColor(message.role == .system ? .secondary : .primary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(roleBackground(message.role))
        .cornerRadius(8)
    }

    // MARK: - Send Bar

    private var sendBar: some View {
        HStack(spacing: 8) {
            TextField("Send to \(agent.projectName)...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.body)
            }
            .buttonStyle(.borderedProminent)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Actions

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        agentStore.sendToAgent(pid: agent.pid, text: text)
        inputText = ""

        // Reload after a brief delay to show the new message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            loadMessages()
        }
    }

    private func loadMessages() {
        isLoading = true
        let pid = agent.pid
        DispatchQueue.global(qos: .userInteractive).async {
            let cwd = agent.cwd
            let msgs: [SessionReader.SessionMessage]

            // Use PID-based matching to find this agent's specific session file
            if let sessionURL = SessionReader.sessionFile(cwd: cwd, pid: pid) {
                msgs = SessionReader.readMessages(from: sessionURL, maxMessages: 80)
            } else {
                msgs = []
            }

            DispatchQueue.main.async {
                self.messages = msgs
                self.isLoading = false
                self.lastLoadTime = Date()
            }
        }
    }

    // MARK: - Helpers

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

    private func roleIcon(_ role: SessionReader.SessionMessage.Role) -> String {
        switch role {
        case .user: return "person.fill"
        case .assistant: return "brain"
        case .system: return "info.circle"
        }
    }

    private func roleColor(_ role: SessionReader.SessionMessage.Role) -> Color {
        switch role {
        case .user: return .blue
        case .assistant: return .green
        case .system: return .orange
        }
    }

    private func roleLabel(_ role: SessionReader.SessionMessage.Role) -> String {
        switch role {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }

    private func roleBackground(_ role: SessionReader.SessionMessage.Role) -> Color {
        switch role {
        case .user: return Color.blue.opacity(0.06)
        case .assistant: return Color.green.opacity(0.04)
        case .system: return Color.orange.opacity(0.04)
        }
    }

    private func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .replacingOccurrences(of: "<status>", with: "")
            .replacingOccurrences(of: "</status>", with: "")
            .replacingOccurrences(of: #"<status>[^<]*</status>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
