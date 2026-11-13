#!/usr/bin/env python3
"""
Build-time pipeline for Maktabat Al-Arrab (مكتبة العرّاب)
=========================================================

Processes PDF books by Dr. Ahmed Khaled Tawfik into structured JSON
with extracted/normalized Arabic text or high-quality page images.

Pipeline steps:
  1. Extract text via PyMuPDF
  2. Remove running headers & page numbers (repeated lines at top/bottom)
  3. Normalize Arabic text (NFKC) and rebuild paragraphs
  4. Calculate quality score; if below threshold -> convert to WebP images
  5. Generate per-book JSON (metadata, chapters, text or image paths)
  6. Generate cover from first page as WebP
  7. Generate library.json with categorized book list
  8. Print final report

Usage:
  python process_library.py --source "/path/to/pdfs" --output "./assets"
  python process_library.py --source "/path/to/pdfs" --output "./assets" --limit 3
"""

import argparse
import json
import os
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

try:
    import fitz  # PyMuPDF
except ImportError:
    print("ERROR: PyMuPDF is not installed. Run: pip install PyMuPDF Pillow")
    sys.exit(1)

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow is not installed. Run: pip install Pillow")
    sys.exit(1)


# ─── Constants ───────────────────────────────────────────────────────────────

QUALITY_THRESHOLD = 0.45       # Below this → book is "scanned/distorted" → image mode
MIN_TEXT_PER_PAGE = 50         # Minimum characters per page to count as "text page"
COVER_DPI = 150                # DPI for cover extraction
IMAGE_PAGE_DPI = 200           # DPI for image-based book pages
WEBP_QUALITY = 85              # WebP compression quality
MAX_HEADER_FOOTER_LINES = 3    # Lines to check at top/bottom of each page

# Series classification patterns
SERIES_PATTERNS = {
    "ma_wara_al_tabia": [
        "ما وراء الطبيعة",
        "ماوراء الطبيعة",
        "أسطور",          # all "أسطورة ..." books belong to this series
        "حكايات التاروت",
        "الرجل الذي يجمع كتب بو",
    ],
    "fantazia": [
        "فانتازيا",
        "ما أمام الطبيعة",
    ],
    "safari": [
        "سافاري",
        "سفاري",
    ],
}

# Books that belong to standalone novels (original works by Dr. Ahmed Khaled Tawfik)
STANDALONE_NOVELS = [
    "يوتوبيا", "YOUTUBIA", "أوتوبيا",
    "قصاصات قابلة للحرق",
    "7 باب", "سبعة باب",
    "7 وجوه للحب", "سبعة وجوه للحب",
    "زغازيغ",
    "شاي بالنعناع",
    "ضحكات كئيبة",
    "دماغي كده",
    "الآن أفهم",
    "عرض لا تستطيع رفضه",
    "تأثير الجرادة",
    "عقل بلا جسد",
    "مثل إيكاروس",
    "محامي الشوارع",
    "حظك اليوم",
    "خمنوا معي",
    "تلك المدينة",
    "عشاق الأدرينالين",
    "غرباء الأطوار",
    "هؤلاء النصابون",
    "مصر والجزائر",
    "حب في أغسطس",
    "ما وراء العالم",
    "قصص من أزيموف",
    "أكواريل",
    "الأبجدية",
    "قصتان",
    "7 وجوه",
]

