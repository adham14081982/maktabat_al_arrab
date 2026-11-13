#!/usr/bin/env python3
"""
Build the Maktabat Al-Arrab library as clean, single, PORTRAIT pages.
=====================================================================

v2 — "clean paper" rendering.

The v1 pipeline produced pages that looked like raw scans: grey, mottled,
inconsistent in size and with the text block cropped flush against the edges.
v2 fixes the *look* of every page:

  1. Render each PDF page at its NATIVE resolution (no wasted upscaling).
  2. Split a landscape spread into two portrait pages (RTL order preserved).
  3. **Flatten the background**: divide the page by a heavily blurred copy of
     itself. This removes uneven lighting, paper mottling, the shadow of the
     book spine and the faint "light spots" the user complained about, turning
     the paper into uniform white without touching the ink.
  4. Stretch levels so the text is solid black on pure white.
  5. Crop to the ink block but keep GENEROUS padding (4.5%) so nothing is cut
     at the sides — the v1 trim was flush against the glyphs.
  6. Paste onto a **fixed-aspect canvas** (600x968). Every page is therefore
     exactly the same size, so the reader never rescales or jumps between
     pages, and a chapter-end page simply shows clean blank paper.
  7. Encode as grayscale WebP — the reader tints it at runtime for the
     paper / sepia / dark themes, so one asset serves all themes.

Output layout is identical to v1 (books/<id>.zip, covers/<id>.webp,
book_jsons/<id>.json, library.json) so the app and its progress data keep
working unchanged.

Usage (resumable):
  py -3 build_page_library_v2.py --source "C:/MyProject/ahmed khalid tawfek" \
      --output "../assets_v2" --count 40 --workers 8
"""

import argparse
import io
import json
import os
import re
import unicodedata
import zipfile
from collections import Counter
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import cv2
import numpy as np
import pymupdf
from PIL import Image

try:
    pymupdf.TOOLS.mupdf_display_errors(False)
except Exception:
    pass

# Each worker process is already a unit of parallelism. Left to itself OpenCV
# spawns a thread per core inside *every* worker, so 8 workers became 64 threads
# fighting over 8 cores — measured at 20 s per book standalone but >7 min under
# the pool. One thread per process restores near-linear scaling.
cv2.setNumThreads(1)

# ─── Tunables ────────────────────────────────────────────────────────────────
CANVAS_W = 540            # px width of the fixed page canvas
CANVAS_ASPECT = 0.62      # width / height -> 540 x 871
INK_WIDTH_FRAC = 0.90     # text block occupies this fraction of the canvas width
PAGE_PAD_FRAC = 0.04      # padding kept around the ink block, relative to it
PAGE_WEBP_QUALITY = 34
FLATTEN_KERNEL_FRAC = 0.05
# Ceiling on the rasterised page area. 24 MP is ~4x the detail the 540px page
# can show, so nothing is lost, but a rogue 9000px scan can no longer blow up a
# worker's memory.
MAX_PAGE_PIXELS = 24_000_000
BG_MAX_SIDE = 320          # background is estimated at this size, then upscaled
LEVELS_LO, LEVELS_HI = 42, 228
# Snap near-white to pure white and near-black to pure black. Without this the
# paper keeps a faint grey grain that costs ~2x the file size and is exactly
# the "dirty scan" look we are removing.
WHITE_CLIP = 226
BLACK_CLIP = 30
INK_THRESHOLD = 200       # pixel value below which a pixel counts as ink
INK_ROW_FRAC = 0.008      # a row needs this share of the width as ink
INK_COL_FRAC = 0.008      # a column needs this share of the height as ink
EDGE_BAND_FRAC = 0.22     # how far from a border a crease line may sit
EDGE_SOLID_FRAC = 0.30    # a border row/column this dark is an edge, not text
CREASE_RUN_FRAC = 0.45    # a vertical run this tall is the fold, never a glyph
BLANK_INK_FRAC = 0.0008   # below this a page is blank and gets dropped
BINARIZE = False          # hard thresholding compresses WORSE than grey — off
BINARIZE_C = 10           # adaptive-threshold bias (higher = more white)

COVER_TARGET_WIDTH = 480
COVER_WEBP_QUALITY = 78
COVER_RENDER_DPI = 200

# The fold is not always at 50%: these scans are cropped asymmetrically.
GUTTER_SEARCH = (0.42, 0.63)
GUTTER_MIN_BRIGHTNESS = 195
GUTTER_MIN_CONTRAST = 8
SPREAD_ASPECT = 1.10

