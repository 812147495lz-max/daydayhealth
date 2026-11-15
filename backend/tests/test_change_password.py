from __future__ import annotations

from .conftest import PASSWORD_A, sync


def login(client, password=PASSWORD_A, ip="203.0.113.70"):
    return client.post(
        "/api/v1/auth/login",
        json={"username": "alice", "password": password, "device_name": "test"},
        headers={"CF-Connecting-IP": ip},
    )


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_change_password_and_old_token_survives(client):
    first = login(client)
    assert first.status_code == 200
    token = first.json()["token"]

    changed = client.post(
        "/api/v1/auth/change-password",
        headers=auth_headers(token),
        json={
            "current_password": PASSWORD_A,
            "new_password": "new-password-123",
        },
    )
    assert changed.status_code == 200
    assert changed.json() == {"changed": True}

    # The old token continues to work; password change does not log out devices.
    assert sync(client, token).status_code == 200

    # Old password no longer works, new password does.
    old = login(client, password=PASSWORD_A, ip="203.0.113.71")
    assert old.status_code == 401
    new = login(client, password="new-password-123", ip="203.0.113.72")
    assert new.status_code == 200


def test_change_password_rejects_wrong_current(client):
    token = login(client).json()["token"]
    response = client.post(
        "/api/v1/auth/change-password",
        headers=auth_headers(token),
        json={
            "current_password": "wrong-current",
            "new_password": "new-password-123",
        },
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_credentials"

    # Password was not changed.
    assert login(client, ip="203.0.113.73").status_code == 200


def test_change_password_requires_bearer(client):
    response = client.post(
        "/api/v1/auth/change-password",
        json={"current_password": PASSWORD_A, "new_password": "new-password-123"},
    )
    assert response.status_code == 401


def test_change_password_rejects_short_new_password(client):
    token = login(client).json()["token"]
    response = client.post(
        "/api/v1/auth/change-password",
        headers=auth_headers(token),
        json={"current_password": PASSWORD_A, "new_password": "short"},
    )
    assert response.status_code == 422
