import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct MagpiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private var conversationLoop: ConversationLoop!
    private var mainWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep running in menubar when window is closed
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show dock icon — this is a proper app, not just a menubar accessory
        NSApp.setActivationPolicy(.regular)

        // Prevent macOS from auto-terminating us when idle
        ProcessInfo.processInfo.disableAutomaticTermination("Voice conversation loop active")

        // Set app icon from bundled icns
        if let icnsURL = Bundle.module.url(forResource: "Magpi", withExtension: "icns", subdirectory: "Resources"),
           let icon = NSImage(contentsOf: icnsURL) {
            NSApp.applicationIconImage = icon
        }

        print("Magpi: Starting up...")

        // Create conversation loop
        conversationLoop = ConversationLoop()

        // Set up menu bar
        statusBar = StatusBarController(conversationLoop: conversationLoop)

        statusBar.onShowSettings = { [weak self] in
            self?.showMainWindow()
        }

        statusBar.onQuit = {
            NSApp.terminate(nil)
        }

        // Register global keyboard shortcuts
        setupKeyboardShortcuts()

        // Check models and start
        let models = ModelManager.shared

        if !models.sileroVADReady || !models.smartTurnReady {
            print("Magpi: VAD models missing — downloading...")
            Task {
                do {
                    try await models.downloadVADModels()
                    models.checkModels()
                    await startConversation()
                } catch {
                    print("Magpi: Model download failed: \(error)")
                    showMainWindow()
                }
            }
        } else if !models.allReady {
            print("Magpi: Some models missing: \(models.missingModels.joined(separator: ", "))")
            Task { await startConversation() }
        } else {
            Task { await startConversation() }
        }

        // Show main window on launch
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        conversationLoop?.stop()
        statusBar?.agentStore.stop()
        KeyboardShortcutManager.shared.unregisterAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Main Window

    func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let mainView = MainWindowView(
            conversationLoop: conversationLoop,
            agentStore: statusBar.agentStore
        )

        let controller = NSHostingController(rootView: mainView)

        let window = NSWindow(contentViewController: controller)
        window.title = "Magpi"
        window.titlebarAppearsTransparent = false
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 800, height: 560))
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        window.isReleasedWhenClosed = false

        // Set window icon
        if let icnsURL = Bundle.module.url(forResource: "Magpi", withExtension: "icns", subdirectory: "Resources"),
           let icon = NSImage(contentsOf: icnsURL) {
            window.representedURL = URL(fileURLWithPath: "/")
            window.standardWindowButton(.documentIconButton)?.image = icon
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    // MARK: - Global Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        let manager = KeyboardShortcutManager.shared

        manager.setHandler(for: .stopSpeech) { [weak self] in
            Task { @MainActor in
                self?.conversationLoop?.stopSpeech()
            }
        }

        manager.setHandler(for: .toggleMute) { [weak self] in
            Task { @MainActor in
                self?.conversationLoop?.isMuted.toggle()
            }
        }

        manager.setHandler(for: .showWindow) { [weak self] in
            Task { @MainActor in
                self?.showMainWindow()
            }
        }

        manager.registerAll()

        // Log active shortcuts
        let shortcuts = ShortcutAction.allCases.compactMap { action -> String? in
            guard let binding = manager.bindings[action] else { return nil }
            return "\(binding.displayString) = \(action.displayName)"
        }
        print("Magpi: Global hotkeys: \(shortcuts.joined(separator: ", "))")
    }

    // MARK: - Private

    @MainActor
    private func startConversation() async {
        await conversationLoop.start()
    }
}
