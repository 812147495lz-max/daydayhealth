from __future__ import annotations

from .conftest import (
    OG_A,
    OG_B,
    TOKEN_A,
    TOKEN_B,
    auth,
    make_workout,
    rows,
    sync,
)


def test_full_initialization_paginates_and_then_switches_to_incremental(
    env, adapter, client
):
    env.write_state(
        workouts=[
            make_workout("w1", name="A"),
            make_workout("w2", name="B"),
            make_workout("w3", name="C"),
        ]
    )
    adapter.run_cycle()

    cursor = None
    seen: list[str] = []
    pages = 0
    while True:
        body = sync(client, TOKEN_A, cursor, limit=1).json()
        pages += 1
        assert body["schema_version"] == 1
        seen.extend(c["workout"]["source_id"] for c in body["changes"])
        cursor = body["next_cursor"]
        if not body["has_more"]:
            break
        assert pages < 10

    assert pages == 3
    assert seen == ["w1", "w2", "w3"]
    assert len(set(seen)) == 3

    # After a finished full init the cursor continues from the change log.
    assert sync(client, TOKEN_A, cursor).json()["changes"] == []

    env.write_state(
        workouts=[
            make_workout("w1", name="A"),
            make_workout("w2", name="B"),
            make_workout("w3", name="C"),
            make_workout("w4", name="D"),
        ]
    )
    adapter.run_cycle()
    body = sync(client, TOKEN_A, cursor).json()
    assert [c["workout"]["source_id"] for c in body["changes"]] == ["w4"]


def test_users_are_fully_isolated(env, adapter, client):
    env.write_state(OG_A, workouts=[make_workout("a1", name="Alice")])
    env.write_state(OG_B, workouts=[make_workout("b1", name="Bob")])
    adapter.run_cycle()

    a = sync(client, TOKEN_A).json()
    b = sync(client, TOKEN_B).json()
    assert [c["workout"]["source_id"] for c in a["changes"]] == ["a1"]
    assert [c["workout"]["source_id"] for c in b["changes"]] == ["b1"]

    # A cursor is bound to its user even though the HMAC is valid.
    cross = sync(client, TOKEN_B, a["next_cursor"])
    assert cross.status_code == 400
    assert cross.json()["error"]["code"] == "cursor_invalid"

    status_a = client.get("/api/v1/sync/status", headers=auth(TOKEN_A)).json()
    status_b = client.get("/api/v1/sync/status", headers=auth(TOKEN_B)).json()
    assert [s["opengym_user_id"] for s in status_a["sources"]] == [OG_A]
    assert [s["opengym_user_id"] for s in status_b["sources"]] == [OG_B]

    # Unmapping user B immediately removes access to B's data.
    conn = rows(env, "SELECT 1")
    assert conn
    from daydayhealth import db

    c = db.connect(env.db_path)
    try:
        c.execute(
            "DELETE FROM opengym_user_map WHERE opengym_user_id=?", (OG_B,)
        )
    finally:
        c.close()
    assert sync(client, TOKEN_B).json()["changes"] == []
    assert sync(client, TOKEN_A).json()["changes"][0]["workout"]["source_id"] == "a1"


def test_missing_or_bad_token_is_401_without_data(client):
    r = client.get("/api/v1/workouts/sync")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "unauthorized"
    assert r.headers["www-authenticate"].startswith("Bearer")

    r = client.get(
        "/api/v1/workouts/sync", headers=auth("wb_" + "z" * 40)
    )
    assert r.status_code == 401
    assert "changes" not in r.json()
    assert "next_cursor" not in r.json()


def test_401_wins_over_cursor_validation(client):
    r = client.get(
        "/api/v1/workouts/sync",
        params={"cursor": "garbage"},
        headers=auth("wb_" + "z" * 40),
    )
    assert r.status_code == 401


def test_invalid_and_tampered_cursors_are_cursor_invalid(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    cursor = sync(client, TOKEN_A).json()["next_cursor"]

    r = sync(client, TOKEN_A, cursor[:-1] + ("0" if cursor[-1] != "0" else "1"))
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "cursor_invalid"

    r = sync(client, TOKEN_A, "not-a-cursor")
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "cursor_invalid"

    # Empty cursor means full initialization, not an error.
    r = client.get(
        "/api/v1/workouts/sync",
        params={"cursor": ""},
        headers=auth(TOKEN_A),
    )
    assert r.status_code == 200
    assert len(r.json()["changes"]) == 1


def test_limit_validation(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    assert sync(client, TOKEN_A, limit=0).status_code == 422
    assert sync(client, TOKEN_A, limit=501).status_code == 422
    assert sync(client, TOKEN_A, limit=1).status_code == 200


def test_response_shape_and_null_delete(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    body = sync(client, TOKEN_A).json()
    assert set(body) == {"schema_version", "next_cursor", "has_more", "changes"}
    change = body["changes"][0]
    assert set(change) == {"op", "workout_id", "workout"}
    workout = change["workout"]
    assert set(workout) == {
        "id",
        "source",
        "source_id",
        "date",
        "started_at",
        "ended_at",
        "name",
        "exercises",
    }
    assert set(workout["exercises"][0]) == {"id", "name", "sets"}
    # Bilateral sets have the required fields only (no side key).
    assert set(workout["exercises"][0]["sets"][0]) == {
        "index",
        "weight_kg",
        "reps",
        "seconds",
        "rpe",
        "rir",
        "warmup",
    }

    cursor = body["next_cursor"]
    env.write_state(workouts=[], deleted={"w1": 1793786500000})
    adapter.run_cycle()
    delete_body = sync(client, TOKEN_A, cursor).json()
    assert delete_body["changes"][0]["workout"] is None


def test_status_reports_last_success_and_errors(env, adapter, client):
    env.write_state(workouts=[make_workout("w1")])
    adapter.run_cycle()
    status = client.get("/api/v1/sync/status", headers=auth(TOKEN_A)).json()
    assert status["schema_version"] == 1
    source = status["sources"][0]
    assert source["opengym_user_id"] == OG_A
    assert source["last_success_at"] is not None
    assert source["last_error"] is None
    assert source["workouts"] == 1

    (env.data_dir / f"state-{OG_A}.json").write_text("broken", encoding="utf-8")
    adapter.run_cycle()
    status = client.get("/api/v1/sync/status", headers=auth(TOKEN_A)).json()
    assert status["sources"][0]["last_error"] is not None


def test_deleted_workout_not_returned_by_full_init(env, adapter, client):
    env.write_state(workouts=[make_workout("w1"), make_workout("w2")])
    adapter.run_cycle()
    env.write_state(workouts=[make_workout("w1")], deleted={"w2": 1793786500000})
    adapter.run_cycle()
    body = sync(client, TOKEN_A).json()
    assert [c["workout"]["source_id"] for c in body["changes"]] == ["w1"]
    assert all(c["op"] == "upsert" for c in body["changes"])
