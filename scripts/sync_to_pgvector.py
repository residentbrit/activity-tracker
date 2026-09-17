#!/usr/bin/env python3
"""Direct SQLite → pgvector sync.

Reads captured events straight out of the local SQLite database and upserts them
into the homellm pgvector database. This replaces the file-based outbox
hand-off: the local DB already holds the text *and* the embeddings, so writing a
second copy to disk only created another thing to collect.

Transport is a direct Postgres connection, which is what spec D13 originally
described ("TCP health check to pgvector port → if reachable and unsynced rows
exist → push batch").

Queue state is `events.pg_synced`, deliberately separate from `synced` (which
the daemon's file exporter sets). If the two shared a flag, whichever mechanism
ran first would mark rows done and silently starve the other.

Credentials are never stored in this repo. Resolution order:
    1. PGPASSWORD environment variable
    2. macOS Keychain (service `activity-tracker-pgvector`, account = db user)
    3. `syncTarget.password` in ~/.config/activity-tracker/config.json

Setup:
    make sync-setup                      # venv + pg8000 (pure-Python driver)
    security add-generic-password \\
        -s activity-tracker-pgvector -a activity_tracker -w
    make sync-check                      # connectivity + row counts
    make sync-pgvector                   # push pending rows

Examples:
    make sync-pgvector ARGS="--dry-run"  # no connection, shows what would go
    make sync-pgvector ARGS="--limit 500"
    make sync-pgvector ARGS="--reset-queue"   # re-queue everything
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sqlite3
import sys
from pathlib import Path

DB_PATH = str(Path.home() / ".local/share/activity-tracker/activity.db")
CONFIG_PATH = str(Path.home() / ".config/activity-tracker/config.json")
KEYCHAIN_SERVICE = "activity-tracker-pgvector"

# Embeddings are 1024-dim float32 (mxbai-embed-large).
EMBEDDING_DIM = 1024
EMBEDDING_BYTES = EMBEDDING_DIM * 4
# float32 round-trips at 9 significant digits; 6 is ample for cosine ranking
# (abs error ~1e-7 against a 0.62 threshold) and keeps the payload smaller.
VECTOR_PRECISION = ".6g"

EVENT_COLUMNS = (
    "id", "machine_id", "session_id", "captured_at", "trigger",
    "app_bundle_id", "app_name", "window_title", "active_file_path",
    "source_type", "text_content", "embedding",
)

# The same set minus machine_id (which lives on `sessions`, not `events`) and
# minus the embedding blob, which is selected separately.
EVENT_SELECT_COLUMNS = (
    "id", "session_id", "captured_at", "trigger", "app_bundle_id",
    "app_name", "window_title", "active_file_path", "source_type", "text_content",
)

SCHEMA_STATEMENTS = [
    "CREATE TABLE IF NOT EXISTS activity_events ("
    "  id TEXT PRIMARY KEY,"
    "  machine_id TEXT NOT NULL,"
    "  session_id TEXT NOT NULL,"
    "  captured_at TIMESTAMPTZ NOT NULL,"
    '  "trigger" TEXT NOT NULL,'
    "  app_bundle_id TEXT,"
    "  app_name TEXT,"
    "  window_title TEXT,"
    "  active_file_path TEXT,"
    "  source_type TEXT NOT NULL,"
    "  text_content TEXT NOT NULL,"
    "  embedding vector(1024),"
    "  synced_at TIMESTAMPTZ DEFAULT NOW()"
    ")",
    "CREATE TABLE IF NOT EXISTS activity_sessions ("
    "  id TEXT PRIMARY KEY,"
    "  machine_id TEXT NOT NULL,"
    "  started_at TIMESTAMPTZ NOT NULL,"
    "  ended_at TIMESTAMPTZ,"
    "  timezone TEXT NOT NULL,"
    "  event_count INTEGER,"
    "  summary TEXT"
    ")",
    "CREATE TABLE IF NOT EXISTS activity_audio_segments ("
    "  id TEXT PRIMARY KEY,"
    "  machine_id TEXT NOT NULL,"
    "  session_id TEXT NOT NULL,"
    "  started_at TIMESTAMPTZ NOT NULL,"
    "  ended_at TIMESTAMPTZ NOT NULL,"
    "  meeting_app TEXT,"
    "  transcript TEXT NOT NULL,"
    "  embedding vector(1024),"
    "  synced_at TIMESTAMPTZ DEFAULT NOW()"
    ")",
    "CREATE INDEX IF NOT EXISTS idx_activity_events_ts ON activity_events(captured_at)",
    "CREATE INDEX IF NOT EXISTS idx_activity_events_machine ON activity_events(machine_id)",
]


class SyncError(Exception):
    pass


# --------------------------------------------------------------------------
# Configuration and credentials
# --------------------------------------------------------------------------

def load_target() -> dict:
    if not os.path.exists(CONFIG_PATH):
        raise SyncError(f"config not found at {CONFIG_PATH}")
    with open(CONFIG_PATH) as handle:
        config = json.load(handle)
    target = config.get("syncTarget")
    if not target:
        raise SyncError(f"no syncTarget block in {CONFIG_PATH}")
    return target


def resolve_password(user: str, target: dict) -> str | None:
    """Never store the password in the repo; look it up at runtime."""
    if os.environ.get("PGPASSWORD"):
        return os.environ["PGPASSWORD"]

    result = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", user, "-w"],
        capture_output=True, text=True,
    )
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()

    configured = (target.get("password") or "").strip()
    if configured:
        return configured

    return None


def missing_password_help(user: str) -> str:
    return (
        "No Postgres password found.\n"
        "Add it to the Keychain (this command prompts, so the value never enters "
        "shell history or this repo):\n"
        f"    security add-generic-password -s {KEYCHAIN_SERVICE} -a {user} -w\n"
        "Alternatives: export PGPASSWORD, or set syncTarget.password in the config."
    )


def import_driver():
    try:
        import pg8000.dbapi  # noqa: F401
        return pg8000.dbapi
    except ImportError:
        raise SyncError(
            "pg8000 is not installed. Run:\n"
            "    make sync-setup"
        )


def connect(target: dict):
    driver = import_driver()
    user = target.get("user", "activity_tracker")
    password = resolve_password(user, target)
    if not password:
        raise SyncError(missing_password_help(user))

    try:
        return driver.connect(
            user=user,
            password=password,
            host=target.get("host", "127.0.0.1"),
            port=int(target.get("port", 5432)),
            database=target.get("database", "postgres"),
            timeout=10,
        )
    except Exception as exc:  # noqa: BLE001 - surfaced verbatim to the operator
        raise SyncError(
            f"could not connect to {target.get('host')}:{target.get('port')} "
            f"as {user}: {exc}"
        )


# --------------------------------------------------------------------------
# Reading from local SQLite
# --------------------------------------------------------------------------

def queue_depth(conn: sqlite3.Connection) -> int:
    return conn.execute(
        "SELECT COUNT(*) FROM events WHERE pg_synced = 0 AND is_duplicate = 0"
    ).fetchone()[0]


def fetch_batch(conn: sqlite3.Connection, limit: int) -> list[tuple]:
    """Next pending non-duplicate events, oldest first.

    machine_id comes from the session because the remote schema carries it per
    event. Duplicates are skipped for the same reason they are skipped
    everywhere else: their text is already present on the row that introduced it.
    """
    return conn.execute(
        f"""
        SELECT {', '.join('e.' + c for c in EVENT_SELECT_COLUMNS)}, e.embedding, s.machine_id
        FROM events e
        JOIN sessions s ON s.id = e.session_id
        WHERE e.pg_synced = 0 AND e.is_duplicate = 0
        ORDER BY e.captured_at ASC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()


