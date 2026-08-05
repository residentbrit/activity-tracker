#!/usr/bin/env python3
"""
Migrate screenpipe historical data into activity-tracker database.

Imports the first occurrence of each unique content_hash from screenpipe's
frames table, plus all audio transcriptions. Creates one synthetic session
per calendar day. Does not embed — run backfill_embeddings.py afterward
for any events you want searchable.

Usage:
    python3 scripts/migrate_screenpipe.py [--dry-run] [--limit N]
"""

import sqlite3
import uuid
import hashlib
import json
import argparse
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

SCREENPIPE_DB = Path.home() / ".screenpipe" / "db.sqlite"
ACTIVITY_DB   = Path.home() / ".local" / "share" / "activity-tracker" / "activity.db"

# Screenpipe app_name → approximate bundle ID (best-effort; not critical)
BUNDLE_MAP = {
    "Code":         "com.microsoft.VSCode",
    "Terminal":     "com.apple.Terminal",
    "iTerm2":       "com.googlecode.iterm2",
    "Slack":        "com.tinyspeck.slackmacgap",
    "Google Chrome":"com.google.Chrome",
    "LibreWolf":    "io.gitlab.librewolf-community",
    "Safari":       "com.apple.Safari",
    "Finder":       "com.apple.finder",
    "Outlook":      "com.microsoft.Outlook",
    "zoom.us":      "us.zoom.xos",
    "Microsoft Teams": "com.microsoft.teams",
}


from typing import Optional


def bundle_id_for(app_name: str) -> Optional[str]:
    if not app_name:
        return None
    return BUNDLE_MAP.get(app_name)


def iso_now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def content_dedup_key(content_hash: Optional[int], text: str) -> str:
    """Produce a dedup key — use screenpipe's content_hash if available."""
    if content_hash is not None:
        return f"sp_{content_hash}"
    return hashlib.md5(text.encode()).hexdigest()


