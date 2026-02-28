# 🐦 Magpi

**Voice conversation loop for Pi** — a macOS menubar app that combines local VAD, turn detection, STT, and TTS into a continuous hands-free voice interface.

Magpi listens continuously, detects when you're speaking (Silero VAD), figures out when you're done (Smart Turn), transcribes your speech (qwen-asr), sends it to Pi, and speaks the response (pocket-tts). All local, no cloud APIs.

## Architecture

```
Mic → Silero VAD → Smart Turn → qwen-asr → Pi bridge → pocket-tts → Speaker
      (speech?)     (done?)      (STT)      (inbox)     (TTS)
         ↑                                                  │
         └──────── barge-in detection ◄─────────────────────┘
```

### Components

| Component | Model/Binary | Size | Source |
|-----------|-------------|------|--------|
| VAD | Silero VAD v5 (ONNX) | ~2 MB | [snakers4/silero-vad](https://github.com/snakers4/silero-vad) |
| Turn Detection | Smart Turn v3.2 (ONNX) | ~8 MB | [pipecat-ai/smart-turn](https://huggingface.co/pipecat-ai/smart-turn-v3) |
| STT | qwen-asr (binary) | bundled | [antirez/qwen-asr](https://github.com/antirez/qwen-asr) |
| TTS | pocket-tts-cli (binary) | bundled | [babybirdprd/pocket-tts](https://github.com/babybirdprd/pocket-tts) |
| Inference | ONNX Runtime (C API) | ~15 MB | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) |

## Setup

```bash
# 1. Download ONNX Runtime + model files
./scripts/setup.sh

# 2. Build
swift build

# 3. Run
./run.sh
```

## How it works

1. **Continuous listening** — Mic is always open, audio frames fed to Silero VAD
2. **Speech detection** — VAD triggers when speech probability exceeds threshold
3. **Turn detection** — After silence is detected, Smart Turn analyzes the last 8s of audio to determine if the speaker is done (not just pausing)
4. **Transcription** — Confirmed speech is sent to qwen-asr for local STT
5. **Pi bridge** — Transcribed text is sent to Pi via the inbox mechanism
6. **Response** — Pi's response (with `<voice>` tags) arrives via the speech broker
7. **TTS** — pocket-tts synthesizes speech locally
8. **Barge-in** — If user speaks during TTS playback, playback stops immediately

## Integration with Pi

Magpi works with the existing `pi-talk` extension. It:
- Runs a TCP broker on port `18081` (same as Loqui) to receive `speak` commands
- Writes transcribed text to Pi's inbox (`~/.pi/agent/pitalk-inbox/{pid}/`)
- Replaces both Loqui (TTS) and Hearsay (STT) with a single app

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
- Microphone permission
- Accessibility permission (for text insertion fallback)

## Credits

- [Silero VAD](https://github.com/snakers4/silero-vad) — Voice Activity Detection
- [Smart Turn](https://github.com/pipecat-ai/smart-turn) — Turn detection by Pipecat
- [qwen-asr](https://github.com/antirez/qwen-asr) — Speech-to-text by Antirez
- [Pocket TTS](https://github.com/kyutai-labs/pocket-tts) — Text-to-speech by Kyutai Labs
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) — Cross-platform inference

## License

MIT
