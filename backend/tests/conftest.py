from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from daydayhealth import db, security
from daydayhealth.config import Settings
from daydayhealth.main import create_app

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "daydayhealth" / "data" / "exercise_catalog.json"
SECRET = b"0123456789abcdef0123456789abcdef"
PEPPER = b"password-pepper-for-tests-32bytes!!"
PASSWORD_A = "correct horse battery staple"

OG_A = "OGUSERAAAAAA"
OG_B = "OGUSERBBBBBB"
WB_A = "wb_usr_alice"
WB_B = "wb_usr_bob"
TOKEN_A = "wb_" + "a" * 40
TOKEN_B = "wb_" + "b" * 40

START = 1793786400000  # 2026-11-04T10:00:00Z
END = 1793790000000  # 2026-11-04T11:00:00Z


def make_workout(
    source_id: str = "w1",
    entries: list[dict] | None = None,
    *,
    name: str = "胸部训练",
    date: str = "2026-11-04",
    start: int = START,
    end: int = END,
) -> dict:
    if entries is None:
        entries = [
            {
                "id": "0025",
                "sets": [
                    {"w": 40, "r": 10, "done": True, "at": start},
                    {"w": 60, "r": 8, "done": True, "at": start + 1000},
                ],
            }
        ]
    return {
        "id": source_id,
        "d": date,
        "start": start,
        "end": end,
        "name": name,
        "entries": entries,
    }


@pytest.fixture
def env(tmp_path: Path):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    settings = Settings(
        db_path=str(tmp_path / "wb.db"),
        opengym_data_dir=str(data_dir),
        profiles_dir=str(tmp_path / "profiles"),
        archive_dir=str(tmp_path / "archive"),
        cursor_secret_file=str(tmp_path / "cursor_secret"),
        catalog_path=str(CATALOG),
        sync_interval_seconds=60,
        read_retry_delay_seconds=0,
    )
    db.init_db(settings.db_path)
    conn = db.connect(settings.db_path)
    now = db.utc_now_iso()
    try:
        with db.transaction(conn):
            for uid, username in ((WB_A, "alice"), (WB_B, "bob")):
                conn.execute(
                    "INSERT INTO users(id, username, created_at) VALUES(?,?,?)",
                    (uid, username, now),
                )
            for token, uid in ((TOKEN_A, WB_A), (TOKEN_B, WB_B)):
                conn.execute(
                    "INSERT INTO api_tokens(user_id, token_hash, label, created_at) "
                    "VALUES(?,?,?,?)",
                    (uid, security.hash_token(token), "test", now),
                )
            for og_id, uid in ((OG_A, WB_A), (OG_B, WB_B)):
                conn.execute(
                    "INSERT INTO opengym_user_map(opengym_user_id, wb_user_id, created_at) "
                    "VALUES(?,?,?)",
                    (og_id, uid, now),
                )
            conn.execute(
                "UPDATE users SET password_hash=? WHERE id=?",
                (security.hash_password(PASSWORD_A, PEPPER), WB_A),
            )
    finally:
        conn.close()

    def write_state(
        user_id: str = OG_A,
        workouts: list[dict] | None = None,
        *,
        deleted: dict | None = None,
        unit: str = "kg",
        lang: str = "zh",
        raw: str | None = None,
    ) -> Path:
        path = data_dir / f"state-{user_id}.json"
        if raw is not None:
            path.write_text(raw, encoding="utf-8")
        else:
            payload = {
                "unit": unit,
                "lang": lang,
                "workouts": workouts if workouts is not None else [make_workout()],
                "deleted": {"workouts": deleted or {}},
            }
            path.write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8"
            )
        return path

    return SimpleNamespace(
        settings=settings,
        data_dir=data_dir,
        db_path=settings.db_path,
        write_state=write_state,
        token_a=TOKEN_A,
        token_b=TOKEN_B,
        og_a=OG_A,
        og_b=OG_B,
        wb_a=WB_A,
        wb_b=WB_B,
        secret=SECRET,
        pepper=PEPPER,
        password_a=PASSWORD_A,
    )


@pytest.fixture
def adapter(env):
    from daydayhealth.adapter import OpenGymSyncAdapter

    return OpenGymSyncAdapter(env.settings)


@pytest.fixture
def client(env):
    app = create_app(
        env.settings, cursor_secret=env.secret, password_pepper=env.pepper
    )
    with TestClient(app) as test_client:
        yield test_client


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def sync(client: TestClient, token: str, cursor: str | None = None, limit: int | None = None):
    params: dict[str, str | int] = {}
    if cursor is not None:
        params["cursor"] = cursor
    if limit is not None:
        params["limit"] = limit
    return client.get(
        "/api/v1/workouts/sync", params=params, headers=auth(token)
    )


def rows(env, sql: str, params: tuple = ()) -> list[dict]:
    conn = db.connect(env.db_path)
    try:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
    finally:
        conn.close()
