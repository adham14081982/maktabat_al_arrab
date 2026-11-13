#!/usr/bin/env python3
"""
Build the FULL Maktabat Al-Arrab library from scanned PDFs.
===========================================================

The source PDFs are scanned two-page spreads (image-only, no text layer).
Bundling 24k page images individually is slow and bloated, so this script:

  1. De-duplicates books that appear more than once (same title, with/without
     the "سلسلة ..." suffix, alef/hamza variants).
  2. Renders every PDF page to a compressed grayscale WebP spread.
  3. Packs each book's pages into a single ZIP asset: books/<id>.zip
     (ZIP_STORED - WebP is already compressed).
  4. Extracts a small color cover: covers/<id>.webp
  5. Writes a per-book JSON (metadata only): book_jsons/<id>.json
  6. Writes the full library.json with all sections + books.

Usage:
  py -3 build_image_library.py --source "C:/MyProject/ahmed khalid tawfek" \
      --output "C:/MyProject/ahmed khalid tawfek/maktabat_al_arrab/assets" \
      [--limit N] [--workers 6]
"""

import argparse
import io
import json
import os
import re
import sys
import unicodedata
import zipfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

try:
    import pymupdf
except ImportError:  # older versions expose it as fitz
    import fitz as pymupdf

try:
    from PIL import Image, ImageOps
except ImportError:
    print("ERROR: Pillow is not installed. Run: py -3 -m pip install Pillow")
    sys.exit(1)

# Silence noisy MuPDF warnings about broken XObjects in the scans
try:
    pymupdf.TOOLS.mupdf_display_errors(False)
except Exception:
    pass

# ─── Tunables ────────────────────────────────────────────────────────────────
PAGE_TARGET_WIDTH = 440      # px width of each rendered spread
PAGE_WEBP_QUALITY = 40       # WebP quality for page spreads
PAGE_AUTOCONTRAST = 1        # autocontrast cutoff
COVER_TARGET_WIDTH = 300     # px width of cover
COVER_WEBP_QUALITY = 68
RENDER_DPI = 96              # render DPI before downscaling

# ─── Classification (kept in sync with process_library.py) ───────────────────
SERIES_PATTERNS = {
    "ma_wara_al_tabia": [
        "ما وراء الطبيعة", "ماوراء الطبيعة", "أسطور",
        "حكايات التاروت", "الرجل الذي يجمع كتب بو",
    ],
    "fantazia": ["فانتازيا", "ما أمام الطبيعة"],
    "safari": ["سافاري", "سفاري"],
}

STANDALONE_NOVELS = [
    "يوتوبيا", "YOUTUBIA", "أوتوبيا", "قصاصات قابلة للحرق",
    "7 باب", "سبعة باب", "7 وجوه للحب", "سبعة وجوه للحب",
    "زغازيغ", "شاي بالنعناع", "ضحكات كئيبة", "دماغي كده", "الآن أفهم",
    "عرض لا تستطيع رفضه", "تأثير الجرادة", "عقل بلا جسد", "مثل إيكاروس",
    "محامي الشوارع", "حظك اليوم", "خمنوا معي", "تلك المدينة",
    "عشاق الأدرينالين", "غرباء الأطوار", "هؤلاء النصابون", "مصر والجزائر",
    "حب في أغسطس", "ما وراء العالم", "قصص من أزيموف", "أكواريل",
    "الأبجدية", "قصتان", "7 وجوه",
]

SECTION_META = [
    {"id": "ma_wara_al_tabia", "title": "ما وراء الطبيعة",
     "subtitle": "سلسلة الرعب والخيال العلمي", "color_accent": "#8B1E2D", "icon": "moon"},
    {"id": "fantazia", "title": "فانتازيا",
     "subtitle": "سلسلة الخيال التاريخي", "color_accent": "#4A7C59", "icon": "castle"},
    {"id": "safari", "title": "سافاري",
     "subtitle": "سلسلة الرحلات والمغامرات", "color_accent": "#8B6914", "icon": "compass"},
    {"id": "standalone_novels", "title": "روايات منفردة",
     "subtitle": "روايات د. أحمد خالد توفيق", "color_accent": "#6B3FA0", "icon": "book"},
    {"id": "translations", "title": "ترجمات وكتب غير روائية",
     "subtitle": "من أدب العالم", "color_accent": "#2C5F7F", "icon": "globe"},
]


