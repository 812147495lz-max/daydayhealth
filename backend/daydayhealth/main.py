"""DayDayHealth FastAPI application (workout sync v1)."""

from __future__ import annotations

import contextlib
import logging
import os
import secrets
import sqlite3
from typing import AsyncIterator, Iterator

from fastapi import Depends, FastAPI, Query, Request, Response
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from . import apple_health_archive, auth, backups, cfaccess, db, health_store, opengym_names, profiles, security, whitelist
from .config import Settings
from .models import (
    ChangePasswordRequest,
    ChangePasswordResponse,
    ErrorResponse,
    LoginRequest,
    LoginResponse,
    SetupPasswordRequest,
    SyncResponse,
    SyncStatusResponse,
)
from .health_models import (
    HealthBatchRequest,
    HealthBatchResponse,
    HealthError,
    HealthSample,
)
from .repository import (
    full_page_with_after,
    incremental_page,
    source_status,
)

logger = logging.getLogger("daydayhealth.api")

AUTH_HEADER = "Authorization"


class ApiError(Exception):
    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        headers: dict[str, str] | None = None,
    ):
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.headers = headers or {}


def create_app(
    settings: Settings | None = None,
    cursor_secret: bytes | None = None,
    password_pepper: bytes | None = None,
    cf_access: cfaccess.CFIdentity | None = None,
) -> FastAPI:
    cfg = settings or Settings.from_env()

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        db.init_db(cfg.db_path)
        app.state.cursor_secret = cursor_secret or security.load_secret_from_env_or_file(
            cfg.cursor_secret_file
        )
        app.state.password_pepper = password_pepper or security.load_or_create_pepper(
            cfg.password_pepper_file,
            os.environ.get("DAYDAYHEALTH_PASSWORD_PEPPER"),
        )
        app.state.cf_access = cf_access or cfaccess.load(cfg.cf_access_file)
        logger.info(
            "daydayhealth.api.start db=%s cf_access_configured=%s",
            cfg.db_path,
            app.state.cf_access is not None,
        )
        yield

    app = FastAPI(
        title="DayDayHealth Workout Sync API",
        version="1.0.0",
        description=(
            "Authenticated, read-only workout synchronization for the DayDayHealth "
            "iPhone app.  Data originates from openGym and is imported by the "
            "DayDayHealth sync worker.\n\n"
            "All endpoints require `Authorization: Bearer <token>`.  The sync "
            "endpoint only returns workouts belonging to the authenticated user."
        ),
        lifespan=lifespan,
    )
    app.state.settings = cfg

    @app.middleware("http")
    async def login_host_guard(request: Request, call_next):
        """The bypassed login hostname must never expose data endpoints."""
        host = request.headers.get("host", "").split(":")[0].strip().lower()
        if host in cfg.login_hosts and request.url.path not in (
            "/api/v1/auth/login",
            "/api/v1/auth/setup-password",
            "/healthz",
        ):
            return JSONResponse(
                status_code=404,
                content={
                    "error": {
                        "code": "not_found",
                        "message": "Not found.",
                    }
                },
            )
        return await call_next(request)

    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": {"code": exc.code, "message": exc.message}},
            headers=exc.headers,
        )

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception) -> JSONResponse:
        logger.exception("api.unhandled error=%s", type(exc).__name__)
        return JSONResponse(
            status_code=500,
            content={
                "error": {
                    "code": "internal_error",
                    "message": "An unexpected server error occurred.",
                }
            },
        )

    bearer_scheme = HTTPBearer(
        auto_error=False,
        scheme_name="bearerAuth",
        description="DayDayHealth API token issued by the operator CLI (`wb_...`).",
    )

    def get_conn(request: Request) -> Iterator[sqlite3.Connection]:
        conn = db.connect(request.app.state.settings.db_path)
        try:
            yield conn
        finally:
            conn.close()

    def require_user(
        request: Request,
        conn: sqlite3.Connection = Depends(get_conn),
        _credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    ) -> sqlite3.Row:
        user = security.authenticate(conn, request.headers.get(AUTH_HEADER))
        if user is None:
            raise ApiError(
                401,
                "unauthorized",
                "Missing or invalid bearer token.",
                {"WWW-Authenticate": 'Bearer realm="daydayhealth"'},
            )
        return user

    def require_backup_user(user: sqlite3.Row = Depends(require_user)) -> sqlite3.Row:
        if int(user["must_change_password"]):
            raise ApiError(
                403, "password_change_required",
                "Change the default password before accessing backups.",
            )
        return user

    app.include_router(backups.router(require_backup_user, get_conn))
    app.include_router(apple_health_archive.router(require_backup_user))

    @app.get("/healthz", tags=["ops"], summary="Liveness probe")
    def healthz() -> dict:
        return {"ok": True, "service": "daydayhealth", "schema_version": 1}

    @app.post(
        "/api/v1/auth/login",
        response_model=LoginResponse,
        tags=["auth"],
        summary="Exchange username/password for a Bearer token",
        description=(
            "Password login for the DayDayHealth app.  The endpoint itself is "
            "deployed behind Cloudflare Access, so the app must also send "
            "`CF-Access-Client-Id` / `CF-Access-Client-Secret` (or be on the "
            "LAN).  On success a new long-lived Bearer token is returned; the "
            "app stores it in the Keychain and uses it for the sync API.\n\n"
            "Lockout is scoped to (username, client IP): 5 failures lock only "
            "that pair for 24 hours.  Existing Bearer tokens are NOT revoked."
        ),
        responses={
            200: {
                "model": LoginResponse,
                "description": "Password accepted; store the returned token securely.",
            },
            401: {
                "model": ErrorResponse,
                "description": "Invalid username or password (`invalid_credentials`).",
            },
            423: {
                "model": ErrorResponse,
                "description": "Account is manually locked (`account_locked`); set CSV locked=false to unlock.",
            },
            429: {
                "model": ErrorResponse,
                "description": (
                    "Too many failures from this username+IP (`locked`); see "
                    "`Retry-After`."
                ),
                "headers": {
                    "Retry-After": {
                        "schema": {"type": "string"},
                        "description": "Seconds until the lock expires.",
                    }
                },
            },
        },
    )
    def login(
        payload: LoginRequest,
        request: Request,
        response: Response,
        conn: sqlite3.Connection = Depends(get_conn),
    ) -> dict:
        csv_path = request.app.state.settings.user_csv_path
        if csv_path:
            allowed = whitelist.load(csv_path)
            if allowed is None:
                raise ApiError(
                    503,
                    "whitelist_unavailable",
                    "The login whitelist is unavailable.",
                )
            if payload.username.strip() not in allowed:
                logger.warning(
                    "auth.login.not_whitelisted user=%s",
                    payload.username.strip()[:64],
                )
                raise ApiError(
                    401,
                    "invalid_credentials",
                    "Invalid username or password.",
                )
            entry = allowed[payload.username.strip()]
            if entry.locked:
                response.headers["Cache-Control"] = "no-store"
                raise ApiError(
                    423,
                    "account_locked",
                    "This account is locked. Set locked=false in yonghu.csv to unlock.",
                )
            existing = conn.execute(
                "SELECT id, password_hash FROM users WHERE username=?",
                (payload.username.strip(),),
            ).fetchone()
            if existing is None or not existing["password_hash"]:
                # New CSV users get the shared default password and must change
                # it after the first successful login.
                username = payload.username.strip()
                now = db.utc_now_iso()
                uid = str(existing["id"]) if existing is not None else (
                    "wb_usr_" + secrets.token_hex(8)
                )
                default_hash = security.hash_password(
                    request.app.state.settings.default_password,
                    request.app.state.password_pepper,
                )
                if existing is None:
                    conn.execute(
                        "INSERT INTO users(id, username, created_at, password_hash, "
                        "must_change_password) VALUES(?,?,?,?,1)",
                        (uid, username, now, default_hash),
                    )
                else:
                    conn.execute(
                        "UPDATE users SET password_hash=?, must_change_password=1 "
                        "WHERE id=?",
                        (default_hash, uid),
                    )
                entry.reset_password = True
                # Best-effort immediate mapping; the daily reconciler is the
                # authoritative repair path.
                og_name = entry.opengym_name.strip()
                if og_name:
                    try:
                        names = opengym_names.load(
                            request.app.state.settings.opengym_users_snapshot
                        ) or {}
                        og_id = names.get(og_name, "")
                        if og_id:
                            mapped = conn.execute(
                                "SELECT wb_user_id FROM opengym_user_map "
                                "WHERE opengym_user_id=?",
                                (og_id,),
                            ).fetchone()
                            if mapped is None:
                                conn.execute(
                                    "INSERT INTO opengym_user_map(opengym_user_id, "
                                    "wb_user_id, created_at) VALUES(?,?,?)",
                                    (og_id, uid, now),
                                )
                    except Exception:  # noqa: BLE001
                        logger.exception("auth.login.default_map_failed")
                try:
                    profiles.write_profile(
                        conn, request.app.state.settings, username
                    )
                except Exception:  # noqa: BLE001
                    logger.exception("auth.login.profile_write_failed")
                existing = conn.execute(
                    "SELECT id, password_hash FROM users WHERE username=?",
                    (username,),
                ).fetchone()
            if entry.reset_password:
                conn.execute(
                    "UPDATE users SET must_change_password=1 WHERE username=?",
                    (payload.username.strip(),),
                )
        outcome = auth.login(
            conn,
            payload.username,
            payload.password,
            auth.client_ip(request),
            request.app.state.password_pepper,
            payload.device_name,
            ignore_lock=bool(csv_path and entry and not entry.locked),
        )
        response.headers["Cache-Control"] = "no-store"
        if not outcome.ok:
            if outcome.retry_after is not None:
                if csv_path and entry:
                    try:
                        whitelist.update(
                            csv_path,
                            entry.username,
                            entry.last_login_at,
                            entry.anomaly == "true",
                            locked=True,
                            reset_password=entry.reset_password,
                        )
                    except Exception:  # noqa: BLE001
                        logger.exception("auth.login.lock_csv_update_failed")
                raise ApiError(
                    429,
                    "locked",
                    "Too many failed login attempts. Set locked=false in yonghu.csv to unlock.",
                    {"Retry-After": str(outcome.retry_after)},
                )
            raise ApiError(
                401,
                "invalid_credentials",
                "Invalid username or password.",
            )
        host = request.headers.get("host", "").split(":")[0].strip().lower()
        cf = request.app.state.cf_access if host in request.app.state.settings.login_hosts else None
        flag_row = conn.execute(
            "SELECT must_change_password FROM users WHERE id=?", (outcome.user_id,)
        ).fetchone()
        db_flag = bool(flag_row and int(flag_row["must_change_password"]))
        must_change = db_flag or (bool(entry.reset_password) if csv_path else False)
        if must_change and not db_flag:
            conn.execute(
                "UPDATE users SET must_change_password=1 WHERE id=?",
                (outcome.user_id,),
            )
        if csv_path:
            try:
                whitelist.update(
                    csv_path,
                    str(outcome.username),
                    outcome.current_login_at or db.utc_now_iso(),
                    bool(outcome.anomaly),
                    locked=False,
                    reset_password=must_change,
                )
            except Exception:  # noqa: BLE001 - login should still succeed
                logger.exception("auth.login.whitelist_update_failed")
        return {
            "schema_version": 1,
            "token": outcome.token,
            "token_type": "Bearer",
            "user_id": outcome.user_id,
            "username": outcome.username,
            "cf_access_client_id": cf.client_id if cf else None,
            "cf_access_client_secret": cf.client_secret if cf else None,
            "last_login_at": outcome.previous_login_at,
            "last_login_ip": outcome.previous_login_ip,
            "anomaly": bool(outcome.anomaly),
            "anomaly_reasons": outcome.anomaly_reasons or [],
            "must_change_password": must_change,
        }

    @app.post(
        "/api/v1/auth/setup-password",
        response_model=LoginResponse,
        tags=["auth"],
        summary="Set the first password for a whitelisted username",
        description=(
            "Used by the login hostname when `yonghu.csv` lists a username whose "
            "database account has no password yet.  No Bearer is required, but "
            "the username must be present in the whitelist, must not be locked, "
            "and must not already have a password.  Creates the DayDayHealth user "
            "if needed; openGym mapping is a separate operator step."
        ),
        responses={
            200: {"model": LoginResponse},
            401: {
                "model": ErrorResponse,
                "description": "Username not in the whitelist.",
            },
            409: {
                "model": ErrorResponse,
                "description": "Password already set, openGym ID already mapped, or whitelist unavailable.",
            },
            423: {
                "model": ErrorResponse,
                "description": "Account is manually locked (`locked=true`).",
            },
            422: {"model": ErrorResponse, "description": "Password too short."},
        },
    )
    def setup_password(
        payload: SetupPasswordRequest,
        request: Request,
        response: Response,
        conn: sqlite3.Connection = Depends(get_conn),
    ) -> dict:
        csv_path = request.app.state.settings.user_csv_path
        if not csv_path:
            raise ApiError(
                503, "whitelist_unavailable", "The login whitelist is unavailable."
            )
        allowed = whitelist.load(csv_path)
        if allowed is None:
            raise ApiError(
                503, "whitelist_unavailable", "The login whitelist is unavailable."
            )
        username = payload.username.strip()
        entry = allowed.get(username)
        if entry is None:
            raise ApiError(
                401, "invalid_credentials", "Invalid username or password."
            )
        if entry.locked:
            raise ApiError(
                423,
                "account_locked",
                "This account is locked. Set locked=false in yonghu.csv to unlock.",
            )
        user = conn.execute(
            "SELECT id, disabled, password_hash FROM users WHERE username=?",
            (username,),
        ).fetchone()
        if user is not None and int(user["disabled"]):
            raise ApiError(
                401, "invalid_credentials", "Invalid username or password."
            )
        if user is not None and user["password_hash"]:
            whitelist.update(
                csv_path,
                username,
                entry.last_login_at,
                entry.anomaly == "true",
                locked=False,
                reset_password=entry.reset_password,
            )
            raise ApiError(
                409, "password_already_set", "Password is already set for this user."
            )

        now = db.utc_now_iso()
        ip = auth.client_ip(request)
        uid = str(user["id"]) if user is not None else (
            "wb_usr_" + secrets.token_hex(8)
        )
        og_name = entry.opengym_name.strip()
        opengym_id = ""
        if og_name:
            names = opengym_names.load(
                request.app.state.settings.opengym_users_snapshot
            )
            if names is None:
                raise ApiError(
                    503,
                    "opengym_users_unavailable",
                    "The openGym user name snapshot is unavailable.",
                )
            opengym_id = names.get(og_name, "")
            if not opengym_id:
                raise ApiError(
                    409,
                    "opengym_user_not_found",
                    "The openGym name in yonghu.csv is not known.",
                )
        existing_map = None
        if opengym_id:
            existing_map = conn.execute(
                "SELECT wb_user_id FROM opengym_user_map WHERE opengym_user_id=?",
                (opengym_id,),
            ).fetchone()
            if existing_map is not None and str(existing_map["wb_user_id"]) != uid:
                raise ApiError(
                    409,
                    "opengym_id_already_mapped",
                    "This openGym user is already mapped to another account.",
                )
            user_map = conn.execute(
                "SELECT opengym_user_id FROM opengym_user_map WHERE wb_user_id=?",
                (uid,),
            ).fetchone()
            if user_map is not None and str(user_map["opengym_user_id"]) != opengym_id:
                raise ApiError(
                    409,
                    "user_already_mapped",
                    "This account is already mapped to another openGym user.",
                )
        password_hash = security.hash_password(
            payload.new_password, request.app.state.password_pepper
        )
        token = security.new_token()
        label = (payload.device_name or "first-login").strip()[:100] or "first-login"
        with db.transaction(conn):
            if user is None:
                conn.execute(
                    "INSERT INTO users(id, username, created_at, password_hash, "
                    "last_login_at, last_login_ip, must_change_password) "
                    "VALUES(?,?,?,?,?,?,0)",
                    (uid, username, now, password_hash, now, ip),
                )
            else:
                conn.execute(
                    "UPDATE users SET password_hash=?, last_login_at=?, "
                    "last_login_ip=?, must_change_password=0 WHERE id=?",
                    (password_hash, now, ip, uid),
                )
            if opengym_id and existing_map is None:
                conn.execute(
                    "INSERT INTO opengym_user_map(opengym_user_id, wb_user_id, created_at) "
                    "VALUES(?,?,?)",
                    (opengym_id, uid, now),
                )
            conn.execute(
                "INSERT INTO api_tokens(user_id, token_hash, label, created_at) "
                "VALUES(?,?,?,?)",
                (uid, security.hash_token(token), f"setup:{label}", now),
            )
        try:
            whitelist.update(
                csv_path,
                username,
                now,
                False,
                locked=False,
                reset_password=False,
            )
        except Exception:  # noqa: BLE001
            logger.exception("auth.setup.whitelist_update_failed")

        host = request.headers.get("host", "").split(":")[0].strip().lower()
        cf = (
            request.app.state.cf_access
            if host in request.app.state.settings.login_hosts
            else None
        )
        response.headers["Cache-Control"] = "no-store"
        logger.info("auth.setup.ok user=%s", username[:64])
        return {
            "schema_version": 1,
            "token": token,
            "token_type": "Bearer",
            "user_id": uid,
            "username": username,
            "cf_access_client_id": cf.client_id if cf else None,
            "cf_access_client_secret": cf.client_secret if cf else None,
            "last_login_at": None,
            "last_login_ip": None,
            "anomaly": False,
            "anomaly_reasons": [],
            "must_change_password": False,
        }

    @app.post(
        "/api/v1/auth/change-password",
        response_model=ChangePasswordResponse,
        tags=["auth"],
        summary="Change the authenticated user's password",
        description=(
            "Requires a valid Bearer token (and Cloudflare Access headers on the "
            "public data hostname).  The current password must be supplied.  "
            "The password is stored as scrypt + server-side pepper; existing "
            "Bearer tokens are not revoked by this operation."
        ),
        responses={
            200: {"model": ChangePasswordResponse},
            401: {
                "model": ErrorResponse,
                "description": "Missing Bearer or wrong current password.",
            },
            409: {
                "model": ErrorResponse,
                "description": "The user has no password configured.",
            },
            422: {
                "model": ErrorResponse,
                "description": "New password is shorter than 8 characters.",
            },
        },
    )
    def change_password(
        payload: ChangePasswordRequest,
        request: Request,
        response: Response,
        user: sqlite3.Row = Depends(require_user),
        conn: sqlite3.Connection = Depends(get_conn),
    ) -> dict:
        row = conn.execute(
            "SELECT password_hash FROM users WHERE id=?", (user["id"],)
        ).fetchone()
        if row is None or not row["password_hash"]:
            raise ApiError(409, "password_not_set", "No password is configured.")
        if not security.verify_password(
            payload.current_password,
            str(row["password_hash"]),
            request.app.state.password_pepper,
        ):
            logger.warning(
                "auth.change_password.failed user=%s", str(user["username"])[:64]
            )
            raise ApiError(
                401, "invalid_credentials", "Current password is incorrect."
            )
        new_hash = security.hash_password(
            payload.new_password, request.app.state.password_pepper
        )
        conn.execute(
            "UPDATE users SET password_hash=?, must_change_password=0 WHERE id=?",
            (new_hash, user["id"]),
        )
        csv_path = request.app.state.settings.user_csv_path
        if csv_path:
            try:
                allowed = whitelist.load(csv_path) or {}
                entry = allowed.get(str(user["username"]))
                whitelist.update(
                    csv_path,
                    str(user["username"]),
                    entry.last_login_at if entry else "",
                    bool(entry and entry.anomaly == "true"),
                    locked=bool(entry and entry.locked),
                    reset_password=False,
                )
            except Exception:  # noqa: BLE001
                logger.exception("auth.change_password.whitelist_update_failed")
        response.headers["Cache-Control"] = "no-store"
        logger.info(
            "auth.change_password.ok user=%s", str(user["username"])[:64]
        )
        return {"changed": True}

    @app.post(
        "/api/v1/health/batch",
        response_model=HealthBatchResponse,
        tags=["health"],
        summary="Upload health samples in a batch",
        description=(
            "Idempotent health sample upload.  The server classifies by "
            "`category`, deduplicates by source/external id or natural key, and "
            "stores JSONL under `<profile>/health/<category>/<YYYY-MM>.jsonl`. "
            "Invalid samples are reported per item; valid samples are still stored."
        ),
    )
    def health_batch(
        payload: HealthBatchRequest,
        request: Request,
        user: sqlite3.Row = Depends(require_user),
        conn: sqlite3.Connection = Depends(get_conn),
    ) -> dict:
        if int(user["must_change_password"]):
            raise ApiError(
                403,
                "password_change_required",
                "Change the default password before uploading health data.",
            )
        valid: list[HealthSample] = []
        errors: list[dict] = []
        for index, raw in enumerate(payload.samples):
            try:
                valid.append(HealthSample.model_validate(raw))
            except Exception as exc:  # noqa: BLE001
                message = str(exc).splitlines()[0][:300]
                errors.append(
                    {"index": index, "code": "invalid_sample", "message": message}
                )
        result = health_store.store_samples(
            request.app.state.settings,
            str(user["username"]),
            valid,
        )
        data = result.as_dict()
        data["rejected"] = len(errors)
        data["errors"] = errors
        return data

    @app.get(
        "/api/v1/workouts/sync",
        response_model=SyncResponse,
        tags=["workouts"],
        summary="Read workout changes (v1)",
        description=(
            "Call without `cursor` to perform a full initialization.  Persist "
            "`next_cursor` and send it on the next call to receive only changes.  "
            "When `has_more` is true, immediately call again with `next_cursor`.\n\n"
            "Changes are idempotent: apply `upsert` by `workout_id`, and remove "
            "the local workout for `delete`.  A full initialization emits only "
            "`upsert` entries; reset local state when starting without a cursor."
        ),
        responses={
            200: {
                "description": "A page of workout changes.",
                "content": {
                    "application/json": {
                        "example": {
                            "schema_version": 1,
                            "next_cursor": "eyJhIjowLCJtIjoiaW5jIiwicyI6MSwidSI6IndiX3VzZXIiLCJ2IjoxfQ.abc123",
                            "has_more": False,
                            "changes": [
                                {
                                    "op": "upsert",
                                    "workout_id": "wb_123",
                                    "workout": {
                                        "id": "wb_123",
                                        "source": "opengym",
                                        "source_id": "w_456",
                                        "date": "2026-11-04",
                                        "started_at": "2026-11-04T10:00:00Z",
                                        "ended_at": "2026-11-04T11:00:00Z",
                                        "name": "胸部训练",
                                        "exercises": [
                                            {
                                                "id": "0025",
                                                "name": "杠铃卧推",
                                                "sets": [
                                                    {
                                                        "index": 1,
                                                        "weight_kg": 40,
                                                        "reps": 10,
                                                        "seconds": None,
                                                        "rpe": None,
                                                        "rir": 2,
                                                        "warmup": False,
                                                    }
                                                ],
                                            }
                                        ],
                                    },
                                }
                            ],
                        }
                    }
                },
            },
            400: {
                "model": ErrorResponse,
                "description": "Invalid or expired cursor (`cursor_invalid`).",
            },
            401: {
                "model": ErrorResponse,
                "description": "Missing or invalid bearer token (`unauthorized`).",
                "headers": {
                    "WWW-Authenticate": {
                        "schema": {"type": "string"},
                        "description": 'Bearer realm="daydayhealth"',
                    }
                },
            },
        },
    )
    def sync_workouts(
        request: Request,
        cursor: str | None = Query(
            default=None,
            description=(
                "Opaque cursor returned by the previous call. Omit (or send an "
                "empty value) for full initialization."
            ),
        ),
        limit: int = Query(
            default=100,
            ge=1,
            le=500,
            description="Maximum number of changes in this page (1-500).",
        ),
        user: sqlite3.Row = Depends(require_user),
        conn: sqlite3.Connection = Depends(get_conn),
    ) -> dict:
        if int(user["must_change_password"]):
            raise ApiError(
                403,
                "password_change_required",
                "Change the default password before accessing workout data.",
            )
        secret: bytes = request.app.state.cursor_secret
        wb_user_id = str(user["id"])
        max_seq = db.max_change_seq(conn)

        parsed = None
        if cursor is not None and cursor.strip() != "":
            try:
                parsed = security.decode_cursor(
                    secret, wb_user_id, cursor, max_seq
                )
            except security.CursorError as exc:
                raise ApiError(
                    400,
                    "cursor_invalid",
                    "The supplied cursor is invalid or no longer usable.",
                ) from exc

        if parsed is None or parsed.mode == "full":
            after = parsed.after if parsed is not None else 0
            changes, snapshot, last_after, has_more = full_page_with_after(
                conn, wb_user_id, limit, after, request.app.state.settings
            )
            if has_more:
                next_cursor = security.encode_cursor(
                    secret,
                    wb_user_id,
                    security.Cursor("full", snapshot, last_after),
                )
            else:
                # Initialization is complete: continue from the change log.
                next_cursor = security.encode_cursor(
                    secret,
                    wb_user_id,
                    security.Cursor("inc", snapshot, 0),
                )
        else:
            changes, last_seq, has_more = incremental_page(
                conn, wb_user_id, limit, parsed.snapshot, request.app.state.settings
            )
            next_cursor = security.encode_cursor(
                secret,
                wb_user_id,
                security.Cursor("inc", last_seq, 0),
            )

        return {
            "schema_version": 1,
            "next_cursor": next_cursor,
            "has_more": has_more,
            "changes": changes,
        }

    @app.get(
        "/api/v1/sync/status",
        response_model=SyncStatusResponse,
        tags=["workouts"],
        summary="Sync status for the authenticated user",
        description=(
            "Operational status only: last attempt/success/error per mapped "
            "openGym source.  Never exposes credentials or other users' data."
        ),
        responses={
            401: {"model": ErrorResponse, "description": "Unauthenticated."}
        },
    )
    def sync_status(
        request: Request,
        user: sqlite3.Row = Depends(require_user),
        conn: sqlite3.Connection = Depends(get_conn),
    ) -> dict:
        if int(user["must_change_password"]):
            raise ApiError(
                403,
                "password_change_required",
                "Change the default password before accessing sync status.",
            )
        return {
            "schema_version": 1,
            "worker_last_cycle_at": db.get_meta(conn, "worker_last_cycle_at"),
            "worker_last_success_at": db.get_meta(conn, "worker_last_success_at"),
            "sources": source_status(conn, str(user["id"])),
        }

    return app


app = create_app()
