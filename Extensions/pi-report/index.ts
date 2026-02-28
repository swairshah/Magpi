/**
 * pi-report — Lightweight status reporting extension for Pi agents.
 *
 * Part of the Magpi hub-and-spoke architecture:
 * - Runs on every Pi "spoke" agent session
 * - Injects system prompt telling the agent to emit <status> tags
 * - Parses <status> tags from assistant responses (streaming)
 * - Writes status updates to ~/.pi/agent/magpi-reports/<PID>.jsonl
 * - Magpi (the hub) watches that directory for updates
 *
 * Does NOT include TTS, voice, or inbox features — those stay in pi-talk.
 * Designed to be minimal and coexist with pi-talk.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import process from "node:process";

const REPORTS_DIR = path.join(os.homedir(), ".pi", "agent", "magpi-reports");
const REPORT_FILE = path.join(REPORTS_DIR, `${process.pid}.jsonl`);

const STATUS_PROMPT = `
## Status Reporting

You have a status reporting system. At key moments in your work, emit a <status> tag to report what's happening. An orchestrating agent monitors these to keep the user informed.

When to emit <status> tags:
- Starting a task: <status>started: implementing the auth module</status>
- Making progress: <status>progress: created 3 route handlers, now writing tests</status>
- Completing a task: <status>done: auth module complete, all 5 tests passing</status>
- Hitting an error: <status>error: build failed — missing dependency @types/express</status>
- Needing user input: <status>need-input: should I use JWT or session-based auth?</status>

Rules:
- Keep status text brief (1 sentence)
- Use the prefixes: started, progress, done, error, need-input
- Emit at natural milestones, not on every tool call
- <status> tags are silent — they don't appear in your response to the user
`;

export default function (pi: ExtensionAPI) {
  // Parser state
  let parserBuffer = "";
  let insideStatus = false;
  let lastFullText = "";
  let sessionId: string | null = null;

  // Ensure reports directory exists
  function ensureReportsDir() {
    try {
      fs.mkdirSync(REPORTS_DIR, { recursive: true });
    } catch {
      // ignore
    }
  }

  // Write a status update to the report file (append JSONL)
  function writeReport(type: string, summary: string) {
    ensureReportsDir();

    const report = {
      pid: process.pid,
      cwd: process.cwd(),
      sessionId: sessionId,
      type: type,
      summary: summary,
      timestamp: Date.now(),
    };

    try {
      fs.appendFileSync(REPORT_FILE, JSON.stringify(report) + "\n");
    } catch (err) {
      // Don't crash the agent over reporting failures
    }
  }

  // Parse a status tag content into type + summary
  function parseStatusContent(content: string): { type: string; summary: string } {
    const trimmed = content.trim();

    // Try to extract prefix like "done:", "error:", "started:", etc.
    const prefixMatch = trimmed.match(/^(started|progress|done|error|need-input):\s*(.*)/i);
    if (prefixMatch) {
      return {
        type: prefixMatch[1].toLowerCase(),
        summary: prefixMatch[2],
      };
    }

    // No recognized prefix — treat as generic progress
    return { type: "progress", summary: trimmed };
  }

  // Streaming delta parser for <status> tags
  // Same pattern as pi-talk's voice tag parser
  function processDelta(delta: string) {
    if (!delta) return;

    parserBuffer += delta;

    while (parserBuffer.length > 0) {
      if (!insideStatus) {
        const openIdx = parserBuffer.indexOf("<status>");
        if (openIdx >= 0) {
          parserBuffer = parserBuffer.slice(openIdx + "<status>".length);
          insideStatus = true;
          continue;
        }

        // Keep any partial tag match at the end
        const keep = longestTagPrefixSuffix(parserBuffer, "<status>");
        parserBuffer = keep > 0 ? parserBuffer.slice(-keep) : "";
        return;
      }

      // Inside a status tag — look for closing
      const closeIdx = parserBuffer.indexOf("</status>");
      if (closeIdx >= 0) {
        const statusText = parserBuffer.slice(0, closeIdx);
        const { type, summary } = parseStatusContent(statusText);
        writeReport(type, summary);
        parserBuffer = parserBuffer.slice(closeIdx + "</status>".length);
        insideStatus = false;
        continue;
      }

      // No close yet — keep buffering, but trim safe prefix
      const keep = longestTagPrefixSuffix(parserBuffer, "</status>");
      parserBuffer = keep > 0 ? parserBuffer.slice(-keep) : "";
      return;
    }
  }

  // Find the longest suffix of `text` that is a prefix of `tag`
  function longestTagPrefixSuffix(text: string, tag: string): number {
    const maxCheck = Math.min(text.length, tag.length - 1);
    for (let len = maxCheck; len >= 1; len--) {
      if (text.endsWith(tag.slice(0, len))) {
        return len;
      }
    }
    return 0;
  }

  // Process streaming text
  function processStreamingText(fullText: string) {
    let delta = "";
    if (fullText.startsWith(lastFullText)) {
      delta = fullText.slice(lastFullText.length);
    } else {
      // Stream was re-written — reset parser
      parserBuffer = "";
      insideStatus = false;
      delta = fullText;
    }

    lastFullText = fullText;
    processDelta(delta);
  }

  function resetStreamingState() {
    lastFullText = "";
    parserBuffer = "";
    insideStatus = false;
  }

  // --- Extension event handlers ---

  // Inject status prompt into system prompt
  pi.on("before_agent_start", async (event) => {
    return {
      systemPrompt: event.systemPrompt + "\n" + STATUS_PROMPT,
    };
  });

  // Track session ID
  pi.on("session_start", async (_event, ctx) => {
    sessionId = ctx.sessionManager.getSessionId();
    ensureReportsDir();

    // Write an initial "alive" report so Magpi knows about this agent
    writeReport("alive", `Agent started in ${process.cwd()}`);
  });

  // Process streaming assistant messages
  pi.on("assistant_message", async (event) => {
    if (event.type === "message") {
      // Full message — extract all text content
      const textParts: string[] = [];
      for (const block of event.message.content) {
        if (block.type === "text") {
          textParts.push(block.text);
        }
      }
      const fullText = textParts.join(" ");
      processStreamingText(fullText);
    }
  });

  // Reset on message end
  pi.on("message_end", async () => {
    // Flush any remaining status tag
    if (insideStatus && parserBuffer) {
      const { type, summary } = parseStatusContent(parserBuffer);
      writeReport(type, summary);
    }
    resetStreamingState();
  });

  // Clean up report file on session end
  pi.on("session_end", async () => {
    writeReport("ended", "Session ended");
  });
}
