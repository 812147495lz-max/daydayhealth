"""Operator CLI for DayDayHealth.

Tokens are printed exactly once and only their SHA-256 digest is stored.
Never copy openGym password/passkey material here: mapping uses the openGym
user id that appears in `state-<user-id>.json` only.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import secrets
import sys

from . import auth, cfaccess, db, security
from .adapter import OpenGymSyncAdapter
from .config import Settings
from .reconcile import run_reconcile

OG_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,64}$")
USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{2,64}$")


def _connect(settings: Settings):
    db.init_db(settings.db_path)
    return db.connect(settings.db_path)


def _pepper(settings: Settings) -> bytes:
    return security.load_or_create_pepper(
        settings.password_pepper_file,
        os.environ.get("DAYDAYHEALTH_PASSWORD_PEPPER"),
    )


def cmd_set_cf_access(args, settings: Settings) -> int:
    if args.clear:
        removed = cfaccess.clear(settings.cf_access_file)
        print(json.dumps({"cf_access_cleared": removed}))
        return 0
    if not args.client_id:
        print("--client-id is required", file=sys.stderr)
        return 2
    if args.secret_stdin:
        secret = sys.stdin.readline().rstrip("\n")
    else:
        secret = getpass.getpass("Cloudflare Access Client Secret: ")
    if len(args.client_id.strip()) < 8 or len(secret.strip()) < 20:
        print("invalid client id/secret", file=sys.stderr)
        return 2
    cfaccess.save(settings.cf_access_file, args.client_id, secret)
    print(json.dumps({"cf_access_configured": True}))
    return 0


def cmd_cf_access_status(args, settings: Settings) -> int:
    identity = cfaccess.load(settings.cf_access_file)
    print(
        json.dumps(
            {
                "configured": identity is not None,
                "client_id_suffix": (
                    identity.client_id[-8:] if identity is not None else None
                ),
            }
        )
    )
    return 0


def cmd_set_password(args, settings: Settings) -> int:
    if args.password_stdin:
        password = sys.stdin.readline().rstrip("\n")
    else:
        password = getpass.getpass("New password: ")
        confirm = getpass.getpass("Confirm password: ")
        if password != confirm:
            print("passwords do not match", file=sys.stderr)
            return 2
    if len(password) < 8:
        print("password must be at least 8 characters", file=sys.stderr)
        return 2
    if len(password) > 256:
        print("password is too long", file=sys.stderr)
        return 2
    if password.isdigit():
        print(
            "warning: a numeric-only password is weak even with lockout; "
            "a passphrase is recommended",
            file=sys.stderr,
        )
    conn = _connect(settings)
    try:
        user = conn.execute(
            "SELECT id FROM users WHERE username=?", (args.username,)
        ).fetchone()
        if user is None:
            print("unknown user", file=sys.stderr)
            return 3
        hashed = security.hash_password(password, _pepper(settings))
        conn.execute(
            "UPDATE users SET password_hash=? WHERE id=?",
            (hashed, user["id"]),
        )
        # A password change does not revoke existing Bearer tokens; the
        # operator can rotate/revoke them separately.
    finally:
        conn.close()
    print(json.dumps({"username": args.username, "password_updated": True}))
    return 0


def cmd_unlock(args, settings: Settings) -> int:
    conn = _connect(settings)
    try:
        removed = auth.clear_attempts(conn, args.username, args.ip)
    finally:
        conn.close()
    print(json.dumps({"username": args.username, "ip": args.ip, "removed": removed}))
    return 0


def cmd_login_status(args, settings: Settings) -> int:
    conn = _connect(settings)
    try:
        rows = auth.list_attempts(conn, args.username)
    finally:
        conn.close()
    print(json.dumps(rows, ensure_ascii=False, indent=2))
    return 0


def cmd_create_user(args, settings: Settings) -> int:
    if not USERNAME_RE.match(args.username):
        print("invalid username", file=sys.stderr)
        return 2
    uid = "wb_usr_" + secrets.token_hex(8)
    token = security.new_token()
    now = db.utc_now_iso()
    conn = _connect(settings)
    try:
        with db.transaction(conn):
            exists = conn.execute(
                "SELECT 1 FROM users WHERE username=?", (args.username,)
            ).fetchone()
            if exists:
                print("username already exists", file=sys.stderr)
                return 3
            conn.execute(
                "INSERT INTO users(id, username, created_at) VALUES(?,?,?)",
                (uid, args.username, now),
            )
            conn.execute(
                "INSERT INTO api_tokens(user_id, token_hash, label, created_at) "
                "VALUES(?,?,?,?)",
                (uid, security.hash_token(token), "initial", now),
            )
    finally:
        conn.close()
    print(
        json.dumps(
            {
                "user_id": uid,
                "username": args.username,
                "token": token,
                "note": "Store this token now; it cannot be shown again.",
            },
            ensure_ascii=False,
        )
    )
    return 0


def cmd_create_token(args, settings: Settings) -> int:
    token = security.new_token()
    now = db.utc_now_iso()
    conn = _connect(settings)
    try:
        user = conn.execute(
            "SELECT id FROM users WHERE username=?", (args.username,)
        ).fetchone()
        if user is None:
            print("unknown user", file=sys.stderr)
            return 3
        conn.execute(
            "INSERT INTO api_tokens(user_id, token_hash, label, created_at) "
            "VALUES(?,?,?,?)",
            (user["id"], security.hash_token(token), args.label, now),
        )
    finally:
        conn.close()
    print(
        json.dumps(
            {
                "username": args.username,
                "token": token,
                "label": args.label,
                "note": "Store this token now; it cannot be shown again.",
            },
            ensure_ascii=False,
        )
    )
    return 0


def cmd_map(args, settings: Settings) -> int:
    og_id = args.opengym_user_id.strip()
    if not OG_ID_RE.match(og_id):
        print("invalid openGym user id", file=sys.stderr)
        return 2
    conn = _connect(settings)
    now = db.utc_now_iso()
    try:
        user = conn.execute(
            "SELECT id FROM users WHERE username=?", (args.username,)
        ).fetchone()
        if user is None:
            print("unknown DayDayHealth user", file=sys.stderr)
            return 3
        conn.execute(
            """
            INSERT INTO opengym_user_map(opengym_user_id, wb_user_id, created_at)
            VALUES(?,?,?)
            ON CONFLICT(opengym_user_id) DO UPDATE SET
                wb_user_id=excluded.wb_user_id,
                created_at=excluded.created_at
            """,
            (og_id, user["id"], now),
        )
    finally:
        conn.close()
    print(json.dumps({"mapped": og_id, "username": args.username}))
    return 0


def cmd_unmap(args, settings: Settings) -> int:
    conn = _connect(settings)
    try:
        cur = conn.execute(
            "DELETE FROM opengym_user_map WHERE opengym_user_id=?",
            (args.opengym_user_id.strip(),),
        )
    finally:
        conn.close()
    print(json.dumps({"removed": cur.rowcount}))
    return 0


def cmd_list_users(args, settings: Settings) -> int:
    conn = _connect(settings)
    try:
        rows = conn.execute(
            """
            SELECT u.id, u.username, u.disabled, u.created_at,
                   (SELECT COUNT(*) FROM opengym_user_map m WHERE m.wb_user_id=u.id)
                     AS mappings
              FROM users u ORDER BY u.created_at
            """
        ).fetchall()
        print(
            json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=2)
        )
    finally:
        conn.close()
    return 0


def cmd_status(args, settings: Settings) -> int:
    conn = _connect(settings)
    try:
        rows = conn.execute(
            """
            SELECT m.opengym_user_id, u.username, s.last_attempt_at,
                   s.last_success_at, s.last_error,
                   (SELECT COUNT(*) FROM workouts w
                     WHERE w.opengym_user_id=m.opengym_user_id
                       AND w.deleted_at IS NULL) AS active,
                   (SELECT COUNT(*) FROM workouts w
                     WHERE w.opengym_user_id=m.opengym_user_id
                       AND w.deleted_at IS NOT NULL) AS deleted
              FROM opengym_user_map m
              JOIN users u ON u.id=m.wb_user_id
              LEFT JOIN sync_state s ON s.opengym_user_id=m.opengym_user_id
             ORDER BY m.opengym_user_id
            """
        ).fetchall()
        meta = {
            r["key"]: r["value"]
            for r in conn.execute("SELECT key, value FROM meta").fetchall()
        }
        print(
            json.dumps(
                {"sources": [dict(r) for r in rows], "worker": meta},
                ensure_ascii=False,
                indent=2,
            )
        )
    finally:
        conn.close()
    return 0


def cmd_sync_once(args, settings: Settings) -> int:
    adapter = OpenGymSyncAdapter(settings)
    stats = adapter.run_cycle()
    print(json.dumps(stats.as_dict(), ensure_ascii=False, indent=2))
    return 0 if stats.ok else 1


def cmd_reconcile(args, settings: Settings) -> int:
    conn = _connect(settings)
    try:
        pepper = security.load_or_create_pepper(settings.password_pepper_file, None)
        stats = run_reconcile(conn, settings, pepper)
        print(json.dumps(stats.as_dict(), ensure_ascii=False, indent=2))
        return 0 if not stats.aborted and not stats.errors else 1
    finally:
        conn.close()


def cmd_export_openapi(args, settings: Settings) -> int:
    from .main import create_app

    app = create_app(settings)
    spec = app.openapi()
    with open(args.path, "w", encoding="utf-8") as fh:
        json.dump(spec, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(args.path)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="daydayhealth")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser(
        "set-cf-access",
        help="store the Cloudflare Access Service Token for password-login download",
    )
    p.add_argument("--client-id", required=False)
    p.add_argument(
        "--secret-stdin",
        action="store_true",
        help="read the secret from stdin instead of prompting",
    )
    p.add_argument("--clear", action="store_true")
    p.set_defaults(func=cmd_set_cf_access)

    p = sub.add_parser("cf-access-status", help="show whether CF Access is configured")
    p.set_defaults(func=cmd_cf_access_status)

    p = sub.add_parser("set-password", help="set or change a user's login password")
    p.add_argument("--username", required=True)
    p.add_argument(
        "--password-stdin",
        action="store_true",
        help="read one line from stdin instead of prompting (automation only)",
    )
    p.set_defaults(func=cmd_set_password)

    p = sub.add_parser("unlock", help="clear password-login lockout records")
    p.add_argument("--username", required=True)
    p.add_argument("--ip", default=None, help="only this client IP")
    p.set_defaults(func=cmd_unlock)

    p = sub.add_parser("login-status", help="show password-login failure counters")
    p.add_argument("--username", default=None)
    p.set_defaults(func=cmd_login_status)

    p = sub.add_parser("create-user", help="create a DayDayHealth user + first token")
    p.add_argument("--username", required=True)
    p.set_defaults(func=cmd_create_user)

    p = sub.add_parser("create-token", help="create another API token")
    p.add_argument("--username", required=True)
    p.add_argument("--label", default="iphone")
    p.set_defaults(func=cmd_create_token)

    p = sub.add_parser("map", help="map an openGym user id to a DayDayHealth user")
    p.add_argument("--opengym-user-id", required=True)
    p.add_argument("--username", required=True)
    p.set_defaults(func=cmd_map)

    p = sub.add_parser("unmap", help="remove an openGym mapping")
    p.add_argument("--opengym-user-id", required=True)
    p.set_defaults(func=cmd_unmap)

    p = sub.add_parser("list-users", help="list users (no secrets)")
    p.set_defaults(func=cmd_list_users)

    p = sub.add_parser("status", help="sync status (no secrets)")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("sync-once", help="run one sync cycle")
    p.set_defaults(func=cmd_sync_once)

    p = sub.add_parser("reconcile", help="run one CSV/account/archive reconcile")
    p.set_defaults(func=cmd_reconcile)

    p = sub.add_parser("export-openapi", help="write the OpenAPI JSON document")
    p.add_argument("--path", required=True)
    p.set_defaults(func=cmd_export_openapi)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    settings = Settings.from_env()
    return int(args.func(args, settings))


if __name__ == "__main__":
    raise SystemExit(main())