# ─── Classification (kept in sync with build_page_library.py) ────────────────
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

TITLE_OVERRIDES = {
    "YOUTUBIA": "يوتوبيا",
    "P.C.R pdf": "P.C.R",
    "P.C.R": "P.C.R",
}


def extract_title(filename: str) -> str:
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
    t = extract_title(filename)
    t = unicodedata.normalize("NFKC", t)
    t = re.sub(r'[\u064B-\u0652\u0640]', '', t)
    for a, b in [('أ', 'ا'), ('إ', 'ا'), ('آ', 'ا'), ('ى', 'ي'), ('ة', 'ه')]:
        t = t.replace(a, b)
    return re.sub(r'[\s\-_\.]+', '', t)


# ─── Image helpers ───────────────────────────────────────────────────────────
def render_gray(page) -> np.ndarray:
    """Render a PDF page to grayscale at (approximately) its native resolution.

    Rendering above the embedded image size adds no detail, only blur and time,
    so the zoom factor is derived from the page's own image metadata.
    """
    native_w = 0
    try:
        infos = page.get_image_info()
        if infos:
            native_w = max(int(i.get("width", 0)) for i in infos)
    except Exception:
        native_w = 0
    zoom = 2.0
    if native_w and page.rect.width > 0:
        zoom = min(3.0, max(1.0, native_w / page.rect.width))
    # A few PDFs embed absurdly large scans. Rendering one at native size can
    # allocate hundreds of MB inside a worker and get it killed by the OS, so
    # cap the raster at a size that still exceeds what the 540px page needs.
    est_px = (page.rect.width * zoom) * (page.rect.height * zoom)
    if est_px > MAX_PAGE_PIXELS:
        zoom *= (MAX_PAGE_PIXELS / est_px) ** 0.5
    pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom),
                          colorspace=pymupdf.csGRAY, alpha=False)
    arr = np.frombuffer(pix.samples, dtype=np.uint8)
    if pix.n > 1:
        arr = arr.reshape(pix.height, pix.width, pix.n)[..., 0]
    else:
        arr = arr.reshape(pix.height, pix.width)
    return arr.copy()


def find_gutter(gray: np.ndarray) -> int | None:
    """Return the x of the centre fold, or None if the page is not a spread."""
    h, w = gray.shape
    if w <= h * SPREAD_ASPECT:
        return None
    lo, hi = int(w * GUTTER_SEARCH[0]), int(w * GUTTER_SEARCH[1])
    col = gray[:, lo:hi].mean(axis=0)
    peak = int(col.argmax())
    window = col[max(0, peak - 40): min(len(col), peak + 40)]
    if col[peak] >= GUTTER_MIN_BRIGHTNESS and (col[peak] - window.min()) >= GUTTER_MIN_CONTRAST:
        return lo + peak
    return w // 2  # flat profile: every landscape page here is a spread


def split_page(gray: np.ndarray) -> list[np.ndarray]:
    """Split a spread into [right_page, left_page] (RTL reading order)."""
    g = find_gutter(gray)
    if g is None:
        return [gray]
    return [gray[:, g:], gray[:, :g]]


def flatten_background(gray: np.ndarray) -> np.ndarray:
    """Divide out uneven illumination / paper texture.

    A morphological close with a large kernel removes the dark ink and leaves
    an estimate of the paper itself; dividing the page by that estimate turns
    every page into uniform white regardless of how badly it was scanned.
    Pages that are genuinely dark (illustrations, black chapter openers) are
    left alone, because dividing them would wash the image out.

    The estimate is computed on a **downscaled copy**: an illumination field is
    smooth by definition, so sampling it at ~320 px changes nothing visible,
    while the full-resolution version cost ~58 ms per page — 73% of the whole
    pipeline (measured). The kernel keeps its *relative* size, which is what
    decides how much ink the close removes.
    """
    if float(np.median(gray)) < 110:
        return gray
    h, w = gray.shape

    s = min(1.0, BG_MAX_SIDE / float(max(h, w)))
    if s < 0.95:
        sw = max(16, int(round(w * s)))
        sh = max(16, int(round(h * s)))
        small = cv2.resize(gray, (sw, sh), interpolation=cv2.INTER_AREA)
    else:
        small, sw, sh = gray, w, h

    k = max(5, int(min(sh, sw) * FLATTEN_KERNEL_FRAC) | 1)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    bg = cv2.morphologyEx(small, cv2.MORPH_CLOSE, kernel)
    bg = cv2.GaussianBlur(bg, (0, 0), sigmaX=k * 0.6)
    if (sw, sh) != (w, h):
        bg = cv2.resize(bg, (w, h), interpolation=cv2.INTER_LINEAR)

    norm = gray.astype(np.float32) / np.maximum(bg.astype(np.float32), 1.0) * 240.0
    return np.clip(norm, 0, 255).astype(np.uint8)