# Books that are translations / non-fiction
TRANSLATION_KEYWORDS = [
    "1984", "451 فهرنهايت", "أليس في بلاد العجائب", "موبى ديك", "موبى ديك",
    "ساحر أوز", "لورد جيم", "قلب الظلام", "دوريان جراى", "كارميلا",
    "كلب آل باسكرفيل", "الرجل الخفي", "أوديسا الفضاء", "العالم المفقود",
    "جزيرة الدكتور مورو", "غريب في أرض غريبة", "الأفق المفقود", "ماتيلدا",
    "حكايات أوسكار وايلد", "حكايات اندرسن", "حكايات مارك توين", "قصص من أزيموف",
    "أمريكي في بلاط الملك", "نداء كتولو", "الرجل الذي كان الخميس",
    "عرض لا تستطيع رفضه", "تايبى", "كونغو", "مطار 77", "قطار الجحيم",
    "سباق الموت", "القتل بدون مقدم أتعاب", "المتلصص", "العميل", "الغريم الخفي",
    "الجزيرة الغامضة", "الجزيرة", "قبضة الشيطان الذهبية", "قلعة الأسرار",
    "قاعة المرايا", "في كهوف دراجوسان", "وادي العناكب", "وجاء العنكبوت",
    "لا تنظري الآن", "لقاءات من النوع الثالث", "مدينة مثل أليس",
    "ألف ليلة وليلة", "دكتور جيكل", "فرانكنشتاين", "سليبي هولو",
    "كتب الدم", "أفضل قصص الأشباح", "أغاني المهد", "دورة المذءوب",
    "السنجة", "الستار", "النطاق المسموم", "الغيبوبة", "العد الأخير",
    "الغرفة الحمراء", "الحزاز", "الأعماق", "رهيب", "عبقري آخر",
    "شيء من حتى", "ضحكات كئيبة", "صانع الأمطار", "حظك اليوم",
    "خمنوا معي", "دماغي كده", "تأثير الجرادة", "رحيق الملكات", "شاي بالنعناع",
    "زغازيغ", "تويتات من العصور الوسطى", "هؤلاء النصابون", "مصر والجزائر",
    "عشاق الأدرينالين", "عقل بلا جسد", "غرباء الأطوار", "تلك المدينة",
    "ما وراء العالم", "مثل إيكاروس", "محامي الشوارع", "الآن أفهم",
    "الأبجدية", "الجزيرة", "عالي", "أكواريل", "حب في أغسطس",
]


# ─── Text Processing ─────────────────────────────────────────────────────────

def normalize_arabic(text: str) -> str:
    """NFKC normalization + Arabic-specific fixes."""
    if not text:
        return ""
    # NFKC: fixes presentation forms (connected/disconnected letters)
    text = unicodedata.normalize("NFKC", text)
    # Remove zero-width characters
    text = re.sub(r'[\u200b\u200c\u200d\ufeff]', '', text)
    # Fix reversed parentheses/brackets (common in badly extracted RTL text)
    text = text.replace('(', '﴾').replace(')', '﴿')
    text = text.replace('﴾', '(').replace('﴿', ')')
    # Normalize multiple spaces
    text = re.sub(r'[ \t]+', ' ', text)
    # Normalize Arabic-Indic and extended Arabic-Indic digits to ASCII
    arabic_indic = '٠١٢٣٤٥٦٧٨٩'
    ext_arabic = '۰۱۲۳۴۵۶۷۸۹'
    for i, d in enumerate(arabic_indic):
        text = text.replace(d, str(i))
    for i, d in enumerate(ext_arabic):
        text = text.replace(d, str(i))
    return text.strip()


def rebuild_paragraphs(text: str) -> str:
    """Rebuild paragraphs from line-broken extracted text."""
    if not text:
        return ""
    lines = text.split('\n')
    result = []
    current_para = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            # Empty line → paragraph break
            if current_para:
                result.append(' '.join(current_para))
                current_para = []
        elif len(stripped) < 3:
            # Very short line → likely a page number or artifact, skip
            continue
        else:
            current_para.append(stripped)

    if current_para:
        result.append(' '.join(current_para))

    return '\n\n'.join(result)


