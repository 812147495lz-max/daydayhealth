"""Convert one openGym `state-*.json` document into v1 workouts.

Only the fields listed in ALLOWED_TOP_LEVEL are touched.  In particular the
reader never looks at credentials, tokens, secrets, passkeys or any other
authentication material that may live in the same data directory.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import math
import re
from dataclasses import dataclass, field

from .catalog import ExerciseCatalog, custom_exercise_names
from .db import iso_z, ms_to_iso

ALLOWED_TOP_LEVEL = {"workouts", "deleted", "unit", "lang", "customEx"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LB_TO_KG = 0.45359237
VALID_SIDES = {"l": "left", "r": "right", "left": "left", "right": "right"}


class StateFormatError(ValueError):
    """The document is not a usable openGym state file."""


@dataclass
class ParsedSet:
    index: int
    weight_kg: float | None
    reps: float | None
    seconds: float | None
    rpe: float | None
    rir: float | None
    warmup: bool
    side: str | None = None

    def to_dict(self) -> dict:
        out = {
            "index": self.index,
            "weight_kg": self.weight_kg,
            "reps": self.reps,
            "seconds": self.seconds,
            "rpe": self.rpe,
            "rir": self.rir,
            "warmup": self.warmup,
        }
        if self.side is not None:
            out["side"] = self.side
        return out


@dataclass
class ParsedExercise:
    id: str
    name: str
    sets: list[ParsedSet] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "sets": [s.to_dict() for s in self.sets],
        }


@dataclass
class ParsedWorkout:
    source_id: str
    date: str | None
    started_at: str | None
    ended_at: str | None
    name: str
    exercises: list[ParsedExercise]
    source_updated_at: str | None = None

    def canonical(self) -> dict:
        return {
            "source": "opengym",
            "source_id": self.source_id,
            "date": self.date,
            "started_at": self.started_at,
            "ended_at": self.ended_at,
            "name": self.name,
            "exercises": [e.to_dict() for e in self.exercises],
        }

    def to_api(self, workout_id: str) -> dict:
        return {
            "id": workout_id,
            "source": "opengym",
            "source_id": self.source_id,
            "date": self.date,
            "started_at": self.started_at,
            "ended_at": self.ended_at,
            "name": self.name,
            "exercises": [e.to_dict() for e in self.exercises],
        }

    def content_hash(self) -> str:
        raw = json.dumps(
            self.canonical(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()


@dataclass
class ParsedState:
    workouts: list[ParsedWorkout]
    tombstones: dict[str, str]
    lang: str | None
    unit: str
    warnings: list[str] = field(default_factory=list)


def _number(value: object) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        v = float(value)
    elif isinstance(value, str):
        text = value.strip().replace(",", ".")
        if not text:
            return None
        try:
            v = float(text)
        except ValueError:
            return None
    else:
        return None
    if not math.isfinite(v):
        return None
    return v


def _round(value: float | None, digits: int = 4) -> float | None:
    return None if value is None else round(value, digits)


def _warmup(raw: dict) -> bool:
    if raw.get("warmup") is True or raw.get("warm") is True:
        return True
    phase = raw.get("phase")
    return isinstance(phase, str) and phase.lower() == "warmup"


def _done(raw: dict) -> bool:
    """A set without an explicit done flag is treated as logged if it has data."""
    if raw.get("done") is False:
        return False
    if raw.get("done") is True:
        return True
    return any(raw.get(k) is not None for k in ("w", "r", "sec", "seconds"))


def _weight_kg(raw_value: object, unit: str) -> float | None:
    value = _number(raw_value)
    if value is None:
        return None
    if unit.lower() in ("lb", "lbs", "pound", "pounds"):
        value *= LB_TO_KG
    return _round(value)


def _make_set(
    index: int,
    raw: dict,
    parent: dict,
    unit: str,
) -> ParsedSet:
    seconds = _number(raw.get("sec"))
    if seconds is None:
        seconds = _number(raw.get("seconds"))
    rpe = _number(raw.get("rpe"))
    if rpe is None:
        rpe = _number(parent.get("rpe"))
    rir = _number(raw.get("rir"))
    if rir is None:
        rir = _number(parent.get("rir"))
    return ParsedSet(
        index=index,
        weight_kg=_weight_kg(raw.get("w"), unit),
        reps=_round(_number(raw.get("r"))),
        seconds=_round(seconds),
        rpe=rpe,
        rir=rir,
        warmup=_warmup(parent) or _warmup(raw),
    )


def _sets_for_entry(raw_sets: object, unit: str) -> list[ParsedSet]:
    if not isinstance(raw_sets, list):
        return []
    result: list[ParsedSet] = []
    for pos, item in enumerate(raw_sets, start=1):
        if not isinstance(item, dict):
            continue
        sides = item.get("sides")
        if isinstance(sides, dict) and sides:
            # openGym stores unilateral work as sides.{L,R} with independent
            # load/reps/done.  Emit one entry per performed side, sharing the
            # logical set index.
            for key, side_name in (("l", "left"), ("r", "right")):
                side_raw = None
                for candidate, mapped in VALID_SIDES.items():
                    if mapped != side_name:
                        continue
                    for k, v in sides.items():
                        if isinstance(k, str) and k.lower() == candidate and isinstance(v, dict):
                            side_raw = v
                            break
                    if side_raw is not None:
                        break
                if side_raw is None or not _done(side_raw):
                    continue
                parsed = _make_set(pos, side_raw, item, unit)
                parsed.side = side_name
                result.append(parsed)
        else:
            if not _done(item):
                continue
            result.append(_make_set(pos, item, item, unit))
    return result


def _valid_date(value: object, started_at: str | None) -> str | None:
    if isinstance(value, str) and DATE_RE.match(value.strip()):
        return value.strip()
    if started_at:
        return started_at[:10]
    return None


def _safe_name(value: object, fallback: str) -> str:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return fallback


def parse_state(
    state: object,
    user_id: str,
    catalog: ExerciseCatalog,
) -> ParsedState:
    if not isinstance(state, dict):
        raise StateFormatError("state document is not a JSON object")
    workouts_raw = state.get("workouts")
    if not isinstance(workouts_raw, list):
        raise StateFormatError("state.workouts is missing or not a list")

    unit_raw = state.get("unit")
    unit = unit_raw.strip() if isinstance(unit_raw, str) and unit_raw.strip() else "kg"
    lang = state.get("lang") if isinstance(state.get("lang"), str) else None
    custom = custom_exercise_names(state)
    warnings: list[str] = []

    workouts: list[ParsedWorkout] = []
    seen: set[str] = set()
    for item in workouts_raw:
        if not isinstance(item, dict):
            warnings.append("workout_not_object")
            continue
        raw_id = item.get("id")
        if raw_id is None or isinstance(raw_id, bool):
            warnings.append("workout_without_id")
            continue
        source_id = str(raw_id).strip()
        if not source_id or len(source_id) > 200:
            warnings.append("workout_with_invalid_id")
            continue
        if source_id in seen:
            warnings.append("duplicate_workout_id")
            continue
        seen.add(source_id)

        started_at = ms_to_iso(item.get("start"))
        ended_at = ms_to_iso(item.get("end"))
        date = _valid_date(item.get("d"), started_at)

        exercises: list[ParsedExercise] = []
        raw_entries = item.get("entries")
        if not isinstance(raw_entries, list):
            raw_entries = []
        for entry in raw_entries:
            if not isinstance(entry, dict):
                warnings.append("entry_not_object")
                continue
            entry_id = entry.get("id")
            if entry_id is None or isinstance(entry_id, bool):
                warnings.append("entry_without_id")
                continue
            exercise_id = str(entry_id).strip()
            if not exercise_id:
                warnings.append("entry_with_empty_id")
                continue
            name = catalog.name_for(
                exercise_id,
                lang=lang,
                custom_name=custom.get(exercise_id) or _optional_str(entry.get("name")),
            )
            exercises.append(
                ParsedExercise(
                    id=exercise_id,
                    name=name,
                    sets=_sets_for_entry(entry.get("sets"), unit),
                )
            )

        workouts.append(
            ParsedWorkout(
                source_id=source_id,
                date=date,
                started_at=started_at,
                ended_at=ended_at,
                name=_safe_name(item.get("name"), "Workout"),
                exercises=exercises,
                source_updated_at=ms_to_iso(item.get("_ts")),
            )
        )

    tombstones: dict[str, str] = {}
    deleted = state.get("deleted")
    if isinstance(deleted, dict):
        deleted_workouts = deleted.get("workouts")
        if isinstance(deleted_workouts, dict):
            for raw_sid, ts in deleted_workouts.items():
                source_id = str(raw_sid).strip()
                if not source_id or source_id in seen:
                    continue  # an active workout always wins over its tombstone
                stamp = ms_to_iso(ts)
                if stamp is None:
                    stamp = iso_z(_dt.datetime.now(_dt.timezone.utc))
                tombstones[source_id] = stamp
        elif deleted_workouts is not None:
            warnings.append("deleted_workouts_not_object")

    return ParsedState(
        workouts=workouts,
        tombstones=tombstones,
        lang=lang,
        unit=unit,
        warnings=warnings,
    )


def _optional_str(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None
