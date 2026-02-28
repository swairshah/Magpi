import SwiftUI
import AppKit

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
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menubar-only app (no dock icon by default)
        NSApp.setActivationPolicy(.accessory)
        
        print("Magpi: Starting up...")
        
        // Create conversation loop
        conversationLoop = ConversationLoop()
        
        // Set up menu bar
        statusBar = StatusBarController(conversationLoop: conversationLoop)
        
        statusBar.onShowSettings = { [weak self] in
            self?.openSettings()
        }
        
        statusBar.onQuit = {
            NSApp.terminate(nil)
        }
        
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
                    openSettings()
                }
            }
        } else if !models.allReady {
            print("Magpi: Some models missing: \(models.missingModels.joined(separator: ", "))")
            // Start anyway — STT/TTS might come from Hearsay/Loqui
            Task { await startConversation() }
        } else {
            Task { await startConversation() }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        conversationLoop?.stop()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }
    
    // MARK: - Private
    
    @MainActor
    private func startConversation() async {
        await conversationLoop.start()
    }
    
    private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let controller = NSHostingController(rootView: settingsView)
            
            let window = NSWindow(contentViewController: controller)
            window.title = "Magpi"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 520, height: 480))
            window.minSize = NSSize(width: 420, height: 380)
            window.center()
            
            settingsWindow = window
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
