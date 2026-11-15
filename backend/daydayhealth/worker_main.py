"""Long-running sync worker entrypoint.

The worker is a separate process/container from the API.  It owns all writes to
the SQLite database; the API only reads.  A failed cycle is retried with
bounded exponential backoff, while normal cycles run every
SYNC_INTERVAL_SECONDS (default 60).
"""

from __future__ import annotations

import argparse
import json
import logging
import signal
import sys
import threading

from . import db, security
from .adapter import OpenGymSyncAdapter
from .config import Settings
from .reconcile import run_reconcile


def _configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )


def run(settings: Settings, once: bool = False) -> int:
    adapter = OpenGymSyncAdapter(settings)
    stop = threading.Event()

    def _handle_signal(signum, _frame) -> None:
        logging.getLogger("daydayhealth.worker").info(
            "worker.shutdown signal=%s", signum
        )
        stop.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    logger = logging.getLogger("daydayhealth.worker")
    logger.info(
        "worker.start data_dir=%s interval=%ss db=%s",
        settings.opengym_data_dir,
        settings.sync_interval_seconds,
        settings.db_path,
    )
    pepper = security.load_or_create_pepper(
        settings.password_pepper_file,
        None,
    )

    def _reconcile_if_due() -> None:
        import datetime as _dt
        today = db.utc_now().strftime("%Y-%m-%d")
        conn = db.connect(settings.db_path)
        try:
            last = db.get_meta(conn, "last_reconcile_date")
            if last == today or db.utc_now().hour < settings.reconcile_hour:
                return
            result = run_reconcile(conn, settings, pepper)
            db.set_meta(conn, "last_reconcile_date", today)
            logger.info("reconcile %s", json.dumps(result.as_dict(), ensure_ascii=False))
        except Exception:  # noqa: BLE001
            logger.exception("reconcile.failed")
        finally:
            conn.close()

    attempt = 0
    last_ok = True
    while not stop.is_set():
        _reconcile_if_due()
        stats = adapter.run_cycle()
        if once:
            print(json.dumps(stats.as_dict(), ensure_ascii=False))
            return 0 if stats.ok else 1
        if stats.ok:
            attempt = 0
            last_ok = True
            delay = settings.sync_interval_seconds
        else:
            last_ok = False
            delay = min(settings.sync_interval_seconds, 5 * (2**attempt))
            attempt = min(attempt + 1, 4)
            logger.warning("worker.retry in=%ss attempt=%s", delay, attempt)
        stop.wait(delay)
    logger.info("worker.stop last_ok=%s", last_ok)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="DayDayHealth openGym sync worker")
    parser.add_argument(
        "--once", action="store_true", help="run one cycle and exit (testing/ops)"
    )
    args = parser.parse_args(argv)
    _configure_logging()
    return run(Settings.from_env(), once=args.once)


if __name__ == "__main__":
    raise SystemExit(main())
