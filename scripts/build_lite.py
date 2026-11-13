#!/usr/bin/env python3
"""Build the small APK — code only, no books.

    py -3 build_lite.py                 # -> Maktabat_Al_Arrab_lite.apk  (~25 MB)
    py -3 build_lite.py --restore       # undo a crashed run by hand

The books live in `maktabat_library.zip` and arrive through the in-app
«استيراد المكتبة» screen, so this build must not carry them. Flutter has no
conditional asset list, and it *errors* when a declared asset directory is
missing — so the build temporarily moves the heavy folders aside and rewrites
the asset block in `pubspec.yaml`.

Moving is a rename on the same volume, so it costs milliseconds. Everything is
restored in `finally`, and `--restore` (plus an automatic check at startup)
recovers from a hard kill mid-build.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "pubspec.yaml"
BACKUP = ROOT / "pubspec.yaml.litebak"
STASH = ROOT / "_lite_stash"
MARKER = ROOT / ".lite-build-in-progress"

# Folders that make up the library payload (see scripts/pack_library.py).
HEAVY = ["assets/books", "assets/covers", "assets/book_jsons"]
HEAVY_FILES = ["assets/library.json"]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def restore() -> None:
    """Put every moved folder and the original pubspec back."""
    if STASH.exists():
        for rel in HEAVY + HEAVY_FILES:
            src = STASH / rel
            dst = ROOT / rel
            if not src.exists():
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists():
                if dst.is_dir():
                    shutil.rmtree(dst)
                else:
                    dst.unlink()
            shutil.move(str(src), str(dst))
        shutil.rmtree(STASH, ignore_errors=True)
    if BACKUP.exists():
        shutil.move(str(BACKUP), str(PUBSPEC))
    if MARKER.exists():
        MARKER.unlink()


def stash() -> None:
    """Move the library out of the project and strip it from pubspec."""
    if MARKER.exists() or STASH.exists():
        log("a previous run left the project stashed — restoring first")
        restore()

    MARKER.write_text("1")
    shutil.copy2(PUBSPEC, BACKUP)
    STASH.mkdir()

    for rel in HEAVY + HEAVY_FILES:
        src = ROOT / rel
        if not src.exists():
            continue
        dst = STASH / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))

    text = BACKUP.read_text(encoding="utf-8")
    kept = []
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("- assets/books") or \
           stripped.startswith("- assets/covers") or \
           stripped.startswith("- assets/book_jsons") or \
           stripped.startswith("- assets/library.json"):
            continue
        kept.append(line)
    PUBSPEC.write_text("".join(kept), encoding="utf-8")
    log("library stashed, pubspec trimmed")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    ap.add_argument("--out", default="Maktabat_Al_Arrab_lite.apk")
    args = ap.parse_args()

    if args.restore:
        restore()
        log("restored")
        return 0

    try:
        stash()
        log("building …")
        # `flutter` is flutter.bat on Windows, and CreateProcess will not add
        # PATHEXT for us — resolve the real path first or the build never starts.
        flutter = shutil.which("flutter")
        if flutter is None:
            log("flutter not found on PATH")
            return 1
        rc = subprocess.call(
            [flutter, "build", "apk", "--release",
             "--target-platform", "android-arm64"],
            cwd=str(ROOT),
        )
    finally:
        restore()
        log("project restored")

    if rc != 0:
        log(f"build failed (exit {rc})")
        return rc

    src = ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    dst = ROOT / args.out
    if not src.exists():
        log("build reported success but no APK was found")
        return 1
    shutil.copy2(src, dst)
    log(f"APK ready: {dst}  ({dst.stat().st_size / 1e6:.0f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
