"""Immutable, account-scoped snapshots of the companion app's local data."""

from __future__ import annotations

import hashlib
import re
import sqlite3

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from . import db

MAX_BYTES = 64 * 1024 * 1024
ACCOUNT_BYTES = 1024 * 1024 * 1024
NO_STORE = {"Cache-Control": "private, no-store"}
DIGEST = re.compile(r"[0-9a-f]{64}")


class BackupInfo(BaseModel):
    id: str
    created_at: str
    bytes: int


def _save(conn: sqlite3.Connection, user_id: str, payload: bytes) -> BackupInfo:
    digest = hashlib.sha256(payload).hexdigest()
    with db.transaction(conn):
        previous = conn.execute(
            "SELECT id, created_at, size AS bytes FROM app_backups WHERE user_id=? AND id=?",
            (user_id, digest),
        ).fetchone()
        if previous is not None:
            return BackupInfo(**dict(previous))
        used = conn.execute(
            "SELECT coalesce(sum(size), 0) FROM app_backups WHERE user_id=?", (user_id,)
        ).fetchone()[0]
        if used + len(payload) > ACCOUNT_BYTES:
            raise HTTPException(507, "Backup storage is full")
        created = db.utc_now_iso()
        conn.execute(
            "INSERT INTO app_backups(user_id,id,created_at,size,payload) VALUES(?,?,?,?,?)",
            (user_id, digest, created, len(payload), payload),
        )
    return BackupInfo(id=digest, created_at=created, bytes=len(payload))


def router(require_user, get_conn) -> APIRouter:
    routes = APIRouter(prefix="/api/v1/app-backups", tags=["app backups"])

    @routes.get("", response_model=list[BackupInfo])
    def list_backups(
        response: Response,
        user: sqlite3.Row = Depends(require_user),
        conn: sqlite3.Connection = Depends(get_conn),
    ):
        response.headers.update(NO_STORE)
        return [
            BackupInfo(**dict(row))
            for row in conn.execute(
                "SELECT id, created_at, size AS bytes FROM app_backups WHERE user_id=? "
                "ORDER BY created_at DESC, rowid DESC",
                (user["id"],),
            )
        ]

    @routes.post(
        "",
        response_model=BackupInfo,
        openapi_extra={"requestBody": {"required": True, "content": {
            "application/octet-stream": {"schema": {"type": "string", "format": "binary"}}
        }}},
    )
    async def upload(
        request: Request,
        response: Response,
        user: sqlite3.Row = Depends(require_user),
        conn: sqlite3.Connection = Depends(get_conn),
    ):
        if request.headers.get("content-type") != "application/octet-stream":
            raise HTTPException(415, "Expected a binary app backup")
        length = request.headers.get("content-length", "")
        if length.isdecimal() and int(length) > MAX_BYTES:
            raise HTTPException(413, "Backup exceeds size limit")
        payload = bytearray()
        async for chunk in request.stream():
            if len(payload) + len(chunk) > MAX_BYTES:
                raise HTTPException(413, "Backup exceeds size limit")
            payload.extend(chunk)
        if not payload:
            raise HTTPException(400, "Empty backup")
        response.headers.update(NO_STORE)
        return await run_in_threadpool(_save, conn, user["id"], bytes(payload))

    @routes.get("/{backup_id}", response_class=Response)
    def download(
        backup_id: str,
        user: sqlite3.Row = Depends(require_user),
        conn: sqlite3.Connection = Depends(get_conn),
    ):
        if not DIGEST.fullmatch(backup_id):
            raise HTTPException(404, "Backup not found")
        row = conn.execute(
            "SELECT payload FROM app_backups WHERE user_id=? AND id=?",
            (user["id"], backup_id),
        ).fetchone()
        if row is None:
            raise HTTPException(404, "Backup not found")
        return Response(row["payload"], media_type="application/octet-stream", headers=NO_STORE)

    return routes
