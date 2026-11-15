"""Bearer-token authentication and opaque sync cursors."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import tempfile
from dataclasses import dataclass
from pathlib import Path

TOKEN_PREFIX = "wb_"
CURSOR_VERSION = 1
PASSWORD_SCHEME = "scrypt"
PASSWORD_N = 2**15
PASSWORD_R = 8
PASSWORD_P = 1
PASSWORD_DKLEN = 32
PASSWORD_MAXMEM = 64 * 1024 * 1024


def new_token() -> str:
    return TOKEN_PREFIX + secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def authenticate(conn: sqlite3.Connection, authorization: str | None) -> sqlite3.Row | None:
    """Resolve `Authorization: Bearer <token>` to an active user.

    Returns None for missing, malformed, unknown or revoked credentials.  The
    caller must turn that into a 401.
    """
    if not authorization:
        return None
    parts = authorization.split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    token = parts[1].strip()
    if len(token) < 20 or len(token) > 512:
        return None
    digest = hash_token(token)
    row = conn.execute(
        """
        SELECT u.id, u.username, u.must_change_password
          FROM api_tokens t
          JOIN users u ON u.id = t.user_id
         WHERE t.token_hash = ? AND t.revoked = 0 AND u.disabled = 0
        """,
        (digest,),
    ).fetchone()
    if row is None:
        return None
    return row


def _b64e_nopad(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64d_nopad(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def hash_password(password: str, pepper: bytes) -> str:
    """scrypt(password + NUL + server-side pepper).

    The pepper is stored outside SQLite, so a stolen database alone is not
    enough to run an offline dictionary attack.
    """
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(
        password.encode("utf-8") + b"\x00" + pepper,
        salt=salt,
        n=PASSWORD_N,
        r=PASSWORD_R,
        p=PASSWORD_P,
        dklen=PASSWORD_DKLEN,
        maxmem=PASSWORD_MAXMEM,
    )
    return (
        f"{PASSWORD_SCHEME}$n={PASSWORD_N},r={PASSWORD_R},p={PASSWORD_P}"
        f"${_b64e_nopad(salt)}${_b64e_nopad(digest)}"
    )


def verify_password(password: str, stored: str, pepper: bytes) -> bool:
    try:
        scheme, params, salt_b64, digest_b64 = stored.split("$", 3)
        if scheme != PASSWORD_SCHEME:
            return False
        values = {}
        for item in params.split(","):
            key, value = item.split("=", 1)
            values[key] = int(value)
        salt = _b64d_nopad(salt_b64)
        expected = _b64d_nopad(digest_b64)
        actual = hashlib.scrypt(
            password.encode("utf-8") + b"\x00" + pepper,
            salt=salt,
            n=values["n"],
            r=values["r"],
            p=values["p"],
            dklen=len(expected),
            maxmem=PASSWORD_MAXMEM,
        )
    except (ValueError, KeyError, TypeError):
        return False
    return hmac.compare_digest(actual, expected)


def load_or_create_pepper(path: str, env_value: str | None = None) -> bytes:
    """Load or create the server-side password pepper (32 bytes)."""
    if env_value:
        return env_value.encode("utf-8")
    p = Path(path)
    try:
        data = p.read_bytes()
        if len(data) >= 32:
            return data
    except FileNotFoundError:
        pass
    p.parent.mkdir(parents=True, exist_ok=True)
    pepper = secrets.token_bytes(32)
    fd, tmp = tempfile.mkstemp(prefix=".pepper.", dir=str(p.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(pepper)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return pepper


def load_cursor_secret(path: str, env_value: str | None = None) -> bytes:
    """Load (or atomically create) the HMAC key used to sign cursors."""
    if env_value:
        return env_value.encode("utf-8")
    p = Path(path)
    try:
        data = p.read_bytes()
        if len(data) >= 32:
            return data
    except FileNotFoundError:
        pass
    p.parent.mkdir(parents=True, exist_ok=True)
    secret = secrets.token_bytes(32)
    fd, tmp = tempfile.mkstemp(prefix=".cursor.", dir=str(p.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(secret)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return secret


class CursorError(ValueError):
    """Raised when a cursor is malformed, forged, foreign or out of range."""


@dataclass(frozen=True)
class Cursor:
    mode: str  # "full" | "inc"
    snapshot: int
    after: int


def _b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64d(text: str) -> bytes:
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


def _sign(secret: bytes, body: str) -> str:
    return hmac.new(secret, body.encode("ascii"), hashlib.sha256).hexdigest()[:32]


def encode_cursor(secret: bytes, user_id: str, cursor: Cursor) -> str:
    payload = {
        "v": CURSOR_VERSION,
        "u": user_id,
        "m": cursor.mode,
        "s": cursor.snapshot,
        "a": cursor.after,
    }
    body = _b64e(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    return f"{body}.{_sign(secret, body)}"


def decode_cursor(
    secret: bytes, user_id: str, raw: str, max_seq: int
) -> Cursor:
    """Validate signature, owner, shape and range of an opaque cursor."""
    if not isinstance(raw, str) or not raw or len(raw) > 4096:
        raise CursorError("cursor is not a valid string")
    try:
        body, signature = raw.split(".", 1)
    except ValueError as exc:
        raise CursorError("cursor has an invalid format") from exc
    expected = _sign(secret, body)
    if not hmac.compare_digest(signature, expected):
        raise CursorError("cursor signature mismatch")
    try:
        payload = json.loads(_b64d(body).decode("utf-8"))
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CursorError("cursor payload is invalid") from exc
    if not isinstance(payload, dict):
        raise CursorError("cursor payload is invalid")
    if payload.get("v") != CURSOR_VERSION:
        raise CursorError("unsupported cursor version")
    if payload.get("u") != user_id:
        raise CursorError("cursor belongs to another user")
    mode = payload.get("m")
    if mode not in ("full", "inc"):
        raise CursorError("unsupported cursor mode")
    snap = payload.get("s")
    after = payload.get("a")
    if not isinstance(snap, int) or isinstance(snap, bool) or snap < 0:
        raise CursorError("invalid cursor snapshot")
    if not isinstance(after, int) or isinstance(after, bool) or after < 0:
        raise CursorError("invalid cursor offset")
    # A cursor pointing beyond the server's change log can only mean the
    # database was replaced/restored.  Treat it as invalid instead of silently
    # returning an empty page forever.
    if snap > max_seq:
        raise CursorError("cursor is older than the current database")
    if after > snap:
        raise CursorError("invalid cursor ordering")
    return Cursor(mode=mode, snapshot=snap, after=after)


def load_secret_from_env_or_file(path: str) -> bytes:
    env = os.environ.get("DAYDAYHEALTH_CURSOR_SECRET")
    return load_cursor_secret(path, env)
