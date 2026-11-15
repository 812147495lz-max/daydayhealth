"""Storage for the Cloudflare Access Service Token that the NAS may hand to
an authenticated app.

The file lives on the private runtime volume (mode 600).  It is only returned
after a successful password login, and only from the designated login hostname.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CFIdentity:
    client_id: str
    client_secret: str


def load(path: str) -> CFIdentity | None:
    p = Path(path)
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (FileNotFoundError, PermissionError, json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    client_id = data.get("client_id")
    client_secret = data.get("client_secret")
    if not isinstance(client_id, str) or not isinstance(client_secret, str):
        return None
    client_id = client_id.strip()
    client_secret = client_secret.strip()
    if len(client_id) < 8 or len(client_secret) < 20:
        return None
    return CFIdentity(client_id=client_id, client_secret=client_secret)


def save(path: str, client_id: str, client_secret: str) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        {"client_id": client_id.strip(), "client_secret": client_secret.strip()},
        separators=(",", ":"),
    ).encode("utf-8")
    fd, tmp = tempfile.mkstemp(prefix=".cfaccess.", dir=str(p.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(payload)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def clear(path: str) -> bool:
    p = Path(path)
    try:
        p.unlink()
        return True
    except FileNotFoundError:
        return False
