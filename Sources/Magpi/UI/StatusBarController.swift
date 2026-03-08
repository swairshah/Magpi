import AppKit
import SwiftUI
import Combine

/// Manages the macOS menu bar icon and menu.
@MainActor
final class StatusBarController {
    
    var onShowSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
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
    
    /// Format a shortcut binding as a menu item suffix, e.g. " (⌘/)"
    private func shortcutLabel(for action: ShortcutAction) -> String {
        guard let binding = KeyboardShortcutManager.shared.bindings[action] else { return "" }
        return " (\(binding.displayString))"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        
        // Status
        let state = conversationLoop?.state ?? .idle
        let statusLine = NSMenuItem(title: state.displayName, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        
        menu.addItem(NSMenuItem.separator())
        
        // Mute/unmute toggle
        let muted = conversationLoop?.isMuted ?? true
        let muteTitle = (muted ? "Unmute" : "Mute") + shortcutLabel(for: .toggleMute)
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(toggleMute), keyEquivalent: "")
        muteItem.target = self
        menu.addItem(muteItem)

        // Stop speech
        let stopTitle = "Stop Speech" + shortcutLabel(for: .stopSpeech)
        let stopItem = NSMenuItem(title: stopTitle, action: #selector(stopSpeech), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        // Show main window
        let windowTitle = "Show Window" + shortcutLabel(for: .showWindow)
        let windowItem = NSMenuItem(title: windowTitle, action: #selector(showWindow), keyEquivalent: "")
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
        
        menu.addItem(NSMenuItem.separator())
        
        // Agent status
        let agentRunning = conversationLoop?.isAgentRunning ?? false
        let agentStatus = NSMenuItem(
            title: "Manager: \(agentRunning ? "Running ✓" : "Not running ✗")",
            action: nil, keyEquivalent: ""
        )
        agentStatus.isEnabled = false
        menu.addItem(agentStatus)

        let s = agentStore.summary
        let spokeStatus = NSMenuItem(
            title: "Agents: \(s.total) (\(s.running) running, \(s.waitingInput) waiting)",
            action: nil, keyEquivalent: ""
        )
        spokeStatus.isEnabled = false
        menu.addItem(spokeStatus)

        let models = ModelManager.shared
        let modelStatus = NSMenuItem(
            title: "Models: VAD \(models.sileroVADReady ? "✓" : "✗") | Turn \(models.smartTurnReady ? "✓" : "✗") | STT \(models.sttModelReady ? "✓" : "✗") | TTS \(models.ttsReady ? "✓" : "✗")",
            action: nil, keyEquivalent: ""
        )
        modelStatus.isEnabled = false
        menu.addItem(modelStatus)
        
        menu.addItem(NSMenuItem.separator())
        
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

        conversationLoop?.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
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
            imageName = "menubar_normal"
        case .turnCheck, .transcribing, .waiting:
            imageName = "menubar_thinking"
        case .speaking:
            imageName = "menubar_saying"
        case .error:
            imageName = "menubar_normal"
        }

        if let image = loadMenuBarImage(named: imageName) {
            image.isTemplate = true
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "bird", accessibilityDescription: state.displayName)
        }
    }

    private func loadMenuBarImage(named name: String) -> NSImage? {
        if let url2x = Bundle.module.url(forResource: name + "@2x", withExtension: "png", subdirectory: "Resources"),
           let image = NSImage(contentsOf: url2x) {
            let pointW = CGFloat(image.representations.first?.pixelsWide ?? Int(image.size.width)) / 2.0
            let pointH = CGFloat(image.representations.first?.pixelsHigh ?? Int(image.size.height)) / 2.0
            image.size = NSSize(width: pointW, height: pointH)
            return image
        }
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

    @objc private func toggleMute() {
        conversationLoop?.isMuted.toggle()
    }
    
    @objc private func stopSpeech() {
        conversationLoop?.stopSpeech()
    }
    
    @objc private func quit() {
        onQuit?()
    }
}
