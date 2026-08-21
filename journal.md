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

