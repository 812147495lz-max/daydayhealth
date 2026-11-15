#!/usr/bin/env python3
"""End-to-end HTTP test against the real DayDayHealth image and a fake openGym dir.

This does NOT touch the live sport_opengym_data volume.  It creates a separate
SQLite database, starts a throw-away API container on 127.0.0.1:18091, and drives
the documented v1 protocol over HTTP.

Usage: python3 scripts/e2e_http.py [--keep]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".e2e"
RUNTIME = WORK / "runtime"
DATA = WORK / "data"
IMAGE = "daydayhealth:1.0.0"
API_PORT = 18091
API_NAME = "daydayhealth-e2e-api"
OG_A = "E2EUSERAAAAA"
OG_B = "E2EUSERBBBBB"

PASS: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise AssertionError(f"{name} failed: {detail}")
    PASS.append(name)
    print(f"PASS {name}")


def docker(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["docker", *args],
        check=check,
        text=True,
        capture_output=True,
    )


def cli(*args: str) -> str:
    return docker(
        "run",
        "--rm",
        "-v",
        f"{RUNTIME}:/var/lib/daydayhealth",
        "-e",
        "DAYDAYHEALTH_DB=/var/lib/daydayhealth/daydayhealth.db",
        IMAGE,
        "python",
        "-m",
        "daydayhealth.cli",
        *args,
    ).stdout


def sync() -> dict:
    proc = docker(
        "run",
        "--rm",
        "-v",
        f"{RUNTIME}:/var/lib/daydayhealth",
        "-v",
        f"{DATA}:/opengym-data:ro",
        "-e",
        "DAYDAYHEALTH_DB=/var/lib/daydayhealth/daydayhealth.db",
        "-e",
        "OPENGYM_DATA_DIR=/opengym-data",
        IMAGE,
        "python",
        "-m",
        "daydayhealth.cli",
        "sync-once",
        check=False,
    )
    if not proc.stdout.strip():
        raise RuntimeError(proc.stderr)
    return json.loads(proc.stdout)


def workout(sid: str, name: str, weight: float, reps: int) -> dict:
    return {
        "id": sid,
        "d": "2026-11-04",
        "start": 1793786400000,
        "end": 1793790000000,
        "name": name,
        "entries": [
            {
                "id": "0025",
                "sets": [{"w": weight, "r": reps, "done": True}],
            }
        ],
    }


def write_state(user: str, workouts: list[dict], deleted: dict | None = None) -> None:
    payload = {
        "unit": "kg",
        "lang": "zh",
        "workouts": workouts,
        "deleted": {"workouts": deleted or {}},
    }
    (DATA / f"state-{user}.json").write_text(
        json.dumps(payload, ensure_ascii=False), encoding="utf-8"
    )


def request(
    token: str, cursor: str | None = None, limit: int = 100
) -> tuple[int, dict]:
    url = f"http://127.0.0.1:{API_PORT}/api/v1/workouts/sync?limit={limit}"
    if cursor is not None:
        url += "&cursor=" + urllib.parse.quote(cursor)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def wait_api() -> None:
    for _ in range(50):
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{API_PORT}/healthz", timeout=2
            ) as resp:
                if resp.status == 200:
                    return
        except Exception:
            pass
        time.sleep(0.2)
    raise RuntimeError("API did not become healthy")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    if WORK.exists():
        shutil.rmtree(WORK)
    RUNTIME.mkdir(parents=True)
    DATA.mkdir(parents=True)
    os.chmod(RUNTIME, 0o700)
    os.chmod(DATA, 0o755)
    subprocess.run(
        ["docker", "rm", "-f", API_NAME],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    user_a = json.loads(cli("create-user", "--username", "e2e-a"))
    user_b = json.loads(cli("create-user", "--username", "e2e-b"))
    token_a, token_b = user_a["token"], user_b["token"]
    cli("map", "--opengym-user-id", OG_A, "--username", "e2e-a")
    cli("map", "--opengym-user-id", OG_B, "--username", "e2e-b")

    docker(
        "run",
        "-d",
        "--rm",
        "--name",
        API_NAME,
        "--read-only",
        "--tmpfs",
        "/tmp",
        "-p",
        f"127.0.0.1:{API_PORT}:8000",
        "-e",
        "DAYDAYHEALTH_DB=/var/lib/daydayhealth/daydayhealth.db",
        "-v",
        f"{RUNTIME}:/var/lib/daydayhealth",
        IMAGE,
    )
    try:
        wait_api()

        status, body = request("bad")
        check("bad token returns 401", status == 401 and body["error"]["code"] == "unauthorized")
        status, _ = request("")
        check("missing token returns 401", status == 401)

        write_state(OG_A, [workout("w1", "W1", 40, 10)])
        write_state(OG_B, [workout("b1", "B1", 80, 5)])
        st = sync()
        check("first full import", st["upserts"] == 2, json.dumps(st, ensure_ascii=False))

        status_a, a = request(token_a)
        status_b, b = request(token_b)
        check("user A only sees A's workout", [c["workout"]["source_id"] for c in a["changes"]] == ["w1"])
        check("user B only sees B's workout", [c["workout"]["source_id"] for c in b["changes"]] == ["b1"])
        first_set = a["changes"][0]["workout"]["exercises"][0]["sets"][0]
        check("API set weight/reps match source", first_set["weight_kg"] == 40 and first_set["reps"] == 10)
        cursor = a["next_cursor"]
        a_workout_id = a["changes"][0]["workout_id"]

        status, cross = request(token_b, cursor)
        check(
            "cross-user cursor -> 400 cursor_invalid",
            status == 400 and cross["error"]["code"] == "cursor_invalid",
        )

        write_state(OG_A, [workout("w1", "W1", 40, 10), workout("w2", "W2", 50, 8)])
        sync()
        status, added = request(token_a, cursor)
        check("new workout arrives incrementally", [c["workout"]["source_id"] for c in added["changes"]] == ["w2"])
        cursor = added["next_cursor"]
        w2_workout_id = added["changes"][0]["workout_id"]

        write_state(OG_A, [workout("w1", "W1", 72.5, 6), workout("w2", "W2", 50, 8)])
        sync()
        status, changed = request(token_a, cursor)
        check(
            "modification is upsert with same workout_id",
            changed["changes"][0]["op"] == "upsert"
            and changed["changes"][0]["workout"]["id"] == a_workout_id,
        )
        sets = changed["changes"][0]["workout"]["exercises"][0]["sets"]
        check("modified weight and reps", sets[0]["weight_kg"] == 72.5 and sets[0]["reps"] == 6)
        cursor = changed["next_cursor"]

        write_state(OG_A, [workout("w1", "W1", 72.5, 6)], deleted={"w2": 1793786500000})
        sync()
        status, deleted = request(token_a, cursor)
        check(
            "delete change with null workout",
            deleted["changes"]
            == [{"op": "delete", "workout_id": w2_workout_id, "workout": None}],
        )
        cursor = deleted["next_cursor"]

        after = sync()
        check("repeated sync is idempotent", after["upserts"] == 0 and after["unchanged"] >= 1)
        check("no changes after cursor caught up", request(token_a, cursor)[1]["changes"] == [])

        (DATA / f"state-{OG_A}.json").write_text("{broken", encoding="utf-8")
        broken = sync()
        check("corrupt file fails safely", broken["failed"] == 1)
        check(
            "corrupt file does not delete data",
            [c["workout"]["source_id"] for c in request(token_a)[1]["changes"]] == ["w1"],
        )

        write_state(OG_A, [workout("w1", "W1", 72.5, 6)], deleted={"w2": 1793786500000})
        check("recovers after corrupt file", sync()["failed"] == 0)

        docker("restart", API_NAME)
        wait_api()
        check("cursor survives API restart", request(token_a, cursor)[1]["changes"] == [])

        write_state(
            OG_A,
            [workout("p1", "P1", 10, 10), workout("p2", "P2", 20, 10), workout("p3", "P3", 30, 10)],
            deleted={"w1": 1793786600000},
        )
        sync()
        seen: list[str] = []
        pages = 0
        page_cursor: str | None = None
        while True:
            _, page = request(token_a, page_cursor, limit=1)
            pages += 1
            seen.extend(c["workout"]["source_id"] for c in page["changes"])
            page_cursor = page["next_cursor"]
            if not page["has_more"]:
                break
        check("pagination covers every current workout once", sorted(seen) == ["p1", "p2", "p3"] and pages == 3)

        print(f"\n{len(PASS)} checks passed")
        return 0
    finally:
        subprocess.run(
            ["docker", "rm", "-f", API_NAME],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not args.keep:
            shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
