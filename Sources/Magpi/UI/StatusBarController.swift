import AppKit
import SwiftUI
import Combine

/// Manages the macOS menu bar icon and popover.
@MainActor
final class StatusBarController {
    
    var onShowSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    private weak var conversationLoop: ConversationLoop?
    private var transcriptPanel: TranscriptPanelController?
    let agentStore = AgentStore()
    
    /// Event monitor to close popover when clicking outside.
    private var eventMonitor: Any?
    
    init(conversationLoop: ConversationLoop) {
        self.conversationLoop = conversationLoop
        self.transcriptPanel = TranscriptPanelController(
            store: conversationLoop.transcript,
            agentStore: agentStore
        )
        agentStore.start()
        setupMenuBar()
        setupPopover()
        observeState()
    }
    
    // MARK: - Setup
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(for: .idle)
        
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        guard let loop = conversationLoop else { return }
        
        let popoverView = MenuBarPopoverView(
            conversationLoop: loop,
            agentStore: agentStore,
            onShowWindow: { [weak self] in
                self?.closePopover()
                self?.onShowSettings?()
            },
            onQuit: { [weak self] in
                self?.closePopover()
                self?.onQuit?()
            }
        )
        
        let hostingController = NSHostingController(rootView: popoverView)
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .semitransient  // More reliable click handling than .transient
        popover.contentViewController = hostingController
        popover.delegate = popoverDelegate
    }
    
    /// Cleans up the event monitor when the popover closes by any means
    /// (transient auto-close, Escape key, etc.), not just our closePopover().
    private lazy var popoverDelegate = PopoverDelegate { [weak self] in
        if let monitor = self?.eventMonitor {
            NSEvent.removeMonitor(monitor)
            self?.eventMonitor = nil
        }
    }
    
    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
    
    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        
        // Ensure the popover window is key so buttons respond to clicks.
        // Without this, the first click may just activate the window
        // without forwarding the event to the button, appearing frozen.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        
        // Close when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }
    
    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    // MARK: - State Observation
    
    private func observeState() {
        conversationLoop?.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)
        
        conversationLoop?.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                self?.updateIcon(for: self?.conversationLoop?.state ?? .idle)
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

// MARK: - Popover Delegate

/// Handles popover lifecycle events (close from any source).
private class PopoverDelegate: NSObject, NSPopoverDelegate {
    let onClose: () -> Void
    
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    
    func popoverDidClose(_ notification: Notification) {
        onClose()
    }
}
