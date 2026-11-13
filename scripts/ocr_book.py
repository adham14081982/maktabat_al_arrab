#!/usr/bin/env python3
"""
OCR pipeline for Maktabat Al-Arrab — Phase (B) of the processing chain.
=======================================================================

Adds searchable text to books that were processed as page images
(content_mode: image). The app keeps serving the ORIGINAL page images;
the OCR output only adds a text layer, so a completed book is promoted
to `content_mode: hybrid`.

Design rules (from the project spec):
  * The engine is swappable — `tesseract` ships enabled (lang: ara);
    other engines plug into `ENGINES` with the same signature.
  * **No automatic spell-correction.** The original print spells final
    vowels like الشاى / هى / أنى with ى — the text layer must reproduce
    the print exactly. Only layout whitespace is normalised.
  * Confidence per page drives a review report; a book is promoted only
    after human review.
  * Arabic books are scans of a real paperback: we upscale the clean
    540px WebP pages before OCR (Tesseract likes ≈2.0–2.5× this size).

Persistence:
  assets/ocr/<book_id>.json  — per-page results, resumable. Re-running a
  book re-OCRs only pages that are missing or marked as failures.
  Reviewer corrections can be merged back with --merge-corrections.

Usage:
  py -3 ocr_book.py book_001 --limit 5       # pilot: 5 pages, worst first
  py -3 ocr_book.py book_001                 # full book (resumable)
  py -3 ocr_book.py book_001 --apply         # merge text into book json
  py -3 ocr_book.py book_001 --promote       # + set content_mode hybrid
  py -3 ocr_book.py --report                 # library-wide status report
"""

from __future__ import annotations

import argparse
import html
import io
import json
import os
import shutil
import sys
import tempfile
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import autocorrect  # noqa: E402

# ---------------------------------------------------------------- config ----
def _parse_simple_yaml(text: str) -> dict:
    """Minimal reader for this config's shape: flat `key: value` lines.

    The pipeline must honour config.yaml even on a machine without PyYAML.
    Silently falling back to hardcoded defaults is worse than useless — it
    makes the file look authoritative while every knob is ignored (that bug
    hid here for the whole first OCR run: `min_pass_ratio: 0.90` in the file
    had no effect because `import yaml` failed).
    """
    out: dict = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip().strip('"').strip("'")
        if not val:
            continue
        low = val.lower()
        if low in ("true", "false"):
            out[key] = low == "true"
            continue
        try:
            out[key] = int(val)
            continue
        except ValueError:
            pass
        try:
            out[key] = float(val)
            continue
        except ValueError:
            pass
        out[key] = val
    return out


def load_config() -> dict:
    """Read scripts/config.yaml — PyYAML when present, else a tiny parser."""
    cfg_path = Path(__file__).resolve().parent / "config.yaml"
    defaults = {
        "ocr_engine": "tesseract",
        "ocr_lang": "ara",
        "ocr_psm": 6,
        "normalize_final_ya": True,
        "max_edit_ratio": 0.08,
        "max_word_delta": 0.05,
        "min_confidence": 45,
        "min_pass_ratio": 0.90,
        "soft_pass_ratio": 0.75,
        "soft_min_confidence": 75,
        "embed_raw_text": True,
        "llm_correction": False,
    }
    try:
        text = cfg_path.read_text(encoding="utf-8")
    except OSError:
        return defaults
    try:
        import yaml
        loaded = yaml.safe_load(text) or {}
    except Exception:
        loaded = _parse_simple_yaml(text)
    defaults.update({k: v for k, v in loaded.items() if v is not None})
    return defaults


CFG = load_config()


def decide_mode(pass_ratio: float, mean_conf: float) -> str:
    """`hybrid` or `image`, from the two-tier promotion rule.

    Strict bar first (`min_pass_ratio`, default 0.90). Below it, a soft bar:
    a book at 77 % still reads as prose with the odd scan in place, because
    every rejected page is rendered as its cleaned image inline — the reader
    degrades page by page rather than losing the text wholesale. A book only
    stays image-only when it is bad on both axes (e.g. the two comics, which
    sit near 24 % at confidence ~50).
    """
    if pass_ratio >= float(CFG.get("min_pass_ratio", 0.90)):
        return "hybrid"
    if (pass_ratio >= float(CFG.get("soft_pass_ratio", 0.75))
            and mean_conf >= float(CFG.get("soft_min_confidence", 75))):
        return "hybrid"
    return "image"

# ---------------------------------------------------------------- paths ----
ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
BOOK_JSONS = ASSETS / "book_jsons"
OCR_DIR = ASSETS / "ocr"
REVIEW_DIR = OCR_DIR / "review"