def vector_literal(blob: bytes | None) -> str | None:
    if not blob:
        return None
    if len(blob) != EMBEDDING_BYTES:
        return None
    values = struct.unpack(f"<{EMBEDDING_DIM}f", blob)
    return "[" + ",".join(format(v, VECTOR_PRECISION) for v in values) + "]"


def mark_synced(conn: sqlite3.Connection, ids: list[str]) -> None:
    placeholders = ",".join("?" for _ in ids)
    conn.execute(
        f"UPDATE events SET pg_synced = 1 WHERE id IN ({placeholders})", ids
    )
    conn.commit()


# --------------------------------------------------------------------------
# Writing to pgvector
# --------------------------------------------------------------------------

def ensure_schema(conn) -> list[str]:
    """Create the remote schema. Returns non-fatal warnings."""
    warnings: list[str] = []
    cursor = conn.cursor()
    try:
        cursor.execute("CREATE EXTENSION IF NOT EXISTS vector")
        conn.commit()
    except Exception as exc:  # noqa: BLE001
        conn.rollback()
        warnings.append(
            f"could not CREATE EXTENSION vector ({exc}); assuming it is already enabled"
        )

    for statement in SCHEMA_STATEMENTS:
        try:
            cursor.execute(statement)
            conn.commit()
        except Exception as exc:  # noqa: BLE001
            conn.rollback()
            raise SyncError(f"schema statement failed:\n  {statement}\n  {exc}")

    return warnings


def insert_batch(conn, rows: list[tuple]) -> int:
    """Multi-row upsert. Idempotent, so a replayed batch is harmless."""
    if not rows:
        return 0

    tuple_placeholder = "(" + ",".join(["%s"] * (len(EVENT_COLUMNS) - 1) + ["%s::vector", "NOW()"]) + ")"
    sql = (
        f"INSERT INTO activity_events ({', '.join(EVENT_COLUMNS)}, synced_at) "
        f"VALUES {','.join([tuple_placeholder] * len(rows))} "
        "ON CONFLICT (id) DO NOTHING"
    )

    params: list = []
    for row in rows:
        *event_values, embedding, machine_id = row
        # Reorder to match EVENT_COLUMNS: machine_id sits second.
        (event_id, session_id, captured_at, trigger, app_bundle_id, app_name,
         window_title, active_file_path, source_type, text_content) = event_values
        params.extend([
            event_id, machine_id, session_id, captured_at, trigger,
            app_bundle_id, app_name, window_title, active_file_path,
            source_type, text_content, vector_literal(embedding),
        ])

    cursor = conn.cursor()
    cursor.execute(sql, params)
    conn.commit()
    return len(rows)


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------

def run_dry_run(conn: sqlite3.Connection, args) -> int:
    pending = queue_depth(conn)
    print(f"pending non-duplicate events : {pending}")
    print(f"batch size                   : {args.batch_size}")
    print(f"batches for full queue       : {(pending + args.batch_size - 1) // args.batch_size}")
    print()

    rows = fetch_batch(conn, min(args.limit or 3, 3))
    print(f"sample of what would be pushed ({len(rows)}):")
    for row in rows:
        *_, text_content = row[:10]
        vector = vector_literal(row[10])
        print(f"  {row[0]}  {row[2]}  {row[8]:<14} {row[5] or ''}")
        print(f"    text    : {' '.join((text_content or '').split())[:80]!r}")
        print(f"    vector  : {'present, ' + str(len(vector)) + ' chars' if vector else 'none'}")
    print()
    print("dry run: no connection attempted, nothing written.")
    return 0


