"""OpenGymSyncAdapter: the only component that reads openGym user data.

Guarantees:
  * one workout and all of its exercises/sets are written in one transaction;
  * a stable deterministic workout id per (DayDayHealth user, openGym workout);
  * identical content is a no-op, so repeated cycles never duplicate rows;
  * changed content replaces the previous version in place;
  * a delete is only applied when openGym records an explicit tombstone in
    `deleted.workouts`; an unreadable/torn/corrupt file never deletes data;
  * every change is appended to `changes` in the same transaction.
"""

from __future__ import annotations

import hashlib
import json
import logging
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path

from . import db, profiles
from .catalog import ExerciseCatalog
from .config import Settings
from .parser import ParsedState, ParsedWorkout, StateFormatError, parse_state
from .state_reader import (
    StateReadError,
    StateSnapshot,
    SourceUnavailableError,
    discover_state_files,
    read_state_file,
)

logger = logging.getLogger("daydayhealth.sync")

SOURCE = "opengym"


def workout_id_for(wb_user_id: str, opengym_user_id: str, source_id: str) -> str:
    material = (
        f"{wb_user_id}\x1f{opengym_user_id}\x1f{SOURCE}\x1f{source_id}"
    ).encode("utf-8")
    return "wb_" + hashlib.sha256(material).hexdigest()[:24]


@dataclass
class CycleStats:
    started_at: str
    finished_at: str | None = None
    ok: bool = True
    files_seen: int = 0
    files_ok: int = 0
    upserts: int = 0
    deletes: int = 0
    unchanged: int = 0
    failed: int = 0
    skipped: int = 0
    errors: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "ok": self.ok,
            "files_seen": self.files_seen,
            "files_ok": self.files_ok,
            "upserts": self.upserts,
            "deletes": self.deletes,
            "unchanged": self.unchanged,
            "failed": self.failed,
            "skipped": self.skipped,
            "errors": list(self.errors),
            "started_at": self.started_at,
            "finished_at": self.finished_at,
        }


