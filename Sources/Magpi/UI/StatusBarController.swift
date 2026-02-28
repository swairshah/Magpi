import AppKit
import SwiftUI
import Combine

/// Manages the macOS menu bar icon and menu.
@MainActor
final class StatusBarController {
    
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    
    var onToggleEnabled: ((Bool) -> Void)?
    var onShowSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    
    private weak var conversationLoop: ConversationLoop?
    private var transcriptPanel: TranscriptPanelController?
    
    init(conversationLoop: ConversationLoop) {
        self.conversationLoop = conversationLoop
        self.transcriptPanel = TranscriptPanelController(store: conversationLoop.transcript)
        setupMenuBar()
        observeState()
    }
    
    // MARK: - Setup
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(for: .idle)
        
        rebuildMenu()
    }
    
    private func rebuildMenu() {
        let menu = NSMenu()
        
        // Status line
        let state = conversationLoop?.state ?? .idle
        let statusItem = NSMenuItem(title: state.displayName, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Enable/disable toggle
        let enabled = conversationLoop?.isEnabled ?? true
        let toggleTitle = enabled ? "Pause Conversation" : "Resume Conversation"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleEnabled), keyEquivalent: "p")
        toggleItem.keyEquivalentModifierMask = [.command]
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        // Transcript panel
        let transcriptVisible = transcriptPanel?.isVisible ?? false
        let transcriptItem = NSMenuItem(
            title: transcriptVisible ? "Hide Transcript" : "Show Transcript",
            action: #selector(toggleTranscript),
            keyEquivalent: "t"
        )
        transcriptItem.keyEquivalentModifierMask = [.command]
        transcriptItem.target = self
        menu.addItem(transcriptItem)

        // Record toggle (Alt+S)
        let isRecording = conversationLoop?.isRecordToggleActive ?? false
        let recordItem = NSMenuItem(
            title: isRecording ? "Stop Recording (⌥S)" : "Record (⌥S)",
            action: #selector(toggleRecording),
            keyEquivalent: "s"
        )
        recordItem.keyEquivalentModifierMask = [.option]
        recordItem.target = self
        menu.addItem(recordItem)

        // Barge-in toggle (Alt+B)
        let bargeIn = conversationLoop?.bargeInEnabled ?? true
        let bargeInItem = NSMenuItem(
            title: "Barge-in (Headphones)",
            action: #selector(toggleBargeIn),
            keyEquivalent: "b"
        )
        bargeInItem.keyEquivalentModifierMask = [.option]
        bargeInItem.state = bargeIn ? .on : .off
        bargeInItem.target = self
        menu.addItem(bargeInItem)

        // Stop speaking
        let stopItem = NSMenuItem(title: "Stop Speech", action: #selector(stopSpeech), keyEquivalent: ".")
        stopItem.keyEquivalentModifierMask = [.command]
        stopItem.target = self
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Agent status
        let agentRunning = conversationLoop?.isAgentRunning ?? false
        let agentStatus = NSMenuItem(
            title: "Pi Agent: \(agentRunning ? "Running ✓" : "Not running ✗")",
            action: nil,
            keyEquivalent: ""
        )
        agentStatus.isEnabled = false
        menu.addItem(agentStatus)

        // Model status
        let models = ModelManager.shared
        let modelStatus = NSMenuItem(
            title: "Models: VAD \(models.sileroVADReady ? "✓" : "✗") | Turn \(models.smartTurnReady ? "✓" : "✗") | STT \(models.sttModelReady ? "✓" : "✗") | TTS \(models.ttsReady ? "✓" : "✗")",
            action: nil,
            keyEquivalent: ""
        )
        modelStatus.isEnabled = false
        menu.addItem(modelStatus)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Magpi", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        self.statusItem.menu = menu
    }
    
    // MARK: - State Observation
    
    private func observeState() {
        conversationLoop?.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }
    
    private func updateIcon(for state: ConversationLoop.State) {
        guard let button = statusItem?.button else { return }
        
        let symbolName: String
        switch state {
        case .idle:
            symbolName = "bird"
        case .listening:
            symbolName = "mic.fill"
        case .turnCheck, .transcribing:
            symbolName = "brain.head.profile"
        case .waiting:
            symbolName = "ellipsis.circle"
        case .speaking:
            symbolName = "speaker.wave.2.fill"
        case .error:
            symbolName = "exclamationmark.triangle"
        }
        
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.displayName)
    }
    
    // MARK: - Actions
    
    @objc private func toggleTranscript() {
        transcriptPanel?.togglePanel()
    }

    @objc private func toggleRecording() {
        conversationLoop?.toggleRecording()
        rebuildMenu()
    }

    @objc private func toggleBargeIn() {
        guard let loop = conversationLoop else { return }
        loop.bargeInEnabled.toggle()
        print("Magpi: Barge-in \(loop.bargeInEnabled ? "enabled" : "disabled")")
        rebuildMenu()
    }

    @objc private func toggleEnabled() {
        guard let loop = conversationLoop else { return }
        loop.isEnabled.toggle()
        onToggleEnabled?(loop.isEnabled)
        rebuildMenu()
    }
    
    @objc private func stopSpeech() {
        conversationLoop?.stop()
        Task {
            await conversationLoop?.start()
        }
    }
    
    @objc private func openSettings() {
        onShowSettings?()
    }
    
    @objc private func quit() {
        onQuit?()
    }
}
