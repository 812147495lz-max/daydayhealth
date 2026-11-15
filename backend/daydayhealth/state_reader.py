"""Safe, read-only access to openGym's `state-*.json` files."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import time
from dataclasses import dataclass
from pathlib import Path

STATE_RE = re.compile(r"^state-([A-Za-z0-9_-]{6,64})\.json$")


class StateReadError(RuntimeError):
    """A state file could not be read consistently.  Callers must not delete."""


class SourceUnavailableError(StateReadError):
    """The openGym data directory itself is unavailable."""


@dataclass(frozen=True)
class StateFile:
    user_id: str
    path: Path
    name: str


@dataclass(frozen=True)
class StateSnapshot:
    user_id: str
    name: str
    raw: bytes
    sha256: str
    mtime_ns: int
    size: int
    document: object


def discover_state_files(data_dir: str | Path, limit: int = 10000) -> list[StateFile]:
    root = Path(data_dir)
    try:
        if not root.is_dir():
            raise SourceUnavailableError("openGym data directory is unavailable")
        entries = list(os.scandir(root))
    except FileNotFoundError as exc:
        raise SourceUnavailableError("openGym data directory does not exist") from exc
    except PermissionError as exc:
        raise SourceUnavailableError("openGym data directory is not readable") from exc
    except OSError as exc:
        raise SourceUnavailableError("openGym data directory cannot be listed") from exc

    result: list[StateFile] = []
    for entry in entries:
        match = STATE_RE.match(entry.name)
        if not match:
            continue
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
        except OSError:
            continue
        result.append(StateFile(match.group(1), Path(entry.path), entry.name))
        if len(result) >= limit:
            break
    result.sort(key=lambda item: item.name)
    return result


def read_state_file(
    state_file: StateFile,
    max_bytes: int,
    retries: int = 3,
    retry_delay: float = 0.25,
) -> StateSnapshot:
    """Read a file only if its bytes are stable across the read.

    A file that is being rewritten, truncated, unreadable or larger than the
    limit raises StateReadError.  No partially-read JSON is ever returned.
    """
    last_error: Exception | None = None
    for attempt in range(max(1, retries)):
        try:
            return _read_once(state_file, max_bytes)
        except StateReadError as exc:
            last_error = exc
            if attempt + 1 < max(1, retries):
                time.sleep(retry_delay * (attempt + 1))
        except Exception as exc:  # noqa: BLE001 - never leak file contents
            last_error = StateReadError(f"state read failed ({type(exc).__name__})")
            if attempt + 1 < max(1, retries):
                time.sleep(retry_delay * (attempt + 1))
    assert last_error is not None
    raise last_error


def _read_once(state_file: StateFile, max_bytes: int) -> StateSnapshot:
    path = state_file.path
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise StateReadError("state file is missing or inaccessible") from exc
    if not stat.S_ISREG(before.st_mode):
        raise StateReadError("state file is not a regular file")
    if before.st_size > max_bytes:
        raise StateReadError("state file exceeds the configured size limit")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise StateReadError("state file cannot be opened") from exc
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise StateReadError("state file is not a regular file")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise StateReadError("state file exceeds the configured size limit")
            chunks.append(chunk)
        after = os.fstat(fd)
    finally:
        os.close(fd)

    # The web client rewrites this file.  If it changed while we read it, the
    # snapshot is not trustworthy; retry rather than applying a torn state.
    if (
        before.st_ino != after.st_ino
        or before.st_dev != after.st_dev
        or before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or opened.st_size != after.st_size
    ):
        raise StateReadError("state file changed while reading")

    raw = b"".join(chunks)
    if not raw:
        raise StateReadError("state file is empty")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateReadError("state file is not valid UTF-8 JSON") from exc

    return StateSnapshot(
        user_id=state_file.user_id,
        name=state_file.name,
        raw=raw,
        sha256=hashlib.sha256(raw).hexdigest(),
        mtime_ns=after.st_mtime_ns,
        size=after.st_size,
        document=document,
    )