def detect_running_headers_footers(pages_text: list) -> set:
    """Detect repeated header/footer lines across pages."""
    if len(pages_text) < 3:
        return set()

    # Collect first N and last N lines from each page
    top_lines = []
    bottom_lines = []

    for page_text in pages_text:
        lines = [l.strip() for l in page_text.split('\n') if l.strip()]
        if lines:
            for i in range(min(MAX_HEADER_FOOTER_LINES, len(lines))):
                top_lines.append(lines[i])
            for i in range(min(MAX_HEADER_FOOTER_LINES, len(lines))):
                idx = len(lines) - 1 - i
                if idx >= 0:
                    bottom_lines.append(lines[idx])

    # Find lines that appear on >40% of pages
    threshold = max(2, len(pages_text) * 0.4)
    top_counter = Counter(top_lines)
    bottom_counter = Counter(bottom_lines)

    noise_lines = set()
    for line, count in top_counter.items():
        if count >= threshold and len(line) < 80:
            noise_lines.add(line)
    for line, count in bottom_counter.items():
        if count >= threshold and len(line) < 80:
            noise_lines.add(line)

    # Also detect pure-number lines (page numbers)
    for line in top_lines + bottom_lines:
        if re.match(r'^\d{1,4}$', line.strip()):
            noise_lines.add(line.strip())

    return noise_lines


def clean_page_text(text: str, noise_lines: set) -> str:
    """Remove running headers/footers and page numbers from a page."""
    if not text:
        return ""
    lines = text.split('\n')
    cleaned = []
    for line in lines:
        stripped = line.strip()
        if stripped in noise_lines:
            continue
        if re.match(r'^\s*\d{1,4}\s*$', stripped):
            continue
        cleaned.append(line)
    return '\n'.join(cleaned)


def calculate_quality(pages_text: list) -> float:
    """
    Calculate text quality score (0.0 to 1.0).
    Low score → book is likely scanned/distorted → use image mode.
    """
    if not pages_text:
        return 0.0

    total_chars = 0
    text_pages = 0
    arabic_chars = 0

    for page_text in pages_text:
        if not page_text:
            continue
        chars = len(page_text.strip())
        total_chars += chars
        if chars >= MIN_TEXT_PER_PAGE:
            text_pages += 1
        # Count Arabic letters
        arabic_chars += sum(1 for c in page_text if '\u0600' <= c <= '\u06FF')

    avg_chars = total_chars / len(pages_text) if pages_text else 0
    text_ratio = text_pages / len(pages_text) if pages_text else 0

    # Arabic letter ratio (of all non-whitespace chars)
    non_ws = sum(1 for pt in pages_text for c in pt if not c.isspace())
    arabic_ratio = arabic_chars / non_ws if non_ws > 0 else 0

    # Weighted score
    score = (text_ratio * 0.4) + (min(avg_chars / 500, 1.0) * 0.3) + (arabic_ratio * 0.3)
    return round(score, 3)


def split_chapters(text: str) -> list:
    """Attempt to split text into chapters by common Arabic chapter markers."""
    if not text:
        return [{"title": "الكتاب كامل", "text": ""}]

    # Common chapter heading patterns in Arabic books
    patterns = [
        r'(?:^|\n)\s*(الفصل\s+\S+.*)',
        r'(?:^|\n)\s*(الباب\s+\S+.*)',
        r'(?:^|\n)\s*(الجزء\s+\S+.*)',
    ]

    for pattern in patterns:
        matches = list(re.finditer(pattern, text))
        if len(matches) >= 2:
            chapters = []
            for i, match in enumerate(matches):
                start = match.start()
                end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
                title = match.group(1).strip()
                chapter_text = text[start:end].strip()
                chapters.append({"title": title, "text": chapter_text})
            return chapters

    # No chapter markers found → single chapter
    return [{"title": "الكتاب كامل", "text": text}]


# ─── PDF Processing ──────────────────────────────────────────────────────────

