from __future__ import annotations

import dataclasses

from fastapi.testclient import TestClient

from daydayhealth.main import create_app
from daydayhealth.whitelist import load

from .conftest import PASSWORD_A


def make_client(env, path, snapshot=None):
    changes = {"user_csv_path": str(path)}
    if snapshot is not None:
        changes["opengym_users_snapshot"] = str(snapshot)
    settings = dataclasses.replace(env.settings, **changes)
    app = create_app(
        settings, cursor_secret=env.secret, password_pepper=env.pepper
    )
    return TestClient(app)


def login(client, username="alice", password=PASSWORD_A, ip="203.0.113.80"):
    return client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": password, "device_name": "test"},
        headers={"CF-Connecting-IP": ip},
    )


def test_whitelist_must_match_before_password(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text("alice,,,false,false,false\nbob,,,false,false,false\n", encoding="utf-8")
    with make_client(env, csv) as client:
        # alice is listed and has a password.
        first = login(client)
        assert first.status_code == 200, first.text
        body = first.json()
        assert body["last_login_at"] is None
        assert body["anomaly"] is False

        # bob is listed but has no password; the login provisions the default
        # password and rejects the supplied one.
        bob = login(client, username="bob", password="whatever")
        assert bob.status_code == 401

        # mallory is not listed; rejected before password verification.
        mallory = login(client, username="mallory", password="whatever")
        assert mallory.status_code == 401

    rows = load(str(csv))
    assert rows is not None
    assert rows["alice"].last_login_at
    assert rows["alice"].anomaly == "false"
    assert rows["bob"].last_login_at == ""


def test_whitelist_updates_last_login_and_ip_anomaly(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text("alice,,,false,false,false\n", encoding="utf-8")
    with make_client(env, csv) as client:
        first = login(client, ip="203.0.113.90")
        assert first.status_code == 200
        assert first.json()["anomaly"] is False

        second = login(client, ip="198.51.100.90")
        assert second.status_code == 200
        body = second.json()
        assert body["last_login_at"] is not None
        assert body["anomaly"] is True
        assert "ip_changed" in body["anomaly_reasons"]

    rows = load(str(csv))
    assert rows["alice"].anomaly == "true"


def test_recent_password_failures_mark_anomaly(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text("alice,,,false,false,false\n", encoding="utf-8")
    with make_client(env, csv) as client:
        bad = login(client, password="wrong", ip="203.0.113.100")
        assert bad.status_code == 401
        good = login(client, ip="203.0.113.100")
        assert good.status_code == 200
        assert good.json()["anomaly"] is True
        assert "failed_attempts" in good.json()["anomaly_reasons"]


def test_missing_whitelist_is_unavailable(env, tmp_path):
    with make_client(env, tmp_path / "missing.csv") as client:
        response = login(client)
        assert response.status_code == 503
        assert response.json()["error"]["code"] == "whitelist_unavailable"


def test_first_login_sets_password_from_whitelist(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text("newbie,,,false,false,false\n", encoding="utf-8")
    with make_client(env, csv) as client:
        setup = client.post(
            "/api/v1/auth/setup-password",
            json={
                "username": "newbie",
                "new_password": "newbie-password-123",
                "device_name": "iphone",
            },
        )
        assert setup.status_code == 200, setup.text
        token = setup.json()["token"]
        assert token

        rows = load(str(csv))
        assert rows["newbie"].locked is False
        assert rows["newbie"].reset_password is False

        login_ok = login(client, username="newbie", password="newbie-password-123")
        assert login_ok.status_code == 200

        again = client.post(
            "/api/v1/auth/setup-password",
            json={"username": "newbie", "new_password": "another-password-123"},
        )
        assert again.status_code == 409
        assert again.json()["error"]["code"] == "password_already_set"


def test_reset_flag_requires_change_password(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text("alice,,,false,false,true\n", encoding="utf-8")
    with make_client(env, csv) as client:
        login_response = login(client)
        assert login_response.status_code == 200
        body = login_response.json()
        assert body["must_change_password"] is True
        token = body["token"]

        changed = client.post(
            "/api/v1/auth/change-password",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "current_password": PASSWORD_A,
                "new_password": "changed-password-123",
            },
        )
        assert changed.status_code == 200

        rows = load(str(csv))
        assert rows["alice"].reset_password is False

        next_login = login(client, password="changed-password-123")
        assert next_login.status_code == 200
        assert next_login.json()["must_change_password"] is False


def test_csv_locked_true_blocks_and_false_unlocks(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text("alice,,,false,true,false\n", encoding="utf-8")
    with make_client(env, csv) as client:
        blocked = login(client)
        assert blocked.status_code == 423
        assert blocked.json()["error"]["code"] == "account_locked"

        csv.write_text("alice,,,false,false,false\n", encoding="utf-8")
        unlocked = login(client)
        assert unlocked.status_code == 200


def test_setup_auto_maps_opengym_id_from_csv(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text(
        "username,opengym_name,last_login_at,anomaly,locked,reset_password\n"
        "feitian,feitian,,false,false,false\n",
        encoding="utf-8",
    )
    snapshot = tmp_path / "opengym_users.json"
    snapshot.write_text(
        '[{"id":"8NOor6E3uniJF84V","name":"feitian"}]',
        encoding="utf-8",
    )
    with make_client(env, csv, snapshot) as client:
        setup = client.post(
            "/api/v1/auth/setup-password",
            json={
                "username": "feitian",
                "new_password": "feitian-password-123",
                "device_name": "iphone",
            },
        )
        assert setup.status_code == 200, setup.text
        user_id = setup.json()["user_id"]
    import sqlite3
    conn = sqlite3.connect(str(env.settings.db_path))
    row = conn.execute(
        "SELECT wb_user_id FROM opengym_user_map WHERE opengym_user_id=?",
        ("8NOor6E3uniJF84V",),
    ).fetchone()
    assert row is not None
    assert row[0] == user_id


def test_default_password_blocks_data_until_changed(env, tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text("newbie,,,false,false,false\n", encoding="utf-8")
    with make_client(env, csv) as client:
        first = login(client, username="newbie", password="123456")
        assert first.status_code == 200, first.text
        body = first.json()
        assert body["must_change_password"] is True
        token = body["token"]

        blocked = client.get(
            "/api/v1/workouts/sync",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert blocked.status_code == 403
        assert blocked.json()["error"]["code"] == "password_change_required"

        changed = client.post(
            "/api/v1/auth/change-password",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "current_password": "123456",
                "new_password": "changed-default-123",
            },
        )
        assert changed.status_code == 200

        allowed = client.get(
            "/api/v1/workouts/sync",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert allowed.status_code == 200
