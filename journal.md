# Activity Tracker — Development Journal

## 2026-08-05

### Session Summary
Full deployment of activity-tracker as a background daemon, replacing screenpipe. Fixed a critical capture bug discovered after deployment.

---

### 1. Daemon Deployment

**Goal:** Run activity-tracker as a persistent launchd background service using `--collector-only` mode.

**Work done:**
- Created `launchd/com.activitytracker.collector.plist` — launchd agent definition
  - Runs `~/.local/bin/activity-tracker --collector-only`
  - `KeepAlive=true` for auto-restart
  - Logs to `~/.local/share/activity-tracker/logs/`
- Added `make daemon-install` target — builds release binary, installs to `~/.local/bin/`, writes plist to `~/Library/LaunchAgents/`, loads daemon
- Added `make daemon-uninstall` target — unloads and removes plist

**Permissions required (macOS Privacy & Security):**
- Screen Recording → `/Users/phillip/.local/bin/activity-tracker`
- Accessibility → `/Users/phillip/.local/bin/activity-tracker`

**Note:** Replacing the binary causes macOS to revoke Screen Recording permission. After any `make daemon-install`, remove and re-add the entry in System Settings.

**Management commands:**
```bash
# Status
launchctl list com.activitytracker.collector

# Restart
launchctl kickstart -k gui/$(id -u)/com.activitytracker.collector

# Monitor
tail -f ~/.local/share/activity-tracker/logs/collector-error.log

# Uninstall
make daemon-uninstall
```

---

### 2. Replaced Screenpipe with SwiftBar Plugin

**Goal:** Replace screenpipe's SwiftBar status plugin with an activity-tracker equivalent.

**Work done:**
- Stopped screenpipe: unloaded both launchd agents (`com.phillip.screenpipe`, `com.phillip.screenpipe.watchdog`), moved SwiftBar plugins out of the Plugins directory
- Archived screenpipe launchd plists as `.disabled` in `~/Library/LaunchAgents/`
- Created `~/Library/Application Support/SwiftBar/Plugins/activity-tracker.1m.sh`

**SwiftBar plugin displays:**
- `👁 Xe/h` — events captured in the last hour
- Events last hour / today
- Top 3 apps by capture count today
- Menu actions: Tail log, Stop/Start collector, Refresh

**Debugging notes:**
- SwiftBar recursively scans subdirectories — disabled plugins must be moved *outside* the Plugins folder entirely, not into a subfolder
- SwiftBar caches plugin state; full quit + relaunch required after plugin changes
- Use explicit binary paths (`/usr/bin/sqlite3`, `/bin/launchctl`) in SwiftBar scripts — restricted PATH in SwiftBar's execution environment

---

### 3. Fixed Event-Driven Capture Bug

**Symptom:** After daemon deployment, 47 events captured at startup then nothing for 30+ minutes despite active app switching, typing, and git operations in Terminal.

**Diagnosis:**
- Tier1 window polling worked correctly (`CGWindowListCreateImage`)
- Event-driven captures (appSwitch, typingPause, heartbeat) were triggering (`capture(X) starting` in logs) but never reaching `storing event`
- Root cause: `captureScreen()` used `CGDisplayCreateImage` which returns `nil` silently in a launchd daemon context, even with Screen Recording permission granted

**Fix (`Sources/CaptureEngine.swift`):**
```swift
// Before
let displayID = CGMainDisplayID()
return CGDisplayCreateImage(displayID)

// After
return CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
```

`CGWindowListCreateImage` is the same API used by tier1 polling and works correctly in daemon context.

**Result:** Event-driven captures immediately began storing events after fix was deployed.

---

### 4. VS Code Chat Harvester (Planned)

**Goal:** Scrape and embed Copilot chat logs from all VS Code workspaces to add work-context to the activity database.

**Source:** `~/Library/Application Support/Code/User/workspaceStorage/*/GitHub.copilot-chat/transcripts/*.jsonl`

**Extract fields:**
1. Timestamp
2. Workspace name
3. User prompt text (clean, no system noise)
4. Response summary (first portion of assistant response)
5. Mentioned files / repos
6. Optional: topics/tags

**Storage:** New `copilot_interaction` event type in activity DB, linked by timestamp to screen capture context.

**Scheduling:** Hourly cron job (`scripts/harvest_vscode_chat.py`), plus one-time backfill via `make harvest-chat`.

**Status:** Planned — not yet implemented.

---

### Commits This Session
- `0928441` — Deploy daemon: launchd plist, Makefile targets, SwiftBar plugin
- `509a16b` — Fix event-driven captures: replace CGDisplayCreateImage with CGWindowListCreateImage

---

## 2026-08-06

### Session Summary
Stabilization marathon. Fixed blocking capture pipeline, persistent permissions, DB corruption, and fully removed screenpipe. The system went from crashing every 10 seconds to stable continuous capture.

---

### 1. Screenpipe Historical Data Migration (later purged)

**Goal:** Import 26 days of screenpipe historical data into activity-tracker DB.

**Work done:**
- Created `scripts/migrate_screenpipe.py` — imported 56,595 events from `~/.screenpipe/db.sqlite`
- Deduplicated by content_hash, created synthetic daily sessions
- Added `make migrate-screenpipe` and `make migrate-screenpipe-embed` targets

**Result:** 62K events in DB after import. DB grew to 695MB.

**Why purged later:** Screenpipe texts had corrupted characters from the recover process. Embedding subprocess exited with SIGABRT (rc:-6) on those rows. Not worth debugging — purged everything.

**Commits:**
- `746cacd` — Add screenpipe migration scripts

---

### 2. Embed Server (llama-server on port 8080)

**Goal:** Replace one-subprocess-per-embed (3-10s/event) with persistent server (~100ms/event).

**Work done:**
- Built `llama-server` alongside `llama-embedding` (cmake `-DLLAMA_BUILD_SERVER=ON`)
- Created `launchd/com.activitytracker.embedserver.plist` — runs llama-server on port 8080 with mxbai-embed-large, KeepAlive auto-restart
- Made `Embedder.swift` re-probe server health after 5 consecutive failures instead of caching `useServer=false` permanently
- Added `make embedserver-install` target
- Updated `make daemon-uninstall` to also stop embedserver

**Result:** Embeddings went from 3-10s/event (subprocess) to ~100ms/event (server).

**Commits:**
- `b6cb5b7` — Add llama-server embed daemon and resilient health checks

---

### 3. AX Extraction Timeout and Text Cap

**Problem:** `AXUIElementCopyAttributeValue` can block indefinitely on unresponsive apps. Single hung call blocked the entire TextExtractor actor, starving all subsequent captures.

