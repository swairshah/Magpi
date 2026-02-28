import SwiftUI
import AppKit

/// Floating panel showing the conversation transcript between user and Pi manager.
struct TranscriptPanel: View {
    @ObservedObject var store: TranscriptStore
    @State private var showingLogs = false
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bird")
                    .foregroundColor(.accentColor)
                Text("Magpi")
                    .font(.headline)

                Spacer()

                // Verbose toggle
                Toggle(isOn: $store.verboseLogging) {
                    Image(systemName: "text.magnifyingglass")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Verbose logging")

                // Log toggle
                Button {
                    showingLogs.toggle()
                } label: {
                    Image(systemName: showingLogs ? "text.bubble.fill" : "list.bullet")
                }
                .buttonStyle(.borderless)
                .help(showingLogs ? "Show transcript" : "Show logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if showingLogs {
                logView
            } else {
                transcriptView
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 300, idealHeight: 500)
    }

    // MARK: - Transcript View

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if store.messages.isEmpty {
                        Text("Start speaking to begin a conversation...")
                            .foregroundColor(.secondary)
                            .italic()
                            .padding()
                    }
                }
                .padding(12)
            }
            .onChange(of: store.messages.count) {
                if autoScroll, let last = store.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Log View

    private var logView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    store.clearLogs()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

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

                        if store.logs.isEmpty {
                            Text("No logs yet")
                                .foregroundColor(.secondary)
                                .italic()
                                .padding()
                        }
                    }
                    .padding(8)
                }
                .onChange(of: store.logs.count) {
                    if autoScroll, let lastIndex = store.logs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("error") || line.contains("failed") {
            return .red
        } else if line.contains("WARN") || line.contains("Warning") {
            return .orange
        } else {
            return .primary
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: TranscriptStore.Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Role icon
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.caption)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                // Role label + timestamp
                HStack(spacing: 4) {
                    Text(roleLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .bold()

                    Text(timeString)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                }

                // Message text
                Text(displayText)
                    .textSelection(.enabled)
                    .font(.body)
                    .foregroundColor(textColor)

                if !message.isComplete {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .cornerRadius(8)
    }

    private var iconName: String {
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "bird.fill"
        case .system: return "info.circle"
        }
    }

    private var iconColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .green
        case .system: return .orange
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Magpi"
        case .system: return "System"
        }
    }

    private var textColor: Color {
        switch message.role {
        case .system: return .secondary
        default: return .primary
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.blue.opacity(0.08)
        case .assistant: return Color.green.opacity(0.06)
        case .system: return Color.orange.opacity(0.06)
        }
    }

    private var displayText: String {
        // Strip <voice> tags for display — show the raw text content
        message.text
            .replacingOccurrences(of: "<voice>", with: "")
            .replacingOccurrences(of: "</voice>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: message.timestamp)
    }
}

// MARK: - Panel Window Controller

@MainActor
final class TranscriptPanelController {
    private var window: NSWindow?
    private let store: TranscriptStore

    init(store: TranscriptStore) {
        self.store = store
    }

    func showPanel() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Magpi Transcript"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: TranscriptPanel(store: store))

        // Position in top-right corner
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 440
            let y = screenFrame.maxY - 520
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    func hidePanel() {
        window?.close()
    }

    func togglePanel() {
        if let window = window, window.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }
}
