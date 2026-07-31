# Personal Activity Tracker — Project Spec

## Goal

A local, privacy-first tool that captures what I work on throughout the day and
makes it queryable later — specifically to support:

1. Ad-hoc questions like "what did I work on yesterday / this week"
2. A periodic (likely monthly) summary, grouped by project/area, with enough
   detail to reconstruct what actually happened — not just time totals
3. An end-of-year query: "summarize what I worked on this year — for each
   project/area I spent significant time on, give a paragraph of what was
   achieved"

This is **not** a billing/time-tracking tool. Time-per-project totals are a
nice-to-have, not the point. The point is substance: what was touched, what
was decided, what shipped.

## Non-goals (explicitly decided against)

- **No visual timeline/video-replay feature.** Not interested in scrubbing
  back through a video of my day. This means no need to stitch screenshots
  into video (see "What we're intentionally simplifying" below).
- **No rule-based project categorization** (e.g. matching app name → project).
  My VS Code/terminal sessions shift between different client
  projects throughout the day, so static app/domain rules can't tell them
  apart. Project/area identification should come from reading actual
  on-screen content (ticket numbers, client/district names, repo/file paths),
  inferred at query time by an LLM — not pre-tagged by rigid rules.

## Architecture

### 1. Capture
- Screenshot capture at **native monitor resolution** — no downscaling.
  (Home: 4K. Office: 1080p — already native there, nothing to avoid.)
- **Event-driven, not polling**: trigger on app-switch, click, typing-pause
  (macOS: `NSWorkspace` notifications + input hooks), with a periodic
  fallback capture during idle stretches.
- Use `ScreenCaptureKit` (or `CGWindowListCreateImage`) directly.

### 2. Text extraction — accessibility-tree first, OCR as fallback only
- **Primary path**: walk the macOS Accessibility API (`AXUIElement`) for the
  focused app/window. This is fast, free, and — critically — resolution
  independent, since it reads structured text directly rather than reading
  pixels.
- **Fallback only** when the accessibility tree comes back empty (canvas-
  rendered apps, remote desktop sessions like Royal TSX, images, video):
  run OCR via Apple's **Vision framework** (`VNRecognizeTextRequest`) —
  free, on-device, fast.
- Empirically validated this priority order matters: side-by-side test on
  real captured data showed accessibility-tree text was clean/accurate,
  while OCR of the identical screen was meaningfully garbled at the
  character level.

### 3. Audio
- Capture system audio + mic via `AVFoundation`.
- VAD (silero or webrtcvad) to skip silence before transcription.
- Transcribe locally via `whisper.cpp`, run on one of the M4 Pro Mac minis
  (already have the hardware/Ollama infra for this).

### 4. Storage
- **No separate SQLite database.** Write directly into the existing
  `phillip_ai` Postgres/pgvector database (192.168.1.33:5433), using the
  same `mxbai-embed-large` embedding pipeline already built for other RAG
  work.
- Rough schema idea (not finalized — see open questions):
  `events(ts, device, app, window_title, source_type[accessibility|ocr|audio],
  text, embedding, tags)`

### 5. What we're intentionally simplifying vs. screenpipe
Reverse-engineered screenpipe's pipeline as a reference point. It captures
at a downscaled resolution, saves JPEGs, then ~10 minutes later runs a
background worker that stitches batches of JPEGs (grouped by device,
timestamp order) into video files and deletes the originals — a real
compression win (3–9x observed), but purely in service of a scrubbable
video-timeline UI feature. Since that feature isn't wanted here:
- No video-encoding step needed at all.
- Raw screenshots only need to live long enough to run extraction +
  embedding, then can be discarded (or kept a day or two as a debug buffer).
- One less dependency (no ffmpeg/video pipeline) and one less thing that
  could silently degrade data quality.

### 6. Multi-machine reality: home (4K, on `phillip_ai` network) vs.
work office (dual 1080p, **no network path to home network**)
- Architecture must be **local-first, not client-server**. Each machine
  captures, extracts, and embeds independently — embedding uses
  `llama.cpp` with `mxbai-embed-large` in-process, same C++ toolchain
  as `whisper.cpp` for audio transcription. No separate daemon needed.