def extract_cover(pdf_path: str, output_path: str) -> bool:
    """Extract cover from first page as WebP."""
    try:
        doc = fitz.open(pdf_path)
        if len(doc) == 0:
            return False
        page = doc[0]
        mat = fitz.Matrix(COVER_DPI / 72, COVER_DPI / 72)
        pix = page.get_pixmap(matrix=mat)
        img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
        # Resize to reasonable cover dimensions (keep aspect ratio)
        max_width = 600
        if img.width > max_width:
            ratio = max_width / img.width
            img = img.resize((max_width, int(img.height * ratio)), Image.LANCZOS)
        img.save(output_path, "WEBP", quality=WEBP_QUALITY)
        doc.close()
        return True
    except Exception as e:
        print(f"  WARNING: Cover extraction failed for {pdf_path}: {e}")
        return False


def convert_to_images(pdf_path: str, output_dir: str, book_id: str) -> list:
    """Convert all PDF pages to WebP images (for scanned/distorted books)."""
    images = []
    try:
        doc = fitz.open(pdf_path)
        for i in range(len(doc)):
            page = doc[i]
            mat = fitz.Matrix(IMAGE_PAGE_DPI / 72, IMAGE_PAGE_DPI / 72)
            pix = page.get_pixmap(matrix=mat)
            img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
            # Resize for performance
            max_width = 1200
            if img.width > max_width:
                ratio = max_width / img.width
                img = img.resize((max_width, int(img.height * ratio)), Image.LANCZOS)
            img_path = os.path.join(output_dir, f"{book_id}_page_{i:04d}.webp")
            img.save(img_path, "WEBP", quality=WEBP_QUALITY)
            images.append(f"books/{book_id}_page_{i:04d}.webp")
        doc.close()
    except Exception as e:
        print(f"  ERROR: Image conversion failed for {pdf_path}: {e}")
    return images


def process_pdf(pdf_path: str, book_id: str, output_dir: str, covers_dir: str) -> dict:
    """Process a single PDF and return its JSON data."""
    filename = os.path.basename(pdf_path)
    print(f"\n{'─' * 60}")
    print(f"Processing: {filename}")

    # Extract cover
    cover_path = os.path.join(covers_dir, f"{book_id}.webp")
    has_cover = extract_cover(pdf_path, cover_path)
    cover_asset = f"covers/{book_id}.webp" if has_cover else None

    # Extract text from all pages
    doc = fitz.open(pdf_path)
    page_count = len(doc)
    raw_pages = []

    for i in range(page_count):
        page = doc[i]
        text = page.get_text("text")
        raw_pages.append(text or "")
    doc.close()

    # Detect and remove running headers/footers
    noise_lines = detect_running_headers_footers(raw_pages)
    if noise_lines:
        print(f"  Removed {len(noise_lines)} header/footer patterns")

    cleaned_pages = [clean_page_text(pt, noise_lines) for pt in raw_pages]

    # Normalize Arabic text
    normalized_pages = [normalize_arabic(pt) for pt in cleaned_pages]

    # Calculate quality score
    quality = calculate_quality(normalized_pages)
    print(f"  Quality score: {quality:.3f} (threshold: {QUALITY_THRESHOLD})")

    # Extract title from filename
    title = extract_title_from_filename(filename)

    book_data = {
        "id": book_id,
        "title": title,
        "original_filename": filename,
        "page_count": page_count,
        "cover": cover_asset,
        "quality_score": quality,
        "content_mode": "text" if quality >= QUALITY_THRESHOLD else "image",
    }

    if quality >= QUALITY_THRESHOLD:
        # Text mode: rebuild paragraphs and split chapters
        full_text = '\n'.join(normalized_pages)
        full_text = rebuild_paragraphs(full_text)
        chapters = split_chapters(full_text)
        book_data["chapters"] = chapters
        book_data["images"] = []
        print(f"  → Text mode: {len(chapters)} chapter(s), {len(full_text)} chars")
    else:
        # Image mode: convert pages to WebP
        images = convert_to_images(pdf_path, output_dir, book_id)
        book_data["chapters"] = []
        book_data["images"] = images
        print(f"  → Image mode: {len(images)} page images")

    return book_data


