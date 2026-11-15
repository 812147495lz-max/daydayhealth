from __future__ import annotations

import json
import sqlite3

import pytest

from daydayhealth import profiles

from .conftest import (
    END,
    OG_A,
    START,
    TOKEN_A,
    auth,
    make_workout,
    rows,
    sync,
)


def json_sets(env, username="alice"):
    payload = profiles.load_workouts(env.settings, username)
    out = []
    for workout in payload.get("workouts", []):
        for exercise in workout.get("exercises", []):
            out.extend(exercise.get("sets", []))
    return out


def test_first_import_normalizes_units_rpe_rir_warmup_side(env, adapter, client):
    entries = [
        {
            "id": "0025",
            "sets": [
                {"w": 100, "r": 10, "done": True, "phase": "warmup", "at": START},
                {"w": 999, "r": 1, "done": False, "at": START},
                {"w": 135.5, "r": 8, "done": True, "rpe": 8, "at": START + 1000},
                {"w": 60, "r": 6, "done": True, "rir": 2, "sec": 45, "at": START + 2000},
            ],
        },
        {
            "id": "0584",
            "sets": [
                {
                    "done": True,
                    "sides": {
                        "L": {"w": 20, "r": 12, "done": True},
                        "R": {"w": 22.5, "r": 10, "done": True},
                    },
                }
            ],
        },
    ]
    env.write_state(workouts=[make_workout(entries=entries)], unit="lb", lang="zh")

    stats = adapter.run_cycle()
    assert stats.ok and stats.upserts == 1, stats.as_dict()

    workouts = rows(env, "SELECT * FROM workouts")
    assert len(workouts) == 1
    w = workouts[0]
    assert w["source"] == "opengym"
    assert w["source_id"] == "w1"
    assert w["date"] == "2026-11-04"
    assert w["started_at"] == "2026-11-04T10:00:00Z"
    assert w["ended_at"] == "2026-11-04T11:00:00Z"
    assert w["name"] == "胸部训练"
    assert w["deleted_at"] is None

    sets = json_sets(env)
    assert [s["index"] for s in sets] == [1, 3, 4, 1, 1]
    assert sets[0]["weight_kg"] == pytest.approx(45.3592)
    assert sets[0]["warmup"] is True
    assert sets[1]["weight_kg"] == pytest.approx(61.4618)
    assert sets[1]["rpe"] == 8
    assert sets[2]["seconds"] == 45
    assert sets[2]["rir"] == 2
    assert sets[3]["side"] == "left" and sets[4]["side"] == "right"
    assert sets[3]["weight_kg"] == pytest.approx(20 * 0.45359237, abs=1e-4)
    assert sets[4]["reps"] == 10

    body = sync(client, TOKEN_A).json()
    assert body["schema_version"] == 1
    assert body["has_more"] is False
    assert body["changes"][0]["op"] == "upsert"
    api_w = body["changes"][0]["workout"]
    assert api_w["id"].startswith("wb_")
    assert api_w["source_id"] == "w1"
    assert api_w["name"] == "胸部训练"
    assert api_w["exercises"][0]["name"] == "杠铃卧推"
    assert api_w["exercises"][0]["sets"][0]["weight_kg"] == pytest.approx(45.3592)
    assert api_w["exercises"][0]["sets"][0]["warmup"] is True
    assert api_w["exercises"][1]["sets"][0]["side"] == "left"
    assert api_w["exercises"][1]["sets"][1]["side"] == "right"


