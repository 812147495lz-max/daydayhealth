"""Per-user filesystem profiles and 90-day cold archive.

Active layout:
    <profiles_dir>/<safe-username>/profile.json
    <profiles_dir>/<safe-username>/workouts.json

Archive layout:
    <archive_dir>/<safe-username>/<archived-at>/profile.json
    <archive_dir>/<safe-username>/<archived-at>/meta.json

openGym's own volume is never touched here.  A restored user keeps the
archived profile (settings/other data) and re-imports training data from
openGym, as agreed.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import shutil
import sqlite3
from pathlib import Path

from . import db
from .config import Settings
from .repository import load_workout

_SAFE = re.compile(r"[^A-Za-z0-9_.-]+")


def safe_name(username: str) -> str:
    base = _SAFE.sub("_", username.strip())[:80] or "user"
    if base != username.strip():
        base = f"{base}-{hashlib.sha256(username.encode('utf-8')).hexdigest()[:8]}"
    return base


def profile_dir(settings: Settings, username: str) -> Path:
    return Path(settings.profiles_dir) / safe_name(username)


def _atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def write_profile(conn: sqlite3.Connection, settings: Settings, username: str) -> Path:
    user = conn.execute(
        "SELECT id, username, last_login_at, last_login_ip, previous_login_at, "
        "previous_login_ip, archived_at, purge_after FROM users WHERE username=?",
        (username,),
    ).fetchone()
    if user is None:
        raise ValueError(f"unknown user {username}")
    mapping = conn.execute(
        "SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=?",
        (user["id"],),
    ).fetchone()
    path = profile_dir(settings, username) / "profile.json"
    _atomic_json(
        path,
        {
            "username": user["username"],
            "user_id": user["id"],
            "opengym_user_id": mapping["opengym_user_id"] if mapping else None,
            "last_login_at": user["last_login_at"],
            "last_login_ip": user["last_login_ip"],
            "previous_login_at": user["previous_login_at"],
            "previous_login_ip": user["previous_login_ip"],
            "archived_at": user["archived_at"],
            "purge_after": user["purge_after"],
        },
    )
    conn.execute(
        "UPDATE users SET profile_dir=? WHERE id=?",
        (str(path.parent), user["id"]),
    )
    changes = path.parent / "changes.jsonl"
    changes.touch(exist_ok=True)
    os.chmod(changes, 0o644)
    return path



def _workouts_path(settings: Settings, username: str) -> Path:
    return profile_dir(settings, username) / "workouts.json"



def append_change(
    settings: Settings,
    username: str,
    seq: int,
    workout_id: str,
    op: str,
    changed_at: str,
) -> None:
    path = profile_dir(settings, username) / "changes.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(
        {
            "seq": int(seq),
            "workout_id": workout_id,
            "op": op,
            "changed_at": changed_at,
        },
        ensure_ascii=False,
    )
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(path, 0o644)


def load_changes(settings: Settings, username: str) -> list[dict]:
    path = profile_dir(settings, username) / "changes.jsonl"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (FileNotFoundError, OSError):
        return []
    out = []
    for line in lines:
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            out.append(item)
    return out

def load_workouts(settings: Settings, username: str) -> dict:
    path = _workouts_path(settings, username)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"schema_version": 1, "username": username, "workouts": []}
    if not isinstance(payload, dict) or not isinstance(payload.get("workouts"), list):
        return {"schema_version": 1, "username": username, "workouts": []}
    return payload


def save_workout(
    settings: Settings,
    username: str,
    workout: dict,
    *,
    list_seq: int,
    content_hash: str,
) -> None:
    payload = load_workouts(settings, username)
    items = [w for w in payload["workouts"] if w.get("id") != workout.get("id")]
    item = dict(workout)
    item["list_seq"] = int(list_seq)
    item["content_hash"] = content_hash
    items.append(item)
    items.sort(key=lambda w: int(w.get("list_seq", 0)))
    payload = {
        "schema_version": 1,
        "username": username,
        "updated_at": db.utc_now_iso(),
        "workouts": items,
    }
    _atomic_json(_workouts_path(settings, username), payload)


def remove_workout(settings: Settings, username: str, workout_id: str) -> None:
    payload = load_workouts(settings, username)
    items = [w for w in payload["workouts"] if w.get("id") != workout_id]
    payload = {
        "schema_version": 1,
        "username": username,
        "updated_at": db.utc_now_iso(),
        "workouts": items,
    }
    _atomic_json(_workouts_path(settings, username), payload)


def get_workout(settings: Settings, username: str, workout_id: str) -> dict | None:
    for item in load_workouts(settings, username).get("workouts", []):
        if item.get("id") == workout_id:
            return item
    return None

def export_workouts(
    conn: sqlite3.Connection, settings: Settings, username: str
) -> Path:
    user = conn.execute(
        "SELECT id FROM users WHERE username=?", (username,)
    ).fetchone()
    if user is None:
        raise ValueError(f"unknown user {username}")
    rows = conn.execute(
        "SELECT id FROM workouts WHERE wb_user_id=? AND deleted_at IS NULL "
        "ORDER BY list_seq",
        (user["id"],),
    ).fetchall()
    workouts = []
    for row in rows:
        item = load_workout(conn, str(user["id"]), str(row["id"]))
        if item is not None:
            workouts.append(item)
    path = profile_dir(settings, username) / "workouts.json"
    _atomic_json(
        path,
        {
            "schema_version": 1,
            "username": username,
            "exported_at": db.utc_now_iso(),
            "workouts": workouts,
        },
    )
    return path


def _archive_root(settings: Settings, username: str) -> Path:
    return Path(settings.archive_dir) / safe_name(username)


def archive_user(
    conn: sqlite3.Connection,
    settings: Settings,
    username: str,
    reason: str,
) -> Path | None:
    user = conn.execute(
        "SELECT id, archived_at FROM users WHERE username=?", (username,)
    ).fetchone()
    if user is None:
        return None
    if user["archived_at"]:
        return None
    now = db.utc_now_iso()
    stamp = now.replace(":", "").replace("-", "")
    dest = _archive_root(settings, username) / stamp
    dest.mkdir(parents=True, exist_ok=True)
    src = profile_dir(settings, username)
    if (src / "profile.json").exists():
        shutil.copy2(src / "profile.json", dest / "profile.json")
    if (src / "health").exists():
        shutil.copytree(src / "health", dest / "health", dirs_exist_ok=True)
    _atomic_json(
        dest / "meta.json",
        {
            "username": username,
            "user_id": user["id"],
            "archived_at": now,
            "reason": reason,
            "restore_policy": "profile_restored_training_reimported_from_opengym",
        },
    )
    # The active folder is removed; the cold archive is the only copy of the
    # profile.  Training data will be re-imported from openGym on restore.
    if src.exists():
        shutil.rmtree(src, ignore_errors=True)
    purge_after = db.iso_z(
        db.utc_now() + dt.timedelta(days=settings.archive_days)
    )
    conn.execute(
        "UPDATE users SET archived_at=?, purge_after=?, profile_dir=? WHERE id=?",
        (now, purge_after, str(dest), user["id"]),
    )
    return dest


def restore_user(
    conn: sqlite3.Connection,
    settings: Settings,
    username: str,
) -> Path | None:
    user = conn.execute(
        "SELECT id FROM users WHERE username=?", (username,)
    ).fetchone()
    if user is None:
        return None
    root = _archive_root(settings, username)
    candidates = sorted((p for p in root.iterdir() if p.is_dir()), reverse=True) if root.exists() else []
    if not candidates:
        return None
    latest = candidates[0]
    dest = profile_dir(settings, username)
    dest.mkdir(parents=True, exist_ok=True)
    if (latest / "profile.json").exists():
        shutil.copy2(latest / "profile.json", dest / "profile.json")
    if (latest / "health").exists():
        shutil.copytree(latest / "health", dest / "health", dirs_exist_ok=True)
    conn.execute(
        "UPDATE users SET archived_at=NULL, purge_after=NULL, profile_dir=? WHERE id=?",
        (str(dest), user["id"]),
    )
    return dest


def purge_expired(conn: sqlite3.Connection, settings: Settings) -> list[str]:
    now = db.utc_now_iso()
    rows = conn.execute(
        "SELECT id, username FROM users WHERE archived_at IS NOT NULL "
        "AND purge_after IS NOT NULL AND purge_after<=?",
        (now,),
    ).fetchall()
    purged: list[str] = []
    for row in rows:
        root = _archive_root(settings, row["username"])
        if root.exists():
            shutil.rmtree(root, ignore_errors=True)
        conn.execute("DELETE FROM users WHERE id=?", (row["id"],))
        purged.append(str(row["username"]))
    return purged