def run_check(conn: sqlite3.Connection, args) -> int:
    target = load_target()
    print(f"target        : {target.get('user')}@{target.get('host')}:{target.get('port')}/{target.get('database')}")
    print(f"pending local : {queue_depth(conn)}")

    password_source = (
        "PGPASSWORD" if os.environ.get("PGPASSWORD")
        else "Keychain" if resolve_password(target.get("user", ""), target)
        else None
    )
    print(f"credentials   : {password_source or 'NOT FOUND'}")
    print()

    remote = connect(target)
    cursor = remote.cursor()

    cursor.execute("SELECT version()")
    print(f"server        : {cursor.fetchone()[0].split(',')[0]}")

    cursor.execute("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')")
    has_vector = cursor.fetchone()[0]
    print(f"pgvector      : {'installed' if has_vector else 'MISSING'}")

    for table in ("activity_events", "activity_sessions", "activity_audio_segments"):
        cursor.execute("SELECT to_regclass(%s)", (table,))
        exists = cursor.fetchone()[0] is not None
        if exists:
            cursor.execute(f"SELECT COUNT(*) FROM {table}")
            print(f"{table:<22}: present, {cursor.fetchone()[0]} rows")
        else:
            print(f"{table:<22}: absent (run sync-pgvector to create)")

    remote.close()

    # The daemon's file outbox is independent of this sync (it writes files that
    # nothing collects, and it sets `synced`, not `pg_synced`). Harmless, but it
    # doubles the data on disk for no benefit now that a direct path exists.
    outbox = Path.home() / ".local/share/activity-tracker/sync-outbox"
    if outbox.is_dir():
        files = list(outbox.glob("*.json"))
        if files:
            print()
            print(f"note          : legacy outbox still enabled — {len(files)} files, "
                  f"{sum(f.stat().st_size for f in files) / 1048576:.0f}MB in {outbox}")
            print("                It is now redundant; see README 'Sync to homellm' "
                  "for retiring it.")

    pending = queue_depth(conn)
    print()
    print(f"verdict       : {'ready - ' + str(pending) + ' rows to push' if has_vector else 'pgvector extension missing on the target'}")
    return 0


def run_sync(conn: sqlite3.Connection, args) -> int:
    if args.reset_queue:
        reset = conn.execute(
            "UPDATE events SET pg_synced = 0 WHERE is_duplicate = 0"
        ).rowcount
        conn.commit()
        print(f"re-queued {reset} rows (pg_synced reset to 0)")

    pending = queue_depth(conn)
    if pending == 0:
        print("nothing to push — queue is empty.")
        return 0

    target = load_target()
    remote = connect(target)
    print(f"target: {target.get('user')}@{target.get('host')}:{target.get('port')}/{target.get('database')}")

    warnings = ensure_schema(remote)
    for warning in warnings:
        print(f"warning: {warning}")

    pushed = 0
    attempted = 0
    remaining = pending if args.limit is None else min(pending, args.limit)

    print(f"pushing {remaining} of {pending} pending rows in batches of {args.batch_size}")
    while attempted < remaining:
        want = min(args.batch_size, remaining - attempted)
        rows = fetch_batch(conn, want)
        if not rows:
            break

        try:
            insert_batch(remote, rows)
        except Exception as exc:  # noqa: BLE001
            print(f"\nERROR after {pushed} rows: {exc}", file=sys.stderr)
            print("Local queue left untouched, so the next run resumes here.",
                  file=sys.stderr)
            remote.close()
            return 1

        # Remote commit succeeded — only now mark locally, so a crash mid-batch
        # replays rather than drops (the upsert makes replays harmless).
        mark_synced(conn, [row[0] for row in rows])
        pushed += len(rows)
        attempted += len(rows)
        print(f"  pushed {pushed}/{remaining}", end="\r", flush=True)

    remote.close()
    print(f"\npushed {pushed} rows. local queue now {queue_depth(conn)}.")
    return 0


# --------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Sync local activity DB to homellm pgvector")
    parser.add_argument("--db", default=DB_PATH, help="Path to local activity.db")
    parser.add_argument("--batch-size", type=int, default=200, help="Rows per remote insert")
    parser.add_argument("--limit", type=int, default=None, help="Max rows to push this run")
    parser.add_argument("--dry-run", action="store_true", help="Report only; no connection")
    parser.add_argument("--check", action="store_true", help="Connectivity and row counts")
    parser.add_argument("--reset-queue", action="store_true", help="Re-queue every non-duplicate event")
    args = parser.parse_args()

    if not os.path.exists(args.db):
        print(f"error: local db not found at {args.db}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(args.db)
    conn.execute("PRAGMA busy_timeout=5000")

    columns = {row[1] for row in conn.execute("PRAGMA table_info(events)")}
    if "pg_synced" not in columns:
        print(
            "error: events.pg_synced is missing — schema migration v3 has not run.\n"
            "       Restart the daemon (make daemon-install) or run the collector once.",
            file=sys.stderr,
        )
        return 2

    try:
        if args.dry_run:
            return run_dry_run(conn, args)
        if args.check:
            return run_check(conn, args)
        return run_sync(conn, args)
    except SyncError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
