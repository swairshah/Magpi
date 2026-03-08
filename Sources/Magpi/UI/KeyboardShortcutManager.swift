import SwiftUI
import Carbon.HIToolbox

// MARK: - Shortcut Model

/// A keyboard shortcut binding: modifier flags + key code.
struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32  // Carbon modifier flags (cmdKey, optionKey, etc.)

    /// Human-readable key symbols, e.g. ["⌘", "."]
    var displayKeys: [String] {
        var keys: [String] = []
        if modifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        keys.append(keyCodeToString(keyCode))
        return keys
    }

    var displayString: String {
        displayKeys.joined()
    }
}

/// An action that can have a keyboard shortcut assigned.
enum ShortcutAction: String, CaseIterable, Codable, Hashable {
    case stopSpeech = "stopSpeech"
    case toggleMute = "toggleMute"
    case showWindow = "showWindow"

    var displayName: String {
        switch self {
        case .stopSpeech: return "Stop Speech"
        case .toggleMute: return "Toggle Mute"
        case .showWindow: return "Show Window"
        }
    }

    var defaultBinding: ShortcutBinding? {
        switch self {
        case .stopSpeech:
            // Cmd+. (key code 47 = period)
            return ShortcutBinding(keyCode: 47, modifiers: UInt32(cmdKey))
        case .toggleMute:
            // Cmd+/ (key code 44 = slash)
            return ShortcutBinding(keyCode: 44, modifiers: UInt32(cmdKey))
        case .showWindow:
            // Cmd+1 (key code 18)
            return ShortcutBinding(keyCode: 18, modifiers: UInt32(cmdKey))
        }
    }
}

// MARK: - KeyboardShortcutManager

/// Manages customizable global keyboard shortcuts via Carbon hotkeys.
/// Persists bindings to UserDefaults, supports conflict detection.
final class KeyboardShortcutManager: ObservableObject {
    static let shared = KeyboardShortcutManager()

    private let userDefaultsKey = "magpiKeyboardShortcuts"
    private let hotKeySignature = OSType(0x4D414750) // "MAGP"

    /// Current bindings for each action.
    @Published var bindings: [ShortcutAction: ShortcutBinding] = [:]

    /// Registered Carbon hotkey refs, keyed by action.
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]

    /// Carbon event handler ref.
    private var eventHandlerRef: EventHandlerRef?

    /// Callbacks for each action.
    private var actionHandlers: [ShortcutAction: () -> Void] = [:]

    private init() {
        loadBindings()
    }

    // MARK: - Persistence

    private func loadBindings() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            var loaded: [ShortcutAction: ShortcutBinding] = [:]
            for action in ShortcutAction.allCases {
                if let binding = saved[action.rawValue] {
                    loaded[action] = binding
                } else if let defaultBinding = action.defaultBinding {
                    loaded[action] = defaultBinding
                }
            }
            bindings = loaded
        } else {
            for action in ShortcutAction.allCases {
                if let defaultBinding = action.defaultBinding {
                    bindings[action] = defaultBinding
                }
            }
        }
    }

    private func saveBindings() {
        var dict: [String: ShortcutBinding] = [:]
        for (action, binding) in bindings {
            dict[action.rawValue] = binding
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    // MARK: - Public API

    /// Set or update the binding for an action. Re-registers the hotkey.
    func setBinding(_ binding: ShortcutBinding?, for action: ShortcutAction) {
        let old = bindings[action]
        bindings[action] = binding
        saveBindings()

        if old != nil {
            unregisterHotKey(for: action)
        }
        if let binding = binding {
            registerHotKey(for: action, binding: binding)
        }
    }

    /// Clear the binding for an action.
    func clearBinding(for action: ShortcutAction) {
        setBinding(nil, for: action)
    }

    /// Reset a single action to its default.
    func resetToDefault(for action: ShortcutAction) {
        setBinding(action.defaultBinding, for: action)
    }

    /// Reset all to defaults.
    func resetAllToDefaults() {
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultBinding
        }
        saveBindings()
        reregisterAllHotKeys()
    }

    /// Check if a binding conflicts with another action.
    func conflictingAction(for binding: ShortcutBinding, excluding: ShortcutAction) -> ShortcutAction? {
        for (action, existing) in bindings where action != excluding && existing == binding {
            return action
        }
        return nil
    }

    /// Whether the current binding matches the default.
    func isDefault(for action: ShortcutAction) -> Bool {
        bindings[action] == action.defaultBinding
    }

    /// Whether any binding differs from defaults.
    var hasCustomBindings: Bool {
        ShortcutAction.allCases.contains { !isDefault(for: $0) }
    }

    // MARK: - Action Handlers

    func setHandler(for action: ShortcutAction, handler: @escaping () -> Void) {
        actionHandlers[action] = handler
    }

    // MARK: - Carbon Hotkey Registration

    /// Install Carbon event handler and register all hotkeys. Call once at launch.
    func registerAll() {
        installEventHandler()
        for action in ShortcutAction.allCases {
            if let binding = bindings[action] {
                registerHotKey(for: action, binding: binding)
            }
        }
    }

    /// Unregister all hotkeys and remove the event handler.
    func unregisterAll() {
        for action in ShortcutAction.allCases {
            unregisterHotKey(for: action)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    private func reregisterAllHotKeys() {
        for action in ShortcutAction.allCases {
            unregisterHotKey(for: action)
            if let binding = bindings[action] {
                registerHotKey(for: action, binding: binding)
            }
        }
    }

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            let manager = Unmanaged<KeyboardShortcutManager>.fromOpaque(userData).takeUnretainedValue()

            let actionIndex = Int(hotKeyID.id)
            let allActions = ShortcutAction.allCases
            guard actionIndex >= 0 && actionIndex < allActions.count else {
                return OSStatus(eventNotHandledErr)
            }

            let action = Array(allActions)[actionIndex]
            if let handler = manager.actionHandlers[action] {
                DispatchQueue.main.async {
                    handler()
                }
            }

            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandlerRef)
    }

    private func registerHotKey(for action: ShortcutAction, binding: ShortcutBinding) {
        guard eventHandlerRef != nil else { return }

        let actionIndex = ShortcutAction.allCases.firstIndex(of: action)!
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: UInt32(actionIndex))

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref = ref {
            hotKeyRefs[action] = ref
        }
    }

    private func unregisterHotKey(for action: ShortcutAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }
}

