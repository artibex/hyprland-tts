"""Per-language text normalisation for a neural TTS engine that reads text literally.

``normalize(text, lang)`` rewrites one sentence so that numbers, currency, dates, times,
abbreviations, units, command lines and acronyms are spoken sensibly. The language must
be known first because it decides the number format (``1.250,75`` German, ``1,250.75``
English). Languages without a rule set (for example Dutch) only get a whitespace tidy-up.
"""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

import importlib
import re

# Stage modules of the normaliser.
import htts_norm_numbers
import htts_norm_tokens

# Languages that have a rule module (htts_lang_<code>.py).
RULE_LANGUAGES = frozenset({"de", "en", "fr", "es", "it"})
# Space left in front of punctuation by the expansion stages is removed again.
SPACE_BEFORE_PUNCTUATION = re.compile(r"\s+([.,;:!?])")
# Runs of blanks collapse to one space.
BLANK_RUN = re.compile(r"[ \t]+")


def load_rules(lang: str):
    """Load the rule module of a language.

    Args:
        lang: ISO 639-1 code.

    Returns:
        The rule module, or None for languages without rules.
    """
    # Only known codes are imported, never arbitrary module names.
    if lang not in RULE_LANGUAGES:
        return None
    return importlib.import_module(f"htts_lang_{lang}")


def tidy(text: str) -> str:
    """Collapse whitespace left behind by the expansion stages.

    Args:
        text: Rewritten sentence.

    Returns:
        Text with single spaces and no space before punctuation.
    """
    # Expansions add spaces around words; collapse them and trim the ends.
    collapsed = BLANK_RUN.sub(" ", text).strip()
    return SPACE_BEFORE_PUNCTUATION.sub(r"\1", collapsed)


def normalize(text: str, lang: str) -> str:
    """Normalise one sentence for speech in the given language.

    Args:
        text: One sentence (already stripped of markdown).
        lang: ISO 639-1 code of the sentence's language.

    Returns:
        The sentence with everything spoken out that a literal reader would garble.
    """
    # Languages without rules keep their text.
    rules = load_rules(lang)
    if rules is None:
        return tidy(text)
    # Abbreviations first; their pattern skips path segments such as "/etc".
    text = htts_norm_tokens.expand_abbreviations(text, rules)
    # Command lines next so path segments are not mistaken for numbers or dates.
    text = htts_norm_tokens.expand_command_line(text, rules)
    # Numbers, money, dates and times need the language's separators.
    text = htts_norm_numbers.expand_numeric(text, rules)
    # Leftover symbols and acronyms come last because earlier stages create capitals.
    text = htts_norm_tokens.expand_symbols(text, rules)
    return tidy(htts_norm_tokens.spell_acronyms(text))