# Tesseract installed by winget only exposes eng/osd; the Arabic
# `tessdata_best` model lives in a user-writable folder.
TESSDATA_DIR = Path(os.environ.get("TESSDATA_DIR", str(Path.home() / ".ocr" / "tessdata")))
TESSERACT_CANDIDATES = (
    r"C:\Program Files\Tesseract-OCR\tesseract.exe",
)

# Reduced-resolution page assets: upscaling them is mandatory for decent
# Arabic OCR. 2.2x ≈ 1188px wide, close to the sweet spot for a print page.
UPSCALE = 2.2

# Engine knobs — tune on the worst-quality book before running the library.
PSM_MODE = "6"  # 6 = assume a uniform block of text (book page)
LANGUAGE = "ara"
OCR_QUALITY_CONFIG = "tessedit_do_invert=0 preserve_interword_spaces=1"

# Hard ceiling per page. A normal page takes 1-8 s; anything past this is a
# wedged Tesseract child and must be killed rather than allowed to block the
# worker (and with it, the whole pool) indefinitely.
PAGE_TIMEOUT_S = 180


# ---------------------------------------------------------------- engine ----
def _tesseract_exe() -> str:
    from shutil import which

    found = which("tesseract")
    if found:
        return found
    for c in TESSERACT_CANDIDATES:
        if Path(c).exists():
            return c
    raise RuntimeError(
        "tesseract.exe not found. Install with: "
        "winget install --id UB-Mannheim.TesseractOCR"
    )


def _tesseract_data(page_image, upscale: float):
    """Run Tesseract, returning (text, page_confidence).

    Confidence is the word-length-weighted mean of word confidences from
    the TSV output — sparse dotted pages don't get dragged to -1 by the
    invisible separators, and noisy pages sink honestly.
    """
    import pytesseract
    from PIL import Image

    pytesseract.pytesseract.tesseract_cmd = _tesseract_exe()
    os.environ["TESSDATA_PREFIX"] = str(TESSDATA_DIR)

    image = page_image
    if upscale != 1.0:
        image = page_image.resize(
            (
                int(page_image.width * upscale),
                int(page_image.height * upscale),
            ),
            Image.Resampling.LANCZOS,
        )

    config = f"--psm {PSM_MODE} {OCR_QUALITY_CONFIG}"
    # A page normally takes 1-8 s. Without a timeout a wedged Tesseract
    # process blocks its worker forever and the whole pool silently stops
    # making progress (that happened once: 30 min with zero output).
    data = pytesseract.image_to_data(
        image,
        lang=LANGUAGE,
        config=config,
        output_type=pytesseract.Output.DICT,
        timeout=PAGE_TIMEOUT_S,
    )
    words, confs = [], []
    for i, word in enumerate(data["text"]):
        word = word.strip()
        if not word:
            continue
        try:
            conf = float(data["conf"][i])
        except (TypeError, ValueError):
            continue
        if conf < 0:
            continue
        words.append(word)
        confs.append((conf, len(word)))

    text = _normalise_whitespace(" ".join(words))
    if not confs:
        return "", 0.0
    total_len = sum(l for _, l in confs)
    mean = sum(c * l for c, l in confs) / total_len
    return text, round(mean, 1)


def _paddle_data(_page_image, _upscale: float):
    """PaddleOCR engine slot (spec: engine swappable).

    Wire up when needed: pip install paddleocr paddlepaddle, then call
    PaddleOCR(use_angle_cls=False, lang="ar") here and return the same
    (text, confidence) pair. Kept as an explicit stub so the CLI stops
    with a clear message instead of silently downgrading quality.
    """
    raise NotImplementedError(
        "PaddleOCR engine not wired yet — use --engine tesseract."
    )


ENGINES = {
    "tesseract": _tesseract_data,
    "paddle": _paddle_data,
}


def _normalise_whitespace(text: str) -> str:
    """Layout fix-ups ONLY — no orthography is ever touched.

    The print's final ى (الشاى، هى، أنى), its ligatures and its diacritics
    are the edition's own; they must survive the pipeline byte-for-byte.
    """
    lines = [ln.rstrip() for ln in text.replace("\r", "\n").split("\n")]
    out = [ln for ln in lines if ln.strip()]
    return "\n".join(out)


