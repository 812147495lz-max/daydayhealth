"""Resolve an openGym display name to its opaque state-file user id.

The CSV keeps a human-readable openGym name (for the operator); the adapter
still needs the opaque id that names `state-<id>.json`.  The worker/root helper
writes this small snapshot from openGym's `db.json` without copying credentials.
"""

from __future__ import annotations

import json
from pathlib import Path


class NameResolutionError(RuntimeError):
    pass


def load(path: str) -> dict[str, str] | None:
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError, OSError):
        return None
    try:
        rows = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise NameResolutionError("openGym user snapshot is invalid") from exc
    mapping: dict[str, str] = {}
    if isinstance(rows, list):
        for row in rows:
            if not isinstance(row, dict):
                continue
            name = str(row.get("name") or "").strip()
            uid = str(row.get("id") or "").strip()
            if name and uid:
                mapping[name] = uid
    return mapping