def migrate(dry_run: bool, limit: Optional[int]):
    if not SCREENPIPE_DB.exists():
        print(f"ERROR: screenpipe DB not found at {SCREENPIPE_DB}")
        sys.exit(1)

    sp  = sqlite3.connect(f"file:{SCREENPIPE_DB}?mode=ro", uri=True)
    sp.row_factory = sqlite3.Row

    act = sqlite3.connect(ACTIVITY_DB)
    act.execute("PRAGMA journal_mode=WAL")
    act.execute("PRAGMA synchronous=NORMAL")

    # ------------------------------------------------------------------ #
    # 1. Fetch one row per unique content_hash (earliest timestamp)        #
    # ------------------------------------------------------------------ #
    print("Querying screenpipe frames …")
    query = """
        SELECT
            MIN(id)              AS id,
            MIN(timestamp)       AS timestamp,
            app_name,
            window_name,
            accessibility_text   AS text,
            content_hash,
            machine_id
        FROM frames
        WHERE accessibility_text IS NOT NULL
          AND accessibility_text != ''
        GROUP BY content_hash
        ORDER BY MIN(timestamp)
    """
    if limit:
        query += f" LIMIT {limit}"

    rows = sp.execute(query).fetchall()
    print(f"  {len(rows):,} unique frames to import")

    # ------------------------------------------------------------------ #
    # 2. Skip rows whose dedup_key already exists in activity DB           #
    # ------------------------------------------------------------------ #
    existing = set(
        r[0] for r in act.execute("SELECT dedup_key FROM events WHERE dedup_key LIKE 'sp_%'").fetchall()
    )
    print(f"  {len(existing):,} already imported — skipping")
    rows = [r for r in rows if f"sp_{r['content_hash']}" not in existing]
    print(f"  {len(rows):,} new frames to insert")

    # ------------------------------------------------------------------ #
    # 3. Build synthetic daily sessions keyed by (date, machine_id)        #
    # ------------------------------------------------------------------ #
    # sessions: (date_str, machine_id) → session_id
    sessions: dict[tuple[str, str], str] = {}

    # Load already-created screenpipe import sessions
    for sid, started_at in act.execute(
        "SELECT id, started_at FROM sessions WHERE id LIKE 'sp_%'"
    ).fetchall():
        day = started_at[:10]
        # machine_id is not in sessions table, use placeholder
        sessions[(day, "_")] = sid

    def get_or_create_session(day: str, machine_id: str) -> str:
        key = (day, machine_id or "_")
        if key in sessions:
            return sessions[key]
        sid = f"sp_{uuid.uuid4().hex}"
        started = f"{day}T00:00:00Z"
        ended   = f"{day}T23:59:59Z"
        if not dry_run:
            act.execute(
                "INSERT OR IGNORE INTO sessions (id, machine_id, started_at, ended_at, timezone) VALUES (?,?,?,?,?)",
                (sid, machine_id or "screenpipe-import", started, ended, "UTC")
            )
        sessions[key] = sid
        return sid

    # ------------------------------------------------------------------ #
    # 4. Insert frames                                                      #
    # ------------------------------------------------------------------ #
    inserted = 0
    batch = []
    BATCH_SIZE = 500

    for row in rows:
        ts        = row["timestamp"]          # e.g. 2026-07-10T18:35:50.076529+00:00
        app_name  = row["app_name"] or ""
        win_title = row["window_name"] or ""
        text      = row["text"] or ""
        machine   = row["machine_id"] or "screenpipe-import"

        # Normalize timestamp to ISO8601 UTC (strip microseconds + tz offset)
        try:
            dt = datetime.fromisoformat(ts)
            ts_utc = dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            ts_utc = ts[:19] + "Z"

        day = ts_utc[:10]
        session_id = get_or_create_session(day, machine)
        dedup_key  = content_dedup_key(row["content_hash"], text)
        event_id   = f"sp_{uuid.uuid4().hex}"
        bundle_id  = bundle_id_for(app_name)

        batch.append((
            event_id,
            session_id,
            ts_utc,
            "screenpipe_import",    # trigger
            bundle_id,
            app_name or None,
            win_title or None,
            None,                   # active_file_path
            "accessibility",        # source_type
            text,
            None,                   # embedding — backfill separately
            dedup_key,
            0,                      # is_duplicate
            0,                      # synced
        ))

        if len(batch) >= BATCH_SIZE:
            if not dry_run:
                act.executemany(
                    """INSERT OR IGNORE INTO events
                       (id, session_id, captured_at, trigger,
                        app_bundle_id, app_name, window_title, active_file_path,
                        source_type, text_content, embedding, dedup_key, is_duplicate, synced)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    batch
                )
                act.commit()
            inserted += len(batch)
            batch.clear()
            print(f"  … {inserted:,} inserted", end="\r", flush=True)

    if batch:
        if not dry_run:
            act.executemany(
                """INSERT OR IGNORE INTO events
                   (id, session_id, captured_at, trigger,
                    app_bundle_id, app_name, window_title, active_file_path,
                    source_type, text_content, embedding, dedup_key, is_duplicate, synced)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                batch
            )
            act.commit()
        inserted += len(batch)

    print(f"\n  {inserted:,} frame events {'would be ' if dry_run else ''}inserted")

    # ------------------------------------------------------------------ #
    # 5. Migrate audio transcriptions                                       #
    # ------------------------------------------------------------------ #
    print("\nQuerying screenpipe audio transcriptions …")
    audio_rows = sp.execute("""
        SELECT timestamp, transcription, device, is_input_device, start_time, end_time
        FROM audio_transcriptions
        WHERE transcription IS NOT NULL AND transcription != ''
        ORDER BY timestamp
    """).fetchall()
    print(f"  {len(audio_rows):,} transcriptions")

    # Skip already-imported audio
    existing_audio = set(
        r[0] for r in act.execute(
            "SELECT dedup_key FROM events WHERE trigger = 'screenpipe_audio_import'"
        ).fetchall()
    )

    audio_batch = []
    audio_inserted = 0

    for row in audio_rows:
        ts           = row["timestamp"]
        transcription = row["transcription"]
        device       = row["device"] or ""

        try:
            dt = datetime.fromisoformat(ts)
            ts_utc = dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            ts_utc = ts[:19] + "Z"

        dedup_key = "sp_audio_" + hashlib.md5(transcription.encode()).hexdigest()
        if dedup_key in existing_audio:
            continue

        day = ts_utc[:10]
        session_id = get_or_create_session(day, "screenpipe-import")
        event_id   = f"sp_{uuid.uuid4().hex}"

        audio_batch.append((
            event_id,
            session_id,
            ts_utc,
            "screenpipe_audio_import",
            None, None,
            f"Audio: {device}",
            None,
            "audio",
            transcription,
            None,
            dedup_key,
            0,
            0,
        ))

    if audio_batch:
        if not dry_run:
            act.executemany(
                """INSERT OR IGNORE INTO events
                   (id, session_id, captured_at, trigger,
                    app_bundle_id, app_name, window_title, active_file_path,
                    source_type, text_content, embedding, dedup_key, is_duplicate, synced)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                audio_batch
            )
            act.commit()
        audio_inserted = len(audio_batch)

    print(f"  {audio_inserted:,} audio events {'would be ' if dry_run else ''}inserted")

    sp.close()
    act.close()

    # ------------------------------------------------------------------ #
    # 6. Summary                                                            #
    # ------------------------------------------------------------------ #
    print("\n" + ("=" * 50))
    if dry_run:
        print("DRY RUN — no data written")
    else:
        print("Migration complete.")
    print(f"  Frame events : {inserted:,}")
    print(f"  Audio events : {audio_inserted:,}")
    print(f"  Total        : {inserted + audio_inserted:,}")
    if not dry_run:
        print("\nTo embed the imported events, run:")
        print("  python3 scripts/backfill_embeddings.py --trigger screenpipe_import")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Migrate screenpipe data to activity-tracker")
    parser.add_argument("--dry-run", action="store_true", help="Count what would be imported without writing")
    parser.add_argument("--limit",   type=int, default=None, help="Limit number of frames (for testing)")
    args = parser.parse_args()

    migrate(dry_run=args.dry_run, limit=args.limit)
