"""Automatic Arabic correction for OCR output — no human review, ever.

Three layers run in order, exactly as specified:

1. **Rules** — whitespace, punctuation, OCR junk, rejoining broken prose lines.
   Deterministic and always applied.
2. **Lexicon** — high-precision spelling repair. Only whole-token substitutions
   against a curated list, plus the final «ى»/«ي» normalisation with its
   exception list. It never rewrites a token it does not recognise, so names,
   dialect words and quotations survive untouched.
3. **LLM** (optional) — contextual correction through an OpenAI-compatible
   endpoint. Off unless a key is configured.

Every corrected page then passes the **safety gates** in :func:`apply_safe`.
A page that trips a gate keeps its raw text and is displayed as its page image
by the app, so a bad correction can never reach the reader as prose.
"""

from __future__ import annotations

import difflib
import re

# ─── Arabic character classes ────────────────────────────────────────────────

TASHKEEL = "\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06ed"
TATWEEL = "\u0640"

# Arabic letters plus the punctuation a literary page actually uses.
ARABIC_LETTER = "\u0621-\u063a\u0641-\u064a\u066e-\u06d3"

RE_TASHKEEL = re.compile(f"[{TASHKEEL}]")
RE_TATWEEL = re.compile(TATWEEL)
RE_MULTISPACE = re.compile(r"[ \t\u00a0]+")
RE_SPACE_BEFORE_PUNCT = re.compile(r"\s+([،؛؟!.,:])")
RE_LATIN_JUNK = re.compile(r"[^\S\r\n]*[|_~`^<>\[\]{}©®°•]{1,}[^\S\r\n]*")
RE_ISOLATED_LETTER = re.compile(rf"(?<!\S)[{ARABIC_LETTER}](?!\S)")
RE_DIGITS = re.compile(r"[0-9\u0660-\u0669]+")
RE_TOKEN = re.compile(rf"[{ARABIC_LETTER}]+")

# ─── Layer 2: the exception list ─────────────────────────────────────────────

# Words that are *correct* Arabic but genuinely end in «ى» (alif maqsura).
# The normaliser must leave these exactly as printed — converting them would
# misspell the text, which is the one thing this pipeline must never do.
# The spec asks for unit tests over this list; see scripts/tests/.
ALIF_MAQSURA_KEEP: frozenset[str] = frozenset("""
على إلى حتى متى لدى سوى هدى مستشفى موسى عيسى يحيى
كبرى صغرى أخرى أولى قصوى حبلى سلوى نجوى بلوى دعوى فتوى تقوى
رؤى منى مدى ندى هوى ضحى أسى فتى معنى مبنى مصطفى مرتضى ذكرى
ليلى سلمى عظمى فضلى وسطى شتى ثرى قرى ردى طوى جوى
أحرى أدنى أقوى أقصى أعلى أسمى أبقى أرقى أزكى أنقى أوفى أرعى أهوى أوفى
""".split())

# Proclitics that may sit in front of a word without changing the fact that it
# ends in a genuine alif maqsura: «بالأحرى»، «والفتى»، «كالمستشفى». Longest
# first, so «وبال» wins over «و».
_PREFIXES: tuple[str, ...] = (
    "وبال", "وكال", "وفال", "بال", "كال", "فال", "وال", "لل", "ال",
    "و", "ف", "ب", "ك", "ل",
)

# Glyphs a scanner actually confuses, taken from the spec. A repair is only
# allowed when the differing letter sits in the same group — otherwise the
# corrector starts "fixing" real words (كانو → كانت instead of كانوا).
CONFUSION_GROUPS: tuple[frozenset[str], ...] = (
    frozenset("بتنثي"),
    frozenset("رز"),
    frozenset("دذ"),
    frozenset("عغ"),
    frozenset("فق"),
    frozenset("ةه"),
    frozenset("أإآا"),
    frozenset("سص"),
    frozenset("طظ"),
)