- Each machine keeps a local "outbox" of captured-and-embedded-but-not-yet-
  synced rows (local SQLite or local Postgres is fine here).
- A separate sync step pushes new rows into `phillip_ai` whenever
  connectivity exists. Mechanism not yet decided (manual trigger vs.
  Tailscale vs. something else) — see open questions. Payload at sync time
  is just text + vectors, not raw screenshots, so it's small either way.

## Decisions log

### D1 — Implementation language: **Swift** (2026-07-30)
Native access to ScreenCaptureKit, Vision, Accessibility, AVFoundation.
No PyObjC bridging tax. Swift Package Manager for builds (no Xcode project).
VS Code + `sswg.swift-lang` extension + Xcode CLT for toolchain.

### D2 — Capture triggers: **hybrid event-driven + heartbeat** (2026-07-30)
| Trigger | Fires when |
|---|---|
| App switch | Active application changes |
| Window title change | Same app, different window/tab/file |
| Typing pause | ~3s after last keystroke |
| Heartbeat | Every 60s while machine is active |
| Idle timeout | No input for 5 min → pause all captures until next event |

Frame dedup: skip embed-and-store if extracted text is near-identical to
previous capture (just note "same context" and move on).

### D3 — AX-tree gaps (e.g. VS Code editor pane): **OCR the content area** (2026-07-30)
When the AX tree returns window chrome / title but the main content area is
empty (canvas-rendered, WebGL, etc.), fall back to OCR for that region
specifically. The window title + file path from AX still provide structured
context; OCR fills in the actual content.

### D4 — Project/area tagging: **hybrid** (2026-07-30)
- At capture time: store structured columns (app bundle ID, window title,
  active file path, git branch if detectable) as first-class fields.
- At query/summarization time: LLM refines grouping based on actual
  content, overriding the structural hints when they mislead (e.g. same
  editor window used for different projects).

