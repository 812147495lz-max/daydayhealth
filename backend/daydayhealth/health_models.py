"""Health upload request/response models."""

from __future__ import annotations

import datetime as dt
import re
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

CATEGORIES = {
    "activity",
    "heart",
    "sleep",
    "body",
    "workouts",
    "vitals",
    "nutrition",
    "mindfulness",
    "symptoms",
    "medications",
    "other",
}

_TYPE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")


class HealthSample(BaseModel):
    model_config = ConfigDict(extra="forbid")

    category: str = Field(..., min_length=1, max_length=40)
    type: str = Field(..., min_length=1, max_length=100)
    source: str = Field(..., min_length=1, max_length=100)
    source_id: str = Field(..., min_length=1, max_length=200)
    external_id: str | None = Field(default=None, max_length=300)
    start_at: dt.datetime
    end_at: dt.datetime | None = None
    local_date: dt.date | None = None
    utc_offset_seconds: int | None = Field(default=None, ge=-86400, le=86400)
    value: float | None = None
    value_text: str | None = Field(default=None, max_length=500)
    value_json: dict[str, Any] | None = None
    unit: str | None = Field(default=None, max_length=40)
    recording_method: Literal[
        "automatic", "actively_recorded", "manual_entry", "unknown"
    ] = "unknown"
    version: int | None = Field(default=None, ge=0)
    metadata: dict[str, Any] = Field(default_factory=dict)

    @field_validator("category")
    @classmethod
    def _category(cls, value: str) -> str:
        value = value.strip().lower()
        if value not in CATEGORIES:
            raise ValueError("unknown health category")
        return value

    @field_validator("type")
    @classmethod
    def _type(cls, value: str) -> str:
        value = value.strip()
        if not _TYPE_RE.fullmatch(value):
            raise ValueError("invalid health type")
        return value

    @field_validator("start_at", "end_at")
    @classmethod
    def _aware(cls, value: dt.datetime | None) -> dt.datetime | None:
        if value is not None and value.tzinfo is None:
            raise ValueError("timestamp must include a timezone offset")
        return value

    @model_validator(mode="after")
    def _normalize(self):
        if self.end_at is None:
            self.end_at = self.start_at
        if self.end_at < self.start_at:
            raise ValueError("end_at must not be before start_at")
        if self.local_date is None:
            self.local_date = self.start_at.date()
        if self.value is None and self.value_text is None and self.value_json is None:
            raise ValueError("one of value/value_text/value_json is required")
        return self


class HealthError(BaseModel):
    index: int
    code: str
    message: str


class HealthBatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = 1
    device: dict[str, Any] | None = None
    samples: list[dict[str, Any]] = Field(..., min_length=1, max_length=1000)


class HealthBatchResponse(BaseModel):
    schema_version: int = 1
    accepted: int = 0
    updated: int = 0
    duplicates: int = 0
    rejected: int = 0
    categories: dict[str, int] = Field(default_factory=dict)
    errors: list[HealthError] = Field(default_factory=list)