**Fixes applied over multiple iterations:**
1. **8KB text cap** — `collectAXText` limits collected text to 8KB to prevent runaway memory use on large documents (VS Code with 600KB text)
2. **3s AX timeout** — entire AX extraction runs on GCD thread with `DispatchSemaphore` timeout; hangs fall back to OCR
3. **8s OCR timeout** — Vision `VNImageRequestHandler.perform()` also wrapped with semaphore timeout
4. **5s screen capture timeout** — `CGWindowListCreateImage` wrapped with timeout (can block in some macOS states)
5. **Capped text before append** — fixed cap to truncate each chunk to remaining budget rather than checking after append (prevented single 4MB text element)
6. **Fully off-thread AX** — moved `AXUIElementCreateApplication` and `kAXFocusedWindowAttribute` lookup onto GCD thread as well; these outer calls could also block

**Key architectural change:** `TextExtractor` changed from actor → class. Extractions now run concurrently on GCD threads rather than serializing through the actor. Thread-safe because AX and Vision are thread-safe and all state is local to each extraction call.

**Commits:**
- `50bdaf4` — Cap AX text collection at 8KB
- `36f7217` — Fix backfill_embeddings.py `__main__` block (dead code regression)
- `435a39b` — Add 3s timeout to AX extraction
- `33f9540` — Fix AX text cap to truncate before append, surface insertEvent errors
- `e05efb3` — Add timeouts to all blocking capture paths
- `518aa47` — Fix double-resume crash and null pointer crash
- `090ad5d` — Fix capture pipeline deadlock, fully off-thread AX extraction

---

### 4. Persistent TCC Permissions with Code Signing

**Problem:** Every rebuild changed the binary's ad-hoc code signature, causing macOS to revoke Screen Recording and Accessibility permissions. Required tedious remove-re-grant cycle.

**Root cause:** macOS TCC tracks permissions by code identity. Ad-hoc signed binaries get a new identity on every build. Without a TeamIdentifier (requires paid Apple Developer account), the hash-based identity changes every time.

**Important discovery about TCC grant flow:**
- **Shortcut (broken):** Manually remove + re-add in System Settings → reuses stale TCC entry → looks granted but fails
- **Proper (works):** Delete entry → binary launches → system prompts → re-enable toggle → password prompt → TCC creates fresh entry validated against current binary
- The password prompt is the signal that real cryptographic validation occurred
- `tccutil reset` forces the proper grant path on next launch

**Solution:** Created `ActivityTracker Dev` self-signed certificate + `codesign --sign` in Makefile install target. Same identity across rebuilds → TCC entry survives.

**Setup (one-time):**
```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=ActivityTracker Dev" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -out cert.pem -keyout key.pem
openssl pkcs12 -legacy -export -out signing.p12 -inkey key.pem -in cert.pem
security import signing.p12 -k ~/Library/Keychains/login.keychain-db -A
```

**Commits:**
- `18d0822` — Sign binary with persistent local cert

---

### 5. SwiftBar Plugin Health Monitoring

**Evolved from simple event counter to full health dashboard:**

V1: `👁 Xe/h` — events per hour
V2: Added embed server health indicator, macOS notification on state change
V3: Added last capture age, permission health from log scanning (Screen Recording deny count, Accessibility deny count)

**Current display:**
- Menu bar: `👁 ⚠️` when stale/broken, `👁 Xe/h` when healthy
- Dropdown: collector status, last capture age, events today/hour, unembedded count
- Permissions: 🔴 DENIED / ✅ OK for Screen Recording and Accessibility
- Embed server: ✅ / ⚠️ DOWN with one-click restart
- Top 3 apps today, Tail log, Stop/Start collector, Refresh

**Detection approach:** Scans last 80 log lines for permission warnings, queries DB for last event timestamp.

---

### 6. DB Corruption and Recovery

**Symptom:** Daemon entered crash loop (SIGSEGV every 10s). System log revealed:
```
database corruption page 46439 of activity.db
database corruption at line 77010
```

**Cause:** Repeated SIGABRT and SIGSEGV crashes during development left the WAL journal in an inconsistent state. 71 integrity_check errors.

**Recovery:** Used `sqlite3 .recover` to extract all salvageable data into a fresh DB. Lost zero events — all 61,695 rows recovered.

**Post-recovery:** Later purged 56,595 screenpipe import events and VACUUMed the DB. DB dropped from 695MB → 71MB with 6,249 live events remaining.

---

### 7. Total Screenpipe Purge

**Removed everything:**
- `~/.screenpipe/db.sqlite` (24GB data)
- `~/scratch/screenpipe-safe/` (295MB — node_modules, binaries)
- `~/Library/Caches/screenpipe/` (36MB)
- `~/Library/Application Support/screenpipe-backups/`
- `~/Library/Application Support/screenpipe-*.sh` (runner, watchdog, start scripts)
- `~/Library/LaunchAgents/com.phillip.screenpipe.*.disabled`
- `~/Library/Application Support/SwiftBar/Plugins/screenpipe.*.sh`
- `~/Library/Application Support/SwiftBar/disabled-plugins/`
- `~/Library/Logs/Claude/mcp-server-screenpipe.log`
- `~/Library/Caches/com.ameba.SwiftBar/Plugins/screenpipe.*.sh`
- Claude Desktop MCP config — removed `screenpipe` server entry
- 25 crash report `.ips` files from diagnostic reports directory
- All `activity.db.corrupt`, `activity.db.bak`, WAL backups

**Total reclaimed: ~24.4 GB**

---

### 8. Key Bugs Fixed (Chronological)

| Bug | Fix | Commit |
|-----|-----|--------|
| `CGDisplayCreateImage` returns nil in daemon context | Switch to `CGWindowListCreateImage` | `509a16b` |
| Embedder cached `useServer=false` permanently | Re-probe after 5 consecutive failures | `b6cb5b7` |
| AX tree walk collected 600KB text, blocking actor | 8KB cap with per-element truncation | `50bdaf4`, `33f9540` |
| `backfill_embeddings.py` silent no-op | `__main__` block was dead code inside `parse_args()` | `36f7217` |
| Single AX call hanging forever | 3s semaphore timeout on GCD thread | `435a39b` |
| OCR hanging forever | `VNImageRequestHandler.perform()` with 8s timeout | `e05efb3` |
| Double-resume crash in OCR timeout | Resume only from semaphore wait path | `518aa47` |
| NULL sqlite3_column_text crash | Guard against NULL before `String(cString:)` | `518aa47` |
| sem.wait() on Swift concurrency threads deadlock | All sem.wait() offloaded to GCD | `090ad5d` |
| Startup backfill deadlocked EventStore actor | Disabled auto-backfill; use `make backfill` | `090ad5d` |
| `kAXFocusedWindowAttribute` blocked actor | Moved ALL AX calls to GCD thread | `090ad5d` |
| TCC permission revoked on every rebuild | Self-signed cert with consistent identity | `18d0822` |
| Screenpipe migration texts corrupted (rc:-6) | Purged all screenpipe data from system | `ecb511c`, `e28ca53` |

---

### 9. Current System State

- **Daemon:** Stable, capturing events every ~5s via AX + OCR
- **DB:** 71MB, 6,249 live events, no corruption
- **Embed server:** Running on port 8080, ~100ms/embedding
- **SwiftBar:** Full health dashboard with permission/embed/last-capture monitoring
- **Screenpipe:** 100% gone — zero artifacts remaining
- **Disk recovered:** ~24.4 GB freed

