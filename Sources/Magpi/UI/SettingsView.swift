import SwiftUI

struct SettingsView: View {
    @ObservedObject var modelManager = ModelManager.shared
    @State private var isDownloading = false
    @State private var vadThreshold: Double = Double(Constants.vadSpeechThreshold)
    @State private var silenceDuration: Double = Double(Constants.vadSilenceDurationMs)
    @State private var smartTurnThreshold: Double = Double(Constants.smartTurnThreshold)
    @State private var selectedVoice = "fantine"
    
    private let voices = ["fantine", "alba", "marius", "javert", "cosette", "eponine", "azelma"]
    
    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
            
            modelsTab
                .tabItem {
                    Label("Models", systemImage: "brain")
                }
            
            tuningTab
                .tabItem {
                    Label("Tuning", systemImage: "slider.horizontal.3")
                }
        }
        .frame(minWidth: 480, minHeight: 400)
        .padding()
    }
    
    // MARK: - General Tab
    
    private var generalTab: some View {
        Form {
            Section("Voice") {
                Picker("TTS Voice", selection: $selectedVoice) {
                    ForEach(voices, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                }
                .pickerStyle(.menu)
            }
            
            Section("Status") {
                LabeledContent("VAD Model") {
                    statusBadge(modelManager.sileroVADReady)
                }
                LabeledContent("Turn Detection") {
                    statusBadge(modelManager.smartTurnReady)
                }
                LabeledContent("Speech-to-Text") {
                    statusBadge(modelManager.sttModelReady)
                }
                LabeledContent("Text-to-Speech") {
                    statusBadge(modelManager.ttsReady)
                }
            }
            
            Section("Integration") {
                LabeledContent("Broker Port") {
                    Text("\(Constants.brokerPort)")
                        .foregroundColor(.secondary)
                }
                LabeledContent("TTS Port") {
                    Text("\(Constants.ttsPort)")
                        .foregroundColor(.secondary)
                }
                Text("Compatible with pi-talk extension. Uses the same broker protocol as Loqui.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Models Tab
    
    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Models")
                .font(.title2)
                .bold()
            
            GroupBox("VAD & Turn Detection (~10 MB)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: modelManager.sileroVADReady ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(modelManager.sileroVADReady ? .green : .red)
                        Text("Silero VAD")
                        Spacer()
                        Text("~2 MB").foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Image(systemName: modelManager.smartTurnReady ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(modelManager.smartTurnReady ? .green : .red)
                        Text("Smart Turn v3.1")
                        Spacer()
                        Text("~8 MB").foregroundColor(.secondary)
                    }
                    
                    if !modelManager.sileroVADReady || !modelManager.smartTurnReady {
                        Button(isDownloading ? "Downloading..." : "Download Missing Models") {
                            downloadModels()
                        }
                        .disabled(isDownloading)
                        .buttonStyle(.borderedProminent)
                    }
                    
                    if !modelManager.downloadStatus.isEmpty {
                        Text(modelManager.downloadStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
            }
            
            GroupBox("Speech-to-Text") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: modelManager.sttModelReady ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(modelManager.sttModelReady ? .green : .red)
                        Text("qwen-asr")
                        Spacer()
                        Text("Shared with Hearsay").foregroundColor(.secondary).font(.caption)
                    }
                    
                    if !modelManager.sttModelReady {
                        Text("Install Hearsay to get the STT model, or download manually.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
            }
            
            GroupBox("Text-to-Speech") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: modelManager.ttsReady ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(modelManager.ttsReady ? .green : .red)
                        Text("pocket-tts")
                        Spacer()
                        Text("Shared with Loqui").foregroundColor(.secondary).font(.caption)
                    }
                    
                    if !modelManager.ttsReady {
                        Text("Install Loqui to get the TTS engine: brew install swairshah/tap/loqui")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Tuning Tab
    
    private var tuningTab: some View {
        Form {
            Section("Voice Activity Detection") {
                LabeledContent("Speech Threshold") {
                    HStack {
                        Slider(value: $vadThreshold, in: 0.2...0.9, step: 0.05)
                        Text(String(format: "%.2f", vadThreshold))
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
                
                LabeledContent("Silence Duration (ms)") {
                    HStack {
                        Slider(value: $silenceDuration, in: 200...2000, step: 100)
                        Text("\(Int(silenceDuration))")
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                }
            }
            
            Section("Turn Detection") {
                LabeledContent("Completion Threshold") {
                    HStack {
                        Slider(value: $smartTurnThreshold, in: 0.2...0.9, step: 0.05)
                        Text(String(format: "%.2f", smartTurnThreshold))
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
                
                Text("Lower = faster response (may cut off mid-sentence)\nHigher = more patience (waits for complete thoughts)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Barge-in") {
                Text("VAD runs during TTS playback. If speech is detected, playback stops and Magpi starts listening again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Shortcuts Tab
    
    private var shortcutsTab: some View {
        Form {
            Section("Global Keyboard Shortcuts") {
                Text("These shortcuts work even when Magpi is not focused.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.displayName) {
                        ShortcutRecorderView(
                            action: action,
                            manager: KeyboardShortcutManager.shared
                        )
                    }
                }
            }
            
            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        KeyboardShortcutManager.shared.resetAllToDefaults()
                    }
                    .disabled(!KeyboardShortcutManager.shared.hasCustomBindings)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func statusBadge(_ ready: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ready ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(ready ? "Ready" : "Missing")
                .foregroundColor(ready ? .green : .red)
                .font(.caption)
        }
    }
    
    private func downloadModels() {
        isDownloading = true
        Task {
            do {
                try await modelManager.downloadVADModels()
            } catch {
                print("Magpi: Download error: \(error)")
            }
            isDownloading = false
        }
    }
}