class OpenGymSyncAdapter:
    def __init__(self, settings: Settings | None = None):
        self.settings = settings or Settings.from_env()
        db.init_db(self.settings.db_path)
        self.catalog = ExerciseCatalog(self.settings.catalog_path)

    # ------------------------------------------------------------------ cycle
    def run_cycle(self) -> CycleStats:
        stats = CycleStats(started_at=db.utc_now_iso())
        conn = db.connect(self.settings.db_path)
        run_id: int | None = None
        try:
            cur = conn.execute(
                "INSERT INTO sync_runs(started_at) VALUES(?)", (stats.started_at,)
            )
            run_id = int(cur.lastrowid)

            try:
                files = discover_state_files(self.settings.opengym_data_dir)
            except SourceUnavailableError as exc:
                # Keep the run row/heartbeat up to date, but never reconcile
                # deletions when the source itself is unavailable.
                stats.ok = False
                stats.failed += 1
                stats.errors.append("source_unavailable")
                logger.error("sync.source.unavailable reason=%s", str(exc))
            else:
                stats.files_seen = len(files)
                for state_file in files:
                    self._process_file(conn, state_file, stats)

            stats.finished_at = db.utc_now_iso()
            stats.ok = stats.failed == 0
            conn.execute(
                """
                UPDATE sync_runs
                   SET finished_at=?, ok=?, error=?, files_seen=?, files_ok=?,
                       upserts=?, deletes=?, unchanged=?, failed=?
                 WHERE id=?
                """,
                (
                    stats.finished_at,
                    1 if stats.ok else 0,
                    "; ".join(stats.errors)[:1000] if stats.errors else None,
                    stats.files_seen,
                    stats.files_ok,
                    stats.upserts,
                    stats.deletes,
                    stats.unchanged,
                    stats.failed,
                    run_id,
                ),
            )
            db.set_meta(conn, "worker_last_cycle_at", stats.finished_at)
            if stats.errors:
                db.set_meta(conn, "worker_last_error", "; ".join(stats.errors)[:500])
            if stats.files_ok:
                db.set_meta(conn, "worker_last_success_at", stats.finished_at)
            logger.info("sync.cycle %s", json.dumps(stats.as_dict(), ensure_ascii=False))
            return stats
        except Exception as exc:  # noqa: BLE001 - cycle must not kill the worker
            self._fail_cycle(
                stats, [f"cycle_error:{type(exc).__name__}"], "sync cycle failed"
            )
            logger.exception("sync.cycle.failed")
            if run_id is not None:
                try:
                    conn.execute(
                        "UPDATE sync_runs SET finished_at=?, ok=0, error=?, "
                        "files_seen=?, files_ok=?, upserts=?, deletes=?, "
                        "unchanged=?, failed=? WHERE id=?",
                        (
                            db.utc_now_iso(),
                            "cycle_error",
                            stats.files_seen,
                            stats.files_ok,
                            stats.upserts,
                            stats.deletes,
                            stats.unchanged,
                            max(1, stats.failed),
                            run_id,
                        ),
                    )
                except sqlite3.Error:
                    pass
            return stats
        finally:
            conn.close()

    def _fail_cycle(
        self, stats: CycleStats, errors: list[str], message: str
    ) -> None:
        stats.ok = False
        stats.failed += 1
        stats.errors.extend(errors)
        stats.finished_at = db.utc_now_iso()
        logger.error("sync.error %s: %s", errors, message)

    # ------------------------------------------------------------------- file
    def _process_file(
        self, conn: sqlite3.Connection, state_file, stats: CycleStats
    ) -> None:
        now = db.utc_now_iso()
        mapping = conn.execute(
            "SELECT wb_user_id FROM opengym_user_map WHERE opengym_user_id=?",
            (state_file.user_id,),
        ).fetchone()
        self._mark_attempt(conn, state_file.user_id, now)

        if mapping is None:
            # Unknown users are never imported, and never guessed into another
            # DayDayHealth account.  They need an explicit operator mapping.
            stats.skipped += 1
            self._mark_error(conn, state_file.user_id, "unmapped_opengym_user", now)
            logger.warning("sync.unmapped user=%s", _short_user(state_file.user_id))
            return

        wb_user_id = str(mapping["wb_user_id"])
        try:
            snapshot = read_state_file(
                state_file,
                max_bytes=self.settings.max_state_file_bytes,
                retries=self.settings.read_retries,
                retry_delay=self.settings.read_retry_delay_seconds,
            )
        except StateReadError as exc:
            # Do NOT reconcile anything for this user.  A failed read must never
            # be interpreted as "all workouts disappeared".
            stats.failed += 1
            stats.errors.append("state_read_failed")
            self._mark_error(conn, state_file.user_id, "state_read_failed", now)
            logger.error(
                "sync.read.failed user=%s file=%s reason=%s",
                _short_user(state_file.user_id),
                state_file.name,
                str(exc),
            )
            return

        try:
            parsed = parse_state(snapshot.document, state_file.user_id, self.catalog)
        except StateFormatError as exc:
            stats.failed += 1
            stats.errors.append("state_parse_failed")
            self._mark_error(conn, state_file.user_id, "state_parse_failed", now)
            logger.error(
                "sync.parse.failed user=%s file=%s reason=%s",
                _short_user(state_file.user_id),
                state_file.name,
                str(exc),
            )
            return

        row = conn.execute(
            "SELECT last_file_hash, last_success_at FROM sync_state "
            "WHERE opengym_user_id=?",
            (state_file.user_id,),
        ).fetchone()
        if (
            row is not None
            and row["last_success_at"]
            and row["last_file_hash"] == snapshot.sha256
        ):
            stats.unchanged += 1
            stats.files_ok += 1
            conn.execute(
                "UPDATE sync_state SET last_success_at=?, last_error=NULL, "
                "updated_at=? WHERE opengym_user_id=?",
                (now, now, state_file.user_id),
            )
            logger.debug("sync.file.unchanged user=%s", _short_user(state_file.user_id))
            return

        try:
            counts = self.apply_state(conn, wb_user_id, state_file.user_id, parsed)
        except sqlite3.Error as exc:
            stats.failed += 1
            stats.errors.append("state_apply_failed")
            self._mark_error(conn, state_file.user_id, "state_apply_failed", now)
            logger.exception(
                "sync.apply.failed user=%s", _short_user(state_file.user_id)
            )
            return

        stats.upserts += counts["upserts"]
        stats.deletes += counts["deletes"]
        stats.unchanged += counts["unchanged"]
        stats.files_ok += 1
        for warning in parsed.warnings:
            logger.warning(
                "sync.parse.warning user=%s code=%s",
                _short_user(state_file.user_id),
                warning,
            )
        self._mark_success(
            conn,
            state_file.user_id,
            snapshot,
            len(parsed.workouts),
            now,
        )
        logger.info(
            "sync.file.ok user=%s file=%s workouts=%d upserts=%d deletes=%d unchanged=%d",
            _short_user(state_file.user_id),
            state_file.name,
            len(parsed.workouts),
            counts["upserts"],
            counts["deletes"],
            counts["unchanged"],
        )

    # ------------------------------------------------------------------ apply
    def apply_state(
        self,
        conn: sqlite3.Connection,
        wb_user_id: str,
        opengym_user_id: str,
        parsed: ParsedState,
    ) -> dict[str, int]:
        counts = {"upserts": 0, "deletes": 0, "unchanged": 0}
        seen = {w.source_id for w in parsed.workouts}

        for workout in parsed.workouts:
            action = self._upsert_workout(
                conn, wb_user_id, opengym_user_id, workout
            )
            if action == "same":
                counts["unchanged"] += 1
            else:
                counts["upserts"] += 1

        for source_id, deleted_at in parsed.tombstones.items():
            action = self._delete_workout(
                conn, wb_user_id, opengym_user_id, source_id, deleted_at
            )
            if action == "deleted":
                counts["deletes"] += 1
            elif action == "already_deleted":
                counts["unchanged"] += 1

        # Previously imported workouts that are absent from both `workouts` and
        # `deleted.workouts` are deliberately kept.  openGym may legitimately
        # omit a record during a partial client write; only an explicit
        # tombstone is authoritative.
        missing = conn.execute(
            """
            SELECT source_id FROM workouts
             WHERE wb_user_id=? AND source=? AND opengym_user_id=?
               AND deleted_at IS NULL
            """,
            (wb_user_id, SOURCE, opengym_user_id),
        ).fetchall()
        for row in missing:
            if row["source_id"] not in seen:
                logger.warning(
                    "sync.missing_without_tombstone user=%s source_id=%s",
                    _short_user(opengym_user_id),
                    _short_id(row["source_id"]),
                )
        if self.settings.profiles_dir:
            user = conn.execute(
                "SELECT username FROM users WHERE id=?", (wb_user_id,)
            ).fetchone()
            if user is not None:
                try:
                    profiles.write_profile(conn, self.settings, str(user["username"]))
                except Exception:  # noqa: BLE001
                    logger.exception("sync.profile_export_failed user=%s", _short_user(opengym_user_id))
        return counts

    def _upsert_workout(
        self,
        conn: sqlite3.Connection,
        wb_user_id: str,
        opengym_user_id: str,
        workout: ParsedWorkout,
    ) -> str:
        wid = workout_id_for(wb_user_id, opengym_user_id, workout.source_id)
        content_hash = workout.content_hash()
        now = db.utc_now_iso()

        with db.transaction(conn):
            row = conn.execute(
                """
                SELECT id, content_hash, deleted_at, list_seq FROM workouts
                 WHERE wb_user_id=? AND source=? AND opengym_user_id=?
                   AND source_id=?
                """,
                (wb_user_id, SOURCE, opengym_user_id, workout.source_id),
            ).fetchone()

            if row is None:
                list_seq = db.next_list_seq(conn)
                conn.execute(
                    """
                    INSERT INTO workouts(
                        id, wb_user_id, opengym_user_id, source, source_id,
                        date, started_at, ended_at, name, source_updated_at,
                        content_hash, list_seq, deleted_at, created_at, updated_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?)
                    """,
                    (
                        wid,
                        wb_user_id,
                        opengym_user_id,
                        SOURCE,
                        workout.source_id,
                        workout.date,
                        workout.started_at,
                        workout.ended_at,
                        workout.name,
                        workout.source_updated_at,
                        content_hash,
                        list_seq,
                        now,
                        now,
                    ),
                )
                self._save_json_workout(conn, wb_user_id, wid, list_seq, workout)
                seq = db.record_change(conn, wb_user_id, wid, "upsert", now)
                self._append_change(conn, wb_user_id, seq, wid, "upsert", now)
                return "insert"

            if row["content_hash"] == content_hash and row["deleted_at"] is None:
                return "same"

            wid = str(row["id"])
            conn.execute(
                """
                UPDATE workouts
                   SET date=?, started_at=?, ended_at=?, name=?,
                       source_updated_at=?, content_hash=?, deleted_at=NULL,
                       updated_at=?
                 WHERE id=? AND wb_user_id=?
                """,
                (
                    workout.date,
                    workout.started_at,
                    workout.ended_at,
                    workout.name,
                    workout.source_updated_at,
                    content_hash,
                    now,
                    wid,
                    wb_user_id,
                ),
            )
            list_seq = int(row["list_seq"])
            self._save_json_workout(conn, wb_user_id, wid, list_seq, workout)
            seq = db.record_change(conn, wb_user_id, wid, "upsert", now)
            self._append_change(conn, wb_user_id, seq, wid, "upsert", now)
            return "update"

    def _save_json_workout(
        self,
        conn: sqlite3.Connection,
        wb_user_id: str,
        wid: str,
        list_seq: int,
        workout: ParsedWorkout,
    ) -> None:
        user = conn.execute(
            "SELECT username FROM users WHERE id=?", (wb_user_id,)
        ).fetchone()
        if user is None:
            raise RuntimeError("unknown DayDayHealth user")
        profiles.save_workout(
            self.settings,
            str(user["username"]),
            workout.to_api(wid),
            list_seq=list_seq,
            content_hash=workout.content_hash(),
        )

    def _append_change(
        self,
        conn: sqlite3.Connection,
        wb_user_id: str,
        seq: int,
        wid: str,
        op: str,
        changed_at: str,
    ) -> None:
        user = conn.execute(
            "SELECT username FROM users WHERE id=?", (wb_user_id,)
        ).fetchone()
        if user is None or not self.settings.profiles_dir:
            return
        try:
            profiles.append_change(
                self.settings, str(user["username"]), seq, wid, op, changed_at
            )
        except Exception:  # noqa: BLE001
            logger.exception("sync.changes_jsonl_failed user=%s", _short_user(wb_user_id))

    def _replace_children(
        self, conn: sqlite3.Connection, workout_id: str, workout: ParsedWorkout
    ) -> None:
        conn.execute("DELETE FROM workout_sets WHERE workout_id=?", (workout_id,))
        conn.execute(
            "DELETE FROM workout_exercises WHERE workout_id=?", (workout_id,)
        )
        ord_counter = 0
        for position, exercise in enumerate(workout.exercises):
            conn.execute(
                """
                INSERT INTO workout_exercises(workout_id, position, exercise_id, name)
                VALUES(?,?,?,?)
                """,
                (workout_id, position, exercise.id, exercise.name),
            )
            for item in exercise.sets:
                conn.execute(
                    """
                    INSERT INTO workout_sets(
                        workout_id, exercise_position, ord, set_index, side,
                        weight_kg, reps, seconds, rpe, rir, warmup
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        workout_id,
                        position,
                        ord_counter,
                        item.index,
                        item.side,
                        item.weight_kg,
                        item.reps,
                        item.seconds,
                        item.rpe,
                        item.rir,
                        1 if item.warmup else 0,
                    ),
                )
                ord_counter += 1

    def _delete_workout(
        self,
        conn: sqlite3.Connection,
        wb_user_id: str,
        opengym_user_id: str,
        source_id: str,
        deleted_at: str,
    ) -> str:
        with db.transaction(conn):
            row = conn.execute(
                """
                SELECT id, deleted_at FROM workouts
                 WHERE wb_user_id=? AND source=? AND opengym_user_id=?
                   AND source_id=?
                """,
                (wb_user_id, SOURCE, opengym_user_id, source_id),
            ).fetchone()
            if row is None:
                return "not_found"
            if row["deleted_at"] is not None:
                return "already_deleted"
            wid = str(row["id"])
            conn.execute(
                "UPDATE workouts SET deleted_at=?, updated_at=? "
                "WHERE id=? AND wb_user_id=?",
                (deleted_at, db.utc_now_iso(), wid, wb_user_id),
            )
            conn.execute("DELETE FROM workout_sets WHERE workout_id=?", (wid,))
            conn.execute("DELETE FROM workout_exercises WHERE workout_id=?", (wid,))
            user = conn.execute(
                "SELECT username FROM users WHERE id=?", (wb_user_id,)
            ).fetchone()
            if user is not None and self.settings.profiles_dir:
                profiles.remove_workout(self.settings, str(user["username"]), wid)
            seq = db.record_change(conn, wb_user_id, wid, "delete", deleted_at)
            self._append_change(conn, wb_user_id, seq, wid, "delete", deleted_at)
            return "deleted"

    # ----------------------------------------------------------------- status
    def _mark_attempt(
        self, conn: sqlite3.Connection, opengym_user_id: str, now: str
    ) -> None:
        conn.execute(
            """
            INSERT INTO sync_state(opengym_user_id, last_attempt_at, updated_at)
            VALUES(?,?,?)
            ON CONFLICT(opengym_user_id) DO UPDATE SET
                last_attempt_at=excluded.last_attempt_at,
                updated_at=excluded.updated_at
            """,
            (opengym_user_id, now, now),
        )

    def _mark_error(
        self,
        conn: sqlite3.Connection,
        opengym_user_id: str,
        error: str,
        now: str,
    ) -> None:
        conn.execute(
            """
            INSERT INTO sync_state(opengym_user_id, last_attempt_at, last_error, updated_at)
            VALUES(?,?,?,?)
            ON CONFLICT(opengym_user_id) DO UPDATE SET
                last_attempt_at=excluded.last_attempt_at,
                last_error=excluded.last_error,
                updated_at=excluded.updated_at
            """,
            (opengym_user_id, now, error, now),
        )

    def _mark_success(
        self,
        conn: sqlite3.Connection,
        opengym_user_id: str,
        snapshot: StateSnapshot,
        workouts_seen: int,
        now: str,
    ) -> None:
        conn.execute(
            """
            INSERT INTO sync_state(
                opengym_user_id, last_attempt_at, last_success_at, last_error,
                last_file_hash, last_source_rev, workouts_seen, updated_at
            ) VALUES(?,?,?,NULL,?,?,?,?)
            ON CONFLICT(opengym_user_id) DO UPDATE SET
                last_attempt_at=excluded.last_attempt_at,
                last_success_at=excluded.last_success_at,
                last_error=NULL,
                last_file_hash=excluded.last_file_hash,
                last_source_rev=excluded.last_source_rev,
                workouts_seen=excluded.workouts_seen,
                updated_at=excluded.updated_at
            """,
            (
                opengym_user_id,
                now,
                now,
                snapshot.sha256,
                _source_rev(snapshot.document),
                workouts_seen,
                now,
            ),
        )


def _source_rev(document: object) -> int | None:
    if isinstance(document, dict):
        rev = document.get("_rev")
        if isinstance(rev, int) and not isinstance(rev, bool):
            return rev
    return None


def _short_user(user_id: str) -> str:
    return user_id[:4] + "…" if len(user_id) > 4 else "…"


def _short_id(value: str) -> str:
    return value[:8] + "…" if len(value) > 8 else value