def stretch_levels(gray: np.ndarray) -> np.ndarray:
    out = (gray.astype(np.float32) - LEVELS_LO) * (255.0 / max(1, LEVELS_HI - LEVELS_LO))
    out = np.clip(out, 0, 255)
    out[out >= WHITE_CLIP] = 255.0
    out[out <= BLACK_CLIP] = 0.0
    return out.astype(np.uint8)


def remove_crease_lines(gray: np.ndarray) -> np.ndarray:
    """Whiten the vertical crease the book's fold leaves near the inner edge.

    After a spread is split in two, each half keeps the shadow of the fold on
    its inner side. It is a *continuous* vertical dark line, whereas no letter
    can produce an unbroken run that tall — so "longest vertical run" separates
    the two reliably, and the line can be erased without touching the type.
    Erasing it (rather than cropping it away) also re-centres the text block,
    because the crease is what was stretching the bounding box sideways.
    """
    h, w = gray.shape
    mask = gray < INK_THRESHOLD
    band = max(6, int(w * EDGE_BAND_FRAC))
    candidates = list(range(0, band)) + list(range(w - band, w))
    hits = []
    min_run = h * CREASE_RUN_FRAC

    for x in candidates:
        col = mask[:, x]
        if col.mean() < 0.5:  # a crease is mostly dark; text never is
            continue
        edges = np.diff(np.concatenate(([0], col.view(np.int8), [0])))
        starts = np.where(edges == 1)[0]
        ends = np.where(edges == -1)[0]
        if len(starts) and int((ends - starts).max()) > min_run:
            hits.append(x)

    if not hits:
        return gray

    # The crease is a soft gradient, so only its darkest columns pass the test
    # above. Grow each hit sideways while the neighbours are still shaded,
    # otherwise a faint stripe survives at the edge of the erase. The growth is
    # capped so it can never march into the type.
    cap = max(6, int(w * 0.04))
    out = gray.copy()
    for x in hits:
        left = x
        while left > 0 and x - left < cap and mask[:, left - 1].mean() > 0.12:
            left -= 1
        right = x
        while right < w - 1 and right - x < cap and mask[:, right + 1].mean() > 0.12:
            right += 1
        out[:, max(0, left - 1):min(w, right + 2)] = 255
    return out


def ink_block(gray: np.ndarray):
    """Bounding box of the text block, robust against dust and page numbers.

    A row/column only counts if it carries a minimum amount of ink, so an
    isolated speck of dust — or the page number alone — cannot stretch the box
    back out to the full page.
    """
    mask = gray < INK_THRESHOLD
    h, w = gray.shape
    rows = mask.sum(axis=1)
    cols = mask.sum(axis=0)

    r_ok = rows >= max(2, int(w * INK_ROW_FRAC))
    c_ok = cols >= max(2, int(h * INK_COL_FRAC))

    # A near-solid dark band hugging the border is the scanner edge, not text.
    edge_x = max(4, int(w * EDGE_BAND_FRAC))
    edge_y = max(4, int(h * EDGE_BAND_FRAC))
    solid_c = cols > h * EDGE_SOLID_FRAC
    solid_r = rows > w * EDGE_SOLID_FRAC
    c_ok[:edge_x] &= ~solid_c[:edge_x]
    c_ok[w - edge_x:] &= ~solid_c[w - edge_x:]
    r_ok[:edge_y] &= ~solid_r[:edge_y]
    r_ok[h - edge_y:] &= ~solid_r[h - edge_y:]

    ridx = np.where(r_ok)[0]
    cidx = np.where(c_ok)[0]
    if len(ridx) == 0 or len(cidx) == 0:
        return None
    return (int(cidx[0]), int(ridx[0]), int(cidx[-1]) + 1, int(ridx[-1]) + 1)


def ink_fraction(gray: np.ndarray) -> float:
    return float((gray < INK_THRESHOLD).mean())