def test_added_workout_arrives_incrementally(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    first = sync(client, TOKEN_A).json()
    cursor = first["next_cursor"]
    assert len(first["changes"]) == 1

    env.write_state(
        workouts=[make_workout("w1"), make_workout("w2", name="背部训练")]
    )
    adapter.run_cycle()
    body = sync(client, TOKEN_A, cursor).json()
    assert [c["op"] for c in body["changes"]] == ["upsert"]
    assert body["changes"][0]["workout"]["source_id"] == "w2"
    assert body["has_more"] is False
    assert len(rows(env, "SELECT * FROM workouts")) == 2

    # Feeding the returned cursor again yields nothing.
    assert sync(client, TOKEN_A, body["next_cursor"]).json()["changes"] == []


def test_modified_workout_replaces_old_version(env, adapter, client):
    env.write_state(
        workouts=[
            make_workout(
                "w1",
                entries=[
                    {"id": "0025", "sets": [{"w": 40, "r": 10, "done": True}]}
                ],
            )
        ]
    )
    adapter.run_cycle()
    cursor = sync(client, TOKEN_A).json()["next_cursor"]
    old_id = rows(env, "SELECT id FROM workouts")[0]["id"]

    env.write_state(
        workouts=[
            make_workout(
                "w1",
                entries=[
                    {"id": "0025", "sets": [{"w": 70, "r": 5, "done": True}]}
                ],
            )
        ]
    )
    stats = adapter.run_cycle()
    assert stats.upserts == 1

    body = sync(client, TOKEN_A, cursor).json()
    assert len(body["changes"]) == 1
    assert body["changes"][0]["op"] == "upsert"
    assert body["changes"][0]["workout_id"] == old_id
    assert body["changes"][0]["workout"]["exercises"][0]["sets"][0][
        "weight_kg"
    ] == 70
    assert body["changes"][0]["workout"]["exercises"][0]["sets"][0]["reps"] == 5

    all_workouts = rows(env, "SELECT * FROM workouts")
    assert len(all_workouts) == 1
    assert all_workouts[0]["id"] == old_id
    all_sets = json_sets(env)
    assert len(all_sets) == 1 and all_sets[0]["weight_kg"] == 70


def test_deleted_workout_emits_delete_and_full_init_omits_it(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    cursor = sync(client, TOKEN_A).json()["next_cursor"]
    wid = rows(env, "SELECT id FROM workouts")[0]["id"]

    env.write_state(workouts=[], deleted={"w1": START + 99999})
    stats = adapter.run_cycle()
    assert stats.deletes == 1

    body = sync(client, TOKEN_A, cursor).json()
    assert body["changes"] == [
        {"op": "delete", "workout_id": wid, "workout": None}
    ]
    assert sync(client, TOKEN_A).json()["changes"] == []

    db_row = rows(env, "SELECT * FROM workouts")[0]
    assert db_row["deleted_at"] is not None
    assert rows(env, "SELECT * FROM workout_sets") == []
    assert rows(env, "SELECT * FROM workout_exercises") == []

    # A second cycle must not emit another delete.
    before = len(rows(env, "SELECT * FROM changes"))
    stats2 = adapter.run_cycle()
    assert stats2.deletes == 0
    assert len(rows(env, "SELECT * FROM changes")) == before


def test_repeated_sync_does_not_duplicate(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    first_changes = rows(env, "SELECT * FROM changes")
    first_sets = json_sets(env)

    stats = adapter.run_cycle()
    assert stats.upserts == 0
    assert stats.unchanged >= 1
    assert len(rows(env, "SELECT * FROM changes")) == len(first_changes)
    assert len(json_sets(env)) == len(first_sets)

    # Rewriting the file with different whitespace (same semantic content,
    # different file hash) still must not create a new workout/change.
    env.write_state(workouts=[make_workout("w1")], unit="kg")
    stats2 = adapter.run_cycle()
    assert stats2.upserts == 0
    assert len(rows(env, "SELECT * FROM changes")) == len(first_changes)
    assert len(rows(env, "SELECT * FROM workouts")) == 1


def test_worker_restart_resumes_from_persisted_state(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    cursor = sync(client, TOKEN_A).json()["next_cursor"]

    from daydayhealth.adapter import OpenGymSyncAdapter

    restarted = OpenGymSyncAdapter(env.settings)
    assert restarted.run_cycle().upserts == 0

    env.write_state(
        workouts=[
            make_workout(
                "w1",
                entries=[
                    {"id": "0025", "sets": [{"w": 80, "r": 4, "done": True}]}
                ],
            )
        ]
    )
    assert restarted.run_cycle().upserts == 1
    body = sync(client, TOKEN_A, cursor).json()
    assert body["changes"][0]["workout"]["exercises"][0]["sets"][0][
        "weight_kg"
    ] == 80


def test_corrupt_file_never_deletes_and_is_reported(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    cursor = sync(client, TOKEN_A).json()["next_cursor"]

    (env.data_dir / f"state-{OG_A}.json").write_text("{this is not json", encoding="utf-8")
    stats = adapter.run_cycle()
    assert stats.failed == 1
    assert "state_read_failed" in stats.errors or "state_parse_failed" in stats.errors

    assert len(rows(env, "SELECT * FROM workouts WHERE deleted_at IS NULL")) == 1
    assert sync(client, TOKEN_A, cursor).json()["changes"] == []

    state = rows(env, "SELECT * FROM sync_state WHERE opengym_user_id=?", (OG_A,))[0]
    assert state["last_error"] in ("state_read_failed", "state_parse_failed")
    assert state["last_success_at"] is not None


def test_wrong_schema_does_not_delete(env, adapter):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    (env.data_dir / f"state-{OG_A}.json").write_text(
        json.dumps({"unit": "kg", "workouts": "not-a-list"}), encoding="utf-8"
    )
    stats = adapter.run_cycle()
    assert stats.failed == 1
    assert len(rows(env, "SELECT * FROM workouts WHERE deleted_at IS NULL")) == 1


def test_missing_state_file_does_not_delete(env, adapter):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    (env.data_dir / f"state-{OG_A}.json").unlink()
    stats = adapter.run_cycle()
    assert stats.ok is True and stats.files_seen == 0
    assert len(rows(env, "SELECT * FROM workouts WHERE deleted_at IS NULL")) == 1


def test_missing_workout_without_tombstone_is_not_deleted(env, adapter):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    env.write_state(workouts=[], deleted={})
    stats = adapter.run_cycle()
    assert stats.ok is True
    assert len(rows(env, "SELECT * FROM workouts WHERE deleted_at IS NULL")) == 1
    assert rows(env, "SELECT * FROM changes WHERE op='delete'") == []


def test_unreadable_file_is_retried_without_deleting(env, adapter):
    import os

    if os.geteuid() == 0:
        pytest.skip("root can read chmod 000 files")
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    path = env.data_dir / f"state-{OG_A}.json"
    path.chmod(0o000)
    try:
        stats = adapter.run_cycle()
        assert stats.failed == 1
        assert len(rows(env, "SELECT * FROM workouts WHERE deleted_at IS NULL")) == 1
    finally:
        path.chmod(0o600)


def test_unknown_opengym_user_is_skipped(env, adapter):
    env.write_state("OGUNKNOWN999", workouts=[make_workout("w1")])
    stats = adapter.run_cycle()
    assert stats.skipped == 1
    assert rows(env, "SELECT * FROM workouts") == []
    state = rows(
        env, "SELECT * FROM sync_state WHERE opengym_user_id=?", ("OGUNKNOWN999",)
    )[0]
    assert state["last_error"] == "unmapped_opengym_user"


def test_workout_and_sets_are_one_transaction(env, adapter, monkeypatch):
    env.write_state(workouts=[make_workout("w1")])

    original = profiles.save_workout

    def explode(*args, **kwargs):
        raise sqlite3.OperationalError("simulated failure")

    monkeypatch.setattr(profiles, "save_workout", explode)
    stats = adapter.run_cycle()
    assert stats.failed == 1
    # The parent row insert and all children must have been rolled back.
    assert rows(env, "SELECT * FROM workouts") == []
    assert rows(env, "SELECT * FROM workout_sets") == []
    assert rows(env, "SELECT * FROM changes") == []

    monkeypatch.setattr(profiles, "save_workout", original)
    assert adapter.run_cycle().ok is True
    assert len(rows(env, "SELECT * FROM workouts")) == 1


def test_stable_workout_id_across_restarts(env, adapter):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    wid1 = rows(env, "SELECT id FROM workouts")[0]["id"]
    from daydayhealth.adapter import OpenGymSyncAdapter

    OpenGymSyncAdapter(env.settings).run_cycle()
    wid2 = rows(env, "SELECT id FROM workouts")[0]["id"]
    assert wid1 == wid2 and wid1.startswith("wb_")


def test_tombstone_for_unknown_workout_is_ignored(env, adapter):
    env.write_state(workouts=[], deleted={"never-synced": START})
    stats = adapter.run_cycle()
    assert stats.deletes == 0
    assert rows(env, "SELECT * FROM changes") == []


def test_restored_workout_becomes_upsert_again(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    cursor = sync(client, TOKEN_A).json()["next_cursor"]
    env.write_state(workouts=[], deleted={"w1": 1793786500000})
    adapter.run_cycle()
    assert sync(client, TOKEN_A, cursor).json()["changes"][0]["op"] == "delete"
    delete_cursor = sync(client, TOKEN_A, cursor).json()["next_cursor"]

    env.write_state(
        workouts=[
            make_workout(
                "w1",
                entries=[
                    {"id": "0025", "sets": [{"w": 90, "r": 3, "done": True}]}
                ],
            )
        ],
        deleted={},
    )
    stats = adapter.run_cycle()
    assert stats.upserts == 1
    body = sync(client, TOKEN_A, delete_cursor).json()
    assert body["changes"][0]["op"] == "upsert"
    assert body["changes"][0]["workout"]["exercises"][0]["sets"][0][
        "weight_kg"
    ] == 90
    assert rows(env, "SELECT deleted_at FROM workouts")[0]["deleted_at"] is None


def test_file_size_limit_fails_safely(env, adapter):
    import dataclasses

    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    tiny = dataclasses.replace(env.settings, max_state_file_bytes=64)
    from daydayhealth.adapter import OpenGymSyncAdapter

    stats = OpenGymSyncAdapter(tiny).run_cycle()
    assert stats.failed == 1
    assert len(rows(env, "SELECT * FROM workouts WHERE deleted_at IS NULL")) == 1


def test_missing_source_directory_fails_safely(env, adapter):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    moved = env.data_dir.with_name("data-away")
    env.data_dir.rename(moved)
    try:
        stats = adapter.run_cycle()
        assert stats.failed == 1
        assert "source_unavailable" in stats.errors
        assert len(rows(env, "SELECT * FROM workouts WHERE deleted_at IS NULL")) == 1
        run = rows(env, "SELECT * FROM sync_runs ORDER BY id DESC LIMIT 1")[0]
        assert run["finished_at"] is not None and run["ok"] == 0
    finally:
        moved.rename(env.data_dir)


def test_non_state_files_are_never_read(env, adapter, client):
    (env.data_dir / "db.json").write_text(
        '{"users":[{"id":"x","pw":{"h":"SUPER-SECRET-HASH"}}]}', encoding="utf-8"
    )
    (env.data_dir / "secret").write_text("SUPER-SECRET-TOKEN", encoding="utf-8")
    env.write_state(
        workouts=[make_workout("w1")],
        raw=json.dumps(
            {
                "unit": "kg",
                "lang": "zh",
                "workouts": [make_workout("w1")],
                "deleted": {"workouts": {}},
                "password": "SUPER-SECRET-PASSWORD",
                "token": "SUPER-SECRET-TOKEN",
            }
        ),
    )
    assert adapter.run_cycle().ok is True
    body = sync(client, TOKEN_A)
    assert body.status_code == 200
    assert "SUPER-SECRET" not in body.text
    assert "SUPER-SECRET" not in json.dumps(rows(env, "SELECT * FROM sync_state"))
