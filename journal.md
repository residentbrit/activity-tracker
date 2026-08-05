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
