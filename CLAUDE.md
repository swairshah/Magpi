# Magpi Development Guide

## Project Overview
Magpi is a macOS menubar app that provides a continuous voice conversation loop for Pi coding agents. It combines VAD (Silero), turn detection (Smart Turn), STT (qwen-asr), and TTS (pocket-tts) into a single local app.

**Key architecture:** Magpi spawns its own Pi session in RPC mode as a "conversation agent" (manager). This agent receives transcribed speech, responds conversationally, and can discover/dispatch to other running Pi sessions via `pi-statusd`.

## Build & Run
```bash
./scripts/setup.sh   # Download ONNX Runtime + models (first time only)
swift build           # Build debug
./run.sh              # Build and run
./run-dev.sh          # Run debug build with logging (MAGPI_LOG_LEVEL=debug)
./scripts/build.sh    # Release build
```

## Architecture

### Voice Pipeline
```
Mic → AudioCaptureSession (16kHz mono)
    → SileroVAD (512-sample frames, speech/silence detection)
    → SmartTurnDetector (8s audio window, turn completion)
    → Transcriber (qwen-asr binary)
    → PiRPCClient (sends prompt to conversation agent)
    → Pi agent responds with <voice> tags
    → pi-talk extension sends speak command to broker (port 18081)
    → TTSEngine (pocket-tts-cli) synthesizes audio
    → AudioPlayer (ffplay) plays it back
```

### Conversation Agent (Pi RPC)
- Magpi spawns `pi --mode rpc` as a subprocess
- Communicates via NDJSON over stdin/stdout
- The agent has its own LLM context and tools (bash, read, edit, write)
- pi-talk extension is loaded → handles <voice> tag parsing → broker → TTS
- Agent can query `pi-statusd` to discover other running Pi sessions
- Agent can dispatch commands to other sessions via statusd's `send` command

### Components
- **ConversationLoop** — Main state machine: IDLE → LISTENING → TURN_CHECK → TRANSCRIBING → WAITING → SPEAKING
- **AudioCaptureSession** — Continuous 16kHz mono mic capture via AVAudioEngine
- **AudioBuffer** — Ring buffer accumulating speech samples
- **SileroVAD** — ONNX-based voice activity detection (frame-level, 512 samples = 32ms)
- **SmartTurnDetector** — ONNX-based turn completion detection (analyzes last 8s)
- **OnnxSession** — Swift wrapper around ONNX Runtime C API
- **Transcriber** — Wraps qwen_asr binary for local STT
- **TTSEngine** — Manages pocket-tts-cli server + speech synthesis
- **PiRPCClient** — Spawns Pi in RPC mode, sends prompts/steer/abort, receives streaming events
- **PiBridge** — TCP broker (port 18081) receiving speak commands from pi-talk extension + inbox fallback
- **StatusBarController** — Menu bar UI showing conversation state + agent status

## Key Design Decisions
- **Pi RPC for conversation agent**: instead of injecting text into a random Pi inbox, Magpi has its own Pi session that acts as a voice-first manager
- ONNX Runtime C API (not the ObjC/Swift pod) for minimal dependencies
- Same broker protocol as Loqui (port 18081) for pi-talk extension compatibility
- VAD runs continuously; Smart Turn only runs after silence detected (saves CPU)
- Barge-in: VAD active during TTS playback, interrupts on speech detection + aborts Pi agent
- Debug logging gated behind `MAGPI_LOG_LEVEL=debug` environment variable

## File Layout
```
Sources/Magpi/
├── MagpiApp.swift              # App entry + AppDelegate
├── Constants.swift             # Ports, paths, thresholds
├── ConversationLoop.swift      # Main state machine
├── Audio/
│   ├── AudioCaptureSession.swift  # Continuous mic
│   ├── AudioBuffer.swift          # Speech accumulator
│   └── AudioPlayer.swift         # TTS playback via ffplay
├── VAD/
│   ├── OnnxSession.swift          # ONNX Runtime wrapper
│   ├── SileroVAD.swift            # Silero model wrapper
│   └── SmartTurnDetector.swift    # Smart Turn model wrapper
├── STT/
│   └── Transcriber.swift          # qwen_asr wrapper
├── TTS/
│   └── TTSEngine.swift            # pocket-tts server + synth
├── Bridge/
│   ├── PiBridge.swift             # Broker + inbox fallback
│   └── PiRPCClient.swift         # Pi RPC subprocess manager
├── UI/
│   ├── StatusBarController.swift  # Menu bar
│   └── SettingsView.swift         # Settings window
└── Models/
    └── ModelManager.swift         # Model download/management
```

## Ports
- 18080: pocket-tts TTS HTTP server
- 18081: Speech broker (NDJSON over TCP, Loqui-compatible)

## Dependencies (external binaries)
- `pi` — Pi coding agent CLI (RPC mode)
- `qwen_asr` — Local STT (finds models in ~/Library/Application Support/Hearsay/Models/)
- `pocket-tts-cli` — Local TTS server (~/.cargo/bin/)
- `ffplay` — Audio playback (/opt/homebrew/bin/)
- `pi-statusd` — Agent status daemon (Unix socket at ~/.pi/agent/statusd.sock)

## Testing
- Build: `swift build`
- Manual testing: Run with `./run-dev.sh` (enables verbose logging)
- Test VAD: speak and watch console for "→ LISTENING" / "→ TURN_CHECK"
- Test RPC: check for "Pi RPC started" in console output
- Test end-to-end: speak → see transcription → hear TTS response
