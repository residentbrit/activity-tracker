#!/usr/bin/env python3
"""One-shot embedding backfill for Activity Tracker SQLite events.

Embeds non-duplicate rows that have text but no embedding yet.
Uses llama-embedding in JSON output mode for robust parsing.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


DEFAULT_DB = str(Path.home() / ".local/share/activity-tracker/activity.db")
DEFAULT_BIN = str(Path.home() / ".local/bin/llama-embedding")
DEFAULT_MODEL = str(Path.home() / ".local/share/activity-tracker/models/mxbai-embed-large.gguf")


@dataclass
class BackfillConfig:
    db_path: str
    embedding_bin: str
    model_path: str
    max_chars: int
    max_words: int
    timeout_sec: int
    include_duplicates: bool
    limit: Optional[int]
    dry_run: bool


def prepare_text(text: str, max_chars: int, max_words: int) -> str:
    t = (text or "").strip()
    if not t:
        return ""

    # Remove object replacement char observed in some AX captures.
    t = t.replace("\uFFFC", " ")
    t = t[:max_chars]

    words = t.split()
    if len(words) > max_words:
        t = " ".join(words[:max_words])

    return t


def embed_json(text: str, cfg: BackfillConfig) -> tuple[Optional[bytes], Optional[str]]:
    fd, path = tempfile.mkstemp(prefix="activity-tracker-backfill-", suffix=".txt")
    os.close(fd)

    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

        proc = subprocess.run(
            [
                cfg.embedding_bin,
                "-m",
                cfg.model_path,
                "--pooling",
                "mean",
                "--embd-normalize",
                "2",
                "--embd-output-format",
                "json",
                "-f",
                path,
                "--no-escape",
            ],
            capture_output=True,
            timeout=cfg.timeout_sec,
        )
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except Exception as exc:
        return None, f"launch_error:{exc}"
    finally:
        try:
            os.remove(path)
        except OSError:
            pass

    if proc.returncode != 0:
        return None, f"rc:{proc.returncode}"

    stdout = (proc.stdout or b"").decode("utf-8", errors="replace").strip()
    if not stdout:
        return None, "empty_stdout"

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return None, "json_parse_failed"

    emb = None
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict):
                emb = first.get("embedding")

    if not isinstance(emb, list):
        return None, "missing_embedding"

    try:
        values = [float(x) for x in emb]
    except Exception:
        return None, "non_numeric_embedding"

    if len(values) < 1024:
        return None, f"bad_dim:{len(values)}"
    if len(values) > 1024:
        values = values[-1024:]

    return struct.pack("<1024f", *values), None


def build_select_sql(include_duplicates: bool, limit: Optional[int], trigger: Optional[str] = None) -> str:
    where_dups = "1=1" if include_duplicates else "is_duplicate = 0"
    trigger_clause = f" AND trigger = '{trigger}'" if trigger else ""
    limit_clause = f" LIMIT {int(limit)}" if limit is not None else ""
    return (
        "SELECT id, text_content FROM events "
        f"WHERE {where_dups} "
        "AND embedding IS NULL "
        "AND COALESCE(LENGTH(text_content), 0) > 0 "
        f"{trigger_clause}"
        "ORDER BY captured_at ASC"
        f"{limit_clause}"
    )


def run(cfg: BackfillConfig) -> int:
    if not os.path.exists(cfg.db_path):
        print(f"error: db not found at {cfg.db_path}", file=sys.stderr)
        return 2
    if not os.path.isfile(cfg.embedding_bin) or not os.access(cfg.embedding_bin, os.X_OK):
        print(f"error: embedding binary not executable at {cfg.embedding_bin}", file=sys.stderr)
        return 2
    if not os.path.exists(cfg.model_path):
        print(f"error: model not found at {cfg.model_path}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(cfg.db_path)
    conn.execute("PRAGMA busy_timeout=5000")
    cur = conn.cursor()

    select_sql = build_select_sql(cfg.include_duplicates, cfg.limit, getattr(cfg, 'trigger', None))
    rows = cur.execute(select_sql).fetchall()

    total = len(rows)
    if total == 0:
        print("No matching rows need backfill.")
        conn.close()
        return 0

    print(f"Backfilling {total} rows...")

    embedded = 0
    failed = 0

    for idx, (event_id, text) in enumerate(rows, start=1):
        prepared = prepare_text(text, cfg.max_chars, cfg.max_words)
        if not prepared:
            failed += 1
            print(f"[{idx}/{total}] {event_id} skipped_empty")
            continue

        blob, err = embed_json(prepared, cfg)
        if blob is None:
            failed += 1
            print(f"[{idx}/{total}] {event_id} failed {err}")
            continue

        if cfg.dry_run:
            print(f"[{idx}/{total}] {event_id} would_embed")
            embedded += 1
            continue

        cur.execute("UPDATE events SET embedding = ? WHERE id = ?", (blob, event_id))
        embedded += 1
        print(f"[{idx}/{total}] {event_id} embedded")

        if embedded % 10 == 0:
            conn.commit()

    if not cfg.dry_run:
        conn.commit()

    remaining_sql = (
        "SELECT COUNT(*) FROM events WHERE embedding IS NULL "
        "AND COALESCE(LENGTH(text_content), 0) > 0 "
        + ("" if cfg.include_duplicates else "AND is_duplicate = 0")
    )
    remaining = cur.execute(remaining_sql).fetchone()[0]

    conn.close()

    print(
        "backfill_done "
        f"embedded={embedded} failed={failed} total={total} remaining={remaining} "
        f"dry_run={str(cfg.dry_run).lower()}"
    )

    return 0 if failed == 0 else 1


def parse_args() -> BackfillConfig:
    p = argparse.ArgumentParser(description="Backfill missing embeddings in Activity Tracker SQLite DB")
    p.add_argument("--db", default=DEFAULT_DB, help="Path to activity.db")
    p.add_argument("--embedding-bin", default=DEFAULT_BIN, help="Path to llama-embedding binary")
    p.add_argument("--model", default=DEFAULT_MODEL, help="Path to embedding model .gguf")
    p.add_argument("--max-chars", type=int, default=1500, help="Max chars per row before embedding")
    p.add_argument("--max-words", type=int, default=200, help="Max words per row before embedding")
    p.add_argument("--timeout-sec", type=int, default=90, help="Per-row subprocess timeout")
    p.add_argument("--include-duplicates", action="store_true", help="Also embed duplicate rows")
    p.add_argument("--limit", type=int, default=None, help="Max rows to process")
    p.add_argument("--trigger", default=None, help="Only embed events with this trigger value (e.g. screenpipe_import)")
    p.add_argument("--dry-run", action="store_true", help="Do not update DB")
    args = p.parse_args()

    cfg = BackfillConfig(
        db_path=args.db,
        embedding_bin=args.embedding_bin,
        model_path=args.model,
        max_chars=args.max_chars,
        max_words=args.max_words,
        timeout_sec=args.timeout_sec,
        include_duplicates=args.include_duplicates,
        limit=args.limit,
        dry_run=args.dry_run,
    )
    cfg.trigger = args.trigger
    return cfg
    raise SystemExit(run(parse_args()))