def extract_title(filename: str) -> str:
    """Clean book title from the PDF filename."""
    title = os.path.splitext(filename)[0]
    title = re.sub(r'^تحميل\s+كتاب\s+', '', title)
    title = re.sub(r'^كتاب\s+', '', title)
    title = re.sub(r'\s*-\s*سلسلة\s+[^\-]+$', '', title)
    title = re.sub(r'\s*-\s*سلسلة\s+\S+$', '', title)
    title = re.sub(r'_\d+_Foulabook\.com_*', '', title)
    title = re.sub(r'_Foulabook\.com_*', '', title)
    title = title.replace('.crdownload', '')
    title = re.sub(r'\s+', ' ', title).strip(' -_')
    return title or filename


def classify(filename: str) -> str:
    for series, pats in SERIES_PATTERNS.items():
        for p in pats:
            if p in filename:
                return series
    for kw in STANDALONE_NOVELS:
        if kw in filename:
            return "standalone_novels"
    return "translations"


def title_key(filename: str) -> str:
    """Normalized key for de-duplication."""
    t = extract_title(filename)
    t = unicodedata.normalize("NFKC", t)
    t = re.sub(r'[\u064B-\u0652\u0640]', '', t)  # diacritics + tatweel
    for a, b in [('أ', 'ا'), ('إ', 'ا'), ('آ', 'ا'), ('ى', 'ي'), ('ة', 'ه')]:
        t = t.replace(a, b)
    t = re.sub(r'[\s\-_\.]+', '', t)
    return t


def make_book_id(index: int, filename: str) -> str:
    slug = re.sub(r'[^\u0600-\u06FF\u0750-\u077F0-9a-zA-Z]', '_', extract_title(filename))
    slug = re.sub(r'_+', '_', slug).strip('_')[:36]
    return f"book_{index:03d}_{slug}"