def extract_title_from_filename(filename: str) -> str:
    """Extract a clean book title from the PDF filename."""
    # Remove extension
    title = os.path.splitext(filename)[0]
    # Remove "كتاب " prefix
    title = re.sub(r'^كتاب\s+', '', title)
    # Remove series suffix patterns
    title = re.sub(r'\s*-\s*سلسلة\s+[^.]+$', '', title)
    title = re.sub(r'\s*-\s*سلسلة\s+\S+$', '', title)
    # Remove Foulabook patterns
    title = re.sub(r'_\d+_Foulabook\.com_*', '', title)
    title = re.sub(r'_Foulabook\.com_*', '', title)
    # Remove "تحميل كتاب " prefix
    title = re.sub(r'^تحميل\s+كتاب\s+', '', title)
    # Remove .crdownload suffix if any
    title = title.replace('.crdownload', '')
    # Clean up extra whitespace
    title = title.strip()
    return title


def classify_series(filename: str) -> str:
    """Classify book into a series based on filename."""
    for series, patterns in SERIES_PATTERNS.items():
        for pattern in patterns:
            if pattern in filename:
                return series

    # Check standalone novels
    for keyword in STANDALONE_NOVELS:
        if keyword in filename:
            return "standalone_novels"

    # Check translations
    for keyword in TRANSLATION_KEYWORDS:
        if keyword in filename:
            return "translations"

    # Default to translations (most unmatched books are world literature)
    return "translations"


def generate_book_id(filename: str, index: int) -> str:
    """Generate a safe book ID from filename."""
    # Use index + simplified title
    title = extract_title_from_filename(filename)
    # Create slug from Arabic text (keep Arabic, remove special chars)
    slug = re.sub(r'[^\u0600-\u06FF\u0750-\u077F0-9a-zA-Z]', '_', title)
    slug = re.sub(r'_+', '_', slug).strip('_')[:40]
    return f"book_{index:03d}_{slug}"


