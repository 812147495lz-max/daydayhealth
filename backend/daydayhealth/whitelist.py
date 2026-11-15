"""Editable CSV username whitelist.

Columns:
    username,opengym_name,last_login_at,anomaly,locked,reset_password

The first row is a header.  Passwords are never stored here; they remain
scrypt hashes in SQLite.  The file is updated in place so its owner/mode (and
the operator's ability to edit it) are preserved.
"""

from __future__ import annotations

import fcntl
import os
from dataclasses import dataclass
from pathlib import Path

HEADER = "username,opengym_name,last_login_at,anomaly,locked,reset_password"


class WhitelistError(RuntimeError):
    pass


@dataclass
class WhitelistUser:
    username: str
    opengym_name: str = ""
    last_login_at: str = ""
    anomaly: str = "false"
    locked: bool = False
    reset_password: bool = False


def _split(line: str) -> list[str]:
    # The operator may use Chinese commas; accept both.
    line = line.replace("，", ",")
    return [part.strip() for part in line.split(",")]


def _true(parts: list[str], index: int, default: str = "false") -> str:
    if len(parts) <= index or not parts[index]:
        return default
    return "true" if parts[index].lower() in ("true", "1", "yes") else "false"


def load(path: str) -> dict[str, WhitelistUser] | None:
    """Return whitelist entries, or None if the file is unavailable."""
    try:
        raw = Path(path).read_text(encoding="utf-8-sig")
    except (FileNotFoundError, PermissionError, OSError):
        return None
    users: dict[str, WhitelistUser] = {}
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = _split(line)
        username = parts[0] if parts else ""
        if not username or username.lower() == "username":
            continue
        users[username] = WhitelistUser(
            username=username,
            opengym_name=parts[1] if len(parts) > 1 else "",
            last_login_at=parts[2] if len(parts) > 2 else "",
            anomaly=(parts[3].lower() if len(parts) > 3 and parts[3] else "false"),
            locked=_true(parts, 4) == "true",
            reset_password=_true(parts, 5) == "true",
        )
    return users


def update(
    path: str,
    username: str,
    last_login_at: str,
    anomaly: bool,
    *,
    locked: bool | None = None,
    reset_password: bool | None = None,
) -> bool:
    """Update one row in place.  Returns False if the user is not listed."""
    p = Path(path)
    try:
        fh = p.open("r+", encoding="utf-8")
    except (FileNotFoundError, PermissionError, OSError) as exc:
        raise WhitelistError("whitelist file is not writable") from exc

    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        raw = fh.read()
        lines = raw.splitlines()
        found = False
        has_header = False
        output: list[str] = []
        for line in lines:
            if not line.strip():
                output.append(line)
                continue
            parts = _split(line)
            name = parts[0] if parts else ""
            if name.lower() == "username":
                has_header = True
                output.append(HEADER)
                continue
            opengym_name = parts[1] if len(parts) > 1 else ""
            old_last = parts[2] if len(parts) > 2 else ""
            old_anomaly = parts[3] if len(parts) > 3 and parts[3] else "false"
            old_locked = parts[4] if len(parts) > 4 and parts[4] else "false"
            old_reset = parts[5] if len(parts) > 5 and parts[5] else "false"
            if name == username and name:
                found = True
                new_locked = str(locked).lower() if locked is not None else old_locked
                new_reset = (
                    str(reset_password).lower() if reset_password is not None else old_reset
                )
                output.append(
                    f"{name},{opengym_name},{last_login_at},"
                    f"{'true' if anomaly else 'false'},{new_locked},{new_reset}"
                )
            elif name:
                output.append(
                    f"{name},{opengym_name},{old_last},{old_anomaly},"
                    f"{old_locked},{old_reset}"
                )
            else:
                output.append(line)
        if not found:
            return False
        if not has_header:
            output.insert(0, HEADER)
        fh.seek(0)
        fh.truncate()
        fh.write("\n".join(output) + ("\n" if raw.endswith("\n") else ""))
        fh.flush()
        os.fsync(fh.fileno())
        return True
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        finally:
            fh.close()
