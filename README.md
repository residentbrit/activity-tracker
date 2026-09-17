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

To run capture, sync, and audio collection without the MCP stdio server, use:

```bash
~/.local/bin/activity-tracker --collector-only
```

That mode is the intended runtime building block for a future `launchd` setup, since it does not depend on an MCP client keeping stdio open.

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
    │  Tools: search, sessions,    │
    │    meetings, sync (9 total)  │
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

### Search: semantic, with keyword as a boost

`search_activities` is hybrid. Embedding similarity does the ranking, and literal
matches add a bounded boost on top:

- **Semantic ranking** catches paraphrase. "writing a change ticket for production
  deployment" matches nothing by `LIKE` — those words never appear in that order —
  but returns the actual change-ticket conversations at 0.77–0.81 similarity.
- **Literal boost** protects exact tokens. A ticket id should rank by verbatim
  presence, not by embedding proximity, so a match adds +0.10 (single distinctive
  token), +0.08 (window-title/app-name match) or +0.02 (a common word inside a large
  OCR blob). Measured: an id present in 1,455 rows scored 0.68 against a
  merely-similar screen at 0.75 — the boost has to exceed that gap to win.
- **Similarity floor 0.62.** Calibrated against real data: genuine matches score
  0.72–0.78 and unrelated content peaks near 0.60, so a query with no real answer
  returns *nothing* rather than "least unrelated" noise.
- **De-duplication.** One screen can produce hundreds of near-identical rows
  (the same Slack window captured 5s apart), so results collapse on app +
  first 200 characters of content.

Fusion is additive rather than rank-based (RRF) on purpose: the semantic list is
ordered by relevance, but a `LIKE` result set is ordered by recency, so its rank
position carries no information — fusing by rank lets an arbitrary keyword match
outrank a strong semantic one.

If the embed server is down, search degrades to keyword-only and says so rather
than reporting a false "no activity found". Ranking is a brute-force scan over
every stored vector (~500ms at ~75k embedded rows, ~130ms when a time range
narrows the set); there is no vector index.

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

| Tool | Answers |
|---|---|
| `search_activities` | Keyword + semantic search over captures, optionally bounded by `start`/`end` |
| `get_recent_activity` | Captures from the last N minutes |
| `get_activity_range` | Everything captured between two timestamps |
| `list_sessions` / `get_session` | Session summaries, and every capture in one |
| `list_meetings`, `get_meeting_transcript`, `search_transcripts` | Meeting transcripts |
| `get_sync_status` | Pipeline queue depths — awaiting embedding, awaiting push to pgvector |

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

Rows are embedded through the resident `llama-server` in batches of 32 — the same
endpoint the daemon uses, so vectors are identical to live captures and no model
is reloaded per row. If the server is unreachable the script falls back to
`llama-embedding` subprocesses.

Inputs that exceed the server's 512-token batch are retried with progressively
smaller word and character caps (token-dense lists and long URLs both trip this).

Advanced options:

```bash
# Preview only (no DB updates)
./scripts/backfill_embeddings.py --dry-run

# Process only a subset
./scripts/backfill_embeddings.py --limit 100

# Include duplicate rows too (skipped by default — see note below)
./scripts/backfill_embeddings.py --include-duplicates

# Force the slow subprocess path, or tune server batching
./scripts/backfill_embeddings.py --no-server
./scripts/backfill_embeddings.py --batch-size 64
```

Note: duplicate rows (`is_duplicate = 1`) are deliberately inserted without an
embedding — they repeat text that is already embedded on the row that introduced
it, so semantic search finds the original. `--include-duplicates` embeds them
anyway (~4KB per row).

## Known gaps

1. TODO: add a per-app exclusion list before unattended always-on use, so sensitive apps and windows can be skipped.
2. Slack answers are currently limited to what was actually visible on screen; channel-aware history would require a separate Slack API integration.
3. Capture-time embedding is fire-and-forget: if an embed fails, the row stays unembedded. A 30-minute launchd sweep (`make embedbackfill-install`) drains them within half an hour, but the daemon itself still has no retry.
4. The legacy outbox's ~990MB of already-written export files are still on disk. The exporter is off, so they no longer grow; delete the directory when convenient.

## Configuration

`~/.config/activity-tracker/config.json` is written automatically on first run. You
never need to create it, and the defaults work as-is — edit it only to change
behaviour. This is the complete set of keys it writes (`/Users/you` stands in for your
home directory):

```json
{
  "audioMode" : "meetings_only",
  "dbPath" : "/Users/you/.local/share/activity-tracker/activity.db",
  "embeddingBinaryPath" : "/Users/you/.local/bin/llama-embedding",
  "embeddingModel" : "mxbai-embed-large",
  "embeddingModelPath" : "/Users/you/.local/share/activity-tracker/models/",
  "heartbeatIntervalSec" : 30,
  "idleTimeoutMin" : 5,
  "meetingBundleIDs" : [
    "com.microsoft.teams",
    "com.tinyspeck.slackmacgap",
    "us.zoom.xos"
  ],
  "meetingWindowTitlePatterns" : [
    "huddle"
  ],
  "screenshotRetentionHours" : 24,
  "syncIntervalMin" : 30,
  "syncOutboxEnabled" : false,
  "syncOutboxRetentionDays" : 0,
  "syncTarget" : {
    "database" : "phillip_ai",
    "host" : "192.168.1.33",
    "password" : "",
    "port" : 5433,
    "user" : "activity_tracker"
  },
  "tier1BundleIDs" : [
    "com.tinyspeck.slackmacgap",
    "com.microsoft.VSCode",
    "com.apple.Terminal",
    "com.google.Chrome",
    "net.librewolf.librewolf",
    "com.microsoft.Outlook"
  ],
  "tier1PollIntervalSec" : 5,
  "typingPauseSec" : 3,
  "whisperBinaryPath" : "/Users/you/.local/bin/whisper-cli",
  "whisperModel" : "small"
}
```