// MARK: - Key Code to String Mapping

func keyCodeToString(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Slash: return "/"
    case kVK_ANSI_Backslash: return "\\"
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_Equal: return "="
    case kVK_ANSI_Grave: return "`"
    case kVK_Space: return "Space"
    case kVK_Return: return "↩"
    case kVK_Tab: return "⇥"
    case kVK_Delete: return "⌫"
    case kVK_ForwardDelete: return "⌦"
    case kVK_Escape: return "⎋"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default: return "Key\(keyCode)"
    }
}

/// Convert NSEvent modifier flags to Carbon modifier flags.
func nsModifiersToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbonMods: UInt32 = 0
    if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
    if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
    if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
    if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
    return carbonMods
}

// MARK: - Keyboard Shortcut Display View

/// Renders a keyboard shortcut as styled key caps (e.g. ⌘ . ).
struct KeyboardShortcutView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
    }
}

// MARK: - Shortcut Recorder View

/// Click to start recording, then press a key combo to assign.
struct ShortcutRecorderView: View {
    let action: ShortcutAction
    @ObservedObject var manager: KeyboardShortcutManager
    @State private var isRecording = false
    @State private var conflictAction: ShortcutAction?
    @State private var showConflictAlert = false
    @State private var pendingBinding: ShortcutBinding?

    private var binding: ShortcutBinding? {
        manager.bindings[action]
    }

    var body: some View {
        HStack(spacing: 8) {
            if binding != nil {
                Button("Clear") {
                    manager.clearBinding(for: action)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .buttonStyle(.plain)
            }

            Button(action: { isRecording.toggle() }) {
                Group {
                    if isRecording {
                        Text("Press shortcut…")
                            .foregroundColor(.accentColor)
                    } else if let binding = binding {
                        KeyboardShortcutView(keys: binding.displayKeys)
                    } else {
                        Text("Not set")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 100)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isRecording
                              ? Color.accentColor.opacity(0.1)
                              : Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRecording
                                ? Color.accentColor
                                : Color.secondary.opacity(0.25),
                                lineWidth: isRecording ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            .background(
                ShortcutCaptureRepresentable(
                    isRecording: $isRecording,
                    onCapture: { keyCode, modifiers in
                        let newBinding = ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
                        if let conflict = manager.conflictingAction(for: newBinding, excluding: action) {
                            pendingBinding = newBinding
                            conflictAction = conflict
                            showConflictAlert = true
                        } else {
                            manager.setBinding(newBinding, for: action)
                        }
                        isRecording = false
                    }
                )
                .frame(width: 0, height: 0)
            )
            .alert("Shortcut Conflict", isPresented: $showConflictAlert) {
                Button("Replace") {
                    if let pending = pendingBinding, let conflict = conflictAction {
                        manager.clearBinding(for: conflict)
                        manager.setBinding(pending, for: action)
                    }
                    pendingBinding = nil
                    conflictAction = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingBinding = nil
                    conflictAction = nil
                }
            } message: {
                if let conflict = conflictAction, let pending = pendingBinding {
                    Text("\(pending.displayString) is already assigned to \"\(conflict.displayName)\". Replace it?")
                }
            }
        }
    }
}

// MARK: - Shortcut Capture (NSViewRepresentable)

struct ShortcutCaptureRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.isRecordingBinding = $isRecording
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ShortcutCaptureNSView else { return }
        view.isRecordingBinding = $isRecording
        if isRecording {
            view.startMonitoring()
        } else {
            view.stopMonitoring()
        }
    }
}

class ShortcutCaptureNSView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?
    var isRecordingBinding: Binding<Bool>?
    private var localMonitor: Any?

    func startMonitoring() {
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Escape cancels recording
            if event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
                DispatchQueue.main.async {
                    self.isRecordingBinding?.wrappedValue = false
                }
                self.stopMonitoring()
                return nil
            }

            // Require at least one modifier unless it's a function key
            let isFunctionKey = event.keyCode >= UInt16(kVK_F1) && event.keyCode <= UInt16(kVK_F12)
            let hasModifier = !modifiers.subtracting([.capsLock, .numericPad, .function]).isEmpty

            guard hasModifier || isFunctionKey else {
                return nil  // consume but ignore bare keys
            }

            let carbonMods = nsModifiersToCarbonModifiers(modifiers)
            let keyCode = UInt32(event.keyCode)

            self.stopMonitoring()
            DispatchQueue.main.async {
                self.onCapture?(keyCode, carbonMods)
            }

            return nil
        }
    }

    func stopMonitoring() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}