# ---------------------------------------------------------------- io -------
def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def book_zip_images(book_json: dict) -> list[tuple[str, bytes]]:
    """(name, bytes) for every page inside the book's asset zip, in reading
    order — the zip stores layers as 0000.webp, 0001.webp, …"""
    zip_rel = book_json["zip_asset"]
    zip_path = ASSETS / zip_rel
    if not zip_path.exists():
        raise FileNotFoundError(f"missing zip asset: {zip_path}")
    pages = []
    with zipfile.ZipFile(zip_path) as zf:
        names = sorted(
            n for n in zf.namelist()
            if n.lower().endswith((".webp", ".png", ".jpg", ".jpeg"))
        )
        for name in names:
            pages.append((name, zf.read(name)))
    if not pages:
        raise RuntimeError(f"no page images inside {zip_path}")
    return pages


# ------------------------------------------------------------- pipeline ----
def ocr_book(book_id: str, engine: str, limit: int | None, worst_first: bool) -> Path:
    """OCR a single book, resumable. Returns the results-file path."""
    from PIL import Image

    if engine not in ENGINES:
        raise ValueError(f"unknown engine '{engine}', use one of {list(ENGINES)}")
    run_engine = ENGINES[engine]

    book_json_path = BOOK_JSONS / f"{book_id}.json"
    if not book_json_path.exists():
        raise FileNotFoundError(book_json_path)
    book_json = load_json(book_json_path)
    total_expected = int(book_json.get("page_count", 0))

    out_path = OCR_DIR / f"{book_id}.json"
    results = load_json(out_path) if out_path.exists() else {
        "book_id": book_id,
        "engine": engine,
        "language": LANGUAGE,
        "psm": PSM_MODE,
        "pages": {},
        "reviewed": False,
    }
    pages: dict = results["pages"]

    with tempfile.TemporaryDirectory(prefix=f"ocr_{book_id}_") as tmp:
        images = book_zip_images(book_json)
        todo = [np for np in images]
        if worst_first:
            # pages already OCR'd define "confidence" ordering; new pages first
            todo.sort(key=lambda np_: pages.get(np_[0], {}).get("confidence", 101))
        if limit:
            todo = todo[:limit]

        for idx, (name, blob) in enumerate(todo):
            done = pages.get(name)
            if done and done.get("text") is not None and not done.get("failed"):
                continue  # resumable: skip finished pages
            page = Image.open(io.BytesIO(blob)).convert("L")
            t0 = time.time()
            try:
                raw_text, conf = run_engine(page, UPSCALE)
                failed = False
            except Exception as exc:  # keep going: one bad page ≠ a broken book
                print(f"  ! {name}: {type(exc).__name__}: {exc}")
                raw_text, conf, failed = "", 0.0, True

            # Layers 1+2 of the spec run here (rules, then lexicon); layer 3 is
            # the optional LLM pass. The gates reject a page that changed too
            # much, and a rejected page carries NO text — the app then shows
            # that page as its cleaned image, exactly as the spec requires.
            text, flags, ratio = autocorrect.apply_safe(
                raw_text,
                normalize_ya=bool(CFG.get("normalize_final_ya", True)),
                max_edit=float(CFG.get("max_edit_ratio", 0.08)),
                max_word=float(CFG.get("max_word_delta", 0.05)),
            )
            if CFG.get("llm_correction") and not flags:
                llm_text = autocorrect.llm_correct(text, CFG)
                if llm_text:
                    # The LLM must clear the same gates as the lexicon pass.
                    text, flags, ratio = autocorrect.gate(
                        raw_text,
                        llm_text,
                        max_edit=float(CFG.get("max_edit_ratio", 0.08)),
                        max_word=float(CFG.get("max_word_delta", 0.05)),
                    )
            if conf < float(CFG.get("min_confidence", 45)):
                flags = flags + [f"low_confidence:{conf:.0f}"]
            if failed:
                flags = flags + ["engine_error"]
            if flags:
                text = ""  # rejected → the reader shows the page image

            pages[name] = {
                "raw": raw_text,
                "text": text,
                "flags": flags,
                "edit_ratio": round(ratio, 4),
                "confidence": conf,
                "failed": failed,
                "chars": len(text),
                "seconds": round(time.time() - t0, 2),
            }
            results["pages"] = pages
            # checkpoint after EVERY page — the pipeline may be interrupted
            save_json(out_path, results)

            n_done = len(pages)
            print(
                f"  [{n_done}/{len(images) or total_expected}] {name} "
                f"conf={conf:>5} chars={len(text):>4} "
                f"({time.time() - t0:.1f}s)",
                # stdout is block-buffered when redirected to a file, so
                # without this the log looks frozen while work continues.
                flush=True,
            )

    results["pages"] = pages
    save_json(out_path, results)

    # ── Promotion decision (fully automatic, per spec §3.9) ──
    # A page counts as "passed" only when it cleared every gate, so the ratio
    # measures pages the reader will actually see as prose.
    total = len(pages)
    passed = sum(
        1 for p in pages.values()
        if not p.get("flags") and not p.get("failed") and p.get("text")
    )
    pass_ratio = (passed / total) if total else 0.0
    results["pass_ratio"] = round(pass_ratio, 4)

    # quick book-level summary
    texts = [p for p in pages.values() if p.get("text")]
    confs = [p["confidence"] for p in texts if p.get("confidence")]
    mean_conf = round(sum(confs) / len(confs), 1) if confs else 0.0
    results["mode"] = decide_mode(pass_ratio, mean_conf)
    low = sorted(
        (
            (p["confidence"], name)
            for name, p in pages.items()
            if p.get("confidence", 0) < 70 and not p.get("failed")
        ),
        reverse=False,
    )
    results["summary"] = {
        "pages_ocr": len(pages),
        "expected_pages": total_expected,
        "mean_confidence": mean_conf,
        "passed_pages": passed,
        "pass_ratio": round(pass_ratio, 4),
        "mode": results["mode"],
        "low_confidence_pages": [name for _, name in low][:20],
    }
    save_json(out_path, results)
    print(
        f"✓ {book_id}: {len(pages)} pages, mean conf {mean_conf}, "
        f"passed {passed}/{total} ({pass_ratio:.1%}) → mode={results['mode']}"
    )
    return out_path