### 10. Known Remaining Gaps

1. **Startup backfill disabled** — the auto-embed-on-start feature was deadlocking EventStore. Run `make backfill` manually to clear unembedded backlog.
2. **No app exclusion list** — captures everything (banking, passwords, etc.)
3. **VS Code chat harvester** — planned but not yet implemented
4. **Embed server uses subprocess as fallback** — works but slow if server is down

---

## 2026-08-12

### Session Summary
Post-stabilization audit. Fixed the last architectural issues: DB write contention, screenshot disk bloat, and a hidden double-capture-engine bug. Also investigated why Claude reported "no activity" and corrected a LibreWolf tier1 config error.

---

### 1. LibreWolf Tier1 Bundle ID Fix

**Symptom:** LibreWolf (browser) barely showing in captures — 1 event/day despite heavy browsing.

**Root cause:** Config `tier1BundleIDs` had `io.gitlab.librewolf-community` but the actual bundle ID is `net.librewolf.librewolf`. LibreWolf was excluded from the 5-second per-window polling loop, only captured on app switches.

**Fix:** Corrected bundle ID in `~/.config/activity-tracker/config.json`. (Config lives outside the repo, so no commit needed.)

---

### 2. Investigated "No activity recorded for 8/11"

**Claim:** Claude (via MCP) reported no activity for 8/11.

**Finding:** 669 events existed. Claude's report was wrong — likely a stale MCP connection or the MCP process needing restart.

**Deeper issue discovered while investigating:** capture quality was degraded:
- Only `tier1_poll` trigger firing (669 events)
- No heartbeat/app_switch/typing events — those captures were timing out
- OCR nearly useless (79 events, avg 12 chars)

---

### 3. Full-Screen Capture Timing Out (100% failure)

**Symptom:** `captureScreen()` (full-desktop composite via `kCGNullWindowID`) timed out on every call. 2,104 event-driven captures started → 2,105 timeouts on 8/11.

**Analysis:** Full-screen composite at `.bestResolution` (7,814×4,406 = 15M pixels) is heavy. The 5s timeout abandons the call but doesn't cancel it — the stuck `CGWindowListCreateImage` keeps running, exhausting window-server resources. Feedback loop: abandoned calls pile up → everything times out.

**Status:** Still open — per-window capture is the planned fix (reuse the tier1 code path that works).

---

### 4. Screenshot Disk Bloat (35GB)

**Finding:** Screenshots were full-Retina desktop composites at 8MB each. 2,258/day = ~18GB/day.

**Two fixes applied:**
1. **Downscaling** — new `downscaledPNGData(maxDimension: 2000)` method. 8MB → ~1MB per screenshot (7x reduction).
2. **Purge fix** — `purgeOldScreenshots` was gating deletion on `embedding IS NOT NULL OR is_duplicate OR synced`, so screenshots whose events hadn't been embedded yet were never purged → orphans.

**Backlog cleanup:** Manually deleted 1,781 old files (>24h) + orphaned files + stale DB rows. 35GB → 19GB, settling to ~2-3GB steady-state as old full-res files age out.

---

### 5. DB Write Contention ("database is locked")

**Finding:** Three processes held the DB open concurrently:
1. Collector daemon (`--collector-only`) — writer
2. MCP server instance (Claude Desktop) — reader/writer
3. Stray `.build/release/ActivityTracker` dev process — orphan

**Root cause of locks:** SQLite WAL allows one writer at a time. Multiple connections contending → `SQLITE_BUSY` with no wait.

**Fixes:**
1. `PRAGMA busy_timeout=5000` — connections wait up to 5s instead of failing instantly. This is the idiomatic SQLite solution, not a band-aid.
2. `PRAGMA synchronous=NORMAL` — faster writes.
3. Killed the stray dev process (PID 74692).

**Architecture discussion:** User asked if we need to re-architect the DB. Answer: no — 71MB single-user DB, ~1 write/5s is trivial for SQLite. busy_timeout is correct.

---

### 6. Hidden Double-Capture-Engine Bug (Critical)

**Finding:** When Claude Desktop launched the MCP (`activity-tracker` with no flags), `main.swift` started **ALL subsystems** — capture engine, sync engine, audio capture, AND the MCP server. This meant a second full capture engine ran in parallel with the daemon, both writing to the DB.

**Fix — proper mode separation:**
- `--collector-only` (daemon): capture + sync + audio, read-write DB
- No flags (MCP): MCP query server only, **read-only** DB — never captures or writes

**Database read-only support:** `Database.init(config:readOnly:)` now uses `sqlite3_open_v2` with `SQLITE_OPEN_READONLY`, skips migrations, and doesn't create directories.

---

### 7. Commits This Session

- `5562075` — Fix DB contention and screenshot bloat; MCP read-only mode

---

### 8. Current System State

- **Daemon:** Stable, capturing via AX (tier1) + OCR fallback
- **MCP:** Read-only query mode, no longer starts a second capture engine
- **DB:** busy_timeout + synchronous=NORMAL, no more lock errors
- **Screenshots:** Downscaled to ~1MB, purged 35GB → 19GB (settling to ~3GB)
- **LibreWolf:** Now in tier1 polling with correct bundle ID

### 9. Known Remaining Gaps (updated)

1. **Full-screen capture still broken** — event-driven captures (heartbeat/app-switch) time out; need per-window capture fix
2. **OCR nearly useless** — avg 12 chars; browser text not captured well
3. **Startup backfill disabled** — run `make backfill` manually
4. **No app exclusion list** — captures everything
5. **VS Code chat harvester** — planned, not implemented
6. **Claude Desktop needs restart** to pick up read-only MCP binary

---

## 2026-08-13

### Session Summary
Fixed Claude's recurring "no activity" false reports. Root cause was two-fold: no MCP tool could express a time-of-day range, and `list_sessions` LIMIT 50 truncated to evening sessions only.

---

### 1. Added get_activity_range MCP Tool

**Symptom:** Claude repeatedly reported "no activity from 8am-4pm" when data clearly existed (5,983 events on 8/12, every hour populated).

