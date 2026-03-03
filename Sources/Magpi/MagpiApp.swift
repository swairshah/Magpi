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
    private var globalHotkeyMonitor: Any?
    // Carbon hotkeys: Cmd+. (stop speech), Cmd+/ (toggle listening)
    private var carbonEventHandler: EventHandlerRef?
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonListenHotKeyRef: EventHotKeyRef?

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

        // Register global hotkeys
        registerGlobalHotkeys()

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
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = carbonListenHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
        }
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

    // MARK: - Global Hotkeys

    private func registerGlobalHotkeys() {
        // NSEvent monitor for Alt+S, Alt+B (works when app is not focused)
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Alt+S (keyCode 1 = 's') → Record toggle
            if event.keyCode == 1 && flags == .option {
                DispatchQueue.main.async {
                    self?.conversationLoop?.toggleRecording()
                }
                return
            }

            // Alt+B (keyCode 11 = 'b') → Barge-in toggle
            if event.keyCode == 11 && flags == .option {
                DispatchQueue.main.async {
                    guard let loop = self?.conversationLoop else { return }
                    loop.bargeInEnabled.toggle()
                    print("Magpi: Barge-in \(loop.bargeInEnabled ? "enabled" : "disabled")")
                }
                return
            }
        }

        // Carbon global hotkeys — work everywhere, even when not focused
        registerCarbonHotkeys()

        print("Magpi: Global hotkeys: ⌘/ = toggle listening, ⌘. = stop speech, ⌥S = record toggle")
    }

    private func registerCarbonHotkeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

            // Read which hotkey was pressed
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil,
                              &hotKeyID)

            DispatchQueue.main.async {
                switch hotKeyID.id {
                case 1: // Cmd+. → stop speech
                    appDelegate.conversationLoop?.stopSpeech()
                    print("Magpi: ⌘. Stop speech")
                case 2: // Cmd+/ → toggle listening
                    guard let loop = appDelegate.conversationLoop else { return }
                    loop.isEnabled.toggle()
                    let status = loop.isEnabled ? "ON — listening" : "OFF — push-to-talk only"
                    print("Magpi: ⌘/ Listening \(status)")
                    loop.transcript.addLog(loop.isEnabled ? "🎙️ Listening enabled (⌘/)" : "🔇 Listening disabled (⌘/)")
                default:
                    break
                }
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler, 1, &eventType,
            selfPtr, &carbonEventHandler
        )

        // Cmd+. (key code 47 = period)
        let stopID = EventHotKeyID(signature: OSType(0x4D414750), id: 1) // "MAGP"
        RegisterEventHotKey(
            47, UInt32(cmdKey), stopID,
            GetApplicationEventTarget(), 0,
            &carbonHotKeyRef
        )

        // Cmd+/ (key code 44 = slash)
        let listenID = EventHotKeyID(signature: OSType(0x4D414750), id: 2)
        RegisterEventHotKey(
            44, UInt32(cmdKey), listenID,
            GetApplicationEventTarget(), 0,
            &carbonListenHotKeyRef
        )
    }

    // MARK: - Private

    @MainActor
    private func startConversation() async {
        await conversationLoop.start()
    }
}
