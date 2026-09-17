#!/usr/bin/env python3
"""One-shot embedding backfill for Activity Tracker SQLite events.

Embeds non-duplicate rows that have text but no embedding yet.

Two execution modes:
  * **server** (default) — batches texts to the resident ``llama-server`` on
    port 8080 (the same endpoint the daemon uses), so vectors are byte-identical
    to live captures and no model reload happens per row.
  * **subprocess** — falls back to ``llama-embedding`` (JSON output mode)
    when the server is unreachable.
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
import urllib.error
import urllib.request
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
    server_url: Optional[str] = None
    batch_size: int = 32


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


def server_healthy(url: str, timeout: float = 2.0) -> bool:
    """True when llama-server answers /health with 200."""
    try:
        with urllib.request.urlopen(f"{url.rstrip('/')}/health", timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def embed_batch_via_server(
    texts: list[str], url: str, timeout: int
) -> tuple[list[Optional[bytes]], Optional[str]]:
    """Embed a batch of texts through llama-server's OpenAI-compatible endpoint.

    Returns (blobs, error) where blobs[i] corresponds to texts[i]; a None entry
    means that individual item failed.
    """
    endpoint = f"{url.rstrip('/')}/v1/embeddings"
    body = json.dumps({"input": texts, "model": "mxbai-embed-large"}).encode("utf-8")
    req = urllib.request.Request(
        endpoint, data=body, headers={"Content-Type": "application/json"}
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="replace"))
    except Exception as exc:
        return [None] * len(texts), f"server_error:{exc}"

    items = payload.get("data")
    if not isinstance(items, list):
        return [None] * len(texts), "missing_data"

    blobs: list[Optional[bytes]] = [None] * len(texts)
    for item in items:
        if not isinstance(item, dict):
            continue
        idx = item.get("index")
        emb = item.get("embedding")
        if not isinstance(idx, int) or not isinstance(emb, list):
            continue
        if idx < 0 or idx >= len(texts):
            continue
        try:
            values = [float(x) for x in emb]
        except Exception:
            continue
        if len(values) < 1024:
            continue
        blobs[idx] = struct.pack("<1024f", *values[-1024:])

    return blobs, None


def shrink_variants(text: str, cfg: BackfillConfig) -> list[str]:
    """Progressively smaller variants of `text`, for retrying over token limits.

    Two axes are needed. Word caps handle token-dense prose (ID/hostname lists),
    while character caps handle single enormous "words" — an 800-char SAML URL is
    one whitespace-separated word but hundreds of tokens.
    """
    variants: list[str] = []
    word_count = len(text.split())
    for words_cap in (100, 60, 30, 15):
        if words_cap >= word_count:
            continue
        variants.append(prepare_text(text, cfg.max_chars, words_cap))
    for chars_cap in (600, 300, 150, 75):
        if chars_cap >= len(text):
            continue
        variants.append(prepare_text(text, chars_cap, cfg.max_words))

    unique: list[str] = []
    seen: set[str] = set()
    for variant in variants:
        if variant and variant not in seen:
            seen.add(variant)
            unique.append(variant)
    return unique


def embed_one_via_server(
    text: str, url: str, cfg: BackfillConfig
) -> tuple[Optional[bytes], Optional[str]]:
    """Embed a single text, shrinking the input if the server rejects it.

    llama-server returns HTTP 500 ("input (N tokens) is too large to process")
    when the tokenized input exceeds its 512-token physical batch — the same
    failure mode as llama-embedding's rc:-6 SIGABRT in subprocess mode.
    """
    blobs, err = embed_batch_via_server([text], url, cfg.timeout_sec)
    if blobs and blobs[0] is not None:
        return blobs[0], None

    for variant in shrink_variants(text, cfg):
        blobs, err = embed_batch_via_server([variant], url, cfg.timeout_sec)
        if blobs and blobs[0] is not None:
            return blobs[0], None

    return None, err


def embed_rows_via_server(
    conn: sqlite3.Connection,
    cur: sqlite3.Cursor,
    prepared_rows: list[tuple[str, str]],
    cfg: BackfillConfig,
) -> tuple[int, int]:
    """Embed rows in server batches. Returns (embedded, failed)."""
    embedded = 0
    failed = 0
    total = len(prepared_rows)
    url = cfg.server_url or ""

    for start in range(0, total, cfg.batch_size):
        chunk = prepared_rows[start : start + cfg.batch_size]
        blobs, err = embed_batch_via_server(
            [text for _, text in chunk], url, cfg.timeout_sec
        )

        for (event_id, text), blob in zip(chunk, blobs):
            if blob is None:
                # Any oversized input fails the whole request, so a failed item
                # is retried alone (and shrunk) rather than sinking its batch.
                blob, item_err = embed_one_via_server(text, url, cfg)
                if blob is None:
                    failed += 1
                    print(f"{event_id} failed {item_err or err}", file=sys.stderr)
                    continue

            cur.execute("UPDATE events SET embedding = ? WHERE id = ?", (blob, event_id))
            embedded += 1

        conn.commit()
        done = min(start + cfg.batch_size, total)
        print(f"[{done}/{total}] embedded={embedded} failed={failed}")

    return embedded, failed


def embed_rows_via_subprocess(
    conn: sqlite3.Connection,
    cur: sqlite3.Cursor,
    prepared_rows: list[tuple[str, str]],
    cfg: BackfillConfig,
) -> tuple[int, int]:
    """Embed rows one subprocess at a time. Returns (embedded, failed)."""
    embedded = 0
    failed = 0
    total = len(prepared_rows)

    for idx, (event_id, prepared) in enumerate(prepared_rows, start=1):
        blob, err = embed_json(prepared, cfg)
        if blob is None:
            # llama-embedding SIGABRTs (rc:-6) when the tokenized input exceeds
            # its batch size; shrink and retry.
            for variant in shrink_variants(prepared, cfg):
                blob, err = embed_json(variant, cfg)
                if blob is not None:
                    break

        if blob is None:
            failed += 1
            print(f"[{idx}/{total}] {event_id} failed {err}", file=sys.stderr)
            continue

        cur.execute("UPDATE events SET embedding = ? WHERE id = ?", (blob, event_id))
        embedded += 1

        if embedded % 10 == 0:
            conn.commit()
            print(f"[{idx}/{total}] embedded={embedded} failed={failed}")

    conn.commit()
    return embedded, failed


def build_select_sql(include_duplicates: bool, limit: Optional[int], trigger: Optional[str] = None) -> str:
    where_dups = "1=1" if include_duplicates else "is_duplicate = 0"
    trigger_clause = f" AND trigger = '{trigger}'" if trigger else ""
    limit_clause = f" LIMIT {int(limit)}" if limit is not None else ""
    return (
        "SELECT id, text_content FROM events "
        f"WHERE {where_dups} "
        "AND embedding IS NULL "
        "AND COALESCE(LENGTH(text_content), 0) > 0 "
        f"{trigger_clause} "
        "ORDER BY captured_at ASC"
        f"{limit_clause}"
    )


def run(cfg: BackfillConfig) -> int:
    if not os.path.exists(cfg.db_path):
        print(f"error: db not found at {cfg.db_path}", file=sys.stderr)
        return 2
    if not os.path.exists(cfg.model_path):
        print(f"error: model not found at {cfg.model_path}", file=sys.stderr)
        return 2

    # Prefer the resident embed server — same endpoint the daemon uses, so the
    # vectors are identical and no model is reloaded per row.
    use_server = bool(cfg.server_url) and server_healthy(cfg.server_url)
    if use_server:
        print(f"mode: server {cfg.server_url} (batch size {cfg.batch_size})")
    else:
        if cfg.server_url:
            print(f"mode: subprocess (embed server unreachable at {cfg.server_url})")
        if not os.path.isfile(cfg.embedding_bin) or not os.access(cfg.embedding_bin, os.X_OK):
            print(f"error: embedding binary not executable at {cfg.embedding_bin}", file=sys.stderr)
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

    prepared_rows: list[tuple[str, str]] = []
    skipped_empty = 0
    for event_id, text in rows:
        prepared = prepare_text(text, cfg.max_chars, cfg.max_words)
        if not prepared:
            skipped_empty += 1
            continue
        prepared_rows.append((event_id, prepared))

    if not prepared_rows:
        print("No rows with embeddable text.")
        conn.close()
        return 0

    embedded = 0
    failed = 0

    if cfg.dry_run:
        for event_id, _ in prepared_rows:
            print(f"{event_id} would_embed")
        embedded = len(prepared_rows)
    elif use_server:
        embedded, failed = embed_rows_via_server(conn, cur, prepared_rows, cfg)
    else:
        embedded, failed = embed_rows_via_subprocess(conn, cur, prepared_rows, cfg)

    if cfg.dry_run:
        remaining = -1
    else:
        remaining_sql = (
            "SELECT COUNT(*) FROM events WHERE embedding IS NULL "
            "AND COALESCE(LENGTH(text_content), 0) > 0 "
            + ("" if cfg.include_duplicates else "AND is_duplicate = 0")
        )
        remaining = cur.execute(remaining_sql).fetchone()[0]

    conn.close()

    print(
        "backfill_done "
        f"embedded={embedded} failed={failed} skipped_empty={skipped_empty} "
        f"total={total} remaining={remaining} "
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
    p.add_argument(
        "--server-url",
        default="http://127.0.0.1:8080",
        help="llama-server base URL for batched embedding (default: %(default)s)",
    )
    p.add_argument("--no-server", action="store_true", help="Always use the llama-embedding subprocess")
    p.add_argument("--batch-size", type=int, default=32, help="Texts per server request (default: %(default)s)")
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
        server_url=None if args.no_server else args.server_url,
        batch_size=max(1, args.batch_size),
    )
    cfg.trigger = args.trigger
    return cfg


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