**Root cause:** No MCP tool could express a time-of-day range:
- `search_activities` — keyword only
- `get_recent_activity` — "last N minutes" only (can't reach back to yesterday)
- `list_sessions` — date filter only, no time-of-day

**Fix:** New `get_activity_range` tool accepting `start`/`end` ISO timestamps. Normalizes to UTC, returns both `captured_at` (UTC) and `captured_at_local`. Also handles `T`-separated no-timezone input (assumes local time).

**Commit:** `bf04038`

---

### 2. Session Churn Race (146 sessions/day)

**Symptom:** 8/12 had 146 sessions (should be ~20). `list_sessions` LIMIT 50 showed only evening sessions, hiding the entire morning.

**Root cause — concurrency race:** `capture()` checked `currentSession == nil` then called `await startNewSession()`. The await suspended the actor, allowing concurrent captures to also see `nil` and each create a session. Many sessions started at the exact same second.

**Fix:** Set `currentSession` synchronously BEFORE the await in `startNewSession()`, so concurrent captures share one session. Also increased `list_sessions` LIMIT 50 → 200.

**Note:** Claude's "sync theory" was wrong — MCP tools read the local SQLite directly; sync only affects homellm push.

**Commit:** `f900dda`

---

## 2026-08-14

### Session Summary
Second DB corruption recovered; disabled SQLite mmap (root cause); fixed idle detection (IOKit); fixed the deploy workflow that was killing the daemon; reduced heartbeat frequency.

---

### 1. Second DB Corruption + mmap Root Cause

**Symptom:** Events "storing" in logs but not persisting; latest event 6.5h stale. `PRAGMA integrity_check` → "database disk image is malformed".

**Root cause:** Crash report showed SIGSEGV in SQLite's `purgeableCacheFetch → _platform_memset` — the macOS SQLite memory-mapped I/O path. Same crash class as the first corruption on 8/6.

**Fixes:**
1. Recovered 25,946 events + 437 sessions via `.recover` (nothing lost)
2. `PRAGMA mmap_size=0` — forces normal page cache, avoids the crash-prone purgeable mmap path entirely

**Commit:** `91c293b`

---

### 2. Idle Detection Fix (IOKit)

**Symptom:** Tracker kept capturing while user away. `CGEventSource.secondsSinceLastEventType(.mouseMoved)` returned a constant small value, so idle never fired.

**Root cause:** The `mouseMoved` event type is unreliable in `secondsSinceLastEventType`. Earlier fix attempt (8/12) also missed mouse movement entirely.

**Fix:** Switched to IOKit `HIDIdleTime` (`IOHIDSystem` registry property) — the canonical screensaver-grade idle source that counts keys, clicks, scroll, and cursor movement in one value. Also handles wake-from-idle by firing a capture on activity resume.

**Commit:** `11d6bec`

---

### 3. "Code Signature Invalid" Kill — Deploy Workflow Bug

**Symptom:** Recurring "background item added" popups and tracker "stopping." 

**Root cause:** Replacing the signed binary (`cp` + `codesign`) while the daemon ran caused macOS to SIGKILL the process with "Code Signature Invalid" (in-memory pages no longer matched on-disk signature). launchd restarted it → popup. This happened on every deploy.

**Fix:** `make install` now unloads the daemon BEFORE replacing the binary. Safe workflow: stop → replace → sign → start.

**Commit:** `65c1549`

---

### 4. Heartbeat Frequency Reduction

**Finding:** `heartbeatIntervalSec` had been set to 5 (from default 30) — full screenshot every 5s while active.

**Fix:** Set to 15s in config (user choice). Confirmed ~3 heartbeats/35s after change.

---

### 5. Commits This Session

- `91c293b` — Disable SQLite mmap
- `242a54b` — Fix idle detection (mouse movement) — *superseded by IOKit fix*
- `11d6bec` — Replace CGEventSource idle polling with IOKit HIDIdleTime
- `65c1549` — Unload daemon before replacing binary in make install

---

### 6. Key Lessons Learned (cumulative)

1. **Never replace a signed binary while it runs** — macOS kills it with "Code Signature Invalid"
2. **SQLite mmap is crash-prone on macOS** — always `PRAGMA mmap_size=0`
3. **`CGEventSource.secondsSinceLastEventType(.mouseMoved)` is unreliable** — use IOKit HIDIdleTime for idle detection
4. **Actor + await = race window** — set state synchronously before awaiting
5. **Diagnostic SQL must wrap timestamps in `datetime()`** — raw string comparison of `T`-separated vs space-separated ISO strings is wrong
6. **MCP tools read local DB directly** — sync status is irrelevant to queryability

---

## 2026-08-17

### Session Summary
Fixed a total capture stall caused by AX-extraction thread pile-up. The 3s AX timeout abandoned callers but never cancelled the blocking `AXUIElementCopyAttributeValue` calls, so each timed-out extraction leaked a permanently-blocked GCD thread. Over hours these accumulated until the global thread pool was exhausted and the whole pipeline stalled.

---

### 1. AX Thread Pil be-Up (capture stall)

**Symptom:** Daemon alive but last persisted event ~40min stale. `capture(heartbeat) starting` logged with no completion. Tier1 polls running at ~3min intervals instead of 5s.

**Diagnosis:**
- `sample` of the daemon: 452/1021 samples stuck in `AXUIElementCopyAttributeValue` → `_AXMIGCopyAttributeValue` → `mach_msg` (window-server IPC), spread across dozens of `com.apple.root.user-initiated-qos` threads

- 1,036 "AX extraction timed out" log lines
- Root cause: `extractViaAX` spawned each AX walk on a fresh `DispatchQueue.global(qos: .userInitiated)` thread. The 3s semaphore timeout resumed the caller (fall back to OCR) but **did not cancel the blocking AX call** — the abandoned thread stayed stuck in window-server IPC forever
- Feedback loop: stuck AX threads exhausted the GCD user-initiated pool → new timeout waiters and `captureScreen()` couldn't get scheduled → `processEvent` hung → serial `extractionQueue` blocked → no events persisted

**Fix (`Sources/TextExtractor.swift`):**
- Dedicated **serial** AX queue (`activity-tracker.ax`) — all AX walks run on one thread
- Non-blocking `axGate` semaphore (capacity 1) — if an AX walk is still stuck, skip AX and fall straight to OCR instead of piling up another blocked thread
- Dedicated concurrent OCR queue (`activity-tracker.ocr`) + `ocrGate` (capacity 2) to bound Vision concurrency
- Timeout waiters moved to `DispatchQueue.global(qos: .utility)` so they don't contend with the user-initiated pool

**Result:** Bounded stuck AX calls to at most one; captures resumed immediately after redeploy.

**Commit:** `63a8b3d`

---

### 2. Key Lesson

- **A timeout that abandons a blocking call without cancelling it leaks the thread** — on APIs like `AXUIElementCopyAttributeValue` that can block in kernel IPC, you must bound concurrency (gate/serial queue), not just time out the caller.

---

## 2026-08-18

### Session Summary
Explored using Ollama + qwen3:14b to scan Obsidian project `.md` files and report which are still in progress, comparing Obsidian-plugin performance against a terminal script. No code committed — produced two temporary untracked test scripts in the repo root.

---

### 1. Ollama / qwen3:14b Project-Scan Test

**Goal:** Have a local model read `~/Library/CloudStorage/Dropbox/OBSIDIAN/Projects/*.md` and report which projects are still in progress (status != done/canceled), to compare Obsidian vs terminal performance.

**Environment:** Ollama 0.24.0 on Apple M4 Pro (48GB). Models present: `qwen3:14b` (14.8B, Q4_K_M, 40,960 ctx, thinking mode) and `qwen2.5-coder:14b`.

**Work:**
- Confirmed Ollama is a model runner, not a file scanner — no native file-read. qwen3 exposes a `tools` capability (tool calling), which is the path to file access.
- Created two temporary scripts (both untracked, not committed):
  - `scan_projects_ollama.py` — explicit classification with timing (model load, TTFT, throughput)
  - `scan_projects_reasoning.py` — reasoning test: raw `.md` files with NO instructions; model must infer file semantics, how status is recorded, and collate not-done projects

**Hang / cold-load:** First run hung for 2+ minutes with no response. Not a bug — cold model load. After an Ollama upgrade the model ran 100% GPU (11GB, 32,768 ctx).

**Cold vs warm benchmark (7,610-token prompt):**

| Metric | Cold | Warm |
|---|---|---|
| Model load | 1.93 s | 0.11 s |
| Prompt ingest | 41.5 s (183 tok/s) | 0.07 s |
| First answer token | 95.3 s | 51.2 s |
| Wall clock total | 116.8 s | 72.6 s |

Decode ~19.2 tok/s (~65% of the ~30 tok/s M4 Pro bandwidth ceiling). Chose 16,384 context window for the test.

---

### 2. Key Lesson

- **Local model "no response" is often a cold load** — first prompt ingest on a fresh model is ~40s for ~7.6k tokens. Check `ollama ps` for load state before assuming a hang.

---

### Commits This Session

- None — two temp scripts left untracked in repo root.

---

## 2026-08-21

### Session Summary
Implemented the VS Code Copilot Chat harvester (planned since 2026-08-05). Harvests chat transcripts into the activity DB as `copilot_chat` events, linked by timestamp to screen-capture context. Decision: transcripts only (not debug logs), as a Python script + hourly launchd job rather than a Swift in-daemon worker.

---

### 1. Source Evaluation: Transcripts vs Debug Logs

- **Transcripts** (`workspaceStorage/*/GitHub.copilot-chat/transcripts/*.jsonl`, 91 files) are a full event stream: `session.start`, `user.message`, `assistant.message` (content + `toolRequests` + `reasoningText`), `assistant.turn_start/end`, `tool.execution_start/complete`. Producer is always `copilot-agent`. This is the "what & why" layer — sufficient for work-context reconstruction.
- **Debug logs** (`debug-logs/<session>/…`, 1,228 files) are OpenTelemetry-style span traces (`ts`, `dur`, `sid`, `spanId`, `status`, `attrs`) — the "how" layer (per-span timing, failures, model + token counts). Deferred as optional future enrichment.
- **Verdict:** transcripts alone are sufficient; debug logs add little for the stated goal.

### 2. Harvester Implementation

- `scripts/harvest_vscode_chat.py` — pairs each `user.message` with the assistant prose that follows it (sequential turn pairing); if a transcript has no `user.message`, emits one event per transcript from the assistant content. Fields:
  - `source_type = copilot_chat`, `trigger = copilot_chat_import`
  - `window_title` = workspace name (resolved from `workspace.json` folder URI)
  - `text_content` = `Prompt: …\nResponse: …` (capped at 1200 chars each)
  - synthetic daily sessions (`vc_` prefix), dedup via `dedup_key = vc_<md5(session+message-id)>`
  - inserts unembedded; embedding is a separate step
- `launchd/com.activitytracker.harvest.plist` — `StartInterval=3600`
- Makefile targets: `harvest-chat`, `harvest-embed`, `harvest-install`; harvest added to `daemon-uninstall`

**Why Python + launchd instead of a Swift worker or cron:**
- Scraping/JSON munging is Python's sweet spot; Swift would be verbose.
- Avoids the daemon rebuild → re-sign → TCC re-grant pain on every harvester tweak.
- macOS cron is unreliable when the machine sleeps; launchd `StartInterval` is the native, reliable equivalent, and the repo already uses launchd plists.

### 3. Initial Import + Embedding

- Import: **984 events** from 91 transcripts, **45** synthetic daily sessions. Idempotent (re-run skipped all 984).
- Embedding via `make harvest-embed`: 979/984 succeeded, 5 failed with `rc:-6` (SIGABRT).

**Root cause of the 5 failures:** `llama-embedding` SIGABRTs (`GGML_ASSERT(i01 >= 0 && i01 < ne01)` in `ggml_compute_forward_get_rows`) when the tokenized input exceeds its 512-token batch limit. The 5 texts are token-dense lists (space-separated SIDs/hostnames), where ~200 words → ~550 tokens. This corrects the earlier assumption that `rc:-6` meant corrupted text.

**Fix (`scripts/backfill_embeddings.py`):** on `rc:-6`, retry with progressively shorter input (100 → 60 → 30 → 15 words). First attempt of the retry loop broke early when the text was already shorter than the first cap; fixed to skip caps that don't actually shrink the text.

**Result:** 984/984 chat events embedded.

### 4. Commits This Session

- `b4cce7c` — Add VS Code Copilot Chat transcript harvester (script + hourly launchd job)
- `7100e0d` — Retry embedding with shorter text on SIGABRT

### 5. Key Lessons

- **`rc:-6` from llama-embedding = token-count overflow, not corrupted text** — token-dense input (ID/hostname lists) exceeds the 512-token batch; word count is a poor proxy for token count. Retry with shrinking input.
- **Transcripts carry tool calls + reasoning, not just prompts** — richer than the original journal plan assumed.

---

## 2026-09-01

### Session Summary
Audio capture audit. Found meetings were never detected because the config listed the old Teams bundle ID (`com.microsoft.teams`), but the machine runs the new Teams client (`com.microsoft.teams2`). Added the new ID, confirmed mic permission is granted, and added a peak-RMS diagnostic to settle whether the mic tap actually delivers audio.

---

### 1. Meetings Not Detected (New Teams Bundle ID)

**Symptom:** User had meetings today; `audio_segments` table still empty (0 rows ever).

**Findings:**
- Events show `com.microsoft.teams2` frontmost 75× today — the user is on **new Microsoft Teams** (2.0)
- Config `meetingBundleIDs` contained `com.microsoft.teams` (classic), which is **not installed** on this machine (`mdfind` → NOT FOUND)
- So `MeetingDetector.isMeetingActive()` never matched during Teams calls
- The only two meeting detections in the whole log history (8/10 Slack huddle, 9/1 LibreWolf "huddle" title) both ended with **0 speech segments**

**Fix:**
- Added `com.microsoft.teams2` to `meetingBundleIDs` in both `~/.config/activity-tracker/config.json` and `Sources/Resources/config.default.json`
- Reloaded the running daemon via SIGHUP (config reload confirmed in logs)

**Mic permission check:** TCC `kTCCServiceMicrophone` for `/Users/phillip/.local/bin/activity-tracker` is `auth_value=2` (ALLOWED) — permission is NOT the blocker.

### 2. Peak-RMS Diagnostic

**Why:** The two prior meeting detections both produced 0 speech segments with no error logged, so it's unclear whether the AVAudioEngine mic tap delivers real audio or silence.

**Change (`Sources/AudioCapture.swift`):**
- Track `peakRMS` (loudest chunk RMS) per meeting
- Refactored VAD to share a `rmsLevel()` helper
- `endMeeting()` now logs `peak RMS` alongside segment count

**Interpretation next meeting:**
- `peak RMS ≈ 0` → mic tap delivers silence (tap format/permission issue)
- `peak RMS` high but 0 segments → VAD threshold (500) too high
- Both nonzero → transcription is the next thing to verify

### 3. Commit

- *(this session)* — Add `com.microsoft.teams2` to meeting bundle IDs + peak-RMS diagnostic

---

## 2026-09-02

### Session Summary
Meetings are now detected and audio flows (peak RMS up to 13k), but nothing was being stored. Fixed two bugs: a WAV sample-rate mismatch that made whisper transcribe at the wrong speed, and a meeting-flapping race that clobbered state mid-transcription.

---

### 1. Meetings Detected, Audio Flowing, Zero Stored

**Symptom:** `meeting started (com.microsoft.teams2)` fires repeatedly and `meeting ended, N speech segments, peak RMS X` shows real audio (RMS 500–13,000), yet `audio_segments` stays at 0 rows and there are no whisper error logs.

**Root cause — WAV sample-rate mismatch (`writeWAV`):**
- The AVAudioEngine tap runs at the mic's **native** sample rate (44.1/48 kHz), but `writeWAV` hardcoded `sampleRate = 16000`
- whisper-cli read the 48 kHz PCM as 16 kHz → audio played ~3× too slow → garbage/empty transcript → `insertAudioSegment` never called (and empty-transcript path logs nothing)

**Root cause — meeting-flapping race (`endMeeting`):**
- Teams becomes frontmost/loses frontmost every few seconds, so meetings start and end rapidly
- `endMeeting()` awaited `transcribeAudio` (10–30s) before clearing state, then read `currentMeetingSession?.id` and `currentMeetingApp` *after* the await
- A new `startMeeting()` could run during that await and replace the session/app; the delayed resume then inserted the old transcript under the **new** session id and clobbered the new meeting's state (nil-ing `meetingStartTime`/`currentMeetingSession`), so the next meeting was never transcribed

**Fixes (`Sources/AudioCapture.swift`):**
1. Capture the real sample rate at engine setup (`inputNode.outputFormat(forBus: 0).sampleRate`) and write it into the WAV header; log the mic format at meeting start
2. Rewrote `endMeeting` to snapshot `session`, `meetingApp`, and `fullAudio` into locals and clear actor state **before** any `await`, so a delayed transcription can't clobber a newer meeting
3. whisper-cli resamples internally, so writing the correct rate is sufficient — no explicit 16 kHz downsampling needed

### 2. Commit

- *(this session)* — Fix WAV sample rate + endMeeting race so meetings actually store transcripts

---

## 2026-09-03 – 2026-09-04 (recorded retroactively)

Not journaled at the time; reconstructed from commits.

- `4d4f8c5` — Fix whisper transcript output path (`.wav.txt`, not `.txt`)
- `69dd0f9` — Detect meetings via window presence + mic usage, not focus
- `33f386d` — Capture frontmost window for event triggers, keep full-screen heartbeat
- `1aeab3a` — Snapshot the call window, not the main app window, for meeting end detection
- `99d5533` — Close dangling sessions on startup
- `be5ef0e` — Add meeting transcript tools to MCP server

This supersedes the 8/12 note that full-screen capture was still broken: event-driven
captures now use the frontmost window, with the full-screen composite reserved for
heartbeat only.

---

## 2026-09-17

### Session Summary
Cleared the embedding backlog, made the backfill fast and self-healing, and finally
built the semantic search the embeddings were always meant to feed. Also settled the
"should duplicates be embedded" question with measurements rather than opinion.

---

### 1. The Backlog Was Not 56,000 Rows

The headline "56,293 unembedded events" decomposed into mostly non-problems:

| Bucket | Rows | Verdict |
|---|---|---|
| Duplicates (`is_duplicate = 1`) | 47,252 | By design — deliberately inserted with `embedding: nil` |
| No text content | ~5,800 | Not embeddable |
| Non-duplicate rows with text | **3,362** | The real backlog |

**Why it kept growing:** `processEvent` embeds fire-and-forget —
`extractionQueue.async { Task { ... } }` with no retry. If the embed returns nil
(server busy, oversized input, daemon restart mid-flight) the row stays `NULL`
forever, invisible to semantic search. That leak was running at ~300-500 rows/day.

### 2. Backfill Now Goes Through the Embed Server

`scripts/backfill_embeddings.py` spawned `llama-embedding` per row, reloading the
model each time. It now POSTs batches of 32 to the resident `llama-server` — the
same endpoint the daemon embeds through, so vectors are identical to live captures.

**Result: 3,362 rows in 3 minutes, 0 failures** (previously hours).

Two distinct token-limit failures were being conflated:
- Prose that is token-dense (SID/hostname lists) → word caps work
- An 829-char SAML URL — a *single* whitespace word, hundreds of tokens → word caps
  can never shrink it; character caps (600/300/150/75) are required

The server reports this as `HTTP 500 — input (524 tokens) is too large to process`,
which is the same condition as `llama-embedding`'s historical `rc:-6` SIGABRT.

### 3. Self-Healing Sweep

Added `com.activitytracker.embedbackfill` (`make embedbackfill-install`) — every 30
minutes, capped at 2,000 rows. Deliberately a launchd job rather than re-enabling the
in-daemon `startEmbeddingBackfill()`: no Swift rebuild, no binary re-sign, no TCC
re-grant. It found and embedded 2 leaked rows within 20 minutes of being installed.

### 4. Duplicates: Measured, Not Guessed

- All four query sites filter `is_duplicate = 0`, so a duplicate's vector would be
  unreachable by any tool that exists.
- 27,541 of 47,282 duplicates (58%) share a `dedup_key` with an already-embedded row.
- **The "embed and compare" test:** cosine similarity between consecutive same-app
  captures — only **0.3%** exceed 0.98, and 90.7% fall in 0.50-0.90. Exact-hash
  dedup is not letting meaningful near-duplicates through, so a similarity-based
  collapse would add real complexity to catch ~7 rows/day. Mean of 0.70 is explained
  by D18: each row's vector represents the *diff*, not the full text.

**Decision: leave duplicates unembedded.** If temporal completeness ("was this on
screen at 3pm?") ever matters, the cheap route is resolving a duplicate through its
`dedup_key` twin at query time — 8 bytes of index, no 4KB vector per row.

### 5. Semantic Search

`search_activities` is now hybrid. The TODO at `MCPServer.swift` ("when llama.cpp is
integrated, this becomes semantic search") is closed.

**Threshold calibrated against real data:** genuine matches score 0.72-0.78,
unrelated content tops out near 0.60, and a query with no real answer peaked at
0.597. A 0.62 floor therefore returns *nothing* rather than least-unrelated noise.

**Fusion is additive, not reciprocal-rank.** This came out of measurement, not
theory. RRF initially looked correct — then a query for a ticket id that exists
verbatim in 1,455 rows returned five semantic near-misses and zero of the real
matches. The reason: the semantic list is ordered by relevance, but a `LIKE` result
set is ordered by *recency*, so its rank position carries no information. Weighting
it cannot fix that; only a boost can.

**And a boost alone wasn't enough either.** Keyword candidates that don't reach the
semantic top-k have no similarity score, so they could only ever contribute their
small boost and lost to every semantic hit — the same query still returned none of
its 1,455 matches. Fixed by scoring those candidates directly
(`SemanticSearch.similarities`: one dot product per id, ~15 of them) so
`score = similarity + boost` holds for every candidate.

Final weights: **+0.10** for a literal hit on a distinctive identifier, **+0.08**
for a window-title/app-name match, **+0.02** for a common word in a large OCR blob.
Measured justification for the 0.10: the ticket id scored 0.68 against a screen that
was merely *similar* at 0.75, so the boost has to exceed that gap for literal
presence to win — which it now does (all five top hits for `DBAAAS-1361` contain it).

Other details:
- De-duplication on `app + first 200 chars`, because one screen can produce hundreds
  of near-identical rows (the same Slack window captured 5s apart filled the top 5).
- Brute-force scan, no vector index: streams `(id, embedding)` and keeps a bounded
  top-k, so text is never copied for a row that won't be returned. vDSP dot product
  on a reused scratch buffer. Stored vectors verified unit-length (norms 1.0000
  across 40k rows) so cosine reduces to a dot product. ~500ms over ~75k rows,
  ~130ms when a time range narrows the set.
- New optional `start`/`end` parameters on the tool.
- If the embed server is down, it degrades to keyword-only *and says so*, rather
  than reporting a false "no activity found" — the failure mode that caused the
  original Claude Desktop confusion.

### 6. Findings Left Open

1. **Sync outbox: 975MB across 820 files, growing ~100MB/day since 2026-08-03.**
   `SyncEngine` writes a ~2MB file every 30 min and marks rows `synced=1`, but
   nothing deletes or acknowledges them — `synced` means "written to outbox", not
   "delivered". No consumer found: no local homellm repo, nothing outside this repo
   references `sync-outbox`, and `syncTarget.password` is empty (though
   `192.168.1.33:5433` is reachable). Opt-in retention was added
   (`syncOutboxRetentionDays`, default 0 = keep everything) rather than deleting
   data whose consumer couldn't be verified.
2. **Repo defaults still ship the wrong LibreWolf bundle id.** The 8/12 fix went
   only into `~/.config/activity-tracker/config.json`, which lives outside the repo,
   so `Sources/Config.swift` and `Sources/CaptureEngine.swift` would reintroduce the
   bug on a fresh clone. Corrected.
3. **The daemon's embed retry gap still exists.** The 30-minute sweep papers over it;
   a proper fix is retry/backoff in the capture path.
- **A boost only works if the boosted candidate also has the base score.** Keyword
  rows outside the semantic top-k had no similarity, so the boost couldn't lift them
  above anything — a subtle ordering bug that only a real query exposed.
- **The Swift compiler can hang instead of erroring.** Two expressions — a
  `guard let x = try? a.b().c, x < y` chain, and `.map{}.filter{}.sorted{ternary}`
  chained over `Dictionary.Values` with `[String: Any]` payloads — pinned one
  frontend at 100% CPU for 10+ minutes with no output, in both debug and release.
  Rewriting them with explicit types and plain loops took the build from hung to
  **4-6 seconds**. Worth knowing: a stalled build is not always a slow machine.
  (That said, Microsoft Defender pegging ~300% CPU also made builds crawl, so check
  `ps -Ao %cpu,comm | sort -rn` before blaming the compiler.)
- **Timestamp comparison got me again.** `captured_at` is `YYYY-MM-DDTHH:MM:SSZ`, so
  comparing it against `datetime('now','-5 minutes')` (space separator) matched the
  entire day, because `T` > ` ` lexicographically. I briefly misread a 5-minute
  window as 1,872 heartbeats before spotting it. This is the *same* mistake recorded
  on 2026-08-12 — wrap the column: `datetime(captured_at) > ...`.

---

## 2026-09-17 (later) — Outbox retired in favour of a direct DB→DB sync

### Context

Confirmed: **there is no homellm integration yet.** The outbox had therefore never
had a consumer — 823 files, 978MB, and `synced=1` on 81,543 rows meant "written to a
file nobody reads", not "delivered". The spec's D10/D13 always described a direct
push ("TCP health check to pgvector port → push batch"); the file drop only existed
because there was no Postgres client in Swift. But the *reader* doesn't have to be
Swift.

**Decision (user): read from one database and write to the other.**

### What was built

`scripts/sync_to_pgvector.py` — reads local SQLite, upserts into
`activity_events` on homellm. Plain Python, so the Swift daemon stays free of a
Postgres dependency, which is the constraint the spec was working around.

- **Migration v3** adds `events.pg_synced` (plus the same column on
  `audio_segments`) and an index.
- **`sync-setup` / `sync-check` / `sync-pgvector` / `sync-dry-run`** Makefile targets.
- Driver is **pg8000** — pure Python, so no compilation and no platform wheels. The
  first attempt with `psycopg[binary]` failed against the pyenv Python 3.9 shim
  (ancient pip, no matching wheel); pg8000 sidesteps that class of problem entirely.

### Why a separate queue flag

`pg_synced` is deliberately *not* `synced`. The daemon's file exporter sets
`synced`, and if the new sync used the same column, whichever mechanism ran first
would mark rows done and silently starve the other. With two flags the two
mechanisms are fully independent and the migration is additive — no daemon
behaviour change, nothing ripped out before the replacement is proven.

### Credentials

Never in the repo. Resolution order: `PGPASSWORD` → macOS Keychain (service
`activity-tracker-pgvector`) → `syncTarget.password`. The missing-password error
prints the exact `security add-generic-password` command, which prompts, so the
value never enters shell history or a chat log.

### Path chosen, and the one not taken

I set aside the "laptop streams over SSH, homellm writes locally" option: SSH to
`192.168.1.33` is denied for key auth, and it would have meant deploying and
debugging a script on a machine I cannot inspect. The direct-push path runs entirely
on a machine I can verify, at the cost of holding DB credentials here (worth
revisiting if that matters later).

### Verification without a live target

I can't reach the remote DB, so I verified everything up to the wire:

- `--dry-run`: **81,703 rows pending, 409 batches**, sample payloads with vectors
  present (~10.6KB per vector as pgvector text input).
- Missing-password path returns the actionable Keychain command, exit 2.
- A fake-cursor harness captures the generated INSERT and asserts: placeholder count
  equals param count (36 for 3 rows), the declared column list matches, params follow
  column order with `machine_id` sourced from `sessions`, the vector literal is
  well-formed at 1024 dims, `ON CONFLICT (id) DO NOTHING` is present, and NULL/short
  blobs degrade to NULL instead of crashing.

That harness caught two real things: `fetch_batch` initially selected
`e.machine_id`, which doesn't exist (it lives on `sessions`) — and when I fixed the
test's expectations, I had mis-mapped `app_bundle_id` vs `app_name` myself. Writing
the assertion forced the mapping to be explicit rather than assumed.

### Still outstanding

1. **Add the Postgres password to the Keychain**, then `make sync-check` →
   `make sync-pgvector`. First run pushes ~82k rows; later runs only new events.
2. The legacy outbox still runs (harmless, independent, ~34MB/day). Retiring it
   means removing the `performSync` export path, repointing `get_sync_status` at the
   `pg_synced` queue, then deleting the files.
3. Audio segments have a `pg_synced` column and a remote table, but aren't pushed yet.

---

## 2026-09-17 (evening) — pipeline throughput, and a config regression I introduced

### 1. The live embedder now actually batches

`drainViaServer` accumulated texts for 3 seconds and then issued **one HTTP POST per
text, sequentially**. The endpoint accepts an array and returns a vector per input —
which the 30-minute sweep script already exploited, so the two paths disagreed and the
hot path was the slow one. Now the accumulated chunk goes out as a single request
(chunks of 64), with a per-text fallback if the request as a whole fails, since any
single input over the server's 512-token physical batch rejects the entire request.

Verified in the running daemon: `[Embedder] batched 5 text(s) in one request`.

### 2. Embed failures are no longer silent

The live path was `if let emb = ... { try? updateEmbedding }` — a failure left the row
NULL with no log line at all, which is precisely how a 56k backlog grew unnoticed.
Failures now log, and the `updateEmbedding` error is caught rather than `try?`-swallowed.

**A follow-on mistake worth recording:** the first version of that log claimed
"left for the embed sweep" for *every* nil result. Two rows tripped it, and the sweep
then reported `failed=0, remaining=0` — because those rows had **empty** text (AX
returned nothing), `embed()` short-circuits on empty input, and the sweep filters
`LENGTH(text_content) > 0`. So the message promised a retry that could never happen.
Now empty captures are skipped before dispatch (~5,900 such rows exist) and the log
line only fires for genuine failures. Chasing this is what uncovered the config bug below.

### 3. `get_sync_status` reports the real queues

It reported only the legacy file export's `synced` count, which says nothing about
whether recent activity is searchable. It now returns `embed_queue`, `ship_queue` and
`legacy_outbox_queue` with a `queue_meaning` map, because "3,000 pending" is useless
without knowing what the queue feeds.

### 4. Config regression (mine) — and the fix

Adding `syncOutboxRetentionDays` to `Config` **broke decoding of the existing config
file**:

```
config load failed, using defaults: keyNotFound(... "syncOutboxRetentionDays" ...)
```

Swift's synthesised `Codable` throws on a missing key rather than falling back to the
property's default value — property defaults only apply to the memberwise initialiser.
Because decoding is all-or-nothing, that one absent key failed the *whole* decode and
`main.swift` substituted a fresh `Config()` — so **every** setting reverted to its
default, not just the new one.

**Measured impact** (correcting an earlier guess of "about five minutes"): the first
build carrying the field was installed at 18:43:32 and the fix at 21:23:10, so the
daemon ran on default settings for **2h39m across four restarts**. During that window:

- 1,093 events captured normally — no data loss, nothing written elsewhere
- heartbeats ran at 30s instead of the configured 15s (fewer full-screen captures)
- `teams2` was absent from the effective meeting bundle ids, so a Teams call would not
  have been detected. Teams happened not to be used in that window (0 teams2 events,
  0 audio segments), so it cost nothing in practice — luck, not design.

Fixed by overlaying the file's JSON onto the encoded defaults (recursively, so a
partially-specified `syncTarget` can't lose its defaults either) and logging which keys
were absent. Also added a startup line with the effective values:

```
config loaded
  heartbeat=15s tier1=6 apps meetings=4 ids audio=meetings_only outbox_retention=0d
```

That line is the real fix for the *class* of problem: the previous failure mode was
invisible unless you happened to read one line of startup log. Verified against the
live daemon — 15s and 4 meeting ids could only come from the config file, since the
defaults are 30s and 3.

Note the earlier attempt to prove this by heartbeat *cadence* was invalid: heartbeats
measured 2/min both before and after, because a full-screen heartbeat capture is heavy
enough that the effective period is ~30s regardless of a 15s timer. Measuring the
config directly beat inferring it from behaviour.

### 5. Key Lesson

**Adding a field to a `Codable` config struct is a breaking change** unless decoding
tolerates absent keys. The failure is silent, total (every setting reverts to defaults,
not just the new one), and easy to miss. Anyone adding a config setting to this repo
should add it to `Config` and rely on the defaulting decode — and check the startup log
line, which now shows what actually loaded.

---

## 2026-09-17 (night) — Outbox exporter switched off

Confirmed the outbox has exactly one purpose, by enumerating every use of the flag
rather than assuming:

| Consumer of `synced` / the outbox | Role |
|---|---|
| `SyncEngine.swift` | writes the files, sets `synced` — the whole mechanism |
| `EventStore.swift` | `unsyncedEvents` / `markSynced` / `unsyncedCount` — its own helpers |
| `MCPServer.swift` | only *reported* the count, no behaviour |
| `CaptureEngine.swift` | **no use at all** |

That last row was the one that mattered: screenshot purging does *not* depend on
`synced` (that coupling was removed in the 8/12 purge fix), so nothing functional hangs
off it. Nothing reads the files either — verified by grepping the whole repo for
`sync-outbox` outside `SyncEngine` and the README.

So the exporter is now off by default via `syncOutboxEnabled: false`, with `performSync`
returning early and a comment pointing at the replacement. It's a switch rather than a
deletion, so the mechanism stays available if the file-drop approach is ever wanted.

Also dropped `legacy_outbox_queue` from `get_sync_status`: with the exporter off, that
count could only grow (nothing sets `synced` any more) and describe nothing. `MCPServer`
doesn't receive the config, so it can't conditionally report it — the honest fix was to
stop reporting it. Status now covers the two queues that have real consumers.

Verified after deploy: outbox file count unchanged (834 before and after a restart), no
new rows in `sync_log`, daemon still capturing. The config came up with
`absent keys keep their defaults: syncOutboxEnabled, syncOutboxRetentionDays` — the
defaulting decoder added earlier tonight handled a brand-new key cleanly, which is
exactly the case that broke everything this afternoon.

The 990MB of existing files were deliberately **not** deleted; the README says how, and
the rows behind them are all in the local DB. Those rows carry `synced = 1`, not
`pg_synced`, so the direct sync still queues every one of them.

### 7. Key Lessons

- **A missing row and a missing embedding look identical to a query.** Both produce
  silence, so the failure is invisible until you measure the table directly.
- **Exact-hash dedup is not the same as semantic redundancy** — measured 0.3%, so
  this was worth testing rather than assuming.
- **Rank fusion assumes both lists rank by relevance.** A recency-ordered `LIKE`
  result set is not a ranking, and fusing it by rank silently buries exact matches.
- **Word count is a poor proxy for token count** (an 829-char URL is one word), and
  character caps are the only reliable way to shrink pathological input.



