#!/usr/bin/env python3
"""
Shrink the page library by re-encoding every page image at a smaller width.

Why re-encode instead of re-rendering from the PDFs: re-rendering would
re-run gutter detection and margin trimming, which can change the page count
of a book and therefore invalidate every saved bookmark and reading position.
Re-encoding keeps the exact same page count, order and file names, so the
reader's progress and bookmarks stay valid.

Pipeline per page:
    decode WebP -> convert to L -> gaussian blur (kills scanner grain, which
    is what the encoder was spending bytes on) -> LANCZOS resize to target
    width -> WebP q45 method 6 (stored, not deflated: WebP is already packed).

Idempotent: a book whose first page already has the target width is skipped,
so an interrupted run resumes where it stopped.

Usage:
    py -3 shrink_pages.py --width 400 --quality 45 --blur 0.6 --workers 6
"""

from __future__ import annotations

import argparse
import io
import os
import sys
import time
import zipfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

from PIL import Image, ImageFilter

BOOKS = Path("assets/books")


def _page_bytes(raw: bytes, width: int, quality: int, blur: float) -> bytes:
    im = Image.open(io.BytesIO(raw))
    if im.mode != "L":
        im = im.convert("L")
    if blur > 0:
        im = im.filter(ImageFilter.GaussianBlur(blur))
    if im.width > width:
        im = im.resize(
            (width, max(1, round(im.height * width / im.width))), Image.LANCZOS
        )
    buf = io.BytesIO()
    im.save(buf, "WEBP", quality=quality, method=6)
    return buf.getvalue()


def shrink_book(args: tuple[str, int, int, float]) -> tuple[str, int, int, int, str]:
    """Returns (book_id, pages, bytes_before, bytes_after, status)."""
    name, width, quality, blur = args
    path = BOOKS / name
    book_id = path.stem
    try:
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.endswith(".webp")]
            if not names:
                return book_id, 0, 0, 0, "empty"
            first = Image.open(io.BytesIO(z.read(names[0])))
            if first.width <= width:
                return book_id, len(names), 0, 0, "skip"
            before = path.stat().st_size
            payload: list[tuple[str, bytes]] = []
            for n in names:
                payload.append((n, _page_bytes(z.read(n), width, quality, blur)))

        tmp = path.with_suffix(".tmp")
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED, allowZip64=True) as out:
            for n, data in payload:
                out.writestr(n, data)
        # Same entry count is a hard requirement: page indices must not shift.
        with zipfile.ZipFile(tmp) as chk:
            if len(chk.namelist()) != len(names):
                tmp.unlink(missing_ok=True)
                return book_id, len(names), before, 0, "MISMATCH"
        os.replace(tmp, path)
        return book_id, len(names), before, path.stat().st_size, "ok"
    except Exception as exc:  # keep the original file intact on any failure
        tmp = path.with_suffix(".tmp")
        tmp.unlink(missing_ok=True)
        return book_id, 0, 0, 0, f"ERR {exc}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, default=400)
    ap.add_argument("--quality", type=int, default=45)
    ap.add_argument("--blur", type=float, default=0.6)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--limit", type=int, default=0, help="process at most N books")
    ap.add_argument("--books", default="assets/books")
    args = ap.parse_args()

    global BOOKS
    BOOKS = Path(args.books)
    zips = sorted(p.name for p in BOOKS.glob("*.zip"))
    if args.limit:
        zips = zips[: args.limit]
    total_in = sum((BOOKS / z).stat().st_size for z in zips)
    print(
        f"{len(zips)} books, {total_in / 1048576:.1f} MiB before | "
        f"target width {args.width}px q{args.quality} blur {args.blur}",
        flush=True,
    )

    t0 = time.time()
    done = skipped = failed = 0
    pages = 0
    bytes_before = bytes_after = 0
    tasks = [(z, args.width, args.quality, args.blur) for z in zips]
    with ProcessPoolExecutor(max_workers=args.workers) as ex:
        futures = {ex.submit(shrink_book, t): t[0] for t in tasks}
        for i, fut in enumerate(as_completed(futures), 1):
            book_id, n, b, a, status = fut.result()
            if status == "ok":
                done += 1
                pages += n
                bytes_before += b
                bytes_after += a
            elif status == "skip":
                skipped += 1
            else:
                failed += 1
                print(f"  !! {book_id}: {status}", flush=True)
            if i % 20 == 0 or i == len(tasks):
                el = time.time() - t0
                rate = bytes_after / max(bytes_before, 1)
                print(
                    f"[{i}/{len(tasks)}] ok={done} skip={skipped} fail={failed} "
                    f"pages={pages} {bytes_before/1048576:.0f}->{bytes_after/1048576:.0f} MiB "
                    f"({rate*100:.1f}%) {el/60:.1f} min",
                    flush=True,
                )

    print(
        f"\nDONE {done} books, {pages} pages, "
        f"{bytes_before/1048576:.1f} -> {bytes_after/1048576:.1f} MiB "
        f"({(1-bytes_after/max(bytes_before,1))*100:.1f}% saved), "
        f"{failed} failures, {(time.time()-t0)/60:.1f} min",
        flush=True,
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
