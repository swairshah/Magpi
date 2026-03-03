import SwiftUI

/// Main application window — sidebar with agents + conversation area.
/// Inspired by Graphone's session sidebar and PiTalk's session cards.
struct MainWindowView: View {
    @ObservedObject var conversationLoop: ConversationLoop
    @ObservedObject var agentStore: AgentStore
    @State private var selectedTab: Tab = .agents
    @State private var sidebarCollapsed = false
    /// nil = show Magpi manager conversation, otherwise show spoke agent's session
    @State private var selectedAgentPid: Int32? = nil

    enum Tab: String, CaseIterable {
        case agents = "Agents"
        case settings = "Settings"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { agentStore.refresh() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Voice status header
            voiceStatusHeader
                .padding(12)

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Tab content
            switch selectedTab {
            case .agents:
                agentSidebar
            case .settings:
                settingsSidebar
            }
        }
    }

    // MARK: - Voice Status Header

    private var voiceStatusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // State indicator with bird icon
                stateIcon
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Magpi")
                        .font(.headline)
                    Text(conversationLoop.state.displayName)
                        .font(.caption)
                        .foregroundColor(stateColor)
                }

                Spacer()

                // Recording indicator
                if conversationLoop.isRecordToggleActive {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("REC").font(.caption2.weight(.bold)).foregroundColor(.red)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.1)))
                }
            }

            // Controls row
            HStack(spacing: 8) {
                // Record toggle
                Button {
                    conversationLoop.toggleRecording()
                } label: {
                    Label(
                        conversationLoop.isRecordToggleActive ? "Stop" : "Record",
                        systemImage: conversationLoop.isRecordToggleActive ? "stop.fill" : "mic.fill"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(VoiceControlButtonStyle(
                    tint: conversationLoop.isRecordToggleActive ? .red : .blue
                ))
                .keyboardShortcut("s", modifiers: .option)

                // Text-only / Voice toggle
                Button {
                    conversationLoop.textOnlyMode.toggle()
                } label: {
                    Label(
                        conversationLoop.textOnlyMode ? "Text" : "Voice",
                        systemImage: conversationLoop.textOnlyMode ? "text.bubble" : "speaker.wave.2.fill"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(VoiceControlButtonStyle(
                    tint: conversationLoop.textOnlyMode ? .orange : .green
                ))
                .keyboardShortcut("t", modifiers: .option)
                .help("⌥T: Toggle text-only responses (no TTS)")

                Spacer()

                // Listening toggle (⌘/)
                Button {
                    conversationLoop.isEnabled.toggle()
                } label: {
                    Label(
                        conversationLoop.isEnabled ? "Listening" : "Paused",
                        systemImage: conversationLoop.isEnabled ? "mic.fill" : "mic.slash"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(VoiceControlButtonStyle(
                    tint: conversationLoop.isEnabled ? .blue : .secondary
                ))
                .help("⌘/ Toggle continuous listening")
            }
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        // Use the full-res 1024px source images for the sidebar (sharp at any size)
        let srcName: String = {
            switch conversationLoop.state {
            case .speaking: return "magpi_saying_1024"
            case .turnCheck, .transcribing, .waiting: return "magpi_thinking_1024"
            default: return "magpi_normal_1024"
            }
        }()

        if let url = Bundle.module.url(forResource: srcName, withExtension: "png", subdirectory: "Resources"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "bird.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
        }
    }

    private var stateColor: Color {
        switch conversationLoop.state {
        case .idle: return .secondary
        case .listening: return .blue
        case .turnCheck, .transcribing: return .orange
        case .waiting: return .purple
        case .speaking: return .green
        case .error: return .red
        }
    }

    // MARK: - Agent Sidebar

    private var agentSidebar: some View {
        VStack(spacing: 0) {
            // Agent summary
            HStack(spacing: 6) {
                Circle()
                    .fill(agentStore.isDaemonRunning ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text("\(agentStore.summary.total) agents")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    agentStore.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if agentStore.agents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("No agents running")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        // Magpi manager row
                        Button {
                            selectedAgentPid = nil
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bird.fill")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                                Text("Magpi Manager")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedAgentPid == nil ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.vertical, 2)

                        // Spoke agents
                        ForEach(agentStore.agents) { agent in
                            Button {
                                selectedAgentPid = agent.pid
                            } label: {
                                SidebarAgentRow(
                                    agent: agent,
                                    agentStore: agentStore,
                                    isSelected: selectedAgentPid == agent.pid
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Settings Sidebar

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Models") {
                    VStack(alignment: .leading, spacing: 4) {
                        modelRow("VAD", ready: ModelManager.shared.sileroVADReady)
                        modelRow("Turn Detection", ready: ModelManager.shared.smartTurnReady)
                        modelRow("STT (qwen-asr)", ready: ModelManager.shared.sttModelReady)
                        modelRow("TTS (pocket-tts)", ready: ModelManager.shared.ttsReady)
                    }
                    .padding(4)
                }

                GroupBox("Manager Agent") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle()
                                .fill(conversationLoop.isAgentRunning ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                            Text(conversationLoop.isAgentRunning ? "Running" : "Not running")
                                .font(.caption)
                        }
                    }
                    .padding(4)
                }

                GroupBox("Ports") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Broker").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Constants.brokerPort)").font(.caption.monospaced())
                        }
                        HStack {
                            Text("TTS Server").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Constants.ttsPort)").font(.caption.monospaced())
                        }
                    }
                    .padding(4)
                }
            }
            .padding(12)
        }
    }

    private func modelRow(_ name: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundColor(ready ? .green : .red)
            Text(name)
                .font(.caption)
            Spacer()
        }
    }

    // MARK: - Detail (Conversation)

    @ViewBuilder
    private var detail: some View {
        if let pid = selectedAgentPid,
           let agent = agentStore.agents.first(where: { $0.pid == pid }) {
            AgentSessionView(agent: agent, agentStore: agentStore)
        } else {
            ConversationView(
                store: conversationLoop.transcript,
                onSend: { text in
                    conversationLoop.transcript.addUserMessage(text)
                    conversationLoop.transcript.logTurn(role: "USER (typed)", text: text)
                    if conversationLoop.piRPC.isRunning {
                        if conversationLoop.piRPC.isStreaming {
                            conversationLoop.piRPC.steer(text)
                            conversationLoop.transcript.addLog("↪ Steered agent with new input")
                        } else {
                            conversationLoop.piRPC.sendPrompt(text)
                        }
                    }
                },
                onNewSession: {
                    conversationLoop.transcript.clearMessages()
                    conversationLoop.transcript.addLog("🔄 Starting new session")
                    conversationLoop.piRPC.newSession()
                    conversationLoop.transcript.addSystemMessage("New session started")
                },
                onClearHistory: {
                    conversationLoop.transcript.clearMessages()
                    conversationLoop.transcript.clearLogs()
                }
            )
        }
    }
}

