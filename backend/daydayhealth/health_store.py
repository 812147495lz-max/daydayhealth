"""Per-user health sample storage with idempotent deduplication.

Files:
    profiles/<username>/health/_index.sqlite
    profiles/<username>/health/<category>/<YYYY-MM>.jsonl

The index is per-user and only stores identity/time/hash metadata.  Full
samples stay in JSONL files.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import db, profiles
from .config import Settings
from .health_models import HealthSample


@dataclass
class HealthStoreResult:
    accepted: int = 0
    updated: int = 0
    duplicates: int = 0
    rejected: int = 0
    categories: dict[str, int] = field(default_factory=dict)
    errors: list[dict[str, Any]] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "schema_version": 1,
            "accepted": self.accepted,
            "updated": self.updated,
            "duplicates": self.duplicates,
            "rejected": self.rejected,
            "categories": self.categories,
            "errors": self.errors,
        }


INDEX_SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    dedup_key    TEXT PRIMARY KEY,
    category     TEXT NOT NULL,
    type         TEXT NOT NULL,
    source       TEXT NOT NULL,
    source_id    TEXT NOT NULL,
    external_id  TEXT,
    start_at     TEXT NOT NULL,
    end_at       TEXT NOT NULL,
    local_date   TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    version      INTEGER,
    file_path    TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_samples_date ON samples(local_date);
CREATE INDEX IF NOT EXISTS idx_samples_category_date
    ON samples(category, local_date);
"""


def _health_dir(settings: Settings, username: str) -> Path:
    return profiles.profile_dir(settings, username) / "health"


def _index_conn(settings: Settings, username: str) -> sqlite3.Connection:
    root = _health_dir(settings, username)
    root.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(
        str(root / "_index.sqlite"),
        timeout=30.0,
        isolation_level=None,
    )
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(INDEX_SCHEMA)
    return conn


def _canonical(sample: HealthSample) -> dict[str, Any]:
    dump = sample.model_dump(mode="json")
    # metadata is intentionally included in content identity
    return {
        "category": dump["category"],
        "type": dump["type"],
        "source": dump["source"],
        "source_id": dump["source_id"],
        "external_id": dump.get("external_id"),
        "start_at": dump["start_at"],
        "end_at": dump["end_at"],
        "local_date": dump["local_date"],
        "utc_offset_seconds": dump.get("utc_offset_seconds"),
        "value": dump.get("value"),
        "value_text": dump.get("value_text"),
        "value_json": dump.get("value_json"),
        "unit": dump.get("unit"),
        "recording_method": dump["recording_method"],
        "metadata": dump.get("metadata") or {},
    }


def _hashes(sample: HealthSample, canonical: dict[str, Any]) -> tuple[str, str]:
    if sample.external_id:
        material = (
            "ext|"
            + sample.source
            + "|"
            + sample.source_id
            + "|"
            + sample.type
            + "|"
            + sample.external_id
        )
    else:
        material = (
            "nat|"
            + sample.source
            + "|"
            + sample.source_id
            + "|"
            + sample.category
            + "|"
            + sample.type
            + "|"
            + canonical["start_at"]
            + "|"
            + canonical["end_at"]
        )
    dedup = hashlib.sha256(material.encode("utf-8")).hexdigest()
    content = hashlib.sha256(
        json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return dedup, content


def store_samples(
    settings: Settings,
    username: str,
    samples: list[HealthSample],
) -> HealthStoreResult:
    result = HealthStoreResult()
    if not samples:
        return result
    root = _health_dir(settings, username)
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / ".write.lock"
    lock_fh = lock_path.open("a+")
    conn = _index_conn(settings, username)
    now = db.utc_now_iso()
    try:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        conn.execute("BEGIN IMMEDIATE")
        for sample in samples:
            canonical = _canonical(sample)
            dedup_key, content_hash = _hashes(sample, canonical)
            existing = conn.execute(
                "SELECT content_hash, version, file_path FROM samples WHERE dedup_key=?",
                (dedup_key,),
            ).fetchone()

            action = "insert"
            if existing is not None:
                old_version = existing["version"]
                new_version = sample.version
                if existing["content_hash"] == content_hash:
                    action = "duplicate"
                elif (
                    old_version is not None
                    and new_version is not None
                    and new_version < int(old_version)
                ):
                    action = "duplicate"
                else:
                    action = "update"

            if action == "duplicate":
                result.duplicates += 1
                continue

            category = sample.category
            month = canonical["local_date"][:7]
            relative = Path("health") / category / f"{month}.jsonl"
            abs_path = profiles.profile_dir(settings, username) / relative
            abs_path.parent.mkdir(parents=True, exist_ok=True)
            record = {
                "schema_version": 1,
                "op": "upsert",
                "dedup_key": dedup_key,
                "content_hash": content_hash,
                "received_at": now,
                "sample": canonical,
            }
            with abs_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, ensure_ascii=False) + "\n")
                fh.flush()
                os.fsync(fh.fileno())

            conn.execute(
                """
                INSERT INTO samples(
                    dedup_key, category, type, source, source_id, external_id,
                    start_at, end_at, local_date, content_hash, version,
                    file_path, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(dedup_key) DO UPDATE SET
                    category=excluded.category,
                    type=excluded.type,
                    source=excluded.source,
                    source_id=excluded.source_id,
                    external_id=excluded.external_id,
                    start_at=excluded.start_at,
                    end_at=excluded.end_at,
                    local_date=excluded.local_date,
                    content_hash=excluded.content_hash,
                    version=excluded.version,
                    file_path=excluded.file_path,
                    updated_at=excluded.updated_at
                """,
                (
                    dedup_key,
                    category,
                    sample.type,
                    sample.source,
                    sample.source_id,
                    sample.external_id,
                    canonical["start_at"],
                    canonical["end_at"],
                    canonical["local_date"],
                    content_hash,
                    sample.version,
                    str(relative),
                    now,
                ),
            )
            result.categories[category] = result.categories.get(category, 0) + 1
            if action == "insert":
                result.accepted += 1
            else:
                result.updated += 1
        conn.execute("COMMIT")
    except Exception:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    finally:
        try:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
        finally:
            lock_fh.close()
            conn.close()
    return result
