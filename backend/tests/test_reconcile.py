from __future__ import annotations

import sqlite3
from pathlib import Path

from daydayhealth import db, profiles, security
from daydayhealth.config import Settings
from daydayhealth.reconcile import run_reconcile

from .conftest import PEPPER

HEADER = "username,opengym_name,last_login_at,anomaly,locked,reset_password\n"


def settings_for(tmp_path: Path, csv: Path) -> Settings:
    return Settings(
        db_path=str(tmp_path / "wb.db"),
        opengym_data_dir=str(tmp_path / "og"),
        cursor_secret_file=str(tmp_path / "cursor"),
        catalog_path=str(Path(__file__).resolve().parents[1] / "daydayhealth" / "data" / "exercise_catalog.json"),
        user_csv_path=str(csv),
        profiles_dir=str(tmp_path / "profiles"),
        archive_dir=str(tmp_path / "archive"),
        archive_days=90,
        default_password="123456",
    )


def add_user(conn: sqlite3.Connection, username: str) -> str:
    uid = "wb_usr_" + username
    now = db.utc_now_iso()
    conn.execute(
        "INSERT INTO users(id, username, created_at, password_hash) VALUES(?,?,?,?)",
        (uid, username, now, security.hash_password("old-password", PEPPER)),
    )
    return uid


def test_reconcile_aborts_on_missing_or_empty_csv(tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text(HEADER, encoding="utf-8")
    settings = settings_for(tmp_path, csv)
    db.init_db(settings.db_path)
    conn = db.connect(settings.db_path)
    try:
        assert run_reconcile(conn, settings, PEPPER).reason == "csv_empty"
        csv.unlink()
        assert run_reconcile(conn, settings, PEPPER).reason == "csv_unavailable"
    finally:
        conn.close()


def test_archive_restore_and_purge_lifecycle(tmp_path):
    csv = tmp_path / "yonghu.csv"
    csv.write_text(
        HEADER
        + "alice,,,false,false,false\n"
        + "bob,,,false,false,false\n",
        encoding="utf-8",
    )
    settings = settings_for(tmp_path, csv)
    db.init_db(settings.db_path)
    conn = db.connect(settings.db_path)
    try:
        add_user(conn, "alice")
        add_user(conn, "bob")
        profiles.write_profile(conn, settings, "alice")
        assert (profiles.profile_dir(settings, "alice") / "profile.json").exists()

        # alice disappears from CSV -> archived, active folder removed.
        csv.write_text(HEADER + "bob,,,false,false,false\n", encoding="utf-8")
        stats = run_reconcile(conn, settings, PEPPER)
        assert "alice" in stats.archived
        row = conn.execute(
            "SELECT archived_at, purge_after FROM users WHERE username='alice'"
        ).fetchone()
        assert row["archived_at"]
        assert row["purge_after"]
        assert not profiles.profile_dir(settings, "alice").exists()
        archives = list(Path(settings.archive_dir).glob("alice/*/profile.json"))
        assert archives

        # add back -> restore profile, reset to default password.
        csv.write_text(
            HEADER
            + "alice,,,false,false,false\n"
            + "bob,,,false,false,false\n",
            encoding="utf-8",
        )
        stats = run_reconcile(conn, settings, PEPPER)
        assert "alice" in stats.restored
        row = conn.execute(
            "SELECT password_hash, archived_at FROM users WHERE username='alice'"
        ).fetchone()
        assert row["archived_at"] is None
        assert security.verify_password("123456", row["password_hash"], PEPPER)
        assert (profiles.profile_dir(settings, "alice") / "profile.json").exists()

        # remove again, then force expiry -> purge account + archive.
        csv.write_text(HEADER + "bob,,,false,false,false\n", encoding="utf-8")
        stats = run_reconcile(conn, settings, PEPPER)
        assert "alice" in stats.archived
        conn.execute(
            "UPDATE users SET archived_at='2000-01-01T00:00:00Z', "
            "purge_after='2000-01-01T00:00:00Z' WHERE username='alice'"
        )
        stats = run_reconcile(conn, settings, PEPPER)
        assert "alice" in stats.purged
        assert conn.execute(
            "SELECT 1 FROM users WHERE username='alice'"
        ).fetchone() is None
        assert not Path(settings.archive_dir, "alice").exists()
    finally:
        conn.close()
