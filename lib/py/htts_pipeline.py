"""Text preparation pipeline: markup clean-up, sentences, language labels, normalisation, chunks.

``prepare`` is the single entry point used by the command-line tool and by the tests. The
order is fixed by the data flow: markup must go first (it would confuse the classifier),
the language must be known before numbers are spoken (it decides the number format), and
chunking comes last because normalisation changes the text length.
"""

# Annotations stay lazy so no typing import is needed at runtime.
from __future__ import annotations

import htts_langid
import htts_markup
# Normalisation and chunk assembly run after labelling.
import htts_norm
import htts_split


def choose_default(allowed: tuple[str, ...], default_lang: str) -> str:
    """Pick the language used for text without evidence.

    Args:
        allowed: Allowed language codes.
        default_lang: Requested default (may be empty or not allowed).

    Returns:
        ``default_lang`` when it is allowed, else the first allowed language.
    """
    # A default outside the allow-list would break the output contract.
    return default_lang if default_lang in allowed else allowed[0]


def prepare(
    raw: str, allowed: tuple[str, ...], default_lang: str, scorer=None
) -> list[tuple[str, str]]:
    """Turn raw selected text into labelled, normalised chunks.

    Args:
        raw: Selected text as copied (may contain markdown and code).
        allowed: Languages that have a voice (validated codes).
        default_lang: Language for sentences without evidence.
        scorer: Optional scoring function replacing fastText (tests).

    Returns:
        ``(language, text)`` chunks ready for synthesis.

    Raises:
        htts_langid.LanguageModelUnavailable: If several languages are allowed but the
            classifier cannot be loaded.
    """
    # Markup goes first, then the text is cut into sentences.
    fallback = choose_default(allowed, default_lang)
    sentences = htts_split.split_sentences(htts_markup.normalize_text(raw))
    # Every sentence gets a language before any number is spoken.
    labels = htts_langid.label_sentences(sentences, allowed, fallback, scorer)
    spoken = [(lang, htts_norm.normalize(text, lang)) for lang, text in zip(labels, sentences)]
    # Chunking works on the final text because normalisation changes its length.
    return htts_split.build_chunks(spoken)


def detect(raw: str, allowed: tuple[str, ...], default_lang: str, scorer=None) -> str:
    """Return the dominant language of a text.

    Args:
        raw: Selected text.
        allowed: Languages that have a voice.
        default_lang: Returned when the text has no letters.
        scorer: Optional scoring function replacing fastText (tests).

    Returns:
        The language covering the most characters; ``default_lang`` for text without letters.
    """
    # Text without any letter has no language evidence: the caller's default (maybe "").
    if not any(char.isalpha() for char in raw):
        return default_lang
    fallback = choose_default(allowed, default_lang)
    # The same markup clean-up and sentence split as the main pipeline.
    sentences = htts_split.split_sentences(htts_markup.normalize_text(raw))
    # The heaviest language by characters wins.
    labels = htts_langid.label_sentences(sentences, allowed, fallback, scorer)
    return htts_langid.dominant_language(sentences, labels, fallback)
