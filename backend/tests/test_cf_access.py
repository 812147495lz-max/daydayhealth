from __future__ import annotations

from dataclasses import replace

from fastapi.testclient import TestClient

from daydayhealth.cfaccess import CFIdentity
from daydayhealth.main import create_app

from .conftest import PASSWORD_A


def login_host_app(env):
    app = create_app(
        replace(env.settings, login_hosts=("login.example.com",)),
        cursor_secret=env.secret,
        password_pepper=env.pepper,
        cf_access=CFIdentity(
            "client-id-1234567890.access",
            "cfast_this-is-a-test-secret-value-1234567890",
        ),
    )
    return app


def test_login_host_downloads_cf_headers_only_after_password(env):
    app = login_host_app(env)
    with TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/login",
            json={
                "username": "alice",
                "password": PASSWORD_A,
                "device_name": "iphone",
            },
            headers={
                "Host": "login.example.com",
                "CF-Connecting-IP": "203.0.113.50",
            },
        )
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["cf_access_client_id"] == "client-id-1234567890.access"
        assert body["cf_access_client_secret"].startswith("cfast_")

        # Wrong password never returns the CF service token.
        wrong = client.post(
            "/api/v1/auth/login",
            json={"username": "alice", "password": "wrong"},
            headers={
                "Host": "login.example.com",
                "CF-Connecting-IP": "203.0.113.51",
            },
        )
        assert wrong.status_code == 401
        assert "cf_access_client_secret" not in wrong.json()


def test_login_host_cannot_read_workouts(env):
    app = login_host_app(env)
    with TestClient(app) as client:
        response = client.get(
            "/api/v1/workouts/sync",
            headers={"Host": "login.example.com"},
        )
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "not_found"

        health = client.get(
            "/healthz", headers={"Host": "login.example.com"}
        )
        assert health.status_code == 200


def test_data_host_login_does_not_return_cf_credentials(env):
    app = login_host_app(env)
    with TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/login",
            json={"username": "alice", "password": PASSWORD_A},
            headers={
                "Host": "health.example.com",
                "CF-Connecting-IP": "203.0.113.52",
            },
        )
        assert response.status_code == 200
        body = response.json()
        assert body["cf_access_client_id"] is None
        assert body["cf_access_client_secret"] is None
