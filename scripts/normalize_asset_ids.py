"""Rename every book asset to an ASCII id so Android asset packaging keeps the
exact paths that Flutter's AssetManifest references.

Arabic filenames get percent-encoded inside the APK by the Android build tools,
which can make rootBundle.load() fail at runtime. Book ids are opaque keys, so
switching them to book_000..book_293 is safe and removes the whole risk.

Run from the maktabat_al_arrab directory:  py -3 scripts/normalize_asset_ids.py
"""
import json
import os
import sys
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / "assets"


def main() -> int:
    lib_path = ASSETS / "library.json"
    lib = json.loads(lib_path.read_text(encoding="utf-8"))

    books = lib["books"]
    print(f"books: {len(books)}")

    mapping = {}  # old_id -> new_id
    for i, b in enumerate(books):
        mapping[b["id"]] = f"book_{i:03d}"

    # ── Rename files ──
    moved = 0
    for old_id, new_id in mapping.items():
        for sub, ext in (("covers", ".webp"), ("books", ".zip"),
                         ("book_jsons", ".json")):
            old = ASSETS / sub / f"{old_id}{ext}"
            new = ASSETS / sub / f"{new_id}{ext}"
            if old.exists() and old != new:
                if new.exists():
                    new.unlink()
                os.replace(old, new)
                moved += 1
    print(f"files renamed: {moved}")

    # ── Rewrite detail JSONs ──
    rewritten = 0
    for old_id, new_id in mapping.items():
        p = ASSETS / "book_jsons" / f"{new_id}.json"
        if not p.exists():
            print(f"  MISSING detail json for {new_id}")
            continue
        d = json.loads(p.read_text(encoding="utf-8"))
        d["id"] = new_id
        d["cover"] = f"covers/{new_id}.webp"
        d["zip_asset"] = f"books/{new_id}.zip"
        p.write_text(
            json.dumps(d, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        rewritten += 1
    print(f"detail jsons rewritten: {rewritten}")

    # ── Rewrite library.json ──
    for b in books:
        new_id = mapping[b["id"]]
        b["id"] = new_id
        b["cover"] = f"covers/{new_id}.webp"
        b["json_file"] = f"book_jsons/{new_id}.json"

    lib_path.write_text(
        json.dumps(lib, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print("library.json rewritten")

    # ── Sanity check ──
    bad = []
    for b in books:
        for rel in (b["cover"], b["json_file"], f"books/{b['id']}.zip"):
            if not (ASSETS / rel).exists():
                bad.append(rel)
    if bad:
        print(f"!! {len(bad)} referenced assets missing, e.g. {bad[:3]}")
        return 1

    non_ascii = [
        p.name for p in ASSETS.rglob("*")
        if p.is_file() and not p.name.isascii()
    ]
    print(f"remaining non-ascii asset names: {len(non_ascii)}")
    print("OK — all referenced assets exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
