"""SQLite schema and small database helpers.

The database is intentionally the only state shared by the API and the sync
worker.  WAL mode lets the API read while the worker commits a workout.
"""

from __future__ import annotations

import contextlib
import datetime as _dt
import sqlite3
from pathlib import Path
from typing import Iterator

SCHEMA_VERSION = 2

SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    created_at        TEXT NOT NULL,
    disabled          INTEGER NOT NULL DEFAULT 0,
    password_hash     TEXT,
    last_login_at     TEXT,
    last_login_ip     TEXT,
    previous_login_at TEXT,
    previous_login_ip TEXT,
    archived_at       TEXT,
    purge_after       TEXT,
    profile_dir       TEXT,
    must_change_password INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS app_backups (
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id          TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    size        INTEGER NOT NULL CHECK (size > 0),
    payload     BLOB NOT NULL,
    PRIMARY KEY (user_id, id)
);

CREATE TABLE IF NOT EXISTS api_tokens (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   TEXT NOT NULL UNIQUE,
    label        TEXT,
    created_at   TEXT NOT NULL,
    last_used_at TEXT,
    revoked      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_api_tokens_user ON api_tokens(user_id);

-- Password-login lockout, scoped to (username, client IP) so an attacker
-- cannot lock out an already authenticated device or another network.
CREATE TABLE IF NOT EXISTS login_attempts (
    key             TEXT PRIMARY KEY,
    username        TEXT NOT NULL,
    ip              TEXT NOT NULL,
    failures        INTEGER NOT NULL DEFAULT 0,
    locked_until    TEXT,
    last_attempt_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_login_attempts_user ON login_attempts(username);

-- Explicit, operator-managed mapping.  Only openGym user ids (from the state
-- file name) are mapped; nothing from openGym's auth database is imported.
CREATE TABLE IF NOT EXISTS opengym_user_map (
    opengym_user_id TEXT PRIMARY KEY,
    wb_user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_opengym_map_user ON opengym_user_map(wb_user_id);

CREATE TABLE IF NOT EXISTS workouts (
    id                TEXT PRIMARY KEY,
    wb_user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    opengym_user_id   TEXT NOT NULL,
    source            TEXT NOT NULL,
    source_id         TEXT NOT NULL,
    date              TEXT,
    started_at        TEXT,
    ended_at          TEXT,
    name              TEXT,
    source_updated_at TEXT,
    content_hash      TEXT NOT NULL,
    list_seq          INTEGER NOT NULL,
    deleted_at        TEXT,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL,
    UNIQUE (wb_user_id, source, opengym_user_id, source_id)
);
CREATE INDEX IF NOT EXISTS idx_workouts_user_list
    ON workouts(wb_user_id, deleted_at, list_seq);
CREATE INDEX IF NOT EXISTS idx_workouts_user_source
    ON workouts(wb_user_id, source, opengym_user_id, source_id);

CREATE TABLE IF NOT EXISTS workout_exercises (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    workout_id   TEXT NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
    position     INTEGER NOT NULL,
    exercise_id  TEXT NOT NULL,
    name         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_exercises_workout ON workout_exercises(workout_id);

CREATE TABLE IF NOT EXISTS workout_sets (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    workout_id         TEXT NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
    exercise_position  INTEGER NOT NULL,
    ord                INTEGER NOT NULL,
    set_index          INTEGER NOT NULL,
    side               TEXT,
    weight_kg          REAL,
    reps               REAL,
    seconds            REAL,
    rpe                REAL,
    rir                REAL,
    warmup             INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_sets_workout ON workout_sets(workout_id);

-- Append-only change feed.  seq is global; the API filters by wb_user_id.
CREATE TABLE IF NOT EXISTS changes (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    wb_user_id  TEXT NOT NULL,
    workout_id  TEXT NOT NULL,
    op          TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
    changed_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_changes_user_seq ON changes(wb_user_id, seq);
CREATE INDEX IF NOT EXISTS idx_changes_workout ON changes(workout_id);

CREATE TABLE IF NOT EXISTS sync_state (
    opengym_user_id TEXT PRIMARY KEY,
    last_attempt_at TEXT,
    last_success_at TEXT,
    last_error      TEXT,
    last_file_hash  TEXT,
    last_source_rev INTEGER,
    workouts_seen   INTEGER NOT NULL DEFAULT 0,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_runs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at  TEXT NOT NULL,
    finished_at TEXT,
    ok          INTEGER,
    error       TEXT,
    files_seen  INTEGER NOT NULL DEFAULT 0,
    files_ok    INTEGER NOT NULL DEFAULT 0,
    upserts     INTEGER NOT NULL DEFAULT 0,
    deletes     INTEGER NOT NULL DEFAULT 0,
    unchanged   INTEGER NOT NULL DEFAULT 0,
    failed      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""


def utc_now() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


def iso_z(dt: _dt.datetime) -> str:
    """UTC ISO-8601 with a literal Z suffix (second precision)."""
    return dt.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_now_iso() -> str:
    return iso_z(utc_now())


def ms_to_iso(value: object) -> str | None:
    """Convert openGym epoch milliseconds to UTC ISO-8601.

    Missing/invalid values stay None.  Sub-second precision is intentionally
    dropped to match the v1 contract examples.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value <= 0:
        return None
    try:
        dt = _dt.datetime.fromtimestamp(float(value) / 1000.0, _dt.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return iso_z(dt)


def connect(path: str) -> sqlite3.Connection:
    parent = Path(path).parent
    parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(
        path,
        timeout=15.0,
        isolation_level=None,
        check_same_thread=False,
    )
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=15000")
    return conn


def init_db(path: str) -> None:
    conn = connect(path)
    try:
        conn.executescript(SCHEMA)
        # Additive migration for databases created before password login.
        user_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(users)").fetchall()
        }
        for column, ddl in (
            ("password_hash", "ALTER TABLE users ADD COLUMN password_hash TEXT"),
            ("last_login_at", "ALTER TABLE users ADD COLUMN last_login_at TEXT"),
            ("last_login_ip", "ALTER TABLE users ADD COLUMN last_login_ip TEXT"),
            ("previous_login_at", "ALTER TABLE users ADD COLUMN previous_login_at TEXT"),
            ("previous_login_ip", "ALTER TABLE users ADD COLUMN previous_login_ip TEXT"),
            ("archived_at", "ALTER TABLE users ADD COLUMN archived_at TEXT"),
            ("purge_after", "ALTER TABLE users ADD COLUMN purge_after TEXT"),
            ("profile_dir", "ALTER TABLE users ADD COLUMN profile_dir TEXT"),
            (
                "must_change_password",
                "ALTER TABLE users ADD COLUMN must_change_password INTEGER NOT NULL DEFAULT 0",
            ),
        ):
            if column not in user_columns:
                conn.execute(ddl)
        conn.execute(
            "INSERT INTO schema_meta(key, value) VALUES('schema_version', ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (str(SCHEMA_VERSION),),
        )
    finally:
        conn.close()


@contextlib.contextmanager
def transaction(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    """One explicit write transaction; rolls back on any exception."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    else:
        conn.execute("COMMIT")


def max_change_seq(conn: sqlite3.Connection) -> int:
    row = conn.execute("SELECT COALESCE(MAX(seq), 0) AS m FROM changes").fetchone()
    return int(row["m"])


def next_list_seq(conn: sqlite3.Connection) -> int:
    """Ordering key for a newly created workout (creation order, immutable)."""
    return max_change_seq(conn) + 1


def record_change(
    conn: sqlite3.Connection,
    wb_user_id: str,
    workout_id: str,
    op: str,
    changed_at: str | None = None,
) -> int:
    cur = conn.execute(
        "INSERT INTO changes(wb_user_id, workout_id, op, changed_at) VALUES(?,?,?,?)",
        (wb_user_id, workout_id, op, changed_at or utc_now_iso()),
    )
    return int(cur.lastrowid)


def get_meta(conn: sqlite3.Connection, key: str) -> str | None:
    row = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return None if row is None else row["value"]


def set_meta(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO meta(key, value) VALUES(?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )
