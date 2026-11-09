"""Sentence splitting and chunk assembly for the text-to-speech pipeline.

Splitting is abbreviation-aware (``z. B.``, ``Dr.``, ordinal ``3.`` do not end a
sentence). Chunk assembly produces what the player wants: a short first chunk for a low
time-to-first-audio, sentence-sized chunks afterwards, very short neighbours of the same
language merged, never across languages and never empty.
"""

# Annotations stay lazy so no typing import is needed at runtime.
from __future__ import annotations

import re

# Longest first chunk (characters) before it is cut at a clause boundary.
FIRST_CHUNK_LIMIT = 90
# Shortest acceptable first-chunk piece, so "Ja," does not become a chunk of its own.
FIRST_CHUNK_MINIMUM = 25
# Chunks longer than this are wrapped at clause or word boundaries.
MAX_CHUNK = 220
# A sentence at most this long may be merged into its predecessor.
SHORT_SENTENCE = 50

# Abbreviations that never end a sentence (lowercase, trailing period removed).
NON_TERMINAL_ABBREVIATIONS = frozenset(
    "z.b d.h u.a o.ä bzw ca nr abs vgl bspw evtl ggf inkl zzgl dr prof hr fr mr mrs ms vs "
    "e.g i.e approx no st sr sra srta mme mlle abb str tel mio mrd sog max etc.p "
    "dott sig dra núm aprox pág pag".split()
)
# A boundary: sentence punctuation, closing quotes, whitespace, then a plausible start.
SENTENCE_BOUNDARY = re.compile(
    r"(?<=[.!?…])[\"'”»)\]]*\s+(?=[\"'“„«(\[]?[A-ZÀ-ÖØ-Þ¿¡0-9])"
)
# Clause boundaries usable for cutting long sentences (position after the punctuation).
CLAUSE_BOUNDARY = re.compile(r"(?<=[,;:])\s+|\s+(?=[–—-]\s)")
# Any alphanumeric character; chunks without one are never emitted.
HAS_CONTENT = re.compile(r"[^\W_]")


def ends_with_abbreviation(prefix: str) -> bool:
    """Tell whether the text before a period ends in an abbreviation, initial or ordinal.

    Args:
        prefix: Text up to and including the candidate sentence-ending period.

    Returns:
        True when splitting here would cut an abbreviation, initial or ordinal number.
    """
    # Examine the last whitespace-separated token without its trailing periods.
    tokens = prefix.split()
    last_token = tokens[-1].rstrip(".").lower() if tokens else ""
    # Single letters (initials) and one or two digit numbers (German ordinals) continue.
    is_initial = len(last_token) == 1 and last_token.isalpha()
    if is_initial or (last_token.isdigit() and len(last_token) <= 2):
        return True
    return last_token in NON_TERMINAL_ABBREVIATIONS


def split_line(line: str) -> list[str]:
    """Split one line into sentences.

    Args:
        line: Text without line breaks.

    Returns:
        Stripped, non-empty sentences.
    """
    # Cut at every boundary that does not follow an abbreviation.
    pieces: list[str] = []
    start = 0
    for match in SENTENCE_BOUNDARY.finditer(line):
        # A period after "z. B." or "3." continues the sentence.
        before = line[:match.start()]
        if before.endswith(".") and ends_with_abbreviation(before):
            continue
        # Everything before the boundary is one finished sentence.
        pieces.append(line[start:match.start()])
        start = match.end()
    # The remainder after the last boundary is the final sentence.
    pieces.append(line[start:])
    return [piece.strip() for piece in pieces if piece.strip()]


def split_sentences(text: str) -> list[str]:
    """Split text into sentences; every line break is a hard boundary.

    Args:
        text: Cleaned text (code lines are separated by newlines).

    Returns:
        Non-empty sentences in reading order.
    """
    # Lines are independent units, each split on its own.
    sentences: list[str] = []
    for line in text.split("\n"):
        sentences.extend(split_line(line))
    return sentences


def last_clause_cut(text: str, limit: int, minimum: int) -> int:
    """Find the best clause boundary inside the first ``limit`` characters.

    Args:
        text: The text to cut.
        limit: Largest allowed length of the first piece.
        minimum: Smallest allowed length of the first piece.

    Returns:
        Cut position, or 0 when no clause boundary qualifies.
    """
    # Prefer the last boundary that still fits into the limit.
    best = 0
    for match in CLAUSE_BOUNDARY.finditer(text):
        # Boundaries after the limit cannot be used.
        if match.start() > limit:
            break
        if match.start() >= minimum:
            # Remember the latest cut that still fits the limit.
            best = match.start()
    return best


def last_word_cut(text: str, limit: int) -> int:
    """Find the last space inside the first ``limit`` characters.

    Args:
        text: The text to cut.
        limit: Largest allowed length of the first piece.

    Returns:
        Cut position (hard cut at ``limit`` if the text has no space).
    """
    # A space is the next best place to cut after a clause boundary.
    position = text.rfind(" ", 0, limit + 1)
    return position if position > 0 else limit


