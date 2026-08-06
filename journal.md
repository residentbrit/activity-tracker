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
