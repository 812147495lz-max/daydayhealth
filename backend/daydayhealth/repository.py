"""Read model for the v1 sync API.

Every query is scoped by `wb_user_id`; a caller can never read another
DayDayHealth user's workouts, regardless of cursor or workout id.
"""

from __future__ import annotations

import sqlite3
from typing import Any

from .db import max_change_seq
from .security import Cursor


def _compact_workout(item: dict) -> dict:
    return {
        "id": item.get("id"),
        "source": item.get("source"),
        "source_id": item.get("source_id"),
        "date": item.get("date"),
        "started_at": item.get("started_at"),
        "ended_at": item.get("ended_at"),
        "name": item.get("name"),
        "exercises": item.get("exercises") or [],
    }


def load_workout(
    conn: sqlite3.Connection,
    wb_user_id: str,
    workout_id: str,
    settings: Any | None = None,
) -> dict | None:
    if settings is not None:
        from . import profiles

        user = conn.execute(
            "SELECT username FROM users WHERE id=?", (wb_user_id,)
        ).fetchone()
        if user is not None:
            item = profiles.get_workout(settings, str(user["username"]), workout_id)
            if item is not None:
                return _compact_workout(item)
    row = conn.execute(
        """
        SELECT id, source, source_id, date, started_at, ended_at, name
          FROM workouts
         WHERE id=? AND wb_user_id=? AND deleted_at IS NULL
           AND opengym_user_id IN (
               SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=?
           )
        """,
        (workout_id, wb_user_id, wb_user_id),
    ).fetchone()
    if row is None:
        return None

    exercise_rows = conn.execute(
        """
        SELECT position, exercise_id, name
          FROM workout_exercises
         WHERE workout_id=?
         ORDER BY position
        """,
        (workout_id,),
    ).fetchall()

    set_rows = conn.execute(
        """
        SELECT exercise_position, set_index, side, weight_kg, reps, seconds,
               rpe, rir, warmup
          FROM workout_sets
         WHERE workout_id=?
         ORDER BY ord
        """,
        (workout_id,),
    ).fetchall()

    by_position: dict[int, list[dict]] = {}
    for item in set_rows:
        parsed = {
            "index": int(item["set_index"]),
            "weight_kg": item["weight_kg"],
            "reps": item["reps"],
            "seconds": item["seconds"],
            "rpe": item["rpe"],
            "rir": item["rir"],
            "warmup": bool(item["warmup"]),
        }
        if item["side"] is not None:
            parsed["side"] = item["side"]
        by_position.setdefault(int(item["exercise_position"]), []).append(parsed)

    exercises = []
    for ex in exercise_rows:
        exercises.append(
            {
                "id": str(ex["exercise_id"]),
                "name": str(ex["name"]),
                "sets": by_position.get(int(ex["position"]), []),
            }
        )
    return {
        "id": str(row["id"]),
        "source": str(row["source"]),
        "source_id": str(row["source_id"]),
        "date": row["date"],
        "started_at": row["started_at"],
        "ended_at": row["ended_at"],
        "name": str(row["name"]),
        "exercises": exercises,
    }


def full_page_with_after(
    conn: sqlite3.Connection,
    wb_user_id: str,
    limit: int,
    after: int,
    settings: Any | None = None,
) -> tuple[list[dict], int, int, bool]:
    snapshot = max_change_seq(conn)
    rows = conn.execute(
        """
        SELECT id, list_seq
          FROM workouts
         WHERE wb_user_id=? AND deleted_at IS NULL
           AND opengym_user_id IN (
               SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=?
           )
           AND list_seq <= ? AND list_seq > ?
         ORDER BY list_seq
         LIMIT ?
        """,
        (wb_user_id, wb_user_id, snapshot, after, limit + 1),
    ).fetchall()
    has_more = len(rows) > limit
    page = rows[:limit]
    changes: list[dict] = []
    last_after = after
    for row in page:
        last_after = int(row["list_seq"])
        workout = load_workout(conn, wb_user_id, str(row["id"]), settings)
        if workout is not None:
            changes.append(
                {
                    "op": "upsert",
                    "workout_id": workout["id"],
                    "workout": workout,
                }
            )
    return changes, snapshot, last_after, has_more


def incremental_page(
    conn: sqlite3.Connection,
    wb_user_id: str,
    limit: int,
    after_seq: int,
    settings: Any | None = None,
) -> tuple[list[dict], int, bool]:
    rows = conn.execute(
        """
        SELECT c.seq, c.workout_id, c.op
          FROM changes c
          JOIN workouts w ON w.id = c.workout_id AND w.wb_user_id = c.wb_user_id
         WHERE c.wb_user_id=? AND c.seq > ?
           AND w.opengym_user_id IN (
               SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=?
           )
         ORDER BY c.seq
         LIMIT ?
        """,
        (wb_user_id, after_seq, wb_user_id, limit),
    ).fetchall()
    if not rows:
        return [], after_seq, False

    # Collapse several changes of the same workout inside the page: the app
    # only needs the latest state.  Deletes are never dropped if latest.
    latest: dict[str, dict] = {}
    for row in rows:
        latest[str(row["workout_id"])] = {
            "seq": int(row["seq"]),
            "op": str(row["op"]),
        }
    last_seq = int(rows[-1]["seq"])
    has_more = (
        conn.execute(
            "SELECT 1 FROM changes c JOIN workouts w "
            "ON w.id=c.workout_id AND w.wb_user_id=c.wb_user_id "
            "WHERE c.wb_user_id=? AND c.seq>? AND w.opengym_user_id IN "
            "(SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=?) "
            "LIMIT 1",
            (wb_user_id, last_seq, wb_user_id),
        ).fetchone()
        is not None
    )

    changes: list[dict] = []
    for workout_id, meta in sorted(latest.items(), key=lambda kv: kv[1]["seq"]):
        workout = (
            load_workout(conn, wb_user_id, workout_id, settings)
            if meta["op"] == "upsert"
            else None
        )
        if meta["op"] == "delete" or workout is None:
            changes.append(
                {"op": "delete", "workout_id": workout_id, "workout": None}
            )
        else:
            changes.append(
                {"op": "upsert", "workout_id": workout_id, "workout": workout}
            )
    return changes, last_seq, has_more


def source_status(conn: sqlite3.Connection, wb_user_id: str) -> list[dict]:
    mappings = conn.execute(
        "SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=? "
        "ORDER BY opengym_user_id",
        (wb_user_id,),
    ).fetchall()
    result = []
    for mapping in mappings:
        og_id = str(mapping["opengym_user_id"])
        state = conn.execute(
            "SELECT last_attempt_at, last_success_at, last_error "
            "FROM sync_state WHERE opengym_user_id=?",
            (og_id,),
        ).fetchone()
        counts = conn.execute(
            """
            SELECT
              SUM(CASE WHEN deleted_at IS NULL THEN 1 ELSE 0 END) AS active,
              SUM(CASE WHEN deleted_at IS NOT NULL THEN 1 ELSE 0 END) AS deleted
            FROM workouts
             WHERE wb_user_id=? AND opengym_user_id=? AND source='opengym'
            """,
            (wb_user_id, og_id),
        ).fetchone()
        result.append(
            {
                "opengym_user_id": og_id,
                "last_attempt_at": state["last_attempt_at"] if state else None,
                "last_success_at": state["last_success_at"] if state else None,
                "last_error": state["last_error"] if state else None,
                "workouts": int(counts["active"] or 0),
                "deleted": int(counts["deleted"] or 0),
            }
        )
    return result
