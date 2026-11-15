from __future__ import annotations

import json
from pathlib import Path

from daydayhealth import db, profiles

from .conftest import TOKEN_A, auth


def batch(client, samples):
    return client.post(
        "/api/v1/health/batch",
        json={"schema_version": 1, "samples": samples},
        headers=auth(TOKEN_A),
    )


def sample(**overrides):
    data = {
        "category": "activity",
        "type": "step_count",
        "source": "apple_health",
        "source_id": "com.apple.health",
        "external_id": "uuid-step-1",
        "start_at": "2026-11-05T00:00:00+08:00",
        "end_at": "2026-11-05T23:59:59+08:00",
        "local_date": "2026-11-05",
        "utc_offset_seconds": 28800,
        "value": 8234,
        "unit": "count",
        "recording_method": "automatic",
        "version": 1,
    }
    data.update(overrides)
    return data


def test_health_batch_dedup_and_category_files(env, client):
    first = batch(
        client,
        [
            sample(),
            sample(
                category="heart",
                type="heart_rate",
                external_id="uuid-hr-1",
                value=72,
                unit="bpm",
            ),
            sample(
                category="sleep",
                type="sleep_stage",
                external_id="uuid-sleep-1",
                value=None,
                value_text="asleep",
                unit=None,
            ),
        ],
    )
    assert first.status_code == 200, first.text
    body = first.json()
    assert body["accepted"] == 3
    assert body["duplicates"] == 0
    assert body["categories"] == {"activity": 1, "heart": 1, "sleep": 1}

    root = profiles.profile_dir(env.settings, "alice") / "health"
    assert (root / "activity" / "2026-11.jsonl").exists()
    assert (root / "heart" / "2026-11.jsonl").exists()
    assert (root / "sleep" / "2026-11.jsonl").exists()
    assert (root / "_index.sqlite").exists()

    again = batch(client, [sample()])
    assert again.status_code == 200
    assert again.json()["duplicates"] == 1
    assert again.json()["accepted"] == 0

    changed = sample(value=9000, version=2)
    updated = batch(client, [changed])
    assert updated.status_code == 200
    assert updated.json()["updated"] == 1
    assert updated.json()["duplicates"] == 0

    lines = (root / "activity" / "2026-11.jsonl").read_text().splitlines()
    assert len(lines) == 2
    assert json.loads(lines[-1])["sample"]["value"] == 9000


def test_health_batch_keeps_overlapping_different_sources(env, client):
    response = batch(
        client,
        [
            sample(),
            sample(
                external_id=None,
                source="manual",
                source_id="manual",
                recording_method="manual_entry",
                value=8000,
            ),
        ],
    )
    assert response.status_code == 200
    assert response.json()["accepted"] == 2


def test_health_batch_reports_invalid_samples_without_losing_valid(env, client):
    response = batch(
        client,
        [
            sample(),
            sample(category="not-a-category"),
            sample(category="heart", type="heart_rate", external_id="hr-2", value=65),
        ],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["accepted"] == 2
    assert body["rejected"] == 1
    assert body["errors"][0]["index"] == 1
    assert body["errors"][0]["code"] == "invalid_sample"


def test_health_batch_blocked_until_password_changed(env, client):
    conn = db.connect(env.settings.db_path)
    try:
        conn.execute(
            "UPDATE users SET must_change_password=1 WHERE username='alice'"
        )
    finally:
        conn.close()
    response = batch(client, [sample()])
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "password_change_required"
