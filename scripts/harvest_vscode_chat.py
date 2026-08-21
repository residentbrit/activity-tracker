#!/usr/bin/env python3
"""Harvest VS Code Copilot Chat transcripts into the activity-tracker DB.

Reads every `GitHub.copilot-chat/transcripts/*.jsonl` under VS Code's
workspaceStorage, extracts user prompts + assistant responses (one event per
user message; one fallback event per transcript if it has no user messages),
and inserts them as `copilot_chat` events linked to synthetic daily sessions.

Idempotent: skips transcripts whose dedup_key is already present.

Embedding is NOT done here — run the embedding backfill separately:
    ./scripts/backfill_embeddings.py --trigger copilot_chat_import

Usage:
    python3 scripts/harvest_vscode_chat.py [--dry-run] [--limit N]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

STORAGE_DIR = Path.home() / "Library" / "Application Support" / "Code" / "User" / "workspaceStorage"
ACTIVITY_DB = Path.home() / ".local" / "share" / "activity-tracker" / "activity.db"

SOURCE_TYPE = "copilot_chat"
TRIGGER = "copilot_chat_import"
APP_BUNDLE_ID = "com.microsoft.VSCode"
APP_NAME = "VS Code"
MACHINE_ID = "vscode-chat-import"

MAX_PROMPT_CHARS = 1200
MAX_RESPONSE_CHARS = 1200


def workspace_name(workspace_dir: Path) -> str | None:
    """Resolve a human-readable workspace name from workspace.json's folder URI."""
    try:
        data = json.loads((workspace_dir / "workspace.json").read_text(encoding="utf-8"))
    except Exception:
        return None
    folder = data.get("folder") if isinstance(data, dict) else None
    if not folder:
        return None
    try:
        path = urlparse(folder).path
    except Exception:
        return None
    name = os.path.basename(path.rstrip("/"))
    return name or None


def normalize_ts(ts: str | None) -> str:
    """Normalize an ISO-8601 timestamp to UTC 'YYYY-MM-DDTHH:MM:SSZ'."""
    if not ts:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        # Best-effort: strip fractional seconds and keep as-is.
        return ts[:19] + "Z"


def parse_transcript(path: Path) -> list[dict]:
    """Parse one transcript JSONL into a list of exchange dicts.

    Each exchange: {ts, dedup, prompt, response}. Assistant text messages are
    paired with the user message that precedes them (sequential turn pairing).
    Leading assistant text (before any user message) is attached to the first
    exchange; if the transcript has no user messages at all, a single exchange
    is synthesized from all assistant text.
    """
    exchanges: list[dict] = []
    leading: list[str] = []
    current: dict | None = None
    session_id: str | None = None
    session_start: str | None = None

    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue

            rtype = d.get("type")
            data = d.get("data") or {}

            if rtype == "session.start":
                session_id = data.get("sessionId")
                session_start = data.get("startTime")

            elif rtype == "user.message":
                content = (data.get("content") or "").strip()
                if current is not None:
                    exchanges.append(current)
                current = {
                    "ts": d.get("timestamp"),
                    "dedup": "vc_" + hashlib.md5(
                        f"{session_id or path.name}:{d.get('id') or 'user'}".encode()
                    ).hexdigest(),
                    "prompt": content,
                    "response": [],
                }

            elif rtype == "assistant.message":
                content = (data.get("content") or "").strip()
                if not content:
                    continue  # tool-call-only message, no prose
                if current is not None:
                    current["response"].append(content)
                else:
                    leading.append(content)

    if current is not None:
        exchanges.append(current)

    if not exchanges and leading:
        exchanges.append({
            "ts": session_start,
            "dedup": "vc_" + hashlib.md5(
                f"{session_id or path.name}:session".encode()
            ).hexdigest(),
            "prompt": "",
            "response": leading,
        })
    elif leading and exchanges:
        # Attach any assistant prose that preceded the first recorded user message.
        exchanges[0]["response"] = leading + exchanges[0]["response"]

    for ex in exchanges:
        ex["response"] = "\n".join(ex["response"]).strip()

    return exchanges


