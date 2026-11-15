"""v1 API schemas.

Field names are part of the public contract and must not be renamed.
`side` is the only additive field: it is emitted solely for unilateral
openGym sets (left/right), where a single logical set carries two separate
loads.  It is omitted entirely for bilateral sets.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_serializer


class WorkoutSet(BaseModel):
    model_config = ConfigDict(extra="forbid")

    index: int = Field(..., ge=1, description="1-based set number from openGym")
    weight_kg: float | None = Field(
        ..., description="Load converted to kg; null when openGym has no value"
    )
    reps: float | None = Field(..., description="Repetitions; null when not applicable")
    seconds: float | None = Field(
        ..., description="Duration for timed sets; null otherwise"
    )
    rpe: float | None = Field(..., description="RPE 0-10 or null")
    rir: float | None = Field(..., description="RIR or null")
    warmup: bool = Field(..., description="True for warm-up sets")
    side: Literal["left", "right"] | None = Field(
        default=None,
        description=(
            "Only present for unilateral sets. Left/right share the same "
            "`index`; count distinct `index` values as the openGym set count."
        ),
    )

    @model_serializer(mode="wrap")
    def _omit_null_side(self, handler):  # type: ignore[no-untyped-def]
        data = handler(self)
        if data.get("side") is None:
            data.pop("side", None)
        return data


class WorkoutExercise(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str = Field(..., description="openGym exercise id, e.g. 0025")
    name: str = Field(..., description="Display name resolved from openGym catalog")
    sets: list[WorkoutSet]


class Workout(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str = Field(..., description="DayDayHealth globally stable workout id")
    source: Literal["opengym"]
    source_id: str = Field(..., description="Original openGym workout id")
    date: str | None = Field(..., description="Local date YYYY-MM-DD")
    started_at: str | None = Field(..., description="UTC ISO-8601 or null")
    ended_at: str | None = Field(..., description="UTC ISO-8601 or null")
    name: str
    exercises: list[WorkoutExercise]


class SyncChange(BaseModel):
    model_config = ConfigDict(extra="forbid")

    op: Literal["upsert", "delete"]
    workout_id: str
    workout: Workout | None


class SyncResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = 1
    next_cursor: str
    has_more: bool
    changes: list[SyncChange]


class ErrorBody(BaseModel):
    code: str
    message: str


class ErrorResponse(BaseModel):
    error: ErrorBody


class SourceStatus(BaseModel):
    opengym_user_id: str
    last_attempt_at: str | None
    last_success_at: str | None
    last_error: str | None
    workouts: int
    deleted: int


class SyncStatusResponse(BaseModel):
    schema_version: int = 1
    worker_last_cycle_at: str | None
    worker_last_success_at: str | None
    sources: list[SourceStatus]


class LoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: str = Field(..., min_length=1, max_length=64)
    password: str = Field(default="", max_length=256)
    device_name: str | None = Field(default=None, max_length=100)


class LoginResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = 1
    token: str
    token_type: Literal["Bearer"] = "Bearer"
    user_id: str
    username: str
    cf_access_client_id: str | None = None
    cf_access_client_secret: str | None = None
    last_login_at: str | None = None
    last_login_ip: str | None = None
    anomaly: bool = False
    anomaly_reasons: list[str] = []
    must_change_password: bool = False


class ChangePasswordRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    current_password: str = Field(..., min_length=1, max_length=256)
    new_password: str = Field(..., min_length=8, max_length=256)


class ChangePasswordResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    changed: bool = True


class SetupPasswordRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: str = Field(..., min_length=1, max_length=64)
    new_password: str = Field(..., min_length=8, max_length=256)
    device_name: str | None = Field(default=None, max_length=100)