def build_canvas_page(gray: np.ndarray):
    """Trim -> pad -> scale to a fixed text width -> centre on a fixed canvas.

    Returns None for a blank page so the caller can drop it: a full screen of
    nothing is one of the ugliest things a scan reader can show.
    """
    canvas_h = int(round(CANVAS_W / CANVAS_ASPECT))
    blank = np.full((canvas_h, CANVAS_W), 255, np.uint8)

    box = ink_block(gray)
    if box is None or ink_fraction(gray) < BLANK_INK_FRAC:
        return None

    x0, y0, x1, y1 = box
    # Generous padding: v1 cropped flush against the glyphs, which made the text
    # look cut off at the sides of the screen.
    px = int((x1 - x0) * PAGE_PAD_FRAC)
    py = int((y1 - y0) * PAGE_PAD_FRAC)
    x0 = max(0, x0 - px); y0 = max(0, y0 - py)
    x1 = min(gray.shape[1], x1 + px); y1 = min(gray.shape[0], y1 + py)
    crop = gray[y0:y1, x0:x1]

    ch, cw = crop.shape
    if cw < 8 or ch < 8:
        return blank

    target_w = int(CANVAS_W * INK_WIDTH_FRAC)
    target_h = max(1, int(round(ch * target_w / cw)))

    if BINARIZE:
        # Threshold at NATIVE resolution (where the strokes are widest and the
        # most faithful) and let the downscale re-introduce smooth anti-aliased
        # edges. This gives pure white paper, no grain, and much smaller files
        # than keeping the grey scan.
        block = max(15, (cw // 24) | 1)
        crop = cv2.adaptiveThreshold(crop, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                     cv2.THRESH_BINARY, block, BINARIZE_C)

    interp = cv2.INTER_AREA if target_w < cw else cv2.INTER_CUBIC
    crop = cv2.resize(crop, (target_w, target_h), interpolation=interp)

    # A very tall page (rare) is fitted by height instead of width.
    max_h = canvas_h - int(canvas_h * 0.04)
    if target_h > max_h:
        scale = max_h / target_h
        crop = cv2.resize(crop, (max(1, int(target_w * scale)), max_h),
                          interpolation=cv2.INTER_AREA)
        target_h, target_w = crop.shape

    canvas = blank.copy()
    top = (canvas_h - target_h) // 2
    left = (CANVAS_W - target_w) // 2
    canvas[top:top + target_h, left:left + target_w] = crop
    return canvas


def encode_page(gray: np.ndarray) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(gray, mode="L").save(
        buf, "WEBP", quality=PAGE_WEBP_QUALITY, method=6)
    return buf.getvalue()


def blank_page() -> bytes:
    h = int(round(CANVAS_W / CANVAS_ASPECT))
    buf = io.BytesIO()
    Image.new("L", (CANVAS_W, h), 255).save(buf, "WEBP", quality=20, method=4)
    return buf.getvalue()


# ─── Per-book worker ─────────────────────────────────────────────────────────
def process_one(job):
    pdf_path, book_id, covers_dir, zips_dir = job
    filename = os.path.basename(pdf_path)
    try:
        doc = pymupdf.open(pdf_path)
        if len(doc) == 0:
            doc.close()
            return {"ok": False, "filename": filename, "error": "empty pdf"}

        # ── Cover: page 1 in colour (kept untouched: it is artwork, not paper) ──
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
                    Image.LANCZOS)
            cover.save(os.path.join(covers_dir, f"{book_id}.webp"),
                       "WEBP", quality=COVER_WEBP_QUALITY, method=4)
            cover_asset = f"covers/{book_id}.webp"
        except Exception:
            cover_asset = None

        # ── Pages ──
        # Written to a .part file and renamed on completion: a killed run then
        # leaves only .part files, which the resume check ignores. Writing
        # straight to <id>.zip left 8 truncated zips that the next run happily
        # skipped, shipping unopenable books.
        zip_path = os.path.join(zips_dir, f"{book_id}.zip")
        tmp_path = zip_path + ".part"
        page_no = 0
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_STORED) as zf:
            for i in range(len(doc)):
                try:
                    raw = render_gray(doc[i])
                    for page in split_page(raw):
                        cleaned = stretch_levels(flatten_background(page))
                        cleaned = remove_crease_lines(cleaned)
                        canvas = build_canvas_page(cleaned)
                        if canvas is None:
                            # Blank page: drop it instead of showing a full
                            # screen of empty paper.
                            continue
                        zf.writestr(f"{page_no:04d}.webp", encode_page(canvas))
                        page_no += 1
                except Exception:
                    zf.writestr(f"{page_no:04d}.webp", blank_page())
                    page_no += 1
            if page_no == 0:
                zf.writestr("0000.webp", blank_page())
                page_no = 1
        doc.close()
        os.replace(tmp_path, zip_path)

        return {
            "ok": True, "filename": filename, "book_id": book_id,
            "page_count": page_no, "cover": cover_asset,
            "zip_size": os.path.getsize(zip_path),
            "title": extract_title(filename),
        }
    except Exception as e:
        try:
            os.remove(tmp_path)  # may be unbound if we failed before setup
        except (NameError, OSError):
            pass
        return {"ok": False, "filename": filename, "error": str(e)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--count", type=int, default=0)
    ap.add_argument("--workers", type=int, default=8)
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
                reverse=True)
            chosen.append(ranked[0])
            dups.extend(ranked[1:])
    chosen = sorted(chosen)
    if args.limit > 0:
        chosen = chosen[:args.limit]

    print(f"Source PDFs: {len(files)}  |  unique books: {len(chosen)}  |  "
          f"duplicates skipped: {len(dups)}", flush=True)

    jobs = []
    for i, f in enumerate(chosen):
        bid = f"book_{i:03d}"
        if (zips_dir / f"{bid}.zip").exists():
            continue
        jobs.append((str(src / f), bid, str(covers_dir), str(zips_dir)))
    if args.count > 0:
        jobs = jobs[:args.count]
    print(f"Pending this run: {len(jobs)}", flush=True)

    # Drop half-written zips left by a previous killed run.
    for stale in zips_dir.glob("*.part"):
        try:
            stale.unlink()
        except OSError:
            pass

    results, total_bytes = [], 0
    done = 0
    queue = list(jobs)
    while queue:
        # Small batches, a fresh pool per batch: if the OS kills a worker on a
        # monster PDF the blast radius is one batch instead of the whole run.
        batch, queue = queue[: args.workers * 2], queue[args.workers * 2:]
        try:
            # `max_tasks_per_child=1` recycles a worker after every book. MuPDF
            # and OpenCV both hold large native buffers and a long-lived worker
            # grows until it is killed.
            with ProcessPoolExecutor(
                max_workers=args.workers, max_tasks_per_child=1
            ) as ex:
                futures = {ex.submit(process_one, j): j for j in batch}
                for fut in as_completed(futures):
                    done += 1
                    try:
                        r = fut.result()
                    except Exception as e:  # one dead worker ≠ dead run
                        name = futures[fut][0].rsplit(os.sep, 1)[-1]
                        print(f"[{done}/{len(jobs)}] CRASHED {name} -> "
                              f"{type(e).__name__}", flush=True)
                        continue
                    if r.get("ok"):
                        results.append(r)
                        total_bytes += r["zip_size"]
                        print(f"[{done}/{len(jobs)}] {r['page_count']:4d}p "
                              f"{r['zip_size']//1024:5d}KB  {r['filename'][:58]}",
                              flush=True)
                    else:
                        print(f"[{done}/{len(jobs)}] FAILED {r['filename']} -> "
                              f"{r.get('error')}", flush=True)
        except Exception as e:
            print(f"Pool died on a batch ({type(e).__name__}); continuing.",
                  flush=True)

    # Write the per-book metadata for EVERY book that has a zip, not just the
    # ones finished in this run. A resumed run reuses zips from a previous one,
    # so keying off `results` alone silently dropped those books from
    # library.json — the app then showed a fraction of the library.
    for i, f in enumerate(chosen):
        bid = f"book_{i:03d}"
        zpath = zips_dir / f"{bid}.zip"
        jpath = jsons_dir / f"{bid}.json"
        if not zpath.exists() or jpath.exists():
            continue
        try:
            with zipfile.ZipFile(zpath) as zf:
                page_count = sum(1 for n in zf.namelist() if n.endswith(".webp"))
        except Exception:
            continue  # corrupt zip: leave it out so it gets rebuilt next run
        cover_file = covers_dir / f"{bid}.webp"
        detail = {
            "id": bid,
            "title": extract_title(f),
            "original_filename": f,
            "page_count": page_count,
            "cover": f"covers/{bid}.webp" if cover_file.exists() else None,
            "quality_score": 1.0,
            "content_mode": "image",
            "series": classify(f),
            "chapters": [],
            "images": [],
            "zip_asset": f"books/{bid}.zip",
        }
        with open(jpath, "w", encoding="utf-8") as fh:
            json.dump(detail, fh, ensure_ascii=False, separators=(",", ":"))

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
        "version": "3.0.0",
        "app_name": "مكتبة العرّاب",
        "author": "د. أحمد خالد توفيق",
        "sections": SECTION_META,
        "books": books_meta,
    }
    (out / "library.json").write_text(
        json.dumps(library, ensure_ascii=False, indent=1), encoding="utf-8")

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
