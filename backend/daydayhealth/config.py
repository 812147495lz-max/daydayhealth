"""Runtime configuration for DayDayHealth.

All settings come from environment variables so the same image can run as the
API process or as the sync worker with different privileges.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DB_PATH = "/var/lib/daydayhealth/daydayhealth.db"
DEFAULT_OPENGYM_DATA_DIR = "/opengym-data"
DEFAULT_CURSOR_SECRET_FILE = "/var/lib/daydayhealth/cursor_secret"
DEFAULT_PASSWORD_PEPPER_FILE = "/var/lib/daydayhealth/password_pepper"
DEFAULT_CF_ACCESS_FILE = "/var/lib/daydayhealth/cf_access.json"
DEFAULT_LOGIN_HOSTS: tuple[str, ...] = ()
DEFAULT_CATALOG_PATH = Path(__file__).resolve().parent / "data" / "exercise_catalog.json"


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return int(raw)


@dataclass(frozen=True)
class Settings:
    db_path: str = DEFAULT_DB_PATH
    opengym_data_dir: str = DEFAULT_OPENGYM_DATA_DIR
    cursor_secret_file: str = DEFAULT_CURSOR_SECRET_FILE
    password_pepper_file: str = DEFAULT_PASSWORD_PEPPER_FILE
    cf_access_file: str = DEFAULT_CF_ACCESS_FILE
    login_hosts: tuple[str, ...] = DEFAULT_LOGIN_HOSTS
    user_csv_path: str | None = None
    opengym_users_snapshot: str = "/var/lib/daydayhealth/opengym_users.json"
    profiles_dir: str = "/var/lib/daydayhealth/profiles"
    archive_dir: str = "/var/lib/daydayhealth/archive"
    archive_days: int = 90
    default_password: str = "123456"
    reconcile_hour: int = 3
    catalog_path: str = str(DEFAULT_CATALOG_PATH)
    sync_interval_seconds: int = 60
    max_state_file_bytes: int = 64 * 1024 * 1024
    read_retries: int = 3
    read_retry_delay_seconds: float = 0.25

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            db_path=os.environ.get("DAYDAYHEALTH_DB", DEFAULT_DB_PATH),
            opengym_data_dir=os.environ.get(
                "OPENGYM_DATA_DIR", DEFAULT_OPENGYM_DATA_DIR
            ),
            cursor_secret_file=os.environ.get(
                "DAYDAYHEALTH_CURSOR_SECRET_FILE", DEFAULT_CURSOR_SECRET_FILE
            ),
            password_pepper_file=os.environ.get(
                "DAYDAYHEALTH_PASSWORD_PEPPER_FILE", DEFAULT_PASSWORD_PEPPER_FILE
            ),
            cf_access_file=os.environ.get(
                "DAYDAYHEALTH_CF_ACCESS_FILE", DEFAULT_CF_ACCESS_FILE
            ),
            login_hosts=tuple(
                item.strip().lower()
                for item in os.environ.get(
                    "DAYDAYHEALTH_LOGIN_HOSTS", ",".join(DEFAULT_LOGIN_HOSTS)
                ).split(",")
                if item.strip()
            ),
            user_csv_path=(
                os.environ.get("DAYDAYHEALTH_USER_CSV", "").strip() or None
            ),
            opengym_users_snapshot=(
                os.environ.get(
                    "DAYDAYHEALTH_OPENGYM_USERS", "/var/lib/daydayhealth/opengym_users.json"
                ).strip()
                or "/var/lib/daydayhealth/opengym_users.json"
            ),
            profiles_dir=(
                os.environ.get("DAYDAYHEALTH_PROFILES_DIR", "/var/lib/daydayhealth/profiles").strip()
                or "/var/lib/daydayhealth/profiles"
            ),
            archive_dir=(
                os.environ.get("DAYDAYHEALTH_ARCHIVE_DIR", "/var/lib/daydayhealth/archive").strip()
                or "/var/lib/daydayhealth/archive"
            ),
            archive_days=int(os.environ.get("DAYDAYHEALTH_ARCHIVE_DAYS", "90")),
            default_password=os.environ.get("DAYDAYHEALTH_DEFAULT_PASSWORD", "123456"),
            reconcile_hour=int(os.environ.get("DAYDAYHEALTH_RECONCILE_HOUR", "3")),
            catalog_path=os.environ.get(
                "DAYDAYHEALTH_CATALOG", str(DEFAULT_CATALOG_PATH)
            ),
            sync_interval_seconds=max(
                5, _env_int("SYNC_INTERVAL_SECONDS", 60)
            ),
            max_state_file_bytes=max(
                1024, _env_int("MAX_STATE_FILE_BYTES", 64 * 1024 * 1024)
            ),
            read_retries=max(1, _env_int("STATE_READ_RETRIES", 3)),
            read_retry_delay_seconds=float(
                os.environ.get("STATE_READ_RETRY_DELAY", "0.25")
            ),
        )
