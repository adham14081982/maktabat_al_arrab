#!/usr/bin/env python3
"""Final asset pass before shipping the release APK.

Two clean-ups, both lossless for the running app:

1. Drop ``text_raw`` from every ``ocr_pages`` entry in ``assets/book_jsons``.
   The reader only ever reads ``text`` (see ``lib/core/models/book.dart``).
   ``text_raw`` is the pre-correction OCR output kept for ``ocr_book.py
   --reapply``; that workflow reads ``assets/ocr/<id>.json`` (key ``raw``),
   which we leave untouched.  Removing the duplicate saves ~50 MB of APK.

2. Copy the real ``quality_score`` from each book JSON into ``library.json``.
   ``library.json`` used to carry a hardcoded 1.0 for every book, which made
   the field useless for sorting/filtering.

Idempotent: running it twice changes nothing the second time.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
BOOK_JSONS = ASSETS / "book_jsons"
LIBRARY = ASSETS / "library.json"


def strip_raw_text() -> tuple[int, int]:
    """Return (files touched, bytes saved)."""
    saved = 0
    touched = 0
    for path in sorted(BOOK_JSONS.glob("book_*.json")):
        before = path.stat().st_size
        data = json.loads(path.read_text(encoding="utf-8"))
        pages = data.get("ocr_pages") or []
        changed = False
        for page in pages:
            if isinstance(page, dict) and "text_raw" in page:
                del page["text_raw"]
                changed = True
        if not changed:
            continue
        path.write_text(
            json.dumps(data, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        saved += before - path.stat().st_size
        touched += 1
    return touched, saved


def sync_quality_scores() -> tuple[int, list[tuple[str, float]]]:
    library = json.loads(LIBRARY.read_text(encoding="utf-8"))
    scores: dict[str, float] = {}
    for path in BOOK_JSONS.glob("book_*.json"):
        try:
            book = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        q = book.get("quality_score")
        if isinstance(q, (int, float)):
            scores[book.get("id") or path.stem] = round(float(q), 4)

    updated = 0
    missing: list[tuple[str, float]] = []
    for book in library.get("books", []):
        bid = book.get("id")
        if bid in scores:
            if book.get("quality_score") != scores[bid]:
                book["quality_score"] = scores[bid]
                updated += 1
        else:
            missing.append((bid, book.get("quality_score", 0.0)))

    LIBRARY.write_text(
        json.dumps(library, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    return updated, missing


def main() -> int:
    touched, saved = strip_raw_text()
    print(f"text_raw stripped from {touched} book JSONs, {saved/1_048_576:.1f} MiB saved")

    updated, missing = sync_quality_scores()
    print(f"quality_score synced into library.json for {updated} books")
    if missing:
        print(f"WARNING: {len(missing)} books have no score: {missing[:5]}")

    total = sum(p.stat().st_size for p in BOOK_JSONS.glob("book_*.json"))
    print(f"assets/book_jsons now {total/1_048_576:.1f} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
