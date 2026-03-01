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
    let agentStore = AgentStore()
    
    init(conversationLoop: ConversationLoop) {
        self.conversationLoop = conversationLoop
        self.transcriptPanel = TranscriptPanelController(
            store: conversationLoop.transcript,
            agentStore: agentStore
        )
        agentStore.start()
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
        
        // Show main window
        let windowItem = NSMenuItem(
            title: "Show Window",
            action: #selector(showWindow),
            keyEquivalent: "1"
        )
        windowItem.keyEquivalentModifierMask = [.command]
        windowItem.target = self
        menu.addItem(windowItem)

        // Floating transcript panel
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
            title: "Manager: \(agentRunning ? "Running ✓" : "Not running ✗")",
            action: nil,
            keyEquivalent: ""
        )
        agentStatus.isEnabled = false
        menu.addItem(agentStatus)

        // Spoke agents
        let s = agentStore.summary
        let spokeStatus = NSMenuItem(
            title: "Agents: \(s.total) (\(s.running) running, \(s.waitingInput) waiting)",
            action: nil,
            keyEquivalent: ""
        )
        spokeStatus.isEnabled = false
        menu.addItem(spokeStatus)

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

        agentStore.$summary
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }
    
    private func updateIcon(for state: ConversationLoop.State) {
        guard let button = statusItem?.button else { return }

        let imageName: String
        switch state {
        case .idle:
            imageName = "menubar_normal"
        case .listening:
            imageName = "menubar_normal"   // normal bird while listening
        case .turnCheck, .transcribing, .waiting:
            imageName = "menubar_thinking" // thought bubble
        case .speaking:
            imageName = "menubar_saying"   // sound waves
        case .error:
            imageName = "menubar_normal"
        }

        if let image = loadMenuBarImage(named: imageName) {
            image.isTemplate = true  // Adapts to light/dark menu bar
            button.image = image
        } else {
            // Fallback to SF Symbol
            button.image = NSImage(systemSymbolName: "bird", accessibilityDescription: state.displayName)
        }
    }

    private func loadMenuBarImage(named name: String) -> NSImage? {
        // Load @2x image and set point size to half pixel size
        // This gives crisp rendering on retina displays
        if let url2x = Bundle.module.url(forResource: name + "@2x", withExtension: "png", subdirectory: "Resources"),
           let image = NSImage(contentsOf: url2x) {
            // Point size = pixel size / 2
            let pointW = CGFloat(image.representations.first?.pixelsWide ?? Int(image.size.width)) / 2.0
            let pointH = CGFloat(image.representations.first?.pixelsHigh ?? Int(image.size.height)) / 2.0
            image.size = NSSize(width: pointW, height: pointH)
            return image
        }
        // Fallback to 1x
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
    
    // MARK: - Actions
    
    @objc private func showWindow() {
        onShowSettings?()
    }

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