# ----------------------------------------------------------------- apply ----
def apply_results(
    book_id: str,
    promote: bool | None = None,
    sync_library: bool = True,
) -> None:
    """Merge OCR text into the book json the app reads.

    Layout: `ocr_pages: [{image, text, confidence}]` — per page, so the reader
    keeps an identical index when switching image ⇄ text. Pages rejected by the
    safety gates carry an empty `text`, which is the app's signal to show that
    page as its cleaned image instead of prose.

    ``promote=None`` promotes automatically when the book cleared
    `min_pass_ratio` (spec §3.9) — no human review step exists in this design.
    """
    ocr_path = OCR_DIR / f"{book_id}.json"
    if not ocr_path.exists():
        raise FileNotFoundError("run ocr_book first")
    ocr = load_json(ocr_path)
    if ocr.get("summary", {}).get("pages_ocr", 0) == 0:
        raise RuntimeError("no OCR text present")

    if promote is None:
        promote = ocr.get("mode") == "hybrid"

    book_json_path = BOOK_JSONS / f"{book_id}.json"
    book_json = load_json(book_json_path)

    ordered = []
    with zipfile.ZipFile(ASSETS / book_json["zip_asset"]) as zf:
        names = sorted(
            n for n in zf.namelist()
            if n.lower().endswith((".webp", ".png", ".jpg", ".jpeg"))
        )
    embed_raw = bool(CFG.get("embed_raw_text", True))
    for name in names:
        p = ocr["pages"].get(name)
        if p is None:
            continue
        page = {
            "image": name,
            "text": p["text"],
            "confidence": p["confidence"],
            # Kept so a page can be re-corrected later (rules change, or an
            # optional LLM pass runs) without re-OCRing the whole library.
            "edit_ratio": round(float(p.get("edit_ratio") or 0.0), 4),
            "flags": list(p.get("flags") or []),
        }
        raw = p.get("raw")
        if embed_raw and raw and raw != p["text"]:
            page["text_raw"] = raw
        ordered.append(page)
    book_json["ocr_pages"] = ordered
    book_json["ocr_engine"] = ocr.get("engine")
    book_json["ocr_pass_ratio"] = ocr.get("pass_ratio")
    book_json["ocr_mean_confidence"] = ocr.get("summary", {}).get("mean_confidence")

    # A real quality score instead of the placeholder 1.0: how much of the book
    # is readable, weighted by how much the OCR trusted itself on those pages.
    pass_ratio = float(ocr.get("pass_ratio") or 0.0)
    mean_conf = float(ocr.get("summary", {}).get("mean_confidence") or 0.0)
    book_json["quality_score"] = round(pass_ratio * (mean_conf / 100.0), 3)
    if promote:
        book_json["content_mode"] = "hybrid"
    save_json(book_json_path, book_json)

    # library.json follows only on explicit promotion — and only from the
    # parent process: several OCR workers writing this one file concurrently
    # would interleave their read-modify-write and lose entries.
    if promote and sync_library:
        lib_path = ASSETS / "library.json"
        lib = load_json(lib_path)
        for b in lib["books"]:
            if b["id"] == book_id:
                b["content_mode"] = "hybrid"
                break
        save_json(lib_path, lib)
    print(f"✓ applied to {book_json_path.name} (promote={promote})")


