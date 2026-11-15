"""Daily CSV -> accounts/profiles/archive reconciliation.

Rules:
  * CSV unreadable or empty -> abort without deleting anything.
  * New CSV users get the default password and must change it.
  * Users absent from CSV are cold-archived for 90 days; their DayDayHealth
    training rows are removed, but openGym's volume is never touched.
  * Re-added users restore the archived profile (other data) and re-import
    training data from openGym.
  * Expired archives are purged after the retention period.
"""

from __future__ import annotations

import secrets
import sqlite3
from dataclasses import dataclass, field

from . import db, opengym_names, profiles, security, whitelist
from .config import Settings


@dataclass
class ReconcileStats:
    aborted: bool = False
    reason: str = ""
    created: list[str] = field(default_factory=list)
    restored: list[str] = field(default_factory=list)
    archived: list[str] = field(default_factory=list)
    purged: list[str] = field(default_factory=list)
    mapped: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "aborted": self.aborted,
            "reason": self.reason,
            "created": self.created,
            "restored": self.restored,
            "archived": self.archived,
            "purged": self.purged,
            "mapped": self.mapped,
            "errors": self.errors,
        }


def _delete_user_training(conn: sqlite3.Connection, user_id: str) -> None:
    conn.execute(
        "DELETE FROM workout_sets WHERE workout_id IN "
        "(SELECT id FROM workouts WHERE wb_user_id=?)",
        (user_id,),
    )
    conn.execute(
        "DELETE FROM workout_exercises WHERE workout_id IN "
        "(SELECT id FROM workouts WHERE wb_user_id=?)",
        (user_id,),
    )
    conn.execute("DELETE FROM changes WHERE wb_user_id=?", (user_id,))
    conn.execute("DELETE FROM workouts WHERE wb_user_id=?", (user_id,))
    conn.execute("DELETE FROM api_tokens WHERE user_id=?", (user_id,))
    conn.execute("DELETE FROM login_attempts WHERE username=(SELECT username FROM users WHERE id=?)", (user_id,))


def run_reconcile(
    conn: sqlite3.Connection,
    settings: Settings,
    pepper: bytes,
) -> ReconcileStats:
    stats = ReconcileStats()
    rows = whitelist.load(settings.user_csv_path or "")
    if rows is None:
        stats.aborted = True
        stats.reason = "csv_unavailable"
        return stats
    if not rows:
        stats.aborted = True
        stats.reason = "csv_empty"
        return stats

    names = opengym_names.load(settings.opengym_users_snapshot) or {}
    csv_names = set(rows)
    now = db.utc_now_iso()
    default_hash = security.hash_password(settings.default_password, pepper)

    for username, entry in rows.items():
        user = conn.execute(
            "SELECT id, password_hash, archived_at FROM users WHERE username=?",
            (username,),
        ).fetchone()
        uid = ""
        if user is None:
            uid = "wb_usr_" + secrets.token_hex(8)
            conn.execute(
                "INSERT INTO users(id, username, created_at, password_hash, "
                "must_change_password) VALUES(?,?,?,?,1)",
                (uid, username, now, default_hash),
            )
            stats.created.append(username)
            entry.reset_password = True
        else:
            uid = str(user["id"])
            if user["archived_at"]:
                profiles.restore_user(conn, settings, username)
                conn.execute(
                    "UPDATE users SET password_hash=?, archived_at=NULL, "
                    "purge_after=NULL, must_change_password=1 WHERE id=?",
                    (default_hash, uid),
                )
                entry.reset_password = True
                stats.restored.append(username)
        # force a change whenever we supplied/reset the default password
        if user is None or user["archived_at"] or not user["password_hash"]:
            conn.execute(
                "UPDATE users SET must_change_password=1 WHERE id=?", (uid,)
            )
            whitelist.update(
                settings.user_csv_path or "",
                username,
                entry.last_login_at,
                entry.anomaly == "true",
                locked=entry.locked,
                reset_password=True,
            )

        og_name = entry.opengym_name.strip()
        og_id = names.get(og_name, "") if og_name else ""
        if og_id:
            mapped = conn.execute(
                "SELECT wb_user_id FROM opengym_user_map WHERE opengym_user_id=?",
                (og_id,),
            ).fetchone()
            if mapped is None:
                conn.execute(
                    "INSERT INTO opengym_user_map(opengym_user_id, wb_user_id, created_at) "
                    "VALUES(?,?,?)",
                    (og_id, uid, now),
                )
                stats.mapped.append(og_name)
            elif str(mapped["wb_user_id"]) != uid:
                stats.errors.append(f"opengym_id_already_mapped:{og_id}")
        try:
            profiles.write_profile(conn, settings, username)
        except Exception as exc:  # noqa: BLE001
            stats.errors.append(f"profile_write:{username}:{type(exc).__name__}")

    # archive active users missing from CSV
    active = conn.execute(
        "SELECT id, username FROM users WHERE archived_at IS NULL"
    ).fetchall()
    for user in active:
        username = str(user["username"])
        if username in csv_names:
            continue
        try:
            profiles.archive_user(conn, settings, username, "removed_from_csv")
            _delete_user_training(conn, str(user["id"]))
            mappings = conn.execute(
                "SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=?",
                (user["id"],),
            ).fetchall()
            for mapping in mappings:
                conn.execute(
                    "DELETE FROM sync_state WHERE opengym_user_id=?",
                    (mapping["opengym_user_id"],),
                )
            conn.execute("DELETE FROM opengym_user_map WHERE wb_user_id=?", (user["id"],))
            stats.archived.append(username)
        except Exception as exc:  # noqa: BLE001
            stats.errors.append(f"archive:{username}:{type(exc).__name__}")

    stats.purged = profiles.purge_expired(conn, settings)
    return stats
