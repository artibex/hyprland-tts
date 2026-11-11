"""Robustness tests: random hostile input must never crash the pipeline or break the contract."""

import random

# Modules under test.
import htts_norm
import htts_pipeline
# The content pattern defines what a speakable chunk is.
import htts_split

# Characters that stress the rules: digits, separators, symbols, markup, unicode, whitespace.
ALPHABET = list("abcXYZäöüß0123456789 .,:;!?-–—/\\~$€£%&()[]{}<>=|*#`'\"\t\n\u00a0日本語✓")
# Language codes that have rule sets plus one without.
LANGUAGES = ["de", "en", "fr", "es", "it", "nl"]


def flat_scorer(text, allowed):
    """Return a uniform distribution so the tests need no model.

    Args:
        text: Ignored.
        allowed: Allowed language codes.

    Returns:
        Equal probability for every allowed language.
    """
    # Uniform scores make the smoothing fall back to the default language.
    return {lang: 1 / len(allowed) for lang in allowed}


def random_texts(count, seed):
    """Generate reproducible random texts from the stress alphabet.

    Args:
        count: Number of texts.
        seed: Random seed.

    Returns:
        List of strings of 0-300 characters.
    """
    # A seeded generator keeps failures reproducible.
    generator = random.Random(seed)
    return ["".join(generator.choice(ALPHABET) for _ in range(generator.randint(0, 300)))
            for _ in range(count)]


def test_pipeline_never_crashes_and_keeps_the_contract():
    """Random input yields chunks without tabs, newlines or empty content.

    Returns:
        None.
    """
    # Every chunk must be a one-line string with at least one letter or digit.
    for text in random_texts(400, seed=1):
        chunks = htts_pipeline.prepare(text, ("de", "en"), "de", scorer=flat_scorer)
        for lang, chunk in chunks:
            assert lang in ("de", "en")
            # The line format forbids tabs and newlines; empty chunks are never allowed.
            assert "\t" not in chunk and "\n" not in chunk
            assert htts_split.HAS_CONTENT.search(chunk)


def test_normalizer_never_crashes_for_any_language():
    """Random sentences normalise without exceptions in every language.

    Returns:
        None.
    """
    # Cycle through the languages so every rule set sees hostile input.
    for index, text in enumerate(random_texts(600, seed=2)):
        assert isinstance(htts_norm.normalize(text, LANGUAGES[index % len(LANGUAGES)]), str)


def test_huge_numbers_and_odd_dates_do_not_crash():
    """Very large numbers, impossible dates and times stay readable or unchanged.

    Returns:
        None.
    """
    # None of these may raise; impossible dates and times stay as written.
    for text in ["9" * 400, "31.02.2026", "99:99", "13/13/2026", "0.0.0", "1e5", "٣٤٥"]:
        for lang in LANGUAGES:
            assert isinstance(htts_norm.normalize(text, lang), str)
