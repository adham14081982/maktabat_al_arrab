#!/usr/bin/env python3
"""One command for the whole chain — Phase (A) images, then Phase (B) text.

    py -3 run_all.py                      # everything, resumable
    py -3 run_all.py --only-a             # images only
    py -3 run_all.py --only-b             # OCR + correction only
    py -3 run_all.py --books 3 --limit 40 # pilot: 3 books, 40 pages each
    py -3 run_all.py --report             # status of the whole library

Both phases resume: Phase A skips a book whose zip already exists, Phase B
skips a book whose OCR results file exists (and skips individual pages inside
a book). Nothing is ever reviewed by hand — every correction is validated by
the automatic gates in autocorrect.py.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ASSETS = ROOT / "assets"
PY = sys.executable


def run(cmd: list[str]) -> int:
    print("\n$ " + " ".join(cmd), flush=True)
    return subprocess.call(cmd, cwd=str(HERE))


def phase_a(source: str, output: str, workers: int, limit: int) -> int:
    cmd = [PY, str(HERE / "build_page_library_v2.py"),
           "--source", source, "--output", output, "--workers", str(workers)]
    if limit:
        cmd += ["--limit", str(limit)]
    return run(cmd)


def phase_b(engine: str, workers: int, limit: int) -> int:
    cmd = [PY, str(HERE / "ocr_book.py"), "--all",
           "--engine", engine, "--workers", str(workers)]
    return run(cmd)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=str(ROOT.parent))
    ap.add_argument("--output", default=str(ASSETS))
    ap.add_argument("--only-a", action="store_true")
    ap.add_argument("--only-b", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--books", type=int, default=0, help="pilot: first N books")
    ap.add_argument("--limit", type=int, default=0, help="pilot: first N pages")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--engine", default="tesseract")
    args = ap.parse_args()

    if args.report:
        run([PY, str(HERE / "ocr_book.py"), "--report"])
        return

    if not args.only_b:
        rc = phase_a(args.source, args.output, args.workers, args.books)
        if rc != 0:
            print("Phase A failed — stopping so the cause is visible.")
            return

    if not args.only_a:
        phase_b(args.engine, args.workers, args.limit)

    # Phase B writes REPORT.md itself when it reaches the end, but a killed or
    # crashed run never gets there and leaves no report at all. Asking for one
    # again here is idempotent and means the file always exists afterwards.
    if not args.only_a:
        run([PY, str(HERE / "ocr_book.py"), "--report"])


if __name__ == "__main__":
    main()
