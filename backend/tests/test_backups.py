from .conftest import TOKEN_A, TOKEN_B, auth
from daydayhealth import backups, db

PATH = "/api/v1/app-backups"


def put(client, payload):
    return client.post(PATH, content=payload, headers={
        **auth(TOKEN_A), "Content-Type": "application/octet-stream"
    })


def test_backup_versions_round_trip_and_are_account_scoped(client):
    first = b"first complete app snapshot"
    next_version = b"second complete app snapshot"
    a = put(client, first)
    assert a.status_code == 200
    first_receipt = a.json()
    assert put(client, first).json() == first_receipt
    b = put(client, next_version)
    assert b.status_code == 200
    second_receipt = b.json()
    assert second_receipt["id"] != first_receipt["id"]

    listing = client.get(PATH, headers=auth(TOKEN_A))
    assert listing.json() == [second_receipt, first_receipt]
    assert "no-store" in listing.headers["Cache-Control"]
    for receipt, payload in ((first_receipt, first), (second_receipt, next_version)):
        download = client.get(f"{PATH}/{receipt['id']}", headers=auth(TOKEN_A))
        assert download.content == payload
        assert download.headers["Content-Type"] == "application/octet-stream"
        assert "no-store" in download.headers["Cache-Control"]
        assert client.get(f"{PATH}/{receipt['id']}", headers=auth(TOKEN_B)).status_code == 404
    assert client.get(PATH, headers=auth(TOKEN_B)).json() == []
    assert client.get(PATH).status_code == 401


def test_failed_upload_preserves_previous_backup(client, monkeypatch):
    monkeypatch.setattr(backups, "MAX_BYTES", 10)
    monkeypatch.setattr(backups, "ACCOUNT_BYTES", 15)
    saved = put(client, b"123456789").json()
    assert put(client, b"").status_code == 400
    assert put(client, b"12345678901").status_code == 413
    assert put(client, b"7654321").status_code == 507
    assert client.get(PATH, headers=auth(TOKEN_A)).json() == [saved]


def test_backup_requires_password_change_and_rejects_login_host(env, client):
    conn = db.connect(env.db_path)
    try:
        conn.execute("UPDATE users SET must_change_password=1 WHERE id=?", (env.wb_a,))
    finally:
        conn.close()

    routes = (
        ("GET", PATH, {}),
        ("GET", PATH + "/" + "a" * 64, {}),
        ("POST", PATH, {"content": b"backup"}),
    )
    for method, path, kwargs in routes:
        denied = client.request(method, path, headers={
            **auth(TOKEN_A), "Content-Type": "application/octet-stream"
        }, **kwargs)
        assert denied.status_code == 403
        assert denied.json()["error"]["code"] == "password_change_required"

    import dataclasses
    from fastapi.testclient import TestClient
    from daydayhealth.main import create_app

    settings = dataclasses.replace(env.settings, login_hosts={"login.example"})
    with TestClient(create_app(settings, cursor_secret=env.secret,
                              password_pepper=env.pepper)) as guarded:
        for method, path, kwargs in routes:
            denied = guarded.request(method, path, headers={
                **auth(TOKEN_B), "Host": "login.example",
                "Content-Type": "application/octet-stream",
            }, **kwargs)
            assert denied.status_code == 404
            assert denied.json()["error"]["code"] == "not_found"