def _confusable(a: str, b: str) -> bool:
    return any(a in g and b in g for g in CONFUSION_GROUPS)

# Frequent OCR confusions, as whole-word fixes only. A token is replaced only
# when it matches *exactly*, which keeps precision at 100% and can never touch
# a proper noun that merely looks similar.
WORD_FIXES: dict[str, str] = {
    # ى / ي editions
    "الذى": "الذي", "التى": "التي", "هى": "هي", "هؤلا": "هؤلاء",
    "شئ": "شيء", "شىء": "شيء", "شئون": "شؤون", "مسئول": "مسؤول",
    "رئيسى": "رئيسي", "عربى": "عربي", "مصرى": "مصري", "وطنى": "وطني",
    # hamza forms
    "الى": "إلى", "ان": "أن", "انه": "أنه", "انها": "أنها", "انهم": "أنهم",
    "انا": "أنا", "اذا": "إذا", "اول": "أول", "الان": "الآن",
    "الا": "إلا", "اثناء": "أثناء", "امام": "أمام", "امس": "أمس",
    "انتم": "أنتم", "انت": "أنت", "او": "أو", "اى": "أي", "اي": "أي",
    "اين": "أين", "اكثر": "أكثر", "اقل": "أقل", "اخر": "آخر",
    "اخرى": "أخرى", "احد": "أحد", "اخي": "أخي", "ابي": "أبي",
    # ة / ه
    "هذة": "هذه", "هاذا": "هذا", "هذى": "هذه", "لاكن": "لكن",
    "عندة": "عنده", "فية": "فيه", "فى": "في",
    # broken words
    "إبن": "ابن", "إبنة": "ابنة", "إمرأة": "امرأة", "إمرأه": "امرأة",
    "إسم": "اسم", "إبنه": "ابنته",
}

# Small high-frequency lexicon used for the one-substitution repair. Kept
# deliberately tight: a correction may only *produce* one of these words.
LEXICON: frozenset[str] = frozenset("""
من في على إلى عن مع هذا هذه ذلك تلك التي الذي الذين كان كانت يكون تكون
قال قالت يقول تقول لم لن لا ما أن إن لكن ثم قد كل بعض غير بين بعد قبل
حتى عند عندما حيث هناك هنا أنا أنت أنتم هم هن هو هي نحن الله رب الناس
رجل امرأة ولد بنت بيت طريق يوم ليلة سنة شهر عالم حياة موت حب خوف فرح
حزن قلب عين يد رأس وجه صوت كلمة كلمات كتاب كتب صفحة صفحات الجزء الباب
الفصل قصة حكاية رواية أسطورة سلسلة شيء أشياء مكان زمان أرض سماء بحر نار
ماء هواء شمس قمر نجم يجعل تجعل جعل يصبح تصبح أصبح قالوا قلنا قلت له لها
لهم لنا لكم ولا ولم فلن فلم وكان وكانت وهذا وهذه ولكن فهو فهي واحد
""".split())

# Index by length so the repair only compares words of equal length — a single
# substitution can never change a word's length.
_lex_by_len: dict[int, list[str]] = {}
for _w in LEXICON:
    _lex_by_len.setdefault(len(_w), []).append(_w)
LEXICON_BY_LEN: dict[int, tuple[str, ...]] = {
    k: tuple(v) for k, v in _lex_by_len.items()
}

MIN_LEXICON_WORD_LEN = 4     # don't "repair" 2–3 letter tokens
MAX_EDIT_RATIO = 0.08
MAX_WORD_DELTA = 0.05

# A prose line is long; a verse line is short and usually ends with «..».
PROSE_LINE_MIN = 45


def strip_diacritics(text: str) -> str:
    """Remove tashkeel/tatweel — OCR emits them unreliably."""
    return RE_TASHKEEL.sub("", RE_TATWEEL.sub("", text))