def sync_library_modes() -> None:
    """Mirror every book json's ``content_mode`` into library.json, once.

    Called by the parent after the worker batches, so the shared file has a
    single writer no matter how many processes ran.
    """
    lib_path = ASSETS / "library.json"
    lib = load_json(lib_path)
    changed = 0
    counts: dict[str, int] = {}
    for b in lib["books"]:
        bj = BOOK_JSONS / f"{b['id']}.json"
        mode = "image"
        if bj.exists():
            try:
                mode = load_json(bj).get("content_mode", "image")
            except Exception:
                mode = b.get("content_mode", "image")
        counts[mode] = counts.get(mode, 0) + 1
        if b.get("content_mode") != mode:
            b["content_mode"] = mode
            changed += 1
    save_json(lib_path, lib)
    print(f"library.json: {changed} entries updated → {counts}", flush=True)


def merge_corrections(book_id: str, corrections_path: Path) -> None:
    """Re-apply human-corrected text from the review tool's exported file."""
    corrections = load_json(corrections_path)
    ocr_path = OCR_DIR / f"{book_id}.json"
    ocr = load_json(ocr_path)
    n = 0
    for name, text in corrections.items():
        if name in ocr["pages"]:
            ocr["pages"][name]["text"] = _normalise_whitespace(text or "")
            ocr["pages"][name]["confidence"] = 100.0
            ocr["pages"][name]["failed"] = False
            ocr["pages"][name]["reviewed"] = True
            n += 1
    ocr["reviewed"] = True
    save_json(ocr_path, ocr)
    print(f"✓ {n} corrected pages merged into {ocr_path.name}")


# ---------------------------------------------------------------- review ----
def build_review_page(book_id: str) -> Path:
    """Static HTML tool: image beside text, worst pages first. Edit a
    textarea and hit 'Export corrections' to produce a JSON the pipeline
    can merge with --merge-corrections. Zero server, works offline."""
    ocr = load_json(OCR_DIR / f"{book_id}.json")
    book_json = load_json(BOOK_JSONS / f"{book_id}.json")

    with zipfile.ZipFile(ASSETS / book_json["zip_asset"]) as zf:
        names = sorted(
            n for n in zf.namelist()
            if n.lower().endswith((".webp", ".png", ".jpg", ".jpeg"))
        )

    # extract pages next to the HTML so <img src> is trivial and offline
    page_dir = REVIEW_DIR / book_id
    page_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ASSETS / book_json["zip_asset"]) as zf:
        for name in names:
            target = page_dir / name
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(zf.read(name))

    rows = []
    for name in sorted(
        names,
        key=lambda n: ocr["pages"].get(n, {}).get("confidence", -1),
    ):
        p = ocr["pages"].get(name, {})
        conf = p.get("confidence")
        conf_style = ""
        if conf is not None and conf < 70:
            conf_style = "background:#fff3cd;"
        elif conf is not None and conf < 85:
            conf_style = "background:#f8f9fa;"
        rows.append(
            f'<div class="row"><img loading="lazy" src="{book_id}/{name}" />'
            f'<div class="tx"><div class="meta" style="{conf_style}">{name} · '
            f'وثقة {conf if conf is not None else "—"} {"· فشل" if p.get("failed") else ""}</div>'
            f'<textarea data-page="{name}">{html.escape(p.get("text") or "")}</textarea></div></div>'
        )

    doc = f"""<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8">
<title>مراجعة OCR — {book_id}</title><style>
body{{font-family:Amiri,serif;margin:12px;background:#f6f1e7}}
.row{{display:flex;gap:10px;margin-bottom:10px;align-items:flex-start}}
.row img{{width:38%;max-width:420px;border:1px solid #c9a24b}}
.tx{{flex:1}} .meta{{font-size:13px;color:#4a2c1a;padding:4px 6px;border-radius:6px}}
textarea{{width:100%;height:220px;font-family:inherit;font-size:16px;line-height:1.7;
border:1px solid #c9a24b;border-radius:8px;padding:8px;background:#fffdf5}}
button{{padding:10px 22px;font-size:16px;background:#4a2c1a;color:#f3e7cf;border:0;border-radius:8px}}
p.warn{{background:#fdecea;border:1px solid #8b1e2d;padding:8px;border-radius:8px;color:#8b1e2d}}
</style></head><body>
<h2>مراجعة OCR — {html.escape(str(book_json.get("title", book_id)))}</h2>
<p class="warn">صحّح ما يلزم <b>دون تغيير إملاء الطبعة الأصلية</b> — تبقى «ى» البائدة
(الشاى، هى، أنى) كما هي. الصفحات منخفضة الوثقة أولاً.</p>
<button onclick="exportCorrections()">⬇️ تصدير التصحيحات (JSON)</button>
<script>
function exportCorrections() {{
  const out = {{}};
  document.querySelectorAll('textarea').forEach(t => {{
    if (t.value !== t.defaultValue) out[t.dataset.page] = t.value;
  }});
  const blob = new Blob([JSON.stringify(out, null, 1)],
    {{type: 'application/json'}});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = '{book_id}_corrections.json';
  a.click();
}}
</script>
{''.join(rows)}
</body></html>"""

    REVIEW_DIR.mkdir(parents=True, exist_ok=True)
    out = REVIEW_DIR / f"{book_id}.html"
    out.write_text(doc, encoding="utf-8")
    print(f"✓ review page: {out}")
    return out


