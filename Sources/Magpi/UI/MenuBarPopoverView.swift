import SwiftUI

/// Rich SwiftUI popover shown when clicking the menu bar icon.
struct MenuBarPopoverView: View {
    @ObservedObject var conversationLoop: ConversationLoop
    @ObservedObject var agentStore: AgentStore
    var onShowWindow: () -> Void
    var onQuit: () -> Void

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Voice status header
            voiceHeader
                .padding(12)

            Divider()

            // Agent list
            agentSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Footer actions
            footer
                .padding(10)
        }
        .frame(width: 320)
    }

    // MARK: - Voice Header

    private var voiceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // State indicator
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Magpi")
                        .font(.headline)
                    Text(conversationLoop.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Speed slider
                HStack(spacing: 2) {
                    Image(systemName: "hare")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: $conversationLoop.speechSpeed, in: 0.7...2.0, step: 0.05)
                        .frame(width: 50)
                        .controlSize(.mini)
                    Text(String(format: "%.1fx", conversationLoop.speechSpeed))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                }
                .help("Speech speed: \(String(format: "%.2f", conversationLoop.speechSpeed))x")

                Divider()
                    .frame(height: 12)

                // Mute toggle
                Button {
                    conversationLoop.isMuted.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: conversationLoop.isMuted ? "mic.slash" : "mic.fill")
                            .font(.system(size: 11))
                        Text(conversationLoop.isMuted ? "Muted" : "Listening")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(conversationLoop.isMuted
                                  ? Color.secondary.opacity(0.12)
                                  : Color.blue.opacity(0.15))
                    )
                    .foregroundColor(conversationLoop.isMuted ? .secondary : .blue)
                }
                .buttonStyle(.plain)
                .help(shortcutHint(for: .toggleMute))
            }

            // Status pills
            HStack(spacing: 6) {
                pill("manager: \(conversationLoop.isAgentRunning ? "✓" : "✗")")

                let models = ModelManager.shared
                let readyCount = [models.sileroVADReady, models.smartTurnReady,
                                  models.sttModelReady, models.ttsReady].filter { $0 }.count
                pill("models: \(readyCount)/4")
            }
        }
    }

    // MARK: - Agent Section

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Agent summary header
            HStack(spacing: 8) {
                Circle()
                    .fill(agentStore.isTelemetryAvailable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                let s = agentStore.summary
                Text("\(s.total) agent\(s.total == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))

                if s.running > 0 {
                    pill("\(s.running) running", color: .red)
                }
                if s.waitingInput > 0 {
                    pill("\(s.waitingInput) waiting", color: .green)
                }

                Spacer()

                Button {
                    agentStore.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh agent list")
            }

            // Agent rows (max 6 visible)
            if agentStore.agents.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text("No agents running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    Spacer()
                }
            } else {
                ForEach(agentStore.agents.prefix(6)) { agent in
                    agentRow(agent)
                }

                let hidden = agentStore.agents.count - 6
                if hidden > 0 {
                    Text("\(hidden) more — open window to see all")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func agentRow(_ agent: AgentStore.AgentInfo) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(activityColor(agent.activity))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(activityLabel(agent.activity))
                        .font(.caption2)
                        .foregroundStyle(activityColor(agent.activity))

                    if let model = agent.model {
                        Text("· \(model)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Status from pi-report
            if let summary = agent.lastStatusSummary {
                Text(summary.prefix(25) + (summary.count > 25 ? "…" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Jump") {
                agentStore.jumpToAgent(agent)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.blue.opacity(0.12))
            )
            .foregroundStyle(.blue)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Stop Speech") {
                conversationLoop.stopSpeech()
            }
            .buttonStyle(PopoverButtonStyle())
            .help(shortcutHint(for: .stopSpeech))
            .disabled(conversationLoop.state != .speaking)

            Button("Window") {
                onShowWindow()
            }
            .buttonStyle(PopoverButtonStyle())
            .help(shortcutHint(for: .showWindow))

            Button("Quit") {
                onQuit()
            }
            .buttonStyle(PopoverButtonStyle(tint: .red))
        }
    }

    // MARK: - Helpers

    private var stateColor: Color {
        switch conversationLoop.state {
        case .idle: return conversationLoop.isMuted ? .secondary : .green
        case .listening: return .blue
        case .turnCheck, .transcribing: return .orange
        case .waiting: return .purple
        case .speaking: return .red
        case .error: return .red
        }
    }

    private func pill(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }

    private func activityColor(_ activity: String) -> Color {
        switch activity {
        case "running", "working": return .red
        case "waiting_input": return .green
        default: return .gray
        }
    }

    private func activityLabel(_ activity: String) -> String {
        switch activity {
        case "running", "working": return "Running"
        case "waiting_input": return "Waiting"
        default: return activity.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func shortcutHint(for action: ShortcutAction) -> String {
        guard let binding = KeyboardShortcutManager.shared.bindings[action] else {
            return action.displayName
        }
        return "\(action.displayName) (\(binding.displayString))"
    }
}

// MARK: - Popover Button Style

struct PopoverButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed
                          ? tint.opacity(0.25)
                          : tint.opacity(0.12))
            )
            .foregroundStyle(isEnabled ? tint : .secondary)
            .opacity(isEnabled ? 1.0 : 0.5)
    }
}