def _keeps_maqsura(word: str) -> bool:
    """True when ``word`` ends in a genuine alif maqsura, prefixes included."""
    if word in ALIF_MAQSURA_KEEP:
        return True
    for pre in _PREFIXES:
        if word.startswith(pre) and len(word) - len(pre) >= 2:
            if word[len(pre):] in ALIF_MAQSURA_KEEP:
                return True
    return False


def normalize_final_ya(word: str) -> str:
    """Turn a word-final «ى» into «ي» unless it is a true alif maqsura."""
    # Two-letter words count: «لى» (لى/لي) is common in these editions and no
    # two-letter Arabic word ends in a genuine alif maqsura.
    if not word.endswith("ى") or len(word) < 2:
        return word
    if _keeps_maqsura(word):
        return word
    return word[:-1] + "ي"


def _one_substitution(token: str) -> str | None:
    """Return the unique lexicon word one letter away, else None.

    Restricting to same-length words with exactly one differing letter is what
    makes this safe: OCR's dominant error is a single misread glyph (ب/ت/ن/ث,
    ر/ز, د/ذ), while names and dialect words are simply not in the lexicon and
    therefore never rewritten.
    """
    if len(token) < MIN_LEXICON_WORD_LEN or token in LEXICON or not token.isalpha():
        return None
    hits: list[str] = []
    for w in LEXICON_BY_LEN.get(len(token), ()):
        diff = [(a, b) for a, b in zip(w, token) if a != b]
        if len(diff) == 1 and _confusable(*diff[0]):
            hits.append(w)
    return hits[0] if len(hits) == 1 else None