# ─── Main Pipeline ───────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Process PDF library for Maktabat Al-Arrab")
    parser.add_argument("--source", required=True, help="Source directory containing PDF files")
    parser.add_argument("--output", default="./assets", help="Output directory for processed assets")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of books (0 = all)")
    parser.add_argument("--report", default="./processing_report.json", help="Path for processing report")
    args = parser.parse_args()

    source_dir = Path(args.source).resolve()
    output_dir = Path(args.output).resolve()
    covers_dir = output_dir / "covers"
    books_dir = output_dir / "books"

    if not source_dir.exists():
        print(f"ERROR: Source directory not found: {source_dir}")
        sys.exit(1)

    # Create output directories
    covers_dir.mkdir(parents=True, exist_ok=True)
    books_dir.mkdir(parents=True, exist_ok=True)
    # Book JSONs go in a subdirectory for clean asset bundling
    book_jsons_dir = output_dir / "book_jsons"
    book_jsons_dir.mkdir(parents=True, exist_ok=True)

    # Find all PDF files
    pdf_files = sorted([
        f for f in source_dir.iterdir()
        if f.suffix.lower() in ('.pdf',) and f.is_file()
    ])

    # Filter out .crdownload files
    pdf_files = [f for f in pdf_files if '.crdownload' not in f.name]

    if args.limit > 0:
        pdf_files = pdf_files[:args.limit]

    print(f"╔══════════════════════════════════════════════════════════╗")
    print(f"║  مكتبة العرّاب — Build-time Processing Pipeline          ║")
    print(f"╚══════════════════════════════════════════════════════════╝")
    print(f"\nSource: {source_dir}")
    print(f"Output: {output_dir}")
    print(f"Found {len(pdf_files)} PDF files to process\n")

    all_books = []
    text_mode_books = []
    image_mode_books = []
    failed_books = []
    series_map = {
        "ma_wara_al_tabia": [],
        "fantazia": [],
        "safari": [],
        "standalone_novels": [],
        "translations": [],
    }

    for i, pdf_path in enumerate(pdf_files):
        book_id = generate_book_id(pdf_path.name, i)
        series = classify_series(pdf_path.name)

        try:
            book_data = process_pdf(str(pdf_path), book_id, str(books_dir), str(covers_dir))
            book_data["series"] = series
            all_books.append(book_data)
            series_map[series].append(book_data["id"])

            if book_data["content_mode"] == "text":
                text_mode_books.append(book_data["title"])
            else:
                image_mode_books.append(book_data["title"])

            # Save individual book JSON
            book_json_path = book_jsons_dir / f"{book_id}.json"
            with open(book_json_path, 'w', encoding='utf-8') as f:
                json.dump(book_data, f, ensure_ascii=False, indent=2)

        except Exception as e:
            print(f"  ERROR: Failed to process {pdf_path.name}: {e}")
            failed_books.append({"filename": pdf_path.name, "error": str(e)})

    # Generate library.json
    library_data = {
        "version": "1.0.0",
        "app_name": "مكتبة العرّاب",
        "author": "د. أحمد خالد توفيق",
        "sections": [
            {
                "id": "ma_wara_al_tabia",
                "title": "ما وراء الطبيعة",
                "subtitle": "سلسلة الرعب والخيال العلمي",
                "color_accent": "#8B1E2D",
                "icon": "moon",
            },
            {
                "id": "fantazia",
                "title": "فانتازيا",
                "subtitle": "سلسلة الخيال التاريخي",
                "color_accent": "#4A7C59",
                "icon": "castle",
            },
            {
                "id": "safari",
                "title": "سافاري",
                "subtitle": "سلسلة الرحلات والمغامرات",
                "color_accent": "#8B6914",
                "icon": "compass",
            },
            {
                "id": "standalone_novels",
                "title": "روايات منفردة",
                "subtitle": "روايات د. أحمد خالد توفيق",
                "color_accent": "#6B3FA0",
                "icon": "book",
            },
            {
                "id": "translations",
                "title": "ترجمات وكتب غير روائية",
                "subtitle": "من أدب العالم",
                "color_accent": "#2C5F7F",
                "icon": "globe",
            },
        ],
        "books": [
            {
                "id": b["id"],
                "title": b["title"],
                "series": b["series"],
                "page_count": b["page_count"],
                "cover": b["cover"],
                "content_mode": b["content_mode"],
                "quality_score": b["quality_score"],
                "json_file": f"book_jsons/{b['id']}.json",
            }
            for b in all_books
        ],
    }

    library_path = output_dir / "library.json"
    with open(library_path, 'w', encoding='utf-8') as f:
        json.dump(library_data, f, ensure_ascii=False, indent=2)

    # Generate report
    report = {
        "total_books": len(all_books),
        "text_mode_count": len(text_mode_books),
        "image_mode_count": len(image_mode_books),
        "failed_count": len(failed_books),
        "series_counts": {k: len(v) for k, v in series_map.items()},
        "text_mode_books": text_mode_books,
        "image_mode_books": image_mode_books,
        "failed_books": failed_books,
    }

    report_path = Path(args.report)
    with open(report_path, 'w', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    # Print summary
    print(f"\n{'═' * 60}")
    print(f"  PROCESSING COMPLETE")
    print(f"{'═' * 60}")
    print(f"  Total books processed:  {len(all_books)}")
    print(f"  Text mode (extracted):  {len(text_mode_books)}")
    print(f"  Image mode (scanned):   {len(image_mode_books)}")
    print(f"  Failed:                 {len(failed_books)}")
    print(f"\n  Series breakdown:")
    for series_id, book_ids in series_map.items():
        print(f"    {series_id:25s}: {len(book_ids)} books")
    print(f"\n  Output files:")
    print(f"    library.json:          {library_path}")
    print(f"    Processing report:     {report_path}")
    print(f"    Book JSONs:            {output_dir}/*.json")
    print(f"    Covers:                {covers_dir}/*.webp")
    print(f"    Page images:           {books_dir}/*.webp")
    print(f"\n{'═' * 60}\n")


if __name__ == "__main__":
    main()
