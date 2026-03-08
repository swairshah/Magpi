import SwiftUI

/// Shows running Pi agents discovered from pi-telemetry snapshots + pi-report.
struct AgentListView: View {
    @ObservedObject var agentStore: AgentStore
    @State private var composingForPid: Int32? = nil
    @State private var composeText = ""

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            summaryBar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            if agentStore.agents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(agentStore.agents) { agent in
                            agentCard(agent)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Summary

    private var summaryBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agentStore.isTelemetryAvailable ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(agentStore.isTelemetryAvailable ? "telemetry active" : "no telemetry")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 6) {
                pill("\(agentStore.summary.total) agents")
                if agentStore.summary.running > 0 {
                    pill("\(agentStore.summary.running) running", color: .red)
                }
                if agentStore.summary.waitingInput > 0 {
                    pill("\(agentStore.summary.waitingInput) waiting", color: .green)
                }
            }

            Button {
                agentStore.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Refresh agent list")
        }
    }

    private func pill(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("No Pi agents running")
                .foregroundColor(.secondary)
            Text("Start a Pi session and it will appear here")
                .font(.caption)
                .foregroundColor(.secondary)
            if !agentStore.isTelemetryAvailable {
                Text("(pi-telemetry extension required)")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Agent Card

    private func agentCard(_ agent: AgentStore.AgentInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: activity dot + project name + PID
            HStack(spacing: 8) {
                Circle()
                    .fill(activityColor(agent.activity))
                    .frame(width: 8, height: 8)

                Text(agent.projectName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                Text("PID \(agent.pid)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }

            // Status from pi-report (if available)
            if let summary = agent.lastStatusSummary {
                HStack(spacing: 4) {
                    if let type = agent.lastStatusType {
                        statusBadge(type)
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            // Metadata line
            HStack(spacing: 8) {
                // Activity label
                Text(activityLabel(agent.activity))
                    .font(.caption2.weight(.medium))
                    .foregroundColor(activityColor(agent.activity))

                if let mux = agent.mux, !mux.isEmpty {
                    Text(mux)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                }

                if let time = agent.lastStatusTime {
                    Text(Self.relativeDateFormatter.localizedString(for: time, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 6) {
                    Button {
                        jumpToAgent(pid: agent.pid)
                    } label: {
                        Text("Jump")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(AgentActionButtonStyle(tint: .blue))

                    Button {
                        if composingForPid == agent.pid {
                            composingForPid = nil
                        } else {
                            composingForPid = agent.pid
                            composeText = ""
                        }
                    } label: {
                        Text("Send")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(AgentActionButtonStyle(tint: .orange))
                }
            }

            // Inline compose field
            if composingForPid == agent.pid {
                composeField(pid: agent.pid)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Compose

    private func composeField(pid: Int32) -> some View {
        HStack(spacing: 6) {
            TextField("Message to agent...", text: $composeText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    sendMessage(pid: pid)
                }

            Button {
                sendMessage(pid: pid)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(composeText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func jumpToAgent(pid: Int32) {
        guard let agent = agentStore.agents.first(where: { $0.pid == pid }) else { return }
        agentStore.jumpToAgent(agent)
    }

    private func sendMessage(pid: Int32) {
        let text = composeText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        agentStore.sendToAgent(pid: pid, text: text)
        composeText = ""
        composingForPid = nil
    }

    // MARK: - Helpers

    private func activityColor(_ activity: String) -> Color {
        switch activity {
        case "running": return .red
        case "waiting_input": return .green
        default: return .gray
        }
    }

    private func activityLabel(_ activity: String) -> String {
        switch activity {
        case "running": return "Running"
        case "waiting_input": return "Waiting"
        default: return activity.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    @ViewBuilder
    private func statusBadge(_ type: String) -> some View {
        let (icon, color) = statusIconAndColor(type)
        Image(systemName: icon)
            .font(.caption2)
            .foregroundColor(color)
    }

    private func statusIconAndColor(_ type: String) -> (String, Color) {
        switch type {
        case "started": return ("play.circle.fill", .blue)
        case "progress": return ("gearshape.fill", .orange)
        case "done": return ("checkmark.circle.fill", .green)
        case "error": return ("exclamationmark.triangle.fill", .red)
        case "need-input": return ("questionmark.circle.fill", .purple)
        case "alive": return ("circle.fill", .green)
        case "ended": return ("stop.circle.fill", .gray)
        default: return ("circle.fill", .secondary)
        }
    }
}

// MARK: - Button Style

struct AgentActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? tint.opacity(0.25) : tint.opacity(0.12))
            )
            .foregroundColor(tint)
    }
}