# ---------------------------------------------------------------- report ----
def report() -> None:
    """Library-wide OCR status, written to `REPORT.md` at the project root.

    Classification reads `content_mode` and the stored pass ratio, not the
    `reviewed` flag: promotion in this pipeline is automatic (spec §3.9), so
    `reviewed` is never set and every promoted book used to be reported as
    "OCR غير مراجَع" — which is how the 2026-11-12 audit came to believe 19
    books had unusable text.
    """
    lib = load_json(ASSETS / "library.json")
    rows = []
    counts = {"hybrid": 0, "image": 0, "no-ocr": 0, "below-threshold": 0}

    for b in lib["books"]:
        bid = b["id"]
        # The book json is the per-book source of truth; library.json is only
        # rewritten by --repromote, so reading it here would report stale modes
        # mid-run.
        book_path = BOOK_JSONS / f"{bid}.json"
        mode = b.get("content_mode", "image")
        if book_path.exists():
            mode = load_json(book_path).get("content_mode", mode)
        ocr_path = OCR_DIR / f"{bid}.json"
        summary = {}
        if ocr_path.exists():
            summary = load_json(ocr_path).get("summary", {}) or {}
        pages = summary.get("pages_ocr", 0)
        ratio = summary.get("pass_ratio", 0.0) or 0.0
        conf = summary.get("mean_confidence", 0.0) or 0.0

        if pages == 0:
            status = "no-ocr"
            detail = "لا نتائج OCR"
        elif mode == "hybrid":
            status = "hybrid"
            detail = f"{ratio:.1%} صفحة مقبولة · ثقة {conf:.1f} · {pages} صفحة"
        else:
            status = "below-threshold"
            detail = f"{ratio:.1%} صفحة مقبولة · ثقة {conf:.1f} · تحت العتبة"

        counts[status] += 1
        rows.append((status, bid, b.get("title", ""), detail, ratio))

    order = {"hybrid": 0, "below-threshold": 1, "no-ocr": 2, "image": 3}
    rows.sort(key=lambda r: (order[r[0]], -r[4]))

    lines = [
        "# تقرير حالة المكتبة",
        "",
        f"**الإجمالي:** {len(lib['books'])} كتاب · "
        + " · ".join(f"{k}: {v}" for k, v in counts.items() if v),
        "",
        "## ملخص",
        "",
        "| الحالة | العدد |",
        "| --- | --- |",
        f"| نص كامل (hybrid) | {counts['hybrid']} |",
        f"| OCR موجود تحت العتبة | {counts['below-threshold']} |",
        f"| بلا نتائج OCR | {counts['no-ocr']} |",
        f"| صور فقط (لا OCR) | {counts['image']} |",
        "",
        "## التفاصيل",
        "",
    ]
    for status, bid, title, detail, _ in rows:
        lines.append(f"- **{bid}** {title} — {status} · {detail}")

    body = "\n".join(lines) + "\n"
    OCR_DIR.mkdir(parents=True, exist_ok=True)
    (OCR_DIR / "REPORT.md").write_text(body, encoding="utf-8")
    root_report = ASSETS.parent / "REPORT.md"
    root_report.write_text(body, encoding="utf-8")
    print(f"✓ report: {root_report}")
    print(f"  {counts}")


