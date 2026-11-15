from __future__ import annotations

import datetime as dt

from .conftest import PASSWORD_A, TOKEN_A, sync


def login(client, username="alice", password=PASSWORD_A, ip="203.0.113.7", device="iphone"):
    return client.post(
        "/api/v1/auth/login",
        json={
            "username": username,
            "password": password,
            "device_name": device,
        },
        headers={"CF-Connecting-IP": ip},
    )


def test_password_login_issues_working_token(client):
    response = login(client)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["schema_version"] == 1
    assert body["token_type"] == "Bearer"
    assert body["username"] == "alice"
    assert body["token"].startswith("wb_")
    assert response.headers["cache-control"] == "no-store"

    # The returned token authenticates the v1 sync API.
    assert sync(client, body["token"]).status_code == 200


def test_wrong_password_locks_after_five_attempts(client):
    for _ in range(4):
        response = login(client, password="wrong-password")
        assert response.status_code == 401
        assert response.json()["error"]["code"] == "invalid_credentials"

    fifth = login(client, password="wrong-password")
    assert fifth.status_code == 429
    assert fifth.json()["error"]["code"] == "locked"
    assert int(fifth.headers["retry-after"]) > 86000

    # Correct password from the same username+IP is still locked.
    assert login(client).status_code == 429


def test_lockout_is_per_username_and_ip(client):
    for _ in range(5):
        login(client, password="wrong-password", ip="198.51.100.10")
    assert login(client, ip="198.51.100.10").status_code == 429

    # A different network is unaffected.
    other = login(client, ip="198.51.100.11")
    assert other.status_code == 200


def test_existing_token_survives_other_peoples_lockout(client, env):
    first = login(client, ip="198.51.100.20")
    assert first.status_code == 200
    token = first.json()["token"]

    for _ in range(5):
        login(client, password="wrong-password", ip="198.51.100.21")
    assert login(client, ip="198.51.100.21").status_code == 429

    # The already-issued device token is untouched by login lockouts.
    assert sync(client, token).status_code == 200

    # The pre-existing operator token also still works.
    assert sync(client, TOKEN_A).status_code == 200


def test_unknown_user_gets_generic_401(client):
    response = login(client, username="nobody", password="whatever")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_credentials"


def test_password_hash_is_not_plaintext(env):
    from daydayhealth import db

    conn = db.connect(env.db_path)
    try:
        value = conn.execute(
            "SELECT password_hash FROM users WHERE username='alice'"
        ).fetchone()["password_hash"]
    finally:
        conn.close()
    assert PASSWORD_A not in value
    assert value.startswith("scrypt$")


def test_unlock_clears_the_lock(client, env):
    from types import SimpleNamespace

    from daydayhealth import cli

    for _ in range(5):
        login(client, password="wrong-password", ip="198.51.100.30")
    assert login(client, ip="198.51.100.30").status_code == 429

    rc = cli.cmd_unlock(
        SimpleNamespace(username="alice", ip="198.51.100.30"), env.settings
    )
    assert rc == 0
    assert login(client, ip="198.51.100.30").status_code == 200


def test_expired_lock_allows_login(client, env):
    from daydayhealth import db

    for _ in range(5):
        login(client, password="wrong-password", ip="198.51.100.40")
    assert login(client, ip="198.51.100.40").status_code == 429

    past = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=5)
    conn = db.connect(env.db_path)
    try:
        conn.execute(
            "UPDATE login_attempts SET locked_until=? WHERE ip=?",
            (db.iso_z(past), "198.51.100.40"),
        )
    finally:
        conn.close()

    assert login(client, ip="198.51.100.40").status_code == 200