def layer1_rules(text: str) -> str:
    """Whitespace, punctuation, OCR junk and line reflow."""
    lines = [ln.strip() for ln in text.replace("\r", "").split("\n")]
    cleaned: list[str] = []
    for ln in lines:
        if not ln:
            cleaned.append("")
            continue
        ln = RE_LATIN_JUNK.sub(" ", ln)
        ln = RE_MULTISPACE.sub(" ", ln).strip()
        if not ln:
            continue
        # A single stray letter on its own line is a scan speck, not a word.
        if RE_ISOLATED_LETTER.fullmatch(ln):
            continue
        cleaned.append(ln)

    merged: list[str] = []
    for ln in cleaned:
        if not ln:
            if merged and merged[-1] != "":
                merged.append("")
            continue
        # Keep the author's own separators exactly as printed.
        if set(ln) <= {".", "*", "،", " "} and len(ln) <= 6:
            merged.append(ln)
            continue
        # Rejoin a line the scanner broke mid-sentence. Only prose qualifies:
        # the previous line must be full-width and must not end in punctuation
        # or in the «..» that marks a verse, otherwise poetry is destroyed.
        prev = merged[-1] if merged else ""
        if (
            prev
            and prev[-1] not in ".،:؛؟!*"
            and not prev.endswith("..")
            and len(prev) >= PROSE_LINE_MIN
            and not ln.startswith(("قال", "قالت", "-", "«", "*"))
        ):
            merged[-1] = prev + " " + ln
        else:
            merged.append(ln)

    text = "\n".join(merged)
    text = RE_SPACE_BEFORE_PUNCT.sub(r"\1", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def layer2_lexicon(text: str, normalize_ya: bool = True) -> str:
    """Whole-word fixes + final-yāʾ normalisation, token by token."""
    def fix(match: re.Match[str]) -> str:
        token = match.group(0)
        if token in WORD_FIXES:
            return WORD_FIXES[token]
        repaired = _one_substitution(token)
        if repaired:
            return repaired
        if normalize_ya:
            return normalize_final_ya(token)
        return token

    return RE_TOKEN.sub(fix, text)


# ─── Safety gates ────────────────────────────────────────────────────────────

def edit_ratio(raw: str, corrected: str) -> float:
    """Fraction of characters changed, 0..1."""
    if not raw:
        return 0.0
    sm = difflib.SequenceMatcher(None, raw, corrected, autojunk=False)
    return 1.0 - sm.ratio()


def word_delta(raw: str, corrected: str) -> float:
    """Change in the number of *words*.

    Counts Arabic-letter tokens only: a rule that moves a full stop (ودخلت ..
    → ودخلت..) must not look like a word was lost.
    """
    a, b = len(RE_TOKEN.findall(raw)), len(RE_TOKEN.findall(corrected))
    if a == 0:
        return 0.0 if b == 0 else 1.0
    return abs(b - a) / a


def digits_preserved(raw: str, corrected: str) -> bool:
    return sorted(RE_DIGITS.findall(raw)) == sorted(RE_DIGITS.findall(corrected))


def gate(
    raw: str,
    corrected: str,
    *,
    max_edit: float = MAX_EDIT_RATIO,
    max_word: float = MAX_WORD_DELTA,
) -> tuple[str, list[str], float]:
    """Validate an already-corrected page against the safety gates.

    Returns ``(text, flags, ratio)``; when ``flags`` is non-empty the caller
    must discard ``text`` and keep the raw page (shown as an image).
    """
    ratio = edit_ratio(raw, corrected)
    flags: list[str] = []
    if ratio > max_edit:
        flags.append(f"edit_ratio:{ratio:.3f}")
    delta = word_delta(raw, corrected)
    if delta > max_word:
        flags.append(f"word_delta:{delta:.3f}")
    if not digits_preserved(raw, corrected):
        flags.append("digits_changed")
    return (raw if flags else corrected), flags, ratio


def apply_safe(
    raw: str,
    *,
    normalize_ya: bool = True,
    max_edit: float = MAX_EDIT_RATIO,
    max_word: float = MAX_WORD_DELTA,
) -> tuple[str, list[str], float]:
    """Correct a page and enforce the gates.

    Returns ``(text, flags, ratio)``. When ``flags`` is non-empty the page was
    rejected: ``text`` is the untouched raw text and the app shows the page
    image instead, so nothing corrupted is ever displayed as prose.
    """
    if not raw.strip():
        return raw, ["empty"], 0.0

    corrected = layer1_rules(raw)
    corrected = layer2_lexicon(corrected, normalize_ya=normalize_ya)
    return gate(raw, corrected, max_edit=max_edit, max_word=max_word)


# ─── Layer 3: optional LLM ───────────────────────────────────────────────────

LLM_PROMPT = (
    "أنت مصحّح إملائي للنصوص العربية الناتجة عن OCR في كتب أدبية. صحّح فقط: "
    "أخطاء التعرف على الحروف، وأخطاء الهمزة، وكتابة الياء والألف المقصورة. "
    "لا تُعد صياغة أي جملة، ولا تضف كلمة أو تحذفها، ولا تغيّر علامات الترقيم "
    "والفواصل (.. و ***)، ولا الأسماء والأرقام والعبارات العامية والاقتباسات. "
    "أعد النص نفسه مصحَّحًا بالبنية نفسها (الفقرات والأسطر)، دون أي شرح أو تعليق."
)


def llm_correct(text: str, cfg: dict) -> str | None:
    """Correct one page through an OpenAI-compatible chat endpoint.

    Returns ``None`` when the layer is disabled, unconfigured or fails — the
    caller then keeps the rule/lexicon result, so the pipeline never depends on
    network availability.
    """
    import json
    import os
    import urllib.request

    if not cfg.get("llm_correction"):
        return None
    key = cfg.get("llm_api_key") or os.environ.get("ARRAB_LLM_KEY", "")
    if not key:
        return None
    if len(text) > int(cfg.get("llm_max_chars", 6000)):
        return None

    base = str(cfg.get("llm_base_url", "")).rstrip("/")
    body = json.dumps({
        "model": cfg.get("llm_model", "gpt-4o-mini"),
        "temperature": 0,
        "messages": [
            {"role": "system", "content": LLM_PROMPT},
            {"role": "user", "content": text},
        ],
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data["choices"][0]["message"]["content"].strip()
    except Exception:
        return None
