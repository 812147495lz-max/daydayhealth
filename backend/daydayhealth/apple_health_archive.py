"""Account-scoped storage for versioned records uploaded by the iPhone app."""

from contextlib import closing, contextmanager
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool

BATCH_BYTES = 1024 * 1024
CHUNK_BYTES = 512 * 1024
RECORD_BYTES = 512 * 1024 * 1024
DIGEST = re.compile(r"[0-9a-f]{64}")
NO_STORE = {"Cache-Control": "private, no-store"}


@contextmanager
def database(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with closing(sqlite3.connect(path, timeout=30)) as conn, conn:
        conn.execute("PRAGMA synchronous = FULL")
        conn.execute("""CREATE TABLE IF NOT EXISTS instance (
            slot INTEGER PRIMARY KEY CHECK(slot = 1), id TEXT NOT NULL)""")
        conn.execute("""CREATE TABLE IF NOT EXISTS records (
            owner TEXT NOT NULL, id TEXT NOT NULL, type TEXT NOT NULL,
            revision REAL, payload BLOB, PRIMARY KEY(owner, id))""")
        conn.execute("""CREATE TABLE IF NOT EXISTS uploads (
            owner TEXT NOT NULL, digest TEXT NOT NULL, total INTEGER NOT NULL,
            received INTEGER NOT NULL, PRIMARY KEY(owner, digest))""")
        conn.execute("""CREATE TABLE IF NOT EXISTS pieces (
            owner TEXT NOT NULL, digest TEXT NOT NULL, offset INTEGER NOT NULL,
            body BLOB NOT NULL, PRIMARY KEY(owner, digest, offset))""")
        conn.execute("BEGIN IMMEDIATE")
        yield conn


def archive_identity(conn):
    row = conn.execute("SELECT id FROM instance WHERE slot = 1").fetchone()
    if row is None:
        identifier = str(uuid4())
        conn.execute("INSERT INTO instance VALUES(1, ?)", (identifier,))
        return identifier
    return row[0]


def write_record(conn, owner, record, encoded=None):
    # Sync metadata controls replacement and deletion. The rest belongs to the client.
    try:
        if not isinstance(record, dict):
            raise ValueError()
        identifier = str(UUID(record["id"]))
        deleted = record.get("deleted", False)
        if not isinstance(deleted, bool):
            raise ValueError()
        revision = record.get("revision")
        if revision is not None and (type(revision) not in (int, float) or not 0 < revision < 1e12):
            raise ValueError()
    except (KeyError, ValueError, TypeError, AttributeError):
        raise HTTPException(422, "Invalid archive record metadata") from None
    sample_type = record.get("type")
    # Retain compatibility with the existing standalone archive database.
    sample_type = sample_type if isinstance(sample_type, str) else ""
    payload = None if deleted else (
        encoded if encoded is not None else json.dumps(record, ensure_ascii=False).encode()
    )
    conn.execute("""INSERT INTO records(owner, id, type, revision, payload) VALUES(?,?,?,?,?)
        ON CONFLICT(owner, id) DO UPDATE SET
          type=excluded.type, revision=excluded.revision, payload=excluded.payload
        WHERE excluded.payload IS NULL OR
          (records.payload IS NOT NULL AND
           (records.revision IS NULL OR excluded.revision >= records.revision))""",
        (owner, identifier, sample_type, revision, payload))


async def read_body(request, limit):
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > limit:
            raise HTTPException(413, "Apple Health upload exceeds the request size limit")
        body.extend(chunk)
    return bytes(body)


def decode(body):
    try:
        return json.loads(body)
    except (ValueError, RecursionError):
        raise HTTPException(422, "Invalid Apple Health JSON") from None


def write_batch(path, owner, instance, body):
    batch = decode(body)
    if not isinstance(batch, list) or not 1 <= len(batch) <= 100:
        raise HTTPException(422, "Invalid Apple Health batch")
    with database(path) as conn:
        if archive_identity(conn) != instance:
            raise HTTPException(412, "Apple Health archive changed")
        for record in batch:
            write_record(conn, owner, record)
    return {"received": len(batch), "sha256": hashlib.sha256(body).hexdigest()}


def write_piece(path, owner, instance, digest, total, offset, body):
    if not DIGEST.fullmatch(digest) or not 0 < total <= RECORD_BYTES or not body:
        raise HTTPException(422, "Invalid Apple Health upload")
    if offset < 0 or offset % CHUNK_BYTES or len(body) != min(CHUNK_BYTES, total - offset):
        raise HTTPException(422, "Invalid Apple Health chunk")
    with database(path) as conn:
        if archive_identity(conn) != instance:
            raise HTTPException(412, "Apple Health archive changed")
        state = conn.execute("SELECT total, received FROM uploads WHERE owner=? AND digest=?",
                             (owner, digest)).fetchone()
        if state is None:
            conn.execute("INSERT INTO uploads VALUES(?,?,?,0)", (owner, digest, total))
            received = 0
        else:
            original_total, received = state
            if original_total != total:
                raise HTTPException(409, "Upload length changed")
        if received == total:
            return {"offset": total, "complete": True}
        if offset < received:
            stored = conn.execute("SELECT body FROM pieces WHERE owner=? AND digest=? AND offset=?",
                                  (owner, digest, offset)).fetchone()
            if stored is None or stored[0] != body:
                raise HTTPException(409, "Upload chunk changed")
        elif offset == received:
            conn.execute("INSERT INTO pieces VALUES(?,?,?,?)", (owner, digest, offset, body))
            received += len(body)
        if received == total:
            parts = conn.execute("SELECT body FROM pieces WHERE owner=? AND digest=? ORDER BY offset",
                                 (owner, digest))
            encoded = b"".join(row[0] for row in parts)
            if hashlib.sha256(encoded).hexdigest() != digest:
                raise HTTPException(422, "Apple Health checksum mismatch")
            write_record(conn, owner, decode(encoded), encoded)
            conn.execute("DELETE FROM pieces WHERE owner=? AND digest=?", (owner, digest))
        conn.execute("UPDATE uploads SET received=? WHERE owner=? AND digest=?", (received, owner, digest))
        return {"offset": received, "complete": received == total}


def router(require_user):
    routes = APIRouter(prefix="/api/v1/healthkit-archive")

    def archive_path(request):
        return Path(request.app.state.settings.db_path).parent / "healthkit" / "records.sqlite3"

    @routes.get("/identity")
    def identity(request: Request, response: Response, user=Depends(require_user)):
        response.headers.update(NO_STORE)
        with database(archive_path(request)) as conn:
            return {"instance_id": archive_identity(conn)}

    @routes.post("/{instance}/batches")
    async def batch(instance: str, request: Request, response: Response, user=Depends(require_user)):
        response.headers.update(NO_STORE)
        body = await read_body(request, BATCH_BYTES)
        return await run_in_threadpool(write_batch, archive_path(request), user["id"], instance, body)

    @routes.put("/{instance}/records/{digest}/chunks/{offset}")
    async def chunk(instance: str, digest: str, offset: int, total: int, request: Request,
                    response: Response, user=Depends(require_user)):
        response.headers.update(NO_STORE)
        body = await read_body(request, CHUNK_BYTES)
        return await run_in_threadpool(
            write_piece, archive_path(request), user["id"], instance, digest, total, offset, body)

    @routes.get("/{instance}/records/{record_id}", response_class=Response)
    def download(instance: str, record_id: UUID, request: Request, user=Depends(require_user)):
        with database(archive_path(request)) as conn:
            if archive_identity(conn) != instance:
                raise HTTPException(412, "Apple Health archive changed")
            row = conn.execute(
                "SELECT payload FROM records WHERE owner=? AND id=? AND payload IS NOT NULL",
                (user["id"], str(record_id)),
            ).fetchone()
        if row is None:
            raise HTTPException(404, "Archive record not found")
        return Response(row[0], media_type="application/json", headers=NO_STORE)

    return routes