def process_one(job):
    """Process a single PDF into cover + page zip + metadata. Runs in a worker."""
    pdf_path, book_id, covers_dir, zips_dir = job
    filename = os.path.basename(pdf_path)
    try:
        doc = pymupdf.open(pdf_path)
        n = len(doc)
        if n == 0:
            doc.close()
            return {"ok": False, "filename": filename, "error": "empty pdf"}

        # ── Cover: first page in color ──
        cover_asset = None
        try:
            pix = doc[0].get_pixmap(dpi=110)
            cimg = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
            if cimg.width > COVER_TARGET_WIDTH:
                cimg = cimg.resize(
                    (COVER_TARGET_WIDTH,
                     int(cimg.height * COVER_TARGET_WIDTH / cimg.width)),
                    Image.LANCZOS)
            cover_path = os.path.join(covers_dir, f"{book_id}.webp")
            cimg.save(cover_path, "WEBP", quality=COVER_WEBP_QUALITY, method=4)
            cover_asset = f"covers/{book_id}.webp"
        except Exception:
            cover_asset = None

        # ── Pages: grayscale compressed spreads packed into one zip ──
        zip_path = os.path.join(zips_dir, f"{book_id}.zip")
        tmp_pages = []
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_STORED) as zf:
            for i in range(n):
                try:
                    pix = doc[i].get_pixmap(dpi=RENDER_DPI)
                    img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
                    img = img.convert("L")
                    if img.width > PAGE_TARGET_WIDTH:
                        img = img.resize(
                            (PAGE_TARGET_WIDTH,
                             max(1, int(img.height * PAGE_TARGET_WIDTH / img.width))),
                            Image.LANCZOS)
                    img = ImageOps.autocontrast(img, cutoff=PAGE_AUTOCONTRAST)
                    buf = io.BytesIO()
                    img.save(buf, "WEBP", quality=PAGE_WEBP_QUALITY, method=4)
                    zf.writestr(f"{i:04d}.webp", buf.getvalue())
                except Exception as e:
                    # keep page count stable with a blank placeholder
                    blank = Image.new("L", (PAGE_TARGET_WIDTH, 620), 255)
                    buf = io.BytesIO()
                    blank.save(buf, "WEBP", quality=30, method=4)
                    zf.writestr(f"{i:04d}.webp", buf.getvalue())
        doc.close()

        size = os.path.getsize(zip_path)
        return {
            "ok": True, "filename": filename, "book_id": book_id,
            "page_count": n, "cover": cover_asset,
            "zip_size": size, "title": extract_title(filename),
        }
    except Exception as e:
        return {"ok": False, "filename": filename, "error": str(e)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--count", type=int, default=0,
                    help="Process at most N not-yet-done books this run (0 = all)")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    src = Path(args.source).resolve()
    out = Path(args.output).resolve()
    covers_dir = out / "covers"
    zips_dir = out / "books"
    jsons_dir = out / "book_jsons"
    for d in (covers_dir, zips_dir, jsons_dir):
        d.mkdir(parents=True, exist_ok=True)

    files = sorted([
        f.name for f in src.iterdir()
        if f.is_file() and f.suffix.lower() == ".pdf" and ".crdownload" not in f.name
    ])

    # ── De-duplicate by normalized title ──
    groups = {}
    for f in files:
        groups.setdefault(title_key(f), []).append(f)
    chosen = []
    dups = []
    for key, group in groups.items():
        if len(group) == 1:
            chosen.append(group[0])
        else:
            # prefer the file that names its series (usually richer metadata)
            group_sorted = sorted(
                group,
                key=lambda x: ("سلسلة" in x, os.path.getsize(str(src / x))),
                reverse=True,
            )
            chosen.append(group_sorted[0])
            dups.extend(group_sorted[1:])
    chosen = sorted(chosen)
    if args.limit > 0:
        chosen = chosen[:args.limit]

    print(f"Source PDFs: {len(files)}  |  unique books: {len(chosen)}  |  duplicates skipped: {len(dups)}")
    for d in dups:
        print(f"  dup: {d}")

    jobs = []
    for i, f in enumerate(chosen):
        bid = make_book_id(i, f)
        # Resumable: skip books whose zip is already built
        if (zips_dir / f"{bid}.zip").exists():
            continue
        jobs.append((str(src / f), bid, str(covers_dir), str(zips_dir)))

    if args.count > 0:
        jobs = jobs[:args.count]

    print(f"Pending this run: {len(jobs)}")

    results = []
    done = 0
    total_pages = 0
    total_bytes = 0
    with ProcessPoolExecutor(max_workers=args.workers) as ex:
        futures = {ex.submit(process_one, j): j for j in jobs}
        for fut in as_completed(futures):
            r = fut.result()
            done += 1
            if r.get("ok"):
                results.append(r)
                total_pages += r["page_count"]
                total_bytes += r["zip_size"]
                print(f"[{done}/{len(jobs)}] {r['page_count']:3d}p "
                      f"{r['zip_size']//1024:5d}KB  {r['filename'][:60]}")
            else:
                print(f"[{done}/{len(jobs)}] FAILED: {r['filename']} -> {r.get('error')}")

    # ── Write per-book detail JSON for books processed this run ──
    for r in sorted(results, key=lambda x: x["book_id"]):
        series = classify(r["filename"])
        detail = {
            "id": r["book_id"],
            "title": r["title"],
            "original_filename": r["filename"],
            "page_count": r["page_count"],
            "cover": r["cover"],
            "quality_score": 1.0,
            "content_mode": "image",
            "series": series,
            "chapters": [],
            "images": [],
            "zip_asset": f"books/{r['book_id']}.zip",
        }
        with open(jsons_dir / f"{r['book_id']}.json", "w", encoding="utf-8") as fh:
            json.dump(detail, fh, ensure_ascii=False, separators=(",", ":"))

    # ── Rebuild library.json from ALL completed books (resumable) ──
    books_meta = []
    for jf in sorted(jsons_dir.glob("*.json")):
        try:
            with open(jf, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:
            continue
        bid = d.get("id")
        if not bid or not (zips_dir / f"{bid}.zip").exists():
            continue
        books_meta.append({
            "id": bid,
            "title": d.get("title", ""),
            "series": d.get("series", "translations"),
            "page_count": d.get("page_count", 0),
            "cover": d.get("cover"),
            "content_mode": "image",
            "quality_score": 1.0,
            "json_file": f"book_jsons/{bid}.json",
        })
    books_meta.sort(key=lambda b: (b["series"], b["title"]))

    library = {
        "version": "1.0.0",
        "app_name": "مكتبة العرّاب",
        "author": "د. أحمد خالد توفيق",
        "sections": SECTION_META,
        "books": books_meta,
    }
    with open(out / "library.json", "w", encoding="utf-8") as fh:
        json.dump(library, fh, ensure_ascii=False, indent=1)

    from collections import Counter
    counts = Counter(b["series"] for b in books_meta)
    all_pages = sum(b["page_count"] for b in books_meta)
    all_bytes = sum((zips_dir / f"{b['id']}.zip").stat().st_size for b in books_meta)
    print("\n" + "=" * 60)
    print(f"TOTAL BOOKS DONE: {len(books_meta)}   PAGES: {all_pages}   "
          f"IMAGE DATA: {all_bytes/1024/1024:.0f} MB")
    print(f"This run: {len(results)} books, {total_bytes/1024/1024:.0f} MB")
    for s in SECTION_META:
        print(f"  {s['id']:22s}: {counts.get(s['id'], 0)}")
    print("=" * 60)


if __name__ == "__main__":
    main()