def repromote_all() -> None:
    """Re-apply the promotion rule to results that already exist.

    Lowering `min_pass_ratio` must not require re-running OCR: the per-page
    text is on disk and the decision is a pure function of it. This walks
    every finished results file and promotes the ones that now clear the
    threshold, then syncs library.json once.
    """
    flipped, kept, skipped = [], [], []
    for path in sorted(OCR_DIR.glob("book_*.json")):
        bid = path.stem
        try:
            data = load_json(path)
        except Exception:
            continue
        pages = data.get("pages") or {}
        if not pages:
            skipped.append(bid)
            continue
        expected = 0
        bj = BOOK_JSONS / f"{bid}.json"
        if bj.exists():
            try:
                expected = int(load_json(bj).get("page_count", 0))
            except Exception:
                expected = 0
        if expected and len(pages) < expected:
            skipped.append(bid)          # still being OCR'd — leave it alone
            continue

        passed = sum(
            1 for p in pages.values()
            if not p.get("flags") and not p.get("failed") and p.get("text")
        )
        ratio = passed / len(pages) if pages else 0.0
        confs = [p["confidence"] for p in pages.values() if p.get("confidence")]
        mean_conf = sum(confs) / len(confs) if confs else 0.0
        mode = decide_mode(ratio, mean_conf)
        data["pass_ratio"] = round(ratio, 4)
        data["mode"] = mode
        save_json(path, data)

        if mode == "hybrid":
            apply_results(bid, promote=True, sync_library=False)
            flipped.append((bid, ratio))
        else:
            kept.append((bid, ratio))

    sync_library_modes()
    print(f"threshold {CFG.get('min_pass_ratio', 0.90):.0%} "
          f"(soft {CFG.get('soft_pass_ratio', 0.75):.0%} at conf "
          f"{CFG.get('soft_min_confidence', 75)}) → promoted {len(flipped)}, "
          f"left as images {len(kept)}, skipped (incomplete) {len(skipped)}")
    for bid, r in flipped:
        print(f"  ↑ {bid} {r:.1%}")
    for bid, r in kept:
        print(f"  · {bid} {r:.1%}")


