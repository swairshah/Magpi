# Magpi Dashboard UI Plan

## Date: February 28, 2026

## Inspiration

Combines ideas from:
- **Graphone** (Tauri/Svelte): Session sidebar with project scopes, session history, busy indicators, compact mode
- **PiTalk** (SwiftUI): Status bar with activity dots, session groups by project, Jump/Send buttons, push-to-talk per session, DaemonClient for pi-statusd
- **Existing TranscriptPanel**: Floating NSPanel, message bubbles, log tab

## Architecture

### Data Sources
1. **pi-statusd** (Unix socket `~/.pi/agent/statusd.sock`) — running agents, PIDs, cwds, activity
2. **pi-report JSONL** (`~/.pi/agent/magpi-reports/<PID>.jsonl`) — structured status updates from agents
3. **TranscriptStore** — Magpi manager conversation (user speech + Pi responses)

### New Components

#### `DaemonClient.swift` (from pi-talk-app pattern)
- Native Swift Unix socket client (no socat dependency)
- `status()` → `StatusResponse` with agents array
- `jump(pid:)` → focus terminal for that agent
- Polling timer (every 3-5s) to refresh agent list

#### `AgentStore.swift`
- `@Published var agents: [AgentInfo]` — merged from statusd + reports
- `AgentInfo`: pid, cwd, projectName, activity, model, lastStatus, lastStatusTime
- Watches `~/.pi/agent/magpi-reports/` with DispatchSource/FSEvents for live updates
- Cross-references statusd agents with report files

#### `JumpHandler.swift` (simplified from pi-talk-app)
- Focus terminal window for a given PID
- Ghostty tab switching via Accessibility API
- tmux/zellij pane selection

### UI Layout: Enhanced TranscriptPanel

The existing floating NSPanel gets tabs:

```
┌──────────────────────────────────────┐
│ 🐦 Magpi          [Agents] [Chat] [Logs] │
├──────────────────────────────────────┤
│                                      │
│  ── Agents Tab ──                    │
│                                      │
│  ⚫ 3 agents  🟢 2 waiting  🔴 1 running │
│                                      │
│  ┌─ magpi-project ──────────────┐    │
│  │ 🟢 PID 12345                 │    │
│  │   done: auth module complete │    │
│  │   [Jump] [Send]              │    │
│  └──────────────────────────────┘    │
│                                      │
│  ┌─ hearsay ────────────────────┐    │
│  │ 🔴 PID 67890                 │    │
│  │   progress: running tests    │    │
│  │   [Jump] [Send]              │    │
│  └──────────────────────────────┘    │
│                                      │
│  ┌─ pi-talk-app ────────────────┐    │
│  │ 🟢 PID 11111                 │    │
│  │   waiting for input          │    │
│  │   [Jump] [Send]              │    │
│  └──────────────────────────────┘    │
│                                      │
│  ── Chat Tab ──                      │
│  (existing transcript view)          │
│                                      │
│  ── Logs Tab ──                      │
│  (existing log view)                 │
│                                      │
└──────────────────────────────────────┘
```

### Agent Row Details

Each agent card shows:
- **Activity dot**: 🟢 waiting_input, 🔴 running, 🟠 unknown
- **Project name**: Last path component of cwd
- **PID**: Small monospaced text
- **Model**: e.g. "claude-sonnet-4"
- **Last status**: From pi-report (summary text + relative time)
- **Jump button**: Focus terminal via JumpHandler
- **Send button**: Opens inline text field to dispatch via inbox

### Send Flow (from Dashboard)
1. User clicks "Send" on an agent row
2. Inline text field appears
3. User types message, presses Enter
4. Magpi writes JSON to `~/.pi/agent/pitalk-inbox/<PID>/<timestamp>.json`
5. pi-talk extension on that agent picks it up

### Status Polling
- Poll pi-statusd every 5 seconds for agent list
- Watch magpi-reports directory for file changes (FSEvents)
- Merge: statusd provides PIDs/activity, reports provide task summaries

## Implementation Order

### Phase 1: DaemonClient + AgentStore
- [ ] `DaemonClient.swift` — Unix socket client for pi-statusd
- [ ] `AgentStore.swift` — Agent list with statusd polling + report file reading
- [ ] Wire into ConversationLoop or AppDelegate

### Phase 2: Agents Tab in TranscriptPanel
- [ ] Add tab bar to TranscriptPanel (Agents / Chat / Logs)
- [ ] `AgentListView.swift` — SwiftUI list of agent cards
- [ ] Activity dots, project names, last status

### Phase 3: Jump + Send
- [ ] `JumpHandler.swift` — Terminal focusing (simplified)
- [ ] Jump button per agent
- [ ] Send button with inline compose
- [ ] Write to pitalk-inbox

### Phase 4: Live Status Updates
- [ ] FSEvents watcher for magpi-reports directory
- [ ] Real-time status update display
- [ ] Status change notifications (optional)

## Open Questions
1. Should the dashboard be in the existing TranscriptPanel or a separate window?
2. Should we show context_percent as a progress bar?
3. Should Jump handler support Ghostty tabs (complex AX code from pi-talk)?
4. Should agent groups be collapsible like in PiTalk?
