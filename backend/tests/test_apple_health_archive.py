import hashlib
import json
from pathlib import Path
import sqlite3
from uuid import uuid4

from daydayhealth.apple_health_archive import CHUNK_BYTES
from .conftest import auth

ROOT = "/api/v1/healthkit-archive"


def instance(client, token):
    return client.get(ROOT + "/identity", headers=auth(token)).json()["instance_id"]


def archive_path(env):
    return Path(env.db_path).parent / "healthkit" / "records.sqlite3"


def records(env):
    with sqlite3.connect(archive_path(env)) as conn:
        return conn.execute("SELECT owner, id, payload FROM records ORDER BY owner, id").fetchall()


def sample(**values):
    return {"id": str(uuid4()), "type": "HKQuantityTypeIdentifierStepCount",
            "fields": {"sample": "YWJjZA=="}, **values}


def test_batch_replay_delete_and_account_isolation(client, env):
    assert client.get(ROOT + "/identity").status_code == 401
    url = f"{ROOT}/{instance(client, env.token_a)}/batches"
    a, b = auth(env.token_a), auth(env.token_b)
    record = sample()
    encoded = json.dumps([record]).encode()
    for _ in range(2):  # The first successful receipt can be lost.
        response = client.post(url, headers=a, content=encoded)
        assert response.json() == {"received": 1, "sha256": hashlib.sha256(encoded).hexdigest()}
    assert len(records(env)) == 1
    assert client.post(url, headers=b, json=[record]).status_code == 200
    assert client.post(url, headers=a, json=[{**record, "deleted": True}]).status_code == 200
    assert client.post(url, headers=a, content=encoded).status_code == 200
    saved = records(env)
    assert saved[0] == (env.wb_a, record["id"], None)
    assert saved[1][:2] == (env.wb_b, record["id"])
    assert json.loads(saved[1][2]) == record


def test_batch_is_atomic_and_rejects_stale_archive_identity(client, env):
    token = auth(env.token_a)
    archive = instance(client, env.token_a)
    assert client.post(f"{ROOT}/{uuid4()}/batches", headers=token, json=[sample()]).status_code == 412
    url = f"{ROOT}/{archive}/batches"
    assert client.post(url, headers=token, json=[sample(), None]).status_code == 422
    assert records(env) == []
    assert client.post(url, headers=token, content=b" " * (1024 * 1024 + 1)).status_code == 413
    old = sample(revision=100)
    new = {**old, "revision": 200, "fields": {"sample": "eA=="}}
    assert client.post(url, headers=token, json=[new, old]).status_code == 200
    assert json.loads(records(env)[0][2]) == new


def test_large_record_resumes_and_checks_integrity(client, env):
    token = auth(env.token_a)
    archive = instance(client, env.token_a)
    record = sample(fields={"sample": "A" * (CHUNK_BYTES * 2 + 11)})
    raw = json.dumps(record).encode()
    digest = hashlib.sha256(raw).hexdigest()

    def send(offset, data=None, headers=token):
        return client.put(f"{ROOT}/{archive}/records/{digest}/chunks/{offset}",
                          params={"total": len(raw)}, headers=headers,
                          content=raw[offset:offset + CHUNK_BYTES] if data is None else data)

    assert send(CHUNK_BYTES).json() == {"offset": 0, "complete": False}
    assert send(0).json() == {"offset": CHUNK_BYTES, "complete": False}
    assert send(0).json() == {"offset": CHUNK_BYTES, "complete": False}
    assert send(0, b"!" * CHUNK_BYTES).status_code == 409
    assert send(CHUNK_BYTES, headers=auth(env.token_b)).json() == {"offset": 0, "complete": False}
    assert send(CHUNK_BYTES).json() == {"offset": 2 * CHUNK_BYTES, "complete": False}
    assert records(env) == []
    tail = raw[2 * CHUNK_BYTES:]
    assert send(2 * CHUNK_BYTES, b"!" * len(tail)).status_code == 422
    assert records(env) == []
    assert send(2 * CHUNK_BYTES).json() == {"offset": len(raw), "complete": True}
    assert send(2 * CHUNK_BYTES).json() == {"offset": len(raw), "complete": True}
    assert records(env) == [(env.wb_a, record["id"], raw)]


def test_new_record_shapes_can_be_saved_and_read(client, env):
    a, b = auth(env.token_a), auth(env.token_b)
    url = f"{ROOT}/{instance(client, env.token_a)}"
    record = {
        "id": str(uuid4()),
        "schemaVersion": 2,
        "type": {"namespace": "new-feature", "version": 2},
        "measurements": [{"custom": [None, True, "未知类型"]}],
    }

    assert client.post(url + "/batches", headers=a, json=[record]).status_code == 200
    saved = url + "/records/" + record["id"]
    assert client.get(saved, headers=a).json() == record
    assert client.get(saved, headers=b).status_code == 404
    assert client.get(saved).status_code == 401
    assert client.post(url + "/batches", headers=a, json=[
        {"id": record["id"], "deleted": True},
    ]).status_code == 200
    assert client.get(saved, headers=a).status_code == 404