# ------------------------------------------------------------------ main ----
def reapply_all() -> None:
    """Re-merge every finished OCR result into its book json.

    Needed when the *shape* of `ocr_pages` changes (new fields, a different
    quality formula) but the OCR text itself is still valid — no Tesseract run
    involved, so the whole library takes a couple of minutes instead of hours.
    """
    done = skipped = 0
    for p in sorted(OCR_DIR.glob("book_*.json")):
        bid = p.stem
        try:
            apply_results(bid, promote=None, sync_library=False)
            done += 1
        except Exception as exc:
            skipped += 1
            print(f"  ! {bid} skipped: {type(exc).__name__}: {exc}", flush=True)
    sync_library_modes()
    report()
    print(f"re-applied {done} book(s), skipped {skipped}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("book_id", nargs="?", help="e.g. book_001")
    ap.add_argument("--engine", choices=list(ENGINES), default=CFG.get("ocr_engine", "tesseract"))
    ap.add_argument("--limit", type=int, help="OCR only the first N pending pages (pilot)")
    ap.add_argument("--worst-first", action="store_true",
                    help="process the lowest-confidence/oldest pages first")
    ap.add_argument("--apply", action="store_true",
                    help="merge text into the book json (automatic after OCR anyway)")
    ap.add_argument("--promote", action="store_true",
                    help="force hybrid promotion regardless of the pass ratio")
    ap.add_argument("--review", action="store_true",
                    help="also build the optional review HTML page")
    ap.add_argument("--merge-corrections", type=Path,
                    help="apply the review tool's corrections JSON")
    ap.add_argument("--report", action="store_true", help="library-wide status report")
    ap.add_argument("--reapply", action="store_true",
                    help="re-merge existing OCR results into the book jsons")
    ap.add_argument("--all", action="store_true",
                    help="OCR every book that has no results yet (one command)")
    ap.add_argument("--repromote", action="store_true",
                    help="re-apply min_pass_ratio to finished books (no re-OCR)")
    ap.add_argument("--workers", type=int, default=int(CFG.get("workers", 4)))
    args = ap.parse_args()

    if args.repromote:
        repromote_all()
        return

    if args.report:
        report()
        return

    if args.reapply:
        reapply_all()
        return

    if args.all:
        run_all(args.engine, args.workers)
        return

    if not args.book_id:
        ap.error("book_id is required (or use --all / --report)")

    if args.merge_corrections:
        merge_corrections(args.book_id, args.merge_corrections)
        return

    ocr_book(args.book_id, args.engine, args.limit, args.worst_first)

    # The spec has no manual review step: merge and promote automatically.
    apply_results(args.book_id, promote=True if args.promote else None)
    if args.review:
        build_review_page(args.book_id)


def _ocr_complete(book_id: str) -> bool:
    """True when every page of the book has a finished OCR record."""
    res = OCR_DIR / f"{book_id}.json"
    if not res.exists():
        return False
    try:
        data = load_json(res)
        done = sum(
            1 for v in data.get("pages", {}).values()
            if v.get("text") is not None and not v.get("failed")
        )
        expected = int(load_json(BOOK_JSONS / f"{book_id}.json").get("page_count", 0))
    except Exception:
        return False
    return bool(expected) and done >= expected


def _pending_books() -> list[str]:
    """Books whose OCR is missing *or* incomplete.

    A killed run leaves a partial results file (pages are checkpointed one by
    one), so testing only for the file's existence would silently skip every
    book that was mid-flight.
    """
    out: list[str] = []
    for p in sorted(BOOK_JSONS.glob("book_*.json")):
        if not _ocr_complete(p.stem):
            out.append(p.stem)
    return out


def _ocr_and_merge(job: tuple[str, str]) -> str:
    """Worker entry point: OCR one book, then merge it into its book json.

    Module level (not a closure) because Windows spawns workers by pickling
    the callable — a nested function cannot be sent to a child process.
    ``library.json`` is deliberately NOT touched here; see sync_library_modes.
    """
    bid, engine = job
    ocr_book(bid, engine, None, False)
    apply_results(bid, sync_library=False)
    return bid


def run_all(engine: str, workers: int) -> None:
    """OCR every pending book, in crash-resilient batches, then merge each one.

    A pool is recreated per batch instead of living for the whole run: MuPDF
    and Tesseract both hold large native buffers, and a long-lived worker
    eventually dies and takes the pool down with it. Batches bound the blast
    radius to the books in flight, and each page is checkpointed anyway.
    """
    from concurrent.futures import ProcessPoolExecutor, as_completed

    pending = _pending_books()
    total = len(pending)
    print(f"pending books: {total}", flush=True)
    if not pending:
        repromote_all()
        return

    workers = max(1, workers)
    batch_size = max(1, workers * 3)
    failed: list[str] = []
    finished = 0
    started = time.time()

    for b0 in range(0, total, batch_size):
        batch = pending[b0:b0 + batch_size]
        jobs = [(bid, engine) for bid in batch]
        # Never use `with` here: on a broken pool its __exit__ calls
        # shutdown(wait=True) and blocks forever on workers that are already
        # dead. That is exactly how the 2026-11-11 run froze at book_196 —
        # four futures raised BrokenProcessPool and the process hung instead
        # of moving to the next batch.
        ex = ProcessPoolExecutor(
            max_workers=min(workers, len(batch)),
            max_tasks_per_child=1,
        )
        try:
            futures = {ex.submit(_ocr_and_merge, j): j[0] for j in jobs}
            for fut in as_completed(futures):
                bid = futures[fut]
                finished += 1
                elapsed = time.time() - started
                eta = (elapsed / finished) * (total - finished) if finished else 0
                try:
                    fut.result()
                    print(
                        f"[{finished}/{total}] {bid} ok "
                        f"({elapsed/60:.0f}m elapsed, ~{eta/60:.0f}m left)",
                        flush=True,
                    )
                except Exception as exc:
                    failed.append(bid)
                    print(
                        f"[{finished}/{total}] {bid} FAILED: "
                        f"{type(exc).__name__}: {exc}",
                        flush=True,
                    )
        except Exception as exc:  # the pool itself died
            print(f"! batch pool error: {type(exc).__name__}: {exc}", flush=True)
        finally:
            try:
                ex.shutdown(wait=False, cancel_futures=True)
            except Exception:
                pass
            # Anything that already has a *complete* results file is salvageable
            # even if its future never returned. Incomplete files are left alone:
            # the next run resumes them page by page.
            for bid in batch:
                if bid in failed or not _ocr_complete(bid):
                    continue
                try:
                    apply_results(bid, sync_library=False)
                except Exception:
                    failed.append(bid)

    # One retry pass for anything that failed — usually a transient pool death.
    if failed:
        print(f"retrying {len(failed)} failed book(s)…", flush=True)
        retry, failed = list(failed), []
        for bid in retry:
            try:
                _ocr_and_merge((bid, engine))
                print(f"  retry {bid} ok", flush=True)
            except Exception as exc:
                failed.append(bid)
                print(f"  retry {bid} FAILED: {type(exc).__name__}: {exc}", flush=True)

    print(f"\nDONE in {(time.time()-started)/60:.1f} min — "
          f"{total - len(failed)}/{total} books, {len(failed)} failed", flush=True)
    if failed:
        print("failed: " + ", ".join(failed), flush=True)
    # Re-apply the promotion rule across the whole library, not just this
    # run: books finished under an older threshold must follow the current one.
    repromote_all()
    report()


if __name__ == "__main__":
    main()
