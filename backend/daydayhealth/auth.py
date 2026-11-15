"""Password login with per-(username, client IP) lockout.

Existing Bearer tokens are never touched by this module.  A failed login from
one network only locks that username+IP pair for 24 hours; an already logged-in
device continues to use its Bearer token normally.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import ipaddress
import logging
import sqlite3
from dataclasses import dataclass
from typing import Any

from . import db, security

logger = logging.getLogger("daydayhealth.auth")

LOCKOUT_FAILURES = 5
LOCKOUT_SECONDS = 24 * 60 * 60
_DUMMY_CACHE: dict[bytes, str] = {}


@dataclass
class LoginOutcome:
    ok: bool
    token: str | None = None
    user_id: str | None = None
    username: str | None = None
    retry_after: int | None = None
    locked_until: str | None = None
    previous_login_at: str | None = None
    previous_login_ip: str | None = None
    current_login_at: str | None = None
    anomaly: bool = False
    anomaly_reasons: list[str] | None = None


def client_ip(request: Any) -> str:
    """Cloudflare sets CF-Connecting-IP for tunnel traffic."""
    candidate = request.headers.get("cf-connecting-ip")
    if candidate:
        candidate = candidate.split(",")[0].strip()
    else:
        candidate = getattr(getattr(request, "client", None), "host", None) or "unknown"
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return "unknown"


def attempt_key(username: str, ip: str) -> str:
    material = f"{username}\x1f{ip}".encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def _dummy_hash(pepper: bytes) -> str:
    # Equalize the expensive password-verification path for unknown users so
    # timing does not reveal whether a username exists.
    cached = _DUMMY_CACHE.get(pepper)
    if cached is None:
        cached = security.hash_password("not-the-real-password", pepper)
        _DUMMY_CACHE[pepper] = cached
    return cached


def _parse_lock(value: str | None) -> _dt.datetime | None:
    if not value:
        return None
    try:
        parsed = _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed.astimezone(_dt.timezone.utc)


def _record_failure(
    conn: sqlite3.Connection, key: str, username: str, ip: str
) -> tuple[int, str | None, int | None]:
    now = db.utc_now()
    now_iso = db.iso_z(now)
    with db.transaction(conn):
        row = conn.execute(
            "SELECT failures FROM login_attempts WHERE key=?", (key,)
        ).fetchone()
        failures = (int(row["failures"]) if row else 0) + 1
        locked_until = None
        retry_after = None
        if failures >= LOCKOUT_FAILURES:
            until = now + _dt.timedelta(seconds=LOCKOUT_SECONDS)
            locked_until = db.iso_z(until)
            retry_after = LOCKOUT_SECONDS
        conn.execute(
            """
            INSERT INTO login_attempts(
                key, username, ip, failures, locked_until, last_attempt_at
            ) VALUES(?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET
                failures=excluded.failures,
                locked_until=excluded.locked_until,
                last_attempt_at=excluded.last_attempt_at
            """,
            (key, username, ip, failures, locked_until, now_iso),
        )
    return failures, locked_until, retry_after


def login(
    conn: sqlite3.Connection,
    username: str,
    password: str,
    ip: str,
    pepper: bytes,
    device_name: str | None = None,
    ignore_lock: bool = False,
) -> LoginOutcome:
    username = (username or "").strip()
    now = db.utc_now()
    now_iso = db.iso_z(now)
    key = attempt_key(username, ip)

    locked = conn.execute(
        "SELECT locked_until FROM login_attempts WHERE key=?", (key,)
    ).fetchone()
    if locked and locked["locked_until"] and not ignore_lock:
        until = _parse_lock(str(locked["locked_until"]))
        if until is not None and until > now:
            retry_after = max(1, int((until - now).total_seconds()))
            return LoginOutcome(
                ok=False,
                retry_after=retry_after,
                locked_until=db.iso_z(until),
            )
        # Expired lock: start a fresh window.
        conn.execute("DELETE FROM login_attempts WHERE key=?", (key,))

    user = conn.execute(
        "SELECT id, username, disabled, password_hash, last_login_at, "
        "last_login_ip FROM users WHERE username=?",
        (username,),
    ).fetchone()

    valid = False
    if user is not None and not int(user["disabled"]) and user["password_hash"]:
        valid = security.verify_password(
            password, str(user["password_hash"]), pepper
        )
    else:
        # Burn the same expensive verification for unknown/disabled users.
        security.verify_password(password, _dummy_hash(pepper), pepper)

    anomaly_reasons: list[str] = []
    if valid and user is not None:
        # Count failures from any IP within the last 24h before the current
        # success removes this IP's counter.
        cutoff = db.iso_z(now - _dt.timedelta(seconds=LOCKOUT_SECONDS))
        failed = conn.execute(
            "SELECT COALESCE(SUM(failures), 0) AS n FROM login_attempts "
            "WHERE username=? AND last_attempt_at>=?",
            (username, cutoff),
        ).fetchone()
        if failed is not None and int(failed["n"]) > 0:
            anomaly_reasons.append("failed_attempts")
        previous_ip = user["last_login_ip"]
        if previous_ip and ip != "unknown" and previous_ip != ip:
            try:
                prev_net = ipaddress.ip_network(
                    str(previous_ip) + ("/16" if ":" not in str(previous_ip) else "/48"),
                    strict=False,
                )
                cur_net = ipaddress.ip_network(
                    ip + ("/16" if ":" not in ip else "/48"),
                    strict=False,
                )
                if prev_net != cur_net:
                    anomaly_reasons.append("ip_changed")
            except ValueError:
                pass

    if not valid:
        failures, locked_until, retry_after = _record_failure(
            conn, key, username, ip
        )
        logger.warning(
            "auth.login.failed user=%s ip=%s failures=%s locked=%s",
            username[:64],
            ip,
            failures,
            bool(locked_until),
        )
        return LoginOutcome(
            ok=False,
            retry_after=retry_after,
            locked_until=locked_until,
        )

    token = security.new_token()
    label = (device_name or "password-login").strip()[:100] or "password-login"
    previous_login_at = user["last_login_at"]
    previous_login_ip = user["last_login_ip"]
    with db.transaction(conn):
        conn.execute("DELETE FROM login_attempts WHERE key=?", (key,))
        conn.execute(
            "UPDATE users SET previous_login_at=last_login_at, "
            "previous_login_ip=last_login_ip, last_login_at=?, last_login_ip=? "
            "WHERE id=?",
            (now_iso, ip, user["id"]),
        )
        conn.execute(
            "INSERT INTO api_tokens(user_id, token_hash, label, created_at) "
            "VALUES(?,?,?,?)",
            (user["id"], security.hash_token(token), f"login:{label}", now_iso),
        )
    logger.info("auth.login.ok user=%s ip=%s", username[:64], ip)
    return LoginOutcome(
        ok=True,
        token=token,
        user_id=str(user["id"]),
        username=str(user["username"]),
        previous_login_at=previous_login_at,
        previous_login_ip=previous_login_ip,
        current_login_at=now_iso,
        anomaly=bool(anomaly_reasons),
        anomaly_reasons=anomaly_reasons,
    )


def clear_attempts(
    conn: sqlite3.Connection, username: str, ip: str | None = None
) -> int:
    if ip:
        cur = conn.execute(
            "DELETE FROM login_attempts WHERE username=? AND ip=?",
            (username.strip(), ip),
        )
    else:
        cur = conn.execute(
            "DELETE FROM login_attempts WHERE username=?", (username.strip(),)
        )
    return int(cur.rowcount)


def list_attempts(conn: sqlite3.Connection, username: str | None = None) -> list[dict]:
    if username:
        rows = conn.execute(
            "SELECT username, ip, failures, locked_until, last_attempt_at "
            "FROM login_attempts WHERE username=? ORDER BY last_attempt_at DESC",
            (username.strip(),),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT username, ip, failures, locked_until, last_attempt_at "
            "FROM login_attempts ORDER BY last_attempt_at DESC"
        ).fetchall()
    return [dict(row) for row in rows]
