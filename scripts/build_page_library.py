#!/usr/bin/env python3
"""
Build the Maktabat Al-Arrab library as SINGLE, PORTRAIT pages.
=============================================================

The source PDFs are scans of two facing pages captured as one landscape
image ("double-page spread"). Showing a spread on a portrait phone makes the
text tiny, so this pipeline converts every spread into two standalone pages:

  1. Render the PDF page to grayscale at a supersampled DPI.
  2. If the page is landscape AND has a bright vertical gutter near the middle,
     split it there. The RIGHT half is the earlier page (Arabic reads RTL).
     Portrait pages (covers, YOUTUBIA) are left untouched.
  3. Trim the surrounding white margins. This both shrinks the file and makes
     the text larger when the page is fitted to the screen width.
  4. Resize to PAGE_TARGET_WIDTH, autocontrast, encode as grayscale WebP.
  5. Pack all pages of a book into ONE zip: books/<id>.zip (0000.webp, 0001.webp, ...).
     Zero-padded names keep lexicographic order == page order.
  6. Write covers/<id>.webp (colour, from page 1), book_jsons/<id>.json, library.json.

Usage (resumable - already-built books are skipped):
  py -3 build_page_library.py --source "C:/MyProject/ahmed khalid tawfek" \
      --output ".../maktabat_al_arrab/assets2" --count 40 --workers 6
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
except ImportError:  # very old builds expose the module as `fitz`
    import fitz as pymupdf

import numpy as np
from PIL import Image, ImageChops, ImageOps

# MuPDF prints a warning for every broken XObject in these damaged scans.
try:
    pymupdf.TOOLS.mupdf_display_errors(False)
except Exception:
    pass

# ─── Tunables ────────────────────────────────────────────────────────────────
PAGE_TARGET_WIDTH = 300   # px width of a single page (near the native scan res)
PAGE_WEBP_QUALITY = 46
PAGE_AUTOCONTRAST = 1
RENDER_DPI = 150          # supersample before downscaling to the target width
TRIM_THRESHOLD = 238      # pixels brighter than this count as "blank margin"
TRIM_PADDING = 8          # px of margin kept around the text block
# The fold is not always at 50%: these scans are cropped asymmetrically and it
# drifts anywhere between ~49% and ~61%, so search a wide band.
GUTTER_SEARCH = (0.42, 0.63)
GUTTER_MIN_BRIGHTNESS = 195   # fold strip must be reasonably light
GUTTER_MIN_CONTRAST = 8       # ...and stand out from the surrounding columns
SPREAD_ASPECT = 1.10      # width/height above this counts as a spread

COVER_TARGET_WIDTH = 320
COVER_WEBP_QUALITY = 72
COVER_RENDER_DPI = 120

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

# Filenames that arrived with Latin titles; the app is fully Arabic.
TITLE_OVERRIDES = {
    "YOUTUBIA": "يوتوبيا",
    "P.C.R pdf": "P.C.R",
    "P.C.R": "P.C.R",
}


def extract_title(filename: str) -> str:
    """Turn a PDF filename into a clean, human-readable Arabic title."""
    title = os.path.splitext(filename)[0]
    title = re.sub(r'^تحميل\s+كتاب\s+', '', title)
    title = re.sub(r'^كتاب\s+', '', title)
    title = re.sub(r'\s*-\s*سلسلة\s+[^\-]+$', '', title)
    title = re.sub(r'\s*-\s*سلسلة\s+\S+$', '', title)
    title = re.sub(r'_\d+_Foulabook\.com_*', '', title)
    title = re.sub(r'_Foulabook\.com_*', '', title)
    title = title.replace('.crdownload', '')
    title = re.sub(r'\s+', ' ', title).strip(' -_')
    return TITLE_OVERRIDES.get(title, title) or filename


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
    return re.sub(r'[\s\-_\.]+', '', t)


# ─── Image helpers ───────────────────────────────────────────────────────────
def find_gutter(gray: Image.Image) -> int | None:
    """Return the x of the centre fold, or None if the page is not a spread.

    Low-quality scans have a GREY fold, not a white one, so absolute brightness
    alone is not enough. We instead look for the column with the strongest
    local prominence inside the search band (the fold is a narrow bright strip
    between two dark text columns). If the profile is flat we fall back to the
    geometric centre, because every landscape page in this library is a spread.
    """
    a = np.asarray(gray, dtype=np.float32)
    h, w = a.shape
    if w <= h * SPREAD_ASPECT:
        return None  # portrait page: cover, title page, or a text PDF

    lo, hi = int(w * GUTTER_SEARCH[0]), int(w * GUTTER_SEARCH[1])
    col_means = a[:, lo:hi].mean(axis=0)
    peak = int(col_means.argmax())
    peak_value = float(col_means[peak])

    # Prominence = how far the fold stands above the darker text columns.
    window = col_means[max(0, peak - 40): min(len(col_means), peak + 40)]
    prominence = peak_value - float(window.min())

    if peak_value >= GUTTER_MIN_BRIGHTNESS and prominence >= GUTTER_MIN_CONTRAST:
        return lo + peak
    return w // 2  # flat profile: still a spread, cut at the middle


def trim_margins(gray: Image.Image) -> Image.Image:
    """Crop the blank border so the text block fills the frame."""
    background = Image.new("L", gray.size, 255)
    diff = ImageChops.difference(gray, background)
    mask = diff.point(lambda v: 255 if v > TRIM_THRESHOLD else 0)
    box = mask.getbbox()
    if not box:
        return gray
    l, t, r, b = box
    l = max(0, l - TRIM_PADDING)
    t = max(0, t - TRIM_PADDING)
    r = min(gray.width, r + TRIM_PADDING)
    b = min(gray.height, b + TRIM_PADDING)
    # Guard against a speck of dust collapsing the whole page.
    if (r - l) < gray.width * 0.35 or (b - t) < gray.height * 0.35:
        return gray
    return gray.crop((l, t, r, b))


def encode_page(gray: Image.Image) -> bytes:
    """Resize to the target width and encode as a grayscale WebP."""
    if gray.width > PAGE_TARGET_WIDTH:
        gray = gray.resize(
            (PAGE_TARGET_WIDTH,
             max(1, round(gray.height * PAGE_TARGET_WIDTH / gray.width))),
            Image.LANCZOS,
        )
    gray = ImageOps.autocontrast(gray, cutoff=PAGE_AUTOCONTRAST)
    buf = io.BytesIO()
    gray.save(buf, "WEBP", quality=PAGE_WEBP_QUALITY, method=6)
    return buf.getvalue()


def split_page(gray: Image.Image) -> list[Image.Image]:
    """Split a two-page spread into [right_page, left_page] (RTL reading order)."""
    gutter = find_gutter(gray)
    if gutter is None:
        return [gray]
    right = gray.crop((gutter, 0, gray.width, gray.height))
    left = gray.crop((0, 0, gutter, gray.height))
    return [right, left]


# ─── Per-book worker ─────────────────────────────────────────────────────────
def process_one(job):
    pdf_path, book_id, covers_dir, zips_dir = job
    filename = os.path.basename(pdf_path)
    try:
        doc = pymupdf.open(pdf_path)
        if len(doc) == 0:
            doc.close()
            return {"ok": False, "filename": filename, "error": "empty pdf"}

        # ── Cover: page 1 in colour. If it is a spread, keep the right half. ──
        cover_asset = None
        try:
            pix = doc[0].get_pixmap(dpi=COVER_RENDER_DPI)
            cover = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
            if cover.width > cover.height * SPREAD_ASPECT:
                cover = cover.crop((cover.width // 2, 0, cover.width, cover.height))
            if cover.width > COVER_TARGET_WIDTH:
                cover = cover.resize(
                    (COVER_TARGET_WIDTH,
                     max(1, round(cover.height * COVER_TARGET_WIDTH / cover.width))),
                    Image.LANCZOS,
                )
            cover.save(os.path.join(covers_dir, f"{book_id}.webp"),
                       "WEBP", quality=COVER_WEBP_QUALITY, method=4)
            cover_asset = f"covers/{book_id}.webp"
        except Exception:
            cover_asset = None

        # ── Pages ──
        zip_path = os.path.join(zips_dir, f"{book_id}.zip")
        page_no = 0
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_STORED) as zf:
            for i in range(len(doc)):
                try:
                    pix = doc[i].get_pixmap(dpi=RENDER_DPI)
                    gray = Image.frombytes(
                        "RGB", [pix.width, pix.height], pix.samples).convert("L")
                    for page in split_page(gray):
                        zf.writestr(f"{page_no:04d}.webp",
                                    encode_page(trim_margins(page)))
                        page_no += 1
                except Exception:
                    # Keep page numbering stable if one page is unreadable.
                    blank = Image.new("L", (PAGE_TARGET_WIDTH, 500), 255)
                    buf = io.BytesIO()
                    blank.save(buf, "WEBP", quality=30, method=4)
                    zf.writestr(f"{page_no:04d}.webp", buf.getvalue())
                    page_no += 1
        doc.close()

        return {
            "ok": True, "filename": filename, "book_id": book_id,
            "page_count": page_no, "cover": cover_asset,
            "zip_size": os.path.getsize(zip_path),
            "title": extract_title(filename),
        }
    except Exception as e:
        return {"ok": False, "filename": filename, "error": str(e)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--count", type=int, default=0,
                    help="Process at most N not-yet-built books this run (0 = all)")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    src = Path(args.source).resolve()
    out = Path(args.output).resolve()
    covers_dir, zips_dir, jsons_dir = out / "covers", out / "books", out / "book_jsons"
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
    chosen, dups = [], []
    for group in groups.values():
        if len(group) == 1:
            chosen.append(group[0])
        else:
            ranked = sorted(
                group,
                key=lambda x: ("سلسلة" in x, os.path.getsize(str(src / x))),
                reverse=True,
            )
            chosen.append(ranked[0])
            dups.extend(ranked[1:])
    chosen = sorted(chosen)
    if args.limit > 0:
        chosen = chosen[:args.limit]

    print(f"Source PDFs: {len(files)}  |  unique books: {len(chosen)}  |  "
          f"duplicates skipped: {len(dups)}")

    jobs = []
    for i, f in enumerate(chosen):
        bid = f"book_{i:03d}"          # ASCII id — required for Android asset paths
        if (zips_dir / f"{bid}.zip").exists():
            continue
        jobs.append((str(src / f), bid, str(covers_dir), str(zips_dir)))
    if args.count > 0:
        jobs = jobs[:args.count]
    print(f"Pending this run: {len(jobs)}")

    results, total_bytes = [], 0
    with ProcessPoolExecutor(max_workers=args.workers) as ex:
        futures = {ex.submit(process_one, j): j for j in jobs}
        for done, fut in enumerate(as_completed(futures), 1):
            r = fut.result()
            if r.get("ok"):
                results.append(r)
                total_bytes += r["zip_size"]
                print(f"[{done}/{len(jobs)}] {r['page_count']:4d}p "
                      f"{r['zip_size']//1024:5d}KB  {r['filename'][:58]}")
            else:
                print(f"[{done}/{len(jobs)}] FAILED {r['filename']} -> {r.get('error')}")

    # ── Per-book detail JSON ──
    for r in results:
        detail = {
            "id": r["book_id"],
            "title": r["title"],
            "original_filename": r["filename"],
            "page_count": r["page_count"],
            "cover": r["cover"],
            "quality_score": 1.0,
            "content_mode": "image",
            "series": classify(r["filename"]),
            "chapters": [],
            "images": [],
            "zip_asset": f"books/{r['book_id']}.zip",
        }
        with open(jsons_dir / f"{r['book_id']}.json", "w", encoding="utf-8") as fh:
            json.dump(detail, fh, ensure_ascii=False, separators=(",", ":"))

    # ── Rebuild library.json from every completed book (resumable) ──
    books_meta = []
    for jf in sorted(jsons_dir.glob("*.json")):
        try:
            d = json.loads(jf.read_text(encoding="utf-8"))
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
        "version": "2.0.0",
        "app_name": "مكتبة العرّاب",
        "author": "د. أحمد خالد توفيق",
        "sections": SECTION_META,
        "books": books_meta,
    }
    (out / "library.json").write_text(
        json.dumps(library, ensure_ascii=False, indent=1), encoding="utf-8")

    from collections import Counter
    counts = Counter(b["series"] for b in books_meta)
    all_pages = sum(b["page_count"] for b in books_meta)
    all_bytes = sum((zips_dir / f"{b['id']}.zip").stat().st_size for b in books_meta)
    print("\n" + "=" * 62)
    print(f"BOOKS: {len(books_meta)}   PAGES: {all_pages}   "
          f"DATA: {all_bytes/1024/1024:.0f} MB")
    print(f"This run: {len(results)} books, {total_bytes/1024/1024:.0f} MB")
    for s in SECTION_META:
        print(f"  {s['id']:22s}: {counts.get(s['id'], 0)}")
    print("=" * 62)


if __name__ == "__main__":
    main()