Changes take effect on SIGHUP — no restart needed.

### Editing it safely

- **Keys you omit keep their defaults**, so a config file doesn't need updating when the
  schema grows. Absent keys, unknown keys and `null` values are all reported at startup.
- A malformed file or a wrong-typed value is reported rather than silently ignored — but
  note the daemon then falls back to *all* defaults, so check the line below if
  behaviour changes unexpectedly.
- To see what actually took effect:

  ```bash
  grep -A2 'loading config' ~/.local/share/activity-tracker/logs/collector-error.log
  #   config loaded
  #     heartbeat=15s tier1=6 apps meetings=4 ids audio=meetings_only outbox_retention=0d
  ```

### The two settings that fail quietly: bundle ids

Getting a bundle id wrong doesn't error — capture keeps running, just degraded, with
nothing in the logs. Both of these have bitten before:

| Setting | Correct value | With the wrong value |
|---|---|---|
| `tier1BundleIDs` | `net.librewolf.librewolf` | LibreWolf is skipped by tier 1 per-window polling — ~1 event/day instead of hundreds. **Not** `io.gitlab.librewolf-community`. |
| `meetingBundleIDs` | `com.microsoft.teams2` | Meetings are never detected, so no transcripts at all. `com.microsoft.teams` is *classic* Teams only. |

Check an installed app's real id with:

```bash
osascript -e 'id of app "Microsoft Teams"'
```

### Settings that delete data

`screenshotRetentionHours` (screenshots) and `syncOutboxRetentionDays` (sync export
files) are the only two settings that remove anything. `0` for the latter means keep
everything. `audioMode: "off"` disables meeting capture entirely.

## Sync to homellm (optional)

Local SQLite is the working set; the pgvector database on homellm
(`192.168.1.33:5433/phillip_ai`) is for full history and heavy summarization.
The sync reads the local DB directly and upserts into `activity_events` — the
local DB already holds the text *and* the embeddings, so there is no intermediate
export to collect.

```bash
make sync-setup      # one-time: venv + pure-Python pg8000 driver
security add-generic-password -s activity-tracker-pgvector -a activity_tracker -w
make sync-check      # connectivity, server version, remote row counts
make sync-pgvector   # push pending rows
```

Useful flags: `make sync-pgvector ARGS="--dry-run"` (report only, no connection),
`--limit 500`, `--reset-queue` (re-queue everything).

How it works:

- **Queue state is `events.pg_synced`**, deliberately separate from `synced`
  (which the legacy file outbox sets). One shared flag would mean whichever
  mechanism ran first marked rows done and silently starved the other.
- **Idempotent.** `INSERT ... ON CONFLICT (id) DO NOTHING`, so a replayed batch is
  harmless. Local rows are marked only *after* the remote commit, so a crash
  mid-batch replays rather than drops.
- **Duplicates are skipped** — their text already exists on the row that
  introduced it, same as everywhere else in the system.
- **Credentials are never in this repo.** Resolution order: `PGPASSWORD` →
  macOS Keychain (service `activity-tracker-pgvector`) → `syncTarget.password` in
  the config file.
- The script creates the remote schema on first run (`activity_events`,
  `activity_sessions`, `activity_audio_segments`). Creating the `vector`
  extension needs superuser; if that fails it warns and assumes it is enabled.

A full first run pushes ~82k rows (the accumulated history) and takes a few
minutes; subsequent runs only send new events.

### Legacy outbox (now disabled)

The older design wrote a JSON file every 30 minutes to
`~/.local/share/activity-tracker/sync-outbox/` for a companion script on homellm to
collect. That script was never built, so nothing ever read the files — they just
accumulated. The exporter is now **off** by default (`syncOutboxEnabled: false`); turn
it back on only if you resurrect that approach.

While it is off, `syncIntervalMin` and `syncOutboxRetentionDays` do nothing.

The ~990MB of files already written are still on disk and are safe to delete — the rows
behind them all remain in the local DB, and the direct sync pushes from the DB rather
than from these files:

```bash
rm -rf ~/.local/share/activity-tracker/sync-outbox/
```

One wrinkle if you do: those rows are marked `synced` (by the old exporter), not
`pg_synced`, so the direct sync will still pick every one of them up.

Duplicate rows were never exported, so the outbox held only one copy of any given screen.

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
├── MCPServer.swift         JSON-RPC stdio server (9 tools)
├── SemanticSearch.swift    Embedding similarity search (hybrid ranking)
└── SyncEngine.swift        File-based sync export (legacy — see pgvector sync)

scripts/
├── harvest_vscode_chat.py  Copilot chat transcripts → events
├── backfill_embeddings.py  Fill missing embeddings (batched, resumable)
└── sync_to_pgvector.py     Local SQLite → homellm pgvector
```