def cut_once(text: str, limit: int, minimum: int) -> tuple[str, str]:
    """Cut text into a first piece of at most ``limit`` characters and the rest.

    Args:
        text: The text to cut (longer than ``limit``).
        limit: Largest allowed length of the first piece.
        minimum: Smallest length that is still a sensible first piece.

    Returns:
        The first piece and the stripped remainder.
    """
    # Clause boundaries are preferred, word boundaries are the fallback.
    cut = last_clause_cut(text, limit, minimum) or last_word_cut(text, limit)
    return text[:cut].strip(), text[cut:].strip()


def wrap_long(text: str, limit: int = MAX_CHUNK) -> list[str]:
    """Wrap a long sentence into pieces of at most ``limit`` characters.

    Args:
        text: One sentence.
        limit: Largest allowed piece length.

    Returns:
        One or more non-empty pieces.
    """
    # Keep cutting until the remainder fits.
    pieces: list[str] = []
    rest = text
    while len(rest) > limit:
        # Cut off a head piece and keep working on the rest.
        head, rest = cut_once(rest, limit, FIRST_CHUNK_MINIMUM)
        pieces.append(head)
    # The remainder is the last piece.
    pieces.append(rest)
    return [piece for piece in pieces if piece]


def split_first_chunk(text: str) -> list[str]:
    """Shorten the first sentence for a fast start of playback.

    Args:
        text: The first sentence.

    Returns:
        The sentence unchanged when short, else a short head and the remainder.
    """
    # Short sentences are already fast to synthesise.
    if len(text) <= FIRST_CHUNK_LIMIT:
        return [text]
    # Cut at a clause boundary (or word boundary) near the limit.
    head, rest = cut_once(text, FIRST_CHUNK_LIMIT, FIRST_CHUNK_MINIMUM)
    return [head, rest] if rest else [head]


def clean_chunk(text: str) -> str:
    """Make chunk text safe for the one-line ``lang<TAB>text`` format.

    Args:
        text: Chunk text.

    Returns:
        Text with tabs and line breaks replaced by single spaces.
    """
    # Control whitespace would break the line-based output format.
    return " ".join(text.split())


def expand_items(items: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Split the first item for fast start and wrap every long item.

    Args:
        items: ``(language, sentence)`` pairs in reading order.

    Returns:
        Pairs where every text fits the chunk limits.
    """
    # Only the very first sentence gets the short-first treatment.
    expanded: list[tuple[str, str]] = []
    for index, (lang, text) in enumerate(items):
        pieces = split_first_chunk(text) if index == 0 else [text]
        # Every piece may still be longer than the chunk limit.
        for piece in pieces:
            expanded.extend((lang, part) for part in wrap_long(piece))
    return expanded


def can_merge(previous: tuple[str, str], current: tuple[str, str], is_first: bool) -> bool:
    """Decide whether the current sentence may be appended to the previous chunk.

    Args:
        previous: The chunk built so far as ``(language, text)``.
        current: The next ``(language, sentence)``.
        is_first: True when the previous chunk is the (deliberately short) first chunk.

    Returns:
        True for a short sentence of the same language that still fits the chunk limit.
    """
    # The first chunk stays short and languages are never mixed in one chunk.
    if is_first or previous[0] != current[0]:
        return False
    # Only short sentences are glued on, and the result must fit the limit.
    return len(current[1]) <= SHORT_SENTENCE and len(previous[1]) + 1 + len(current[1]) <= MAX_CHUNK


def merge_short(items: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Merge very short same-language sentences into their predecessor.

    Args:
        items: Pairs from ``expand_items``.

    Returns:
        Merged pairs.
    """
    # Walk through the items, extending the last chunk when allowed.
    chunks: list[tuple[str, str]] = []
    for item in items:
        if chunks and can_merge(chunks[-1], item, len(chunks) == 1):
            # Glue the short sentence onto the previous chunk.
            chunks[-1] = (item[0], f"{chunks[-1][1]} {item[1]}")
        else:
            chunks.append(item)
    return chunks


def build_chunks(items: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Turn labelled sentences into the final list of speakable chunks.

    Args:
        items: ``(language, sentence)`` pairs in reading order.

    Returns:
        ``(language, text)`` chunks: first one short, none empty, no tabs or newlines.
    """
    # Normalise whitespace and drop pieces without any letter or digit.
    cleaned = [(lang, clean_chunk(text)) for lang, text in items]
    meaningful = [(lang, text) for lang, text in cleaned if HAS_CONTENT.search(text)]
    # Shorten the first sentence and wrap long ones; cutting can leave a piece of quotes only.
    pieces = [(lang, text) for lang, text in expand_items(meaningful) if HAS_CONTENT.search(text)]
    # Merge tiny neighbours of the same language.
    return merge_short(pieces)
