# Activity Tracker

A local, privacy-first macOS daemon that captures what you work on throughout the day and makes it queryable via MCP (Model Context Protocol). Think of it as a personal search engine for your work activity.

**Not** a time tracker. The point is substance — what you touched, what was decided, what shipped.

## Quick start

```bash
# Prerequisites (one time)
xcode-select --install
brew install cmake           # needed for llama.cpp build

# Clone and build
git clone https://github.com/residentbrit/activity-tracker.git
cd activity-tracker
make install
```

`make install` handles everything: builds the Swift daemon, compiles llama.cpp and whisper.cpp, downloads embedding and transcription models (~1.2GB total), and installs to `~/.local/bin/`.

## Run it

```bash
~/.local/bin/activity-tracker
```

On first run it writes a default config to `~/.config/activity-tracker/config.json`. The daemon runs in the foreground — no GUI, no dock icon.

### macOS permissions

You'll be prompted for:

| Permission | Used for |
|---|---|
| Accessibility | Reading window text via AX API |
| Screen Recording | Screenshot capture |
| Microphone | Meeting transcription (optional, configurable) |

## How it works

```
┌──────────────────────────────────────────────────────┐
│                  Capture Agent (Swift)                 │
│                                                        │
│  ScreenCaptureKit ──► AX Text Extraction ──► Embedding │
│  InputMonitor     ──► OCR Fallback         ──► SQLite  │
│  AVFoundation     ──► VAD → whisper.cpp   ──► SQLite  │
│                                                        │
│  Full-screen triggers: app-switch, window-title-change,│
│       typing-pause (3s), heartbeat (30s)               │
│  Tier 1 per-window polling: every 5s on Slack, VS Code,│
│       Terminal, Chrome/LibreWolf, Outlook              │
│  Content change detection: AX text-hash (fast) or      │
│       pixel-diff thumbnail for AX-opaque apps          │
│  Text diffing: embed only new lines since last capture │
│  Idle: pauses after 5min of no input                   │
└──────────────────┬───────────────────────────────────┘
                   │
    ┌──────────────▼──────────────┐
    │     MCP Server (stdio)       │
    │                              │
    │  Tools: search_activities    │
    │         get_recent_activity  │
    │         list_sessions        │
    │         get_session          │
    │         get_sync_status      │
    └──────────────┬──────────────┘
                   │
    ┌──────────────▼──────────────┐
    │   MCP Client (Claude etc.)   │
    │                              │
    │  "What did I work on today?" │
    └──────────────────────────────┘
```

### Text extraction: AX first, OCR fallback

The primary path walks the macOS Accessibility tree — fast, free, resolution-independent, and more accurate than OCR. Vision OCR only fires when AX comes back empty (canvas-rendered apps, remote desktop, images).

### Audio: meetings only

Audio capture activates only when a meeting app is detected (Teams, Slack huddles, Zoom). Energy-based VAD filters silence. whisper.cpp `small` model transcribes locally. Raw audio is discarded after transcription — only the transcript and its embedding are stored.

### Embedding: local and private

All text is embedded on-device via llama.cpp + mxbai-embed-large. Nothing leaves your machine except during optional sync to your homellm instance.

## Querying your data

Connect any MCP client to the stdio server:

```json
{
  "mcpServers": {
    "activity-tracker": {
      "command": "activity-tracker"
    }
  }
}
```

Then ask natural questions like "what did I work on yesterday?" or "summarize last week."

## Watching it work

```bash
# View recent captures
sqlite3 ~/.local/share/activity-tracker/activity.db \
  "SELECT captured_at, trigger, app_name, substr(text_content,1,80) FROM events ORDER BY captured_at DESC LIMIT 10"

# Count screenshots
ls ~/.local/share/activity-tracker/screenshots/ | wc -l

# Tail the debug log
tail -f ~/.local/share/activity-tracker/debug.log
```

## Backfill embeddings

If older rows were captured before embedding fixes, run a one-shot backfill:

```bash
make backfill
```

Advanced options:

```bash
# Preview only (no DB updates)
./scripts/backfill_embeddings.py --dry-run

# Process only a subset
./scripts/backfill_embeddings.py --limit 100

# Include duplicate rows too
./scripts/backfill_embeddings.py --include-duplicates
```

## Configuration

`~/.config/activity-tracker/config.json` (auto-generated on first run):

```json
{
  "heartbeatIntervalSec": 30,
  "typingPauseSec": 3,
  "idleTimeoutMin": 5,
  "audioMode": "meetings_only",
  "screenshotRetentionHours": 24,
  "syncIntervalMin": 30,
  "tier1PollIntervalSec": 5,
  "tier1BundleIDs": [
    "com.tinyspeck.slackmacgap",
    "com.microsoft.VSCode",
    "com.apple.Terminal",
    "com.google.Chrome",
    "io.gitlab.librewolf-community",
    "com.microsoft.Outlook"
  ]
}
```

Changes take effect on SIGHUP — no restart needed.

## Sync to homellm (optional)

Events are exported as JSON to `~/.local/share/activity-tracker/sync-outbox/`. A companion script on the homellm machine can pick these up and push to pgvector for long-term history and annual summaries.

## Tech stack

| Layer | Technology |
|---|---|
| Language | Swift 6 |
| Screen capture | ScreenCaptureKit + CGWindowList |
| Text extraction | AXUIElement + Vision OCR |
| Audio | AVFoundation + whisper.cpp `small` |
| Embedding | llama.cpp + mxbai-embed-large (1024-dim) |
| Local storage | SQLite (WAL) + disk screenshots |
| Query interface | MCP over stdio (JSON-RPC 2.0) |
| Remote storage | pgvector (homellm, optional) |
| Summarization | mlx-lm on M4 Pro (homellm, optional) |

## Project layout

```
Sources/
├── main.swift              Entry point, wires subsystems
├── Config.swift            JSON config (Codable)
├── Database.swift          SQLite + migrations
├── CaptureEngine.swift     Screen capture + session lifecycle
├── InputMonitor.swift      CGEvent tap, idle detection, typing pause
├── TextExtractor.swift     AX-first, Vision OCR fallback
├── Embedder.swift          llama.cpp subprocess
├── MeetingDetector.swift   Bundle ID + window-title heuristics
├── AudioCapture.swift      AVFoundation + VAD + whisper.cpp
├── EventStore.swift        Prepared-statement CRUD
├── MCPServer.swift         JSON-RPC stdio server (5 tools)
├── SyncEngine.swift        File-based sync export
└── Resources/
    └── config.default.json
```
