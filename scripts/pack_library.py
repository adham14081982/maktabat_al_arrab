#!/usr/bin/env python3
"""Pack the library into ONE transferable file for the on-device import screen.

    py -3 pack_library.py                  # -> maktabat_library.zip
    py -3 pack_library.py --out D:/lib.zip

Why the books are not in the APK any more: the APK was 861 MB, and spec §2
requires anything over 150 MB to live outside it. The APK now ships the code
(~20 MB) and the library arrives through «استيراد المكتبة».

Everything is stored uncompressed (`ZIP_STORED`). The books are already
per-book zips of WebP pages and the covers are WebP, so deflate would spend
minutes to save a couple of percent — and stored entries let the importer copy
bytes instead of inflating 861 MB on a phone.

Layout inside the archive mirrors the asset tree exactly, so the Dart side can
switch between "bundled assets" and "extracted folder" by changing one root
prefix and nothing else.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ASSETS = ROOT / "assets"

# Directories that the app reads at runtime. `ocr/` is deliberately absent:
# it is the pipeline's own scratch data (81 MB) and never loaded by Flutter.
INCLUDE_DIRS = ["books", "covers", "book_jsons"]
INCLUDE_FILES = ["library.json"]


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def collect() -> list[Path]:
    files: list[Path] = []
    for name in INCLUDE_FILES:
        p = ASSETS / name
        if p.exists():
            files.append(p)
        else:
            print(f"! missing {p}", file=sys.stderr)
    for d in INCLUDE_DIRS:
        base = ASSETS / d
        if not base.exists():
            print(f"! missing {base}", file=sys.stderr)
            continue
        files.extend(sorted(p for p in base.rglob("*") if p.is_file()))
    return files


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "maktabat_library.zip"))
    ap.add_argument("--compress", action="store_true",
                    help="deflate instead of store (slower, saves ~2%%)")
    args = ap.parse_args()

    out = Path(args.out)
    files = collect()
    if not files:
        print("nothing to pack", file=sys.stderr)
        return 1

    total_bytes = sum(p.stat().st_size for p in files)
    print(f"packing {len(files):,} files · {human(total_bytes)} → {out}")

    lib = json.loads((ASSETS / "library.json").read_text(encoding="utf-8"))
    manifest = {
        "format": 1,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "app_version": "2.4.0",
        "books": len(lib.get("books", [])),
        "sections": len(lib.get("sections", [])),
        "files": len(files),
        "bytes": total_bytes,
    }

    mode = zipfile.ZIP_DEFLATED if args.compress else zipfile.ZIP_STORED
    tmp = out.with_suffix(out.suffix + ".part")
    written = 0
    started = time.time()
    try:
        with zipfile.ZipFile(tmp, "w", mode, compresslevel=1) as zf:
            zf.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
            for i, p in enumerate(files, 1):
                # The books are already per-book zips of WebP pages, so deflate
                # buys ~2% for a lot of CPU. JSON is the opposite: 90 MB of
                # Arabic text compresses to a third. Compress per entry.
                ctype = (
                    zipfile.ZIP_DEFLATED
                    if args.compress or p.suffix == ".json"
                    else zipfile.ZIP_STORED
                )
                zf.write(
                    p,
                    p.relative_to(ASSETS).as_posix(),
                    compress_type=ctype,
                    compresslevel=6 if ctype == zipfile.ZIP_DEFLATED else None,
                )
                written += p.stat().st_size
                if i % 200 == 0 or i == len(files):
                    pct = written / total_bytes * 100 if total_bytes else 100
                    print(f"  [{i:>5}/{len(files)}] {pct:5.1f}%  "
                          f"{human(written)}  ({time.time()-started:.0f}s)", flush=True)
        os.replace(tmp, out)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise

    size = out.stat().st_size
    print(f"\n✓ {out}")
    print(f"  {human(size)} · {manifest['books']} كتاب · {manifest['files']:,} ملف")
    print("  انقل هذا الملف إلى الهاتف ثم استورده من شاشة «استيراد المكتبة».")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
