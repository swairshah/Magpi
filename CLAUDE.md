# Magpi Development Guide

## Project Overview
Magpi is a macOS menubar app that provides a continuous voice conversation loop for the Pi coding agent. It combines VAD (Silero), turn detection (Smart Turn), STT (qwen-asr), and TTS (pocket-tts) into a single local app.

## Build & Run
```bash
./scripts/setup.sh   # Download ONNX Runtime + models (first time only)
swift build           # Build debug
./run.sh              # Build and run
./run-dev.sh          # Run debug build with logging
./scripts/build.sh    # Release build
```

## Architecture
- **ConversationLoop** — Main state machine: IDLE → LISTENING → TURN_CHECK → TRANSCRIBING → WAITING → SPEAKING
- **AudioCaptureSession** — Continuous 16kHz mono mic capture via AVAudioEngine
- **AudioBuffer** — Ring buffer accumulating speech samples
- **SileroVAD** — ONNX-based voice activity detection (frame-level, 512 samples = 32ms)
- **SmartTurnDetector** — ONNX-based turn completion detection (analyzes last 8s)
- **OnnxSession** — Swift wrapper around ONNX Runtime C API
- **Transcriber** — Wraps qwen_asr binary for local STT
- **TTSEngine** — Manages pocket-tts-cli server + speech synthesis
- **PiBridge** — Sends transcribed text to Pi via inbox files
- **SpeechBroker** — TCP server on port 18081 receiving speak commands from pi-talk extension
- **StatusBarController** — Menu bar UI showing conversation state

## Key Design Decisions
- ONNX Runtime C API (not the ObjC/Swift pod) for minimal dependencies
- Models downloaded on first launch, stored in ~/Library/Application Support/Magpi/
- Same broker protocol as Loqui (port 18081) for pi-talk extension compatibility
- VAD runs continuously; Smart Turn only runs after silence detected (saves CPU)
- Barge-in: VAD active during TTS playback, interrupts on speech detection

## File Layout
```
Sources/Magpi/
├── MagpiApp.swift              # App entry + AppDelegate
├── Constants.swift             # Ports, paths, thresholds
├── ConversationLoop.swift      # Main state machine
├── Audio/
│   ├── AudioCaptureSession.swift  # Continuous mic
│   ├── AudioBuffer.swift          # Speech accumulator
│   └── AudioPlayer.swift          # TTS playback via ffplay
├── VAD/
│   ├── OnnxSession.swift          # ONNX Runtime wrapper
│   ├── SileroVAD.swift            # Silero model wrapper
│   └── SmartTurnDetector.swift    # Smart Turn model wrapper
├── STT/
│   └── Transcriber.swift          # qwen_asr wrapper
├── TTS/
│   └── TTSEngine.swift            # pocket-tts server + synth
├── Bridge/
│   └── PiBridge.swift             # Pi inbox communication
├── UI/
│   ├── StatusBarController.swift  # Menu bar
│   └── SettingsView.swift         # Settings window
└── Models/
    └── ModelManager.swift         # Model download/management
```

## Testing
- Unit tests: `swift test`
- Manual testing: Run with `./run-dev.sh` which enables verbose logging
- Test VAD: speak and watch console for "speech detected" / "silence detected"
- Test turn detection: pause mid-sentence vs end of sentence

## Ports
- 18080: pocket-tts TTS HTTP server
- 18081: Speech broker (NDJSON over TCP, Loqui-compatible)