### D5 — Audio capture: **meetings only, full audio** (2026-07-30)
When a meeting app is detected (Zoom, Teams, Meet, Webex, etc.) via bundle
ID + window-title heuristics, record system audio + mic. Outside of meetings,
no audio capture at all — not even system audio. VAD → whisper.cpp
for transcription. Per-machine config flag to toggle audio capture on/off
entirely (e.g. disable at office if meeting recording isn't appropriate).

### D6 — Session abstraction: **yes** (2026-07-30)
Group captures into sessions: contiguous activity periods between idle
timeouts. Session starts on first capture after idle, ends when idle
timeout fires. Provides natural unit for "yesterday morning vs. afternoon"
summarization.

### D7 — Query interface: **MCP server + homellm** (2026-07-30)
An MCP (Model Context Protocol) server runs locally on each capture machine.
MCP clients (Claude Desktop, VS Code, etc.) connect to it for queries.
Query path: local SQLite for recent captures (same-machine), remote homellm
pgvector for full history. Embedding uses existing `mxbai-embed-large`
pipeline. Events are documents in the existing RAG system — no separate
query tool needed.

### D9 — Runtime configuration: **JSON config file** (2026-07-30)
File at `~/.config/activity-tracker/config.json`. Swift `Codable` — load at
startup, reload on SIGHUP or file-watch. No recompile to tweak intervals.
Key settings: heartbeat interval, typing-pause threshold, idle timeout,
audio mode, screenshot retention hours, sync target.

### D8 — Raw screenshot retention: **24-hour debug buffer** (2026-07-30)
Keep raw screenshots locally for 24 hours in the outbox SQLite DB, then
purge. Long enough to debug extraction quality issues; short enough not to
accumulate 4K bloat. Only text + vectors leave the machine at sync time.

### D10 — Sync target: **homellm infrastructure** (2026-07-30)
Sync pushes local outbox rows → `/Users/phillip/Git/Projects/homellm`
pgvector database. Payload is text + vectors only (no raw screenshots).
Sync step is separate from capture; capture never blocks on network.
Connectivity check before sync; local outbox accumulates when offline.
Mechanism TBD (manual trigger vs. Tailscale vs. other — see open questions).

### D11 — LLM split: **llama.cpp (embed) + mlx-lm (summarize)** (2026-07-30)
- **Embedding on capture machines**: `llama.cpp` in-process via C bindings,
  `mxbai-embed-large` model (GGUF). Same C++ toolchain as `whisper.cpp` —
  consistent dependency pattern, no separate daemon. Model loads only
  during embedding, not resident at idle.
- **Summarization on homellm**: `mlx-lm` on M4 Pro hardware for periodic
  summaries (monthly/yearly). Best throughput on Apple Silicon.
- **Ad-hoc queries**: LLM lives in the MCP client (Claude Desktop, VS Code,
  etc.), not in the capture agent. MCP server exposes search tools; the
  client's LLM synthesizes answers.

### D12 — DB schema: **local SQLite + remote pgvector** (2026-07-30)

#### Local SQLite (each capture machine)

```sql
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,              -- UUID
    machine_id TEXT NOT NULL,         -- "home-mac", "work-mac"
    started_at TEXT NOT NULL,         -- ISO 8601
    ended_at TEXT,                    -- NULL if active
    timezone TEXT NOT NULL
);

CREATE TABLE events (
    id TEXT PRIMARY KEY,              -- UUID
    session_id TEXT NOT NULL REFERENCES sessions(id),
    captured_at TEXT NOT NULL,        -- ISO 8601
    trigger TEXT NOT NULL,            -- app_switch|window_title_change|typing_pause|heartbeat
    app_bundle_id TEXT,               -- e.g. "com.microsoft.VSCode"
    app_name TEXT,                    -- e.g. "Visual Studio Code"
    window_title TEXT,                -- e.g. "spec.md — screenrecorder"
    active_file_path TEXT,
    source_type TEXT NOT NULL,        -- accessibility|ocr|audio_transcript
    text_content TEXT NOT NULL,       -- extracted text or transcript
    embedding BLOB,                   -- 1024-dim float32 from llama.cpp mxbai-embed-large
    dedup_key TEXT,                   -- hash(text_content) for near-duplicate detection
    is_duplicate INTEGER DEFAULT 0,
    synced INTEGER DEFAULT 0          -- 0=pending, 1=pushed to homellm
);

CREATE TABLE screenshots (
    event_id TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
    image_data BLOB NOT NULL,         -- PNG at native resolution
    created_at TEXT NOT NULL          -- for 24h TTL purge
);

CREATE TABLE audio_segments (
    id TEXT PRIMARY KEY,              -- UUID
    session_id TEXT NOT NULL REFERENCES sessions(id),
    started_at TEXT NOT NULL,
    ended_at TEXT NOT NULL,
    meeting_app TEXT,                 -- e.g. "us.zoom.xos", "com.microsoft.teams"
    transcript TEXT NOT NULL,         -- whisper.cpp output
    embedding BLOB,                   -- 1024-dim
    synced INTEGER DEFAULT 0
);
-- No audio files stored — raw audio discarded after transcription.

CREATE TABLE sync_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    events_synced INTEGER DEFAULT 0,
    status TEXT                       -- in_progress|completed|failed
);

CREATE INDEX idx_events_session ON events(session_id);
CREATE INDEX idx_events_captured ON events(captured_at);
CREATE INDEX idx_events_synced ON events(synced);
CREATE INDEX idx_events_dedup ON events(dedup_key);
```

#### Remote pgvector (homellm)

```sql
CREATE TABLE activity_events (
    id TEXT PRIMARY KEY,
    machine_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    captured_at TIMESTAMPTZ NOT NULL,
    trigger TEXT NOT NULL,
    app_bundle_id TEXT,
    app_name TEXT,
    window_title TEXT,
    active_file_path TEXT,
    source_type TEXT NOT NULL,
    text_content TEXT NOT NULL,
    embedding vector(1024),          -- mxbai-embed-large
    synced_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE activity_sessions (
    id TEXT PRIMARY KEY,
    machine_id TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    timezone TEXT NOT NULL,
    event_count INTEGER,
    summary TEXT                      -- pre-computed by mlx-lm cron job
);

CREATE TABLE activity_audio_segments (
    id TEXT PRIMARY KEY,
    machine_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    meeting_app TEXT,
    transcript TEXT NOT NULL,
    embedding vector(1024),
    synced_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_activity_events_ts ON activity_events(captured_at);
CREATE INDEX idx_activity_events_machine ON activity_events(machine_id);
CREATE INDEX idx_activity_events_embedding
    ON activity_events USING ivfflat (embedding vector_cosine_ops);
```

Design notes: embedding as BLOB in SQLite (no native vector type) — MCP
server loads recent events into an in-memory index for local similarity
search. Raw audio discarded after whisper.cpp transcription (same logic as
discarding screenshots after text extraction). dedup_key enables frame
dedup without running embedding on every capture.

### D13 — Sync: **automatic background, configurable interval** (2026-07-30)
Default 30 minutes. Flow: TCP health check to pgvector port → if reachable
and unsynced rows exist → push batch → log to sync_log (started_at,
ended_at, events_synced, status). On failure, retry next interval. MCP
server exposes `get_sync_status` for ad-hoc checking. Interval configurable
in `config.json`.

### D14 — Whisper model: **small** (2026-07-30)
Starting point for meeting transcription. ~500MB disk, ~1.5GB RAM at
runtime, fast on M-series. Good enough quality for semantic search over
meeting transcripts. Configurable — bump to `medium` or `large-v3-turbo`
via config flag if quality is insufficient.

### D15 — Meeting detection: **bundle ID based, desktop apps only** (2026-07-30)
User uses Teams desktop app, Slack desktop app, and occasionally Zoom
desktop app. No browser-based meetings. Detection is pure bundle-ID match:

```json
"meeting_detection": {
  "bundle_ids": [
    "com.microsoft.teams",
    "com.tinyspeck.slackmacgap",
    "us.zoom.xos"
  ]
}
```

For Slack specifically: the app is always running — need to check window
title for "huddle" or similar to distinguish active call from normal chat.
Configurable list in `config.json`, no recompile needed to add/remove apps.

### D16 — DRM handling: **skip it** (2026-07-30)
All captured content is local to the user; nothing they wouldn't see anyway.
No DRM detection needed. One less thing to build.

### D17 — Tier 1 per-window polling: **5s cadence on key apps** (2026-07-30)
In addition to the full-screen heartbeat (30s), visible windows of
configured "tier 1" apps (Slack, VS Code, Terminal, Chrome/LibreWolf,
Outlook) get per-window change detection at a faster cadence (default 5s).

Change detection method depends on AX capability:
- **AX-capable** (Slack, Terminal, Outlook): walk AX tree → hash text.
  Free, microsecond-latency. Only captures when text content changed.
- **AX-opaque** (Chrome, LibreWolf, VS Code editor): capture thumbnail
  (~128px) → hash pixels. ~1ms. Only fires full capture when pixels differ.

Per-window captures use `CGWindowListCreateImage` for that specific window.
Each window tracks its own content hash independently. Combined with text
diffing (D18), only new/changed content is embedded.

### D18 — Text diffing: **embed only new lines** (2026-07-30)
Before embedding, captured text is diffed against the previous capture for
the same app/bundleID. Only new lines (set subtraction) are embedded. This
makes embeddings more specific to "what just happened" and improves semantic
search precision. Overhead is ~100µs per diff — negligible vs. ~50ms embedding.

---

## Open questions / not yet decided

1. **The actual summarization prompt** — still needs real design/tuning work
   once there's captured data to test against. Don't invent this yet;
   treat it as a follow-up task, not part of this build.

---

## Implementation notes (not design decisions)

- **Memory management**: capture writes screenshot immediately to disk, then
  hands off to a serial `.background` QoS queue for extraction/embedding.
  No bounded queue, no frame dropping — if the machine is busy, processing
  catches up later. Capture must never compete with real work.

---

## One thing to check before this becomes a daily driver on the work laptop

The work machine will be capturing SQL output, support-ticket contents, and
district/student-related table names and data — a different risk profile
than personal homelab devices. Worth a quick check against employer policy
on local screen/audio recording tools before running this as a daily driver
there. (Not a coding task — a personal follow-up.)
