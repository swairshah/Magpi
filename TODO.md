# Magpi — Open Design Questions & TODOs

## 1. Conversation Agent via Pi RPC

**Problem:** Right now, when you speak, the transcribed text goes directly into whichever Pi session's inbox Magpi finds. This interrupts whatever that Pi agent is doing in the background (e.g. writing code, running tests). Your voice input gets treated as a new user message in that session, derailing its current task.

**Core tension:** You want to *talk about* what Pi is doing, not necessarily *inject commands into* it mid-task.

**Solution:** Magpi spawns its own Pi session in **RPC mode** (`pi --mode rpc`). This is the "conversation agent" — a full Pi with its own LLM context, tools, and the pi-talk extension loaded. Magpi communicates with it over stdin/stdout using Pi's NDJSON RPC protocol.

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│   Magpi App                                               │
│                                                           │
│   Mic → VAD → Smart Turn → STT ──┐                      │
│                                    │ transcribed text     │
│                                    ▼                      │
│   ┌─────────────────────────────────────────────┐        │
│   │  Pi (--mode rpc)  =  Conversation Agent     │        │
│   │                                              │        │
│   │  stdin  ◄── {"type":"prompt","message":"..."} │       │
│   │  stdout ──► message_update / agent_end events │       │
│   │                                              │        │
│   │  Has pi-talk extension loaded:               │        │
│   │    - Injects <voice> system prompt           │        │
│   │    - Parses <voice> tags from responses      │        │
│   │    - Sends speak commands to broker ──────────┼──┐    │
│   │                                              │  │    │
│   │  Has tools: bash, read, edit, write          │  │    │
│   │    - Can read other Pi sessions' state       │  │    │
│   │    - Can dispatch commands to other sessions │  │    │
│   │    - Can monitor tmux panes                  │  │    │
│   └──────────────────────────────────────────────┘  │    │
│                                                      │    │
│   Broker (port 18081) ◄──────────────────────────────┘    │
│     │                                                     │
│     ▼                                                     │
│   TTS Engine → AudioPlayer → Speaker                     │
│     ▲                                                     │
│     │ barge-in: VAD detects speech during playback        │
│     │ → abort playback                                    │
│     │ → send {"type":"abort"} to Pi RPC                  │
│     │ → start new listen cycle                            │
│                                                           │
│   Background Pi sessions (user's existing agents):        │
│   ┌──────┐ ┌──────┐ ┌──────┐                            │
│   │ Pi#1 │ │ Pi#2 │ │ Pi#3 │  (tmux panes, terminals)   │
│   │ front│ │ back │ │ tests│                             │
│   └──────┘ └──────┘ └──────┘                            │
│   The conversation agent can interact with these          │
│   via bash (tmux send-keys), reading their sessions,     │
│   or writing to their inboxes.                            │
└──────────────────────────────────────────────────────────┘
```

### Key RPC commands Magpi uses

| Command | When | Purpose |
|---------|------|---------|
| `prompt` | After STT transcription | Send user's speech to conversation agent |
| `steer` | Barge-in during response | Interrupt mid-response with new input |
| `abort` | Barge-in during tool use | Cancel current operation |
| `get_state` | Before sending prompt | Check if agent is streaming (decide prompt vs steer) |
| `message_update` events | During response | Stream `<voice>` tags → pi-talk ext → broker → TTS |
| `agent_end` events | Response complete | Know when to go back to idle |

### How it replaces the inbox approach
- **Before:** Magpi writes JSON to `~/.pi/agent/pitalk-inbox/{pid}/`
- **After:** Magpi sends `{"type":"prompt","message":"..."}` to Pi's stdin
- Bidirectional, supports steering/follow-up, proper streaming

### How dispatching to other Pi sessions works

**Key discovery: `pi-statusd` daemon already exists!**

There's already a daemon (`pi-statusd`) running on a Unix socket at `~/.pi/agent/statusd.sock` that tracks all active Pi sessions. PiTalk already uses it via `DaemonClient.swift`. It provides:

**`status` command** → returns JSON with all running agents:
```json
{
  "ok": true,
  "agents": [
    {
      "pid": 12345,
      "ppid": 12340,
      "state": "running",
      "tty": "/dev/ttys003",
      "cpu": 2.5,
      "cwd": "/Users/swair/work/projects/myapp",
      "activity": "editing src/auth.ts",
      "confidence": "high",
      "mux": "tmux",
      "mux_session": "dev",
      "client_pid": 12300,
      "attached_window": true,
      "terminal_app": "iTerm2"
    }
  ],
  "summary": { "total": 3, "running": 2, "waiting_input": 1 }
}
```

**`jump <pid>` command** → focuses the terminal pane for that agent
**`send <pid> <text>` command** → sends text directly to that agent's terminal

So the conversation agent can:
1. Query `pi-statusd` via bash to discover all running sessions and what they're doing
2. Use `send <pid> <text>` to dispatch commands to specific sessions
3. Use `jump <pid>` to bring a session's terminal to focus
4. Read the `activity` field to understand what each agent is working on
5. Use `cwd` to know which project each agent is in

The conversation agent's system prompt tells it to use these tools, and the agent figures out intent from natural voice commands like "tell the frontend agent to use Tailwind."

### Implementation plan
1. **PiRPCClient** — Swift class that spawns `pi --mode rpc` and communicates over stdin/stdout
   - Send commands as NDJSON to stdin
   - Parse events from stdout line by line
   - Handle `message_update` events for streaming
   - Handle `extension_ui_request` for pi-talk extension interactions
2. **Update ConversationLoop** — Replace `PiBridge.sendToPi()` with `PiRPCClient.sendPrompt()`
   - On barge-in: send `abort` or `steer` instead of just stopping audio
   - On `agent_end`: transition back to idle
3. **System prompt** for conversation agent — instruct it about:
   - Being a voice interface (concise, conversational)
   - Available Pi sessions and how to discover them
   - How to dispatch commands (inbox, tmux send-keys)
   - When to answer directly vs dispatch
4. **Keep broker** — pi-talk extension still sends `speak` to port 18081, Magpi still plays it

### Open questions
- What LLM for the conversation agent? Same as Pi (Claude)? Faster/cheaper model for lower latency?
- What system prompt? Needs to be voice-optimized (concise) + aware of sessions + knows about statusd
- Should we build a custom Pi extension that wraps statusd as proper tools (vs raw bash)?
- Latency: RPC prompt → LLM response adds a round-trip. Acceptable? Can we use a fast model?
- Should the manager also use Magpi's broker to receive speak events from OTHER pi sessions?
  (e.g. a coding agent finishes a task and says "done!" via pi-talk — should Magpi speak it?)

---

## 2. Multi-Agent Multiplexing

**Problem:** With pi-talk-app (Loqui + pi-talk extension), you can have multiple Pi agents running in different tmux panes, and PiTalk's UI lets you see all active sessions and jump to any of them. Voice commands can be routed to a specific session via the `sessionId` and `pid` fields in the broker protocol. Magpi currently just picks the most recent inbox and dumps everything there.

### How it works with `pi-statusd`
Session discovery and dispatch is already solved by the daemon:
- **Discovery:** `status` command returns all agents with PID, cwd, activity, mux info
- **Dispatch:** `send <pid> <text>` sends input directly to an agent's terminal
- **Focus:** `jump <pid>` brings an agent's terminal pane to focus
- **Identity:** cwd gives project context, activity describes what the agent is doing

### User interaction patterns
- **Voice (natural):** "Tell the frontend agent to use Tailwind" → manager agent queries statusd, finds the right session by cwd/activity, dispatches via send
- **Voice (explicit):** "Switch to session 2" → manager focuses that session
- **Menu bar:** Click on a session in the list → could either focus it or set it as the voice target
- **Automatic:** Manager agent infers which session based on conversation context

### What PiTalk already does that we can reuse
- `DaemonClient.swift` — full statusd client (status, jump, send) — **copy this directly**
- `JumpHandler.swift` — jumps to tmux panes by PID
- Broker protocol has `sourceApp`, `sessionId`, `pid` fields
- Per-session voice assignment (auto-rotates through voice pool)
- Session activity tracking

---

## 3. UI Design

**Problem:** Magpi is currently a headless menubar app with a basic status icon. For a voice-first interface managing multiple agents, what's the right UI?

### Questions to resolve
- **Menubar only** (like current) vs **floating panel** vs **full window**?
- What information should be always-visible?
  - Current state (idle/listening/speaking)
  - Which agent is active/selected
  - Audio level meter
  - Recent transcript (what you said / what Pi said)
- How to show multi-agent status?
  - List of active Pi sessions with status badges
  - Which one is "focused" for voice input
  - Activity indicators (working / idle / waiting for input)
- Conversation history?
  - Show voice conversation transcript
  - Scrollable history in a panel
- **Minimal viable UI for v1:**
  - Menubar icon showing state (current ✓)
  - Dropdown showing active sessions with radio selection
  - Click session → voice input goes there
  - Audio waveform/level indicator
  - Last transcription shown as tooltip or in menu

### Inspiration
- PiTalk's menu bar with session list and status
- Hearsay's floating recording indicator
- macOS Dictation's floating microphone bubble
- Raycast/Alfred-style floating panel

---

## 4. Implementation Priorities

### Phase 0: Echo cancellation (TTS voice triggering VAD)

**Problem:** The manager's TTS output plays through the speaker and gets picked up by the microphone, triggering the VAD and creating a feedback loop.

**Solution: AVAudioEngine Voice Processing (native macOS AEC)**

macOS has built-in acoustic echo cancellation via `AVAudioEngine`'s voice processing mode. If we play TTS audio through the *same* engine that captures the mic, macOS automatically uses the playback as a reference signal and subtracts it from the mic input.

```swift
let engine = AVAudioEngine()
try engine.inputNode.setVoiceProcessingEnabled(true)
try engine.outputNode.setVoiceProcessingEnabled(true)
```

**What needs to change:**
- [ ] Enable voice processing on `AudioCaptureSession`'s input and output nodes
- [ ] Replace `AudioPlayer` (ffplay subprocess) with `AVAudioPlayerNode` on the same engine
- [ ] Route TTS audio bytes through the player node instead of writing to ffplay's stdin
- [ ] Format requirements: 32-bit Float PCM at 16kHz, 24kHz, or 48kHz — we already use 16kHz

**Key constraint:** The reference signal *must* be audio played through the same `AVAudioEngine` instance. External playback (ffplay) can't be cancelled. This is why we need to replace ffplay.

**Alternatives if native AEC isn't sufficient:**
- WebRTC AEC3: manual reference feeding via `ProcessReverseStream()`, 10ms chunks
- Speex: `speex_echo_playback()` + `speex_echo_capture()`, simpler but older
- Simple approach: just mute the mic during TTS playback (loses barge-in capability)

### Phase 1: RPC conversation agent (next)
- [ ] Build `PiRPCClient` — spawn Pi in RPC mode, send/receive NDJSON
- [ ] Replace `PiBridge.sendToPi()` with RPC `prompt` command
- [ ] Handle barge-in via `abort`/`steer` RPC commands
- [ ] Write conversation agent system prompt
- [ ] Test full voice loop: speak → RPC → LLM → voice tags → broker → TTS → speaker

### Phase 2: Multi-agent awareness
- [ ] Session discovery (scan inboxes, tmux, metadata files)
- [ ] Conversation agent system prompt includes session awareness
- [ ] Dispatch mechanism (agent uses bash to write to inboxes or tmux send-keys)
- [ ] Per-session voice assignment in broker

### Phase 3: UI
- [ ] Menu bar session selector
- [ ] Floating transcript panel
- [ ] Audio level indicator
- [ ] Settings persistence (UserDefaults)

### Phase 4: Polish + Distribution
- [ ] Bundle qwen-asr + pocket-tts-cli in the app
- [ ] Homebrew cask packaging
- [ ] Model download on first launch
- [ ] Wake word detection ("Hey Magpi")
- [ ] Push-to-talk fallback mode
- [ ] Noise/echo cancellation
