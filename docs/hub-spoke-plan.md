# Magpi Hub & Spoke Architecture Plan

## Date: February 28, 2026

## Problem

Currently, Magpi (the voice assistant agent) has no efficient way to know what other Pi agents are doing. The communication is one-directional:

- **Magpi → Agents**: Works via pitalk-inbox (write JSON file to `~/.pi/agent/pitalk-inbox/<PID>/`)
- **Agents → Magpi**: Does NOT exist. Magpi must actively poll by:
  1. Querying `pi-statusd` via Unix socket (only gives basic status: running/waiting)
  2. Finding and reading session JSONL files (full conversation logs, potentially huge)
  3. Grepping through entire session files just to find the last few messages

This is slow, wasteful, and Magpi has no way to get proactively notified when something important happens (agent finishes, hits an error, needs input, etc.)

## Current Architecture

### pi-statusd (Unix socket at `~/.pi/agent/statusd.sock`)
- Returns JSON with all running agents
- Fields: pid, cwd, activity (running/waiting_input), model_id, session_id, context_percent, etc.
- Pull-based: you have to ask for status
- No detail about *what* the agent is working on

### pi-talk extension (`Extensions/pi-talk/index.ts`)
- Runs on each Pi agent session
- **Inbox watcher**: watches `~/.pi/agent/pitalk-inbox/<PID>/` for incoming JSON messages
- **TTS**: Injects voice prompt into system prompt, parses `<voice>` tags from assistant responses, sends audio to Loqui TTS server
- **Message injection**: Uses `pi.sendMessage()` with `triggerTurn: true` to inject received messages as user input

### Session JSONL files (`~/.pi/agent/sessions/<cwd-path>/`)
- Full conversation history for each agent session
- Contains all user messages, assistant responses, tool calls, tool results
- Can be very large for long sessions
- Only way to see *what* an agent is actually discussing

## Proposed Architecture: Hub & Spoke

### Core Idea
- **Magpi is the hub** — the only agent with TTS/voice, the one the user talks to
- **All other agents are spokes** — they report status to Magpi via lightweight structured updates
- **User ↔ Magpi ↔ Agents** (Magpi relays and summarizes)

### Component 1: `pi-report` Extension (runs on every spoke agent)

A lightweight Pi extension that:

1. **Injects a system prompt** telling the agent to emit structured `<status>` tags (NOT `<voice>` tags) at key moments:
   - Task started: `<status>started: implementing Bun HTTP server</status>`
   - Task completed: `<status>done: created 4 files for Bun server, all tests passing</status>`
   - Error/blocked: `<status>error: npm publish failed with 403, need version bump</status>`
   - Waiting for input: `<status>need-input: should I use Express or native Bun APIs?</status>`
   - Progress update: `<status>progress: wrote server.ts and routes, now installing deps</status>`

2. **Parses `<status>` tags** from assistant responses (similar to how pi-talk parses `<voice>` tags)

3. **Writes status updates** to a shared location Magpi can watch:
   - Option A: `~/.pi/agent/magpi-inbox/<MAGPI_PID>/<SPOKE_PID>-<timestamp>.json`
   - Option B: `~/.pi/agent/agent-status/<SPOKE_PID>.json` (overwritten each time, Magpi polls or watches)

4. **Status payload format**:
   ```json
   {
     "pid": 97363,
     "cwd": "/private/tmp/testing",
     "sessionId": "9d7ad9a4-...",
     "type": "done",
     "summary": "created 4 files for Bun HTTP server, all tests passing",
     "timestamp": 1772311415780
   }
   ```

5. **Does NOT include TTS** — no voice output, no Loqui dependency. Super lightweight.

### Component 2: Magpi-side Watcher (runs on Magpi's session)

Magpi already runs pi-talk. We extend Magpi's setup (or add a companion extension) to:

1. **Watch the shared status directory** for incoming updates from spoke agents
2. **Maintain an in-memory dashboard** of all agent statuses — what each agent is working on, last update, current state
3. **Proactive notifications**: When an important event arrives (task done, error, need-input), Magpi can:
   - Speak to the user immediately: "Hey, the Bun server agent just finished!"
   - Or queue it for when the user asks
4. **Efficient context**: When the user asks "what are my agents doing?", Magpi already has the answer — no need to grep session files

### Component 3: Agent Discovery Enhancement

When Magpi starts or periodically:
1. Query `pi-statusd` for running agents
2. Cross-reference with status files from `pi-report`
3. Build a complete picture: PID, project, model, task, last status

## Data Flow

```
User speaks → Magpi (via microphone/transcription)
  ↓
Magpi decides action:
  - Answer directly
  - Dispatch to an agent via pitalk-inbox
  - Check agent status from in-memory dashboard
  ↓
Agent works → emits <status> tags → pi-report extension writes to shared dir
  ↓
Magpi watcher picks up status update → updates dashboard
  ↓
Magpi proactively notifies user (TTS) OR waits for user to ask
```

## Implementation Steps

### Phase 1: `pi-report` Extension
- [ ] Create new extension: `~/.pi/agent/extensions/pi-report/` or in the Pi Talk app Extensions dir
- [ ] System prompt injection with `<status>` tag instructions
- [ ] Parser for `<status>` tags (can reuse pi-talk's streaming parser pattern)
- [ ] File writer to shared status directory
- [ ] Keep it minimal — no TTS, no inbox watching

### Phase 2: Magpi Watcher
- [ ] Add file watcher on Magpi's side for the shared status directory
- [ ] In-memory agent dashboard (Map of PID → latest status)
- [ ] Surface dashboard info when user asks about agents
- [ ] This could be part of Magpi's system prompt or a custom tool

### Phase 3: Proactive Notifications
- [ ] Define which status types trigger proactive speech
- [ ] Priority system: errors and need-input are high priority (speak immediately), progress is low priority (only on request)
- [ ] Rate limiting to avoid overwhelming the user

### Phase 4: Two-way Conversations
- [ ] Magpi can respond to agent questions (need-input) by dispatching follow-up messages
- [ ] Agent-to-agent coordination through Magpi as intermediary

## Open Questions

1. **Status tag format**: Should we use `<status>` or something more structured like `<report type="done">...</report>`?
2. **File vs socket**: Should spoke agents write files (simple) or connect to a Magpi socket (lower latency)?
3. **How does Magpi know its own PID for inbox targeting?** — Could use a well-known path instead of PID-based directories
4. **Should pi-report replace pi-talk on spoke agents entirely?** — Or can they coexist for cases where user wants direct TTS on a specific agent?
5. **How to handle agent restarts/PID changes?** — Session ID might be more stable than PID
6. **Should status updates include the last N user messages as context?** — Helps Magpi understand what the agent was asked to do without reading session files

## Files Referenced

- **DaemonClient.swift**: `Sources/PiTalk/DaemonClient.swift` — Swift client for pi-statusd
- **pi-talk extension**: `Extensions/pi-talk/index.ts` — Current TTS + inbox extension
- **pi-statusd socket**: `~/.pi/agent/statusd.sock`
- **pitalk-inbox**: `~/.pi/agent/pitalk-inbox/<PID>/`
- **Session logs**: `~/.pi/agent/sessions/<cwd-path>/*.jsonl`
