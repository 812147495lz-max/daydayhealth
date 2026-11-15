"""openGym exercise-id -> display-name resolution.

The catalog is extracted from the openGym web bundle that is already deployed
next to the API.  It is read-only reference data; no openGym code or data is
modified.  `customEx` entries stored in a user's own state file take priority.
"""

from __future__ import annotations

import json
from pathlib import Path


class ExerciseCatalog:
    def __init__(self, path: str | Path):
        self._path = Path(path)
        self._en: dict[str, str] | None = None
        self._zh: dict[str, str] | None = None

    def _load(self) -> None:
        if self._en is not None:
            return
        with self._path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        self._en = {str(k): str(v) for k, v in data.get("en", {}).items()}
        self._zh = {str(k): str(v) for k, v in data.get("zh", {}).items()}

    def name_for(
        self,
        exercise_id: str,
        lang: str | None = None,
        custom_name: str | None = None,
    ) -> str:
        if custom_name:
            return custom_name
        self._load()
        if lang and str(lang).lower().startswith("zh"):
            assert self._zh is not None
            if exercise_id in self._zh:
                return self._zh[exercise_id]
        assert self._en is not None
        return self._en.get(exercise_id, exercise_id)


def custom_exercise_names(state: dict) -> dict[str, str]:
    """Extract only id/name pairs from the user's own `customEx` list."""
    result: dict[str, str] = {}
    items = state.get("customEx")
    if not isinstance(items, list):
        return result
    for item in items:
        if not isinstance(item, dict):
            continue
        raw_id = item.get("id")
        if raw_id is None:
            continue
        ex_id = str(raw_id)
        name = item.get("n") or item.get("name")
        if isinstance(name, str) and name.strip():
            result[ex_id] = name.strip()
    return result