// MARK: - Sidebar Agent Row

struct SidebarAgentRow: View {
    let agent: AgentStore.AgentInfo
    let agentStore: AgentStore
    var isSelected: Bool = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(activityColor)
                    .frame(width: 7, height: 7)
                Text(agent.projectName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if agent.isOrphaned {
                    Text("orphan")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Text("PID \(agent.pid)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            // Session title (first user message) — like Graphone
            if let title = agent.sessionTitle {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.7))
                    .lineLimit(1)
            }

            if let summary = agent.lastStatusSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Text(activityLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(activityColor)

                if let time = agent.lastStatusTime {
                    Text(Self.relativeDateFormatter.localizedString(for: time, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Show terminal/mux info for disambiguation
                if let label = agent.disambiguationLabel {
                    Text(label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Jump") {
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = DaemonClient.jump(pid: agent.pid)
                    }
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .foregroundColor(.blue)
            }
        }
        .padding(8)
        .opacity(agent.isOrphaned ? 0.5 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
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
}

// MARK: - Conversation View (Detail Pane)

struct ConversationView: View {
    @ObservedObject var store: TranscriptStore
    @State private var inputText = ""
    @State private var showingLogs = false
    var onSend: (String) -> Void
    var onNewSession: (() -> Void)? = nil
    var onClearHistory: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                // New session button
                Button {
                    onNewSession?()
                } label: {
                    Label("New Session", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Start a new conversation (clears Pi context)")

                // Clear history button
                Button {
                    onClearHistory?()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Clear chat history from display")

                Spacer()

                Picker("", selection: $showingLogs) {
                    Text("Chat").tag(false)
                    Text("Logs").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if showingLogs {
                logView
            } else {
                chatView
            }

            Divider()

            // Input bar
            inputBar
                .padding(12)
        }
    }

    private var chatView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if store.messages.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bird")
                                .font(.largeTitle)
                                .foregroundColor(.secondary.opacity(0.3))
                            Text("Start speaking or type a message")
                                .font(.callout)
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 80)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: store.messages.count) {
                if let last = store.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.logs.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(logColor(for: line))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .onChange(of: store.logs.count) {
                if let last = store.logs.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Type a message…", text: $inputText)
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
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onSend(text)
        inputText = ""
    }

    private func logColor(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("error") { return .red }
        if line.contains("WARN") || line.contains("Warning") { return .orange }
        if line.contains("── USER ──") { return .blue }
        if line.contains("── ASSISTANT ──") { return .green }
        if line.contains("🔧") { return .orange }
        if line.contains("🔊") { return .purple }
        return .primary
    }
}

// MARK: - Voice Control Button Style

struct VoiceControlButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? tint.opacity(0.25) : tint.opacity(0.12))
            )
            .foregroundColor(tint)
    }
}
