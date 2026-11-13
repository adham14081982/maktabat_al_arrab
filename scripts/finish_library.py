#!/usr/bin/env python3
"""Wait for the running OCR job, then finish the release by itself.

    py -3 finish_library.py                # wait for ocr_book.py, repromote, build APK
    py -3 finish_library.py --no-build     # repromote only

Why this exists: OCR on the full library takes hours. Everything that has to
happen afterwards (syncing `content_mode` into library.json, then a ~15 minute
Gradle build) is mechanical, so it should not need a human to press go.

The script is idempotent — running it twice just rebuilds the same APK.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PY = sys.executable

QUERY = (
    "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | "
    "Where-Object { $_.CommandLine -like '*ocr_book.py*' } | "
    "Select-Object -ExpandProperty ProcessId"
)


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def ocr_running() -> bool:
    """True while a python.exe on this machine is running ocr_book.py."""
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command", QUERY],
        capture_output=True, text=True,
    )
    return any(line.strip().isdigit() for line in out.stdout.splitlines())


def run(cmd: list[str], cwd: Path) -> int:
    log("$ " + " ".join(cmd))
    return subprocess.call(cmd, cwd=str(cwd))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--poll", type=int, default=60, help="seconds between checks")
    ap.add_argument("--max-wait", type=int, default=8 * 3600)
    args = ap.parse_args()

    started = time.time()
    log("waiting for the OCR job to finish …")
    while ocr_running():
        if time.time() - started > args.max_wait:
            log("gave up waiting — OCR is still running, re-run this later.")
            return 2
        time.sleep(args.poll)

    log("OCR finished. Syncing library.json …")
    rc = run([PY, str(HERE / "ocr_book.py"), "--repromote"], HERE)
    if rc != 0:
        log(f"repromote failed (exit {rc}) — stopping before the build.")
        return rc

    if args.no_build:
        log("done (build skipped).")
        return 0

    log("building the release APK — this takes 10-20 minutes …")
    rc = run(["flutter", "build", "apk", "--release"], ROOT)
    if rc != 0:
        log(f"build failed (exit {rc}).")
        return rc

    src = ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    dst = ROOT / "Maktabat_Al_Arrab_v2.4.0_hybrid.apk"
    if src.exists():
        shutil.copy2(src, dst)
        log(f"APK ready: {dst}  ({dst.stat().st_size / 1e6:.0f} MB)")
    else:
        log("build reported success but no APK was found.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