def iter_transcripts(storage: Path, limit: int | None):
    transcripts = sorted(storage.glob("*/GitHub.copilot-chat/transcripts/*.jsonl"))
    if limit is not None:
        transcripts = transcripts[:limit]
    return transcripts


def build_text(prompt: str, response: str) -> str:
    parts = []
    if prompt:
        parts.append(f"Prompt: {prompt[:MAX_PROMPT_CHARS]}")
    if response:
        parts.append(f"Response: {response[:MAX_RESPONSE_CHARS]}")
    return "\n".join(parts)


def harvest(dry_run: bool, limit: int | None, db_path: Path) -> None:
    import sqlite3

    if not STORAGE_DIR.exists():
        print(f"ERROR: workspaceStorage not found at {STORAGE_DIR}", file=sys.stderr)
        sys.exit(1)

    transcripts = iter_transcripts(STORAGE_DIR, limit)
    print(f"Scanning {len(transcripts)} transcript file(s)…")

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA journal_mode=WAL")

    # Idempotency: existing dedup keys with our prefix.
    existing = {
        r[0] for r in conn.execute(
            "SELECT dedup_key FROM events WHERE dedup_key LIKE 'vc_%'"
        ).fetchall()
    }

    # Synthetic daily sessions keyed by date string.
    sessions: dict[str, str] = {}
    for sid, started_at in conn.execute(
        "SELECT id, started_at FROM sessions WHERE id LIKE 'vc_%'"
    ).fetchall():
        sessions[(started_at or "")[:10]] = sid

    def get_or_create_session(day: str) -> str:
        if day in sessions:
            return sessions[day]
        sid = f"vc_{uuid.uuid4().hex}"
        if not dry_run:
            conn.execute(
                "INSERT OR IGNORE INTO sessions (id, machine_id, started_at, ended_at, timezone) "
                "VALUES (?, ?, ?, ?, ?)",
                (sid, MACHINE_ID, f"{day}T00:00:00Z", f"{day}T23:59:59Z", "UTC"),
            )
        sessions[day] = sid
        return sid

    files = 0
    exchanges_seen = 0
    inserted = 0
    skipped = 0

    for path in transcripts:
        files += 1
        ws_dir = path.parents[2]  # .../workspaceStorage/<ws>/GitHub.copilot-chat/transcripts/…
        wname = workspace_name(ws_dir)
        exchanges = parse_transcript(path)
        exchanges_seen += len(exchanges)

        for ex in exchanges:
            ts_utc = normalize_ts(ex["ts"])
            day = ts_utc[:10]
            if ex["dedup"] in existing:
                skipped += 1
                continue

            session_id = get_or_create_session(day)
            event_id = f"vc_{uuid.uuid4().hex}"
            text = build_text(ex["prompt"], ex["response"])

            if not dry_run:
                conn.execute(
                    """INSERT OR IGNORE INTO events
                       (id, session_id, captured_at, trigger,
                        app_bundle_id, app_name, window_title, active_file_path,
                        source_type, text_content, embedding, dedup_key, is_duplicate, synced)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        event_id, session_id, ts_utc, TRIGGER,
                        APP_BUNDLE_ID, APP_NAME, wname, None,
                        SOURCE_TYPE, text, None, ex["dedup"], 0, 0,
                    ),
                )
            inserted += 1

    if not dry_run:
        conn.commit()
    conn.close()

    print(
        f"harvest_done files={files} exchanges={exchanges_seen} "
        f"inserted={inserted} skipped={skipped} dry_run={str(dry_run).lower()}"
    )


def main() -> int:
    p = argparse.ArgumentParser(description="Harvest VS Code Copilot Chat transcripts into activity-tracker DB")
    p.add_argument("--dry-run", action="store_true", help="Do not write to DB")
    p.add_argument("--limit", type=int, default=None, help="Max transcript files to process")
    p.add_argument("--db", default=str(ACTIVITY_DB), help="Path to activity.db")
    args = p.parse_args()

    harvest(args.dry_run, args.limit, Path(args.db))
    return 0


if __name__ == "__main__":
    sys.exit(main())
