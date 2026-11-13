"""Unit tests for the Arabic orthography rules (spec §10).

Run with:  py -3 -m pytest scripts/tests -q
       or: py -3 scripts/tests/test_arabic_rules.py
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import autocorrect as ac  # noqa: E402


class FinalYaTests(unittest.TestCase):
    """The «ى» → «ي» normaliser and its exception list."""

    def test_converts_final_ya_in_ordinary_words(self):
        for word, expected in [
            ("دورى", "دوري"),
            ("ثيابى", "ثيابي"),
            ("لى", "لي"),
            ("المورفولوجى", "المورفولوجي"),
            ("مصرى", "مصري"),
            ("كتابى", "كتابي"),
        ]:
            self.assertEqual(ac.normalize_final_ya(word), expected, word)

    def test_keeps_true_alif_maqsura(self):
        # These are spelled correctly with «ى» in every edition; changing them
        # would introduce misspellings, which the pipeline must never do.
        for word in [
            "على", "إلى", "حتى", "متى", "لدى", "سوى", "هدى", "مستشفى",
            "موسى", "عيسى", "يحيى", "كبرى", "صغرى", "أخرى", "أولى", "قصوى",
            "ذكرى", "معنى", "مبنى", "مدى", "ندى", "هوى", "ضحى", "أسى",
            "فتى", "مصطفى", "مرتضى", "ليلى", "سلمى", "عظمى", "دعوى", "فتوى",
        ]:
            self.assertEqual(ac.normalize_final_ya(word), word, word)

    def test_keeps_comparative_forms(self):
        # «أفعل» comparatives that genuinely end in alif maqsura. «بالأحرى»
        # was being rewritten to «بالأحري» in a real page before this guard.
        for word in [
            "أحرى", "أدنى", "أقوى", "أقصى", "أعلى", "أسمى", "أبقى",
            "أرقى", "أزكى", "أنقى", "أوفى", "شتى",
        ]:
            self.assertEqual(ac.normalize_final_ya(word), word, word)

    def test_prefixes_do_not_defeat_the_exception_list(self):
        # A proclitic must not turn a correct word into a misspelling.
        for word in [
            "بالأحرى", "والفتى", "كالمستشفى", "للهدى", "بالذكرى",
            "والأخرى", "فالمعنى", "للمدى", "بالهدى",
        ]:
            self.assertEqual(ac.normalize_final_ya(word), word, word)

    def test_prefix_on_a_ya_word_still_converts(self):
        # The prefix rule must not become a blanket exemption.
        for word, expected in [("بالبيت", "بالبيت"), ("ودورى", "ودوري")]:
            self.assertEqual(ac.normalize_final_ya(word), expected, word)

    def test_every_exception_is_actually_ending_in_ya(self):
        # Guards against a typo in the list silently disabling the protection.
        for word in ac.ALIF_MAQSURA_KEEP:
            self.assertTrue(
                word.endswith("ى"),
                f"{word!r} is in ALIF_MAQSURA_KEEP but does not end in ى",
            )

    def test_short_words(self):
        # A bare «ى» is not a word; a two-letter word ending in «ى» is a ya.
        self.assertEqual(ac.normalize_final_ya("ى"), "ى")
        self.assertEqual(ac.normalize_final_ya("بى"), "بي")

    def test_words_not_ending_in_ya_untouched(self):
        for word in ["كتاب", "بيت", "قال", "شيء"]:
            self.assertEqual(ac.normalize_final_ya(word), word)


class LexiconTests(unittest.TestCase):
    """Whole-token repair must be precise, never inventive."""

    def test_exact_word_fixes(self):
        self.assertEqual(ac.layer2_lexicon("الذى"), "الذي")
        self.assertEqual(ac.layer2_lexicon("هى"), "هي")
        self.assertEqual(ac.layer2_lexicon("هذة"), "هذه")
        self.assertEqual(ac.layer2_lexicon("الى"), "إلى")

    def test_single_substitution_repair(self):
        # «كانب» differs from «كانت» by one *confusable* letter (ب/ت).
        self.assertEqual(ac.layer2_lexicon("كانب"), "كانت")

    def test_non_confusable_letter_is_not_repaired(self):
        # «كانو» is one substitution from «كانت», but و/ت are never confused by
        # a scanner — repairing it would turn كانوا into كانت. Must be left.
        self.assertIsNone(ac._one_substitution("كانو"))

    def test_unknown_proper_noun_survives(self):
        for name in ["عبدالرحمن", "شهرزاد", "كهرومغناطيسي"]:
            self.assertEqual(ac.layer2_lexicon(name), name)


class GateTests(unittest.TestCase):
    """A page that changes too much must be rejected, not shown."""

    def test_light_correction_passes(self):
        raw = "نظرت إلى الدار ثم إلى السيارة ودخلت .."
        text, flags, ratio = ac.apply_safe(raw)
        self.assertEqual(flags, [])
        self.assertLessEqual(ratio, ac.MAX_EDIT_RATIO)

    def test_heavy_rewrite_is_rejected(self):
        raw = "قال الرجل إنه لن يعود إلى البيت مرة أخرى بعد اليوم"
        rewritten = "ذهب الشخص لأنه ما رجع للمنزل ثانية بعد هذا اليوم"
        text, flags, _ = ac.apply_safe(raw)
        self.assertEqual(flags, [])
        # The gates are what protect the author's wording: feed a rewrite in
        # directly and it must be refused.
        gated, gflags, _ = ac.gate(raw, rewritten)
        self.assertTrue(gflags)
        self.assertEqual(gated, raw)

    def test_digits_must_survive(self):
        raw = "في سنة 1945 حدث كذا"
        _, flags, _ = ac.gate(raw, "في سنة 1946 حدث كذا")
        self.assertIn("digits_changed", flags)

    def test_word_count_guard(self):
        raw = " ".join(["كلمة"] * 20)
        longer = raw + " " + " ".join(["زائدة"] * 5)
        _, flags, _ = ac.gate(raw, longer)
        self.assertTrue(any(f.startswith("word_delta") for f in flags))


class RuleLayerTests(unittest.TestCase):
    def test_verse_lines_are_not_merged(self):
        # Poetry: short lines ending in «..» must stay on separate lines.
        raw = "هنا لا توجد مياه وإنما يوجد صخر فقط ..\nصخر ولا مياه والطريق الرملى .."
        out = ac.layer1_rules(raw)
        self.assertEqual(len(out.split("\n")), 2)

    def test_scan_specks_removed(self):
        self.assertNotIn("|", ac.layer1_rules("نص عادي | نص"))
        # A lone letter on its own line is a speck of dust on the platen.
        self.assertEqual(ac.layer1_rules("ك\nس\n"), "")

    def test_separators_preserved(self):
        out = ac.layer1_rules("نص\n***\nنص")
        self.assertIn("***", out)

    def test_spaces_collapsed(self):
        self.assertEqual(ac.layer1_rules("كلمة    أخرى"), "كلمة أخرى")


if __name__ == "__main__":
    unittest.main(verbosity=2)
