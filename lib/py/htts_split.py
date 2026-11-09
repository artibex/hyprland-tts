"""Sentence splitting and chunk assembly for the text-to-speech pipeline.

Splitting is abbreviation-aware (``z. B.``, ``Dr.``, ordinal ``3.`` do not end a
sentence). Chunk assembly produces what the player wants: a short first chunk for a low
time-to-first-audio, sentence-sized chunks afterwards, very short neighbours of the same
language merged, never across languages and never empty. When the first chunk will be
streamed (lib/stream.sh) it is long instead: streaming makes the first sound independent
of its length, and the audio it holds hides the render time of the chunk after it.
"""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

import re

# Longest first chunk (characters) when it is NOT streamed: the first sound only arrives when
# the whole chunk is rendered, so it is short (cut at a clause boundary beyond this).
FIRST_CHUNK_LIMIT = 90
# Longest first chunk when it IS streamed: the first sound no longer depends on its length,
# and the more audio chunk 0 holds the more time chunk 1 has to render (see CHUNK_RAMP).
STREAMED_FIRST_CHUNK_LIMIT = 200
# The same limits for Chinese, Japanese and Korean text, where one character is a syllable
# or word (about 4 characters per second), so the same count means far longer audio.
FIRST_CHUNK_LIMIT_CJK = 30
MAX_CHUNK_CJK = 60
# Share of CJK characters above which a text is treated as CJK.
CJK_SHARE = 0.4
# Window (characters) in front of a period that is searched for an abbreviation.
ABBREVIATION_WINDOW = 40
# Shortest acceptable first-chunk piece, so "Ja," does not become a chunk of its own.
FIRST_CHUNK_MINIMUM = 25
# Longest chunk at the end of the ramp; later chunks may be this long.
MAX_CHUNK = 220
# Longest chunk by position; the last value applies to all later chunks. Chunk n+1 renders
# while chunk n plays, so it must be ready in time: with a request overhead of ~1.1 s, ~0.68 s
# render time per audio second and ~15 characters per second,
# len_{n+1} <= (len_n - 16) / 0.68 (tests/py/test_split.py::test_ramp_*).
CHUNK_RAMP = (FIRST_CHUNK_LIMIT, 70, 78, 90, 105, 120, 140, 160, 185, MAX_CHUNK)
# The ramp for a streamed first chunk. The server is busy with chunk 0 until it has generated
# it (~0.6 s per audio second, while it plays for 1 s), so chunk 1 starts late and the gap
# before it is gap_1 = 0.8 * L1 - 0.38 * L0 + 0.2 s (L = audio seconds, ~15 characters per
# second). It stays below 0.7 s when len_1 <= 9 + 0.475 * len_0: chunk 1 = 70 characters
# needs a chunk 0 of >= 128 characters. The measured speech rate varies by +-20 % between
# renders of one text (16-21 characters/s), so the limit leaves a margin of 70 characters.
STREAMED_RAMP = (STREAMED_FIRST_CHUNK_LIMIT,) + CHUNK_RAMP[1:]
# One CJK character carries about three times the audio of a Latin one.
CJK_RAMP_DIVISOR = 3
# A chunk shorter than this is merged into a neighbour: every chunk costs ~1 s of request overhead.
MIN_FRAGMENT = 15
MIN_FRAGMENT_CJK = 5
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
    r"(?<=[.!?…])(?P<closers>[\"'”»)\]]*)\s+(?=[\"'“„«(\[]?[A-ZÀ-ÖØ-Þ¿¡0-9])"
)
# Clause boundaries usable for cutting long sentences (position after the punctuation);
# CJK commas need no following space.
CLAUSE_BOUNDARY = re.compile(r"(?<=[,;:])\s+|\s+(?=[–—-]\s)|(?<=[，、；：])")
# CJK sentence ends (full stops, exclamation and question marks); a closing quote or bracket
# that follows belongs to the sentence, and no space is needed afterwards.
CJK_SENTENCE_END = re.compile(r"(?<=[。！？｡])(?![」』）”’])\s*|(?<=[。！？｡][」』）”’])\s*")
# Han ideographs, kana, hangul and CJK punctuation.
CJK_CHARACTER = re.compile(
    r"[\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uff00-\uffef]"
)
# Any alphanumeric character; chunks without one are never emitted.
HAS_CONTENT = re.compile(r"[^\W_]")


def ends_with_abbreviation(prefix: str) -> bool:
    """Tell whether the text before a period ends in an abbreviation, initial or ordinal.

    Args:
        prefix: Text up to and including the candidate sentence-ending period.

    Returns:
        True when splitting here would cut an abbreviation, initial or ordinal number.
    """
    # Only the tail matters (abbreviations are short), which keeps long lines linear.
    tokens = prefix[-ABBREVIATION_WINDOW:].split()
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
        before = line[max(0, match.start() - ABBREVIATION_WINDOW):match.start()]
        if before.endswith(".") and ends_with_abbreviation(before):
            continue
        # The sentence keeps its closing quote or bracket; only the whitespace is dropped.
        pieces.append(line[start:match.end("closers")])
        start = match.end()
    # The remainder after the last boundary is the final sentence.
    pieces.append(line[start:])
    # CJK sentence ends need no space, so they are split in a second pass.
    cjk_pieces = [part for piece in pieces for part in CJK_SENTENCE_END.split(piece)]
    return [piece.strip() for piece in cjk_pieces if piece.strip()]


def is_cjk(text: str) -> bool:
    """Tell whether a text is mostly Chinese, Japanese or Korean.

    Args:
        text: Any text.

    Returns:
        True when CJK characters make up a large share of the non-space characters.
    """
    # Only a sample is counted, so a huge text costs no more than a short one.
    sample = "".join(text[:400].split())
    return bool(sample) and len(CJK_CHARACTER.findall(sample)) / len(sample) >= CJK_SHARE


def limit_at(position: int, cjk: bool, ramp: tuple[int, ...] = CHUNK_RAMP) -> int:
    """Return the longest chunk (characters) allowed at a chunk position.

    Args:
        position: Index of the chunk in the output (0 = the first chunk).
        cjk: True for Chinese, Japanese or Korean text.
        ramp: The limits by position (``CHUNK_RAMP``, or ``STREAMED_RAMP`` for a streamed
            first chunk).

    Returns:
        The ramp limit; for CJK text one third of it, at most ``MAX_CHUNK_CJK``.
    """
    # Positions beyond the ramp keep its last (largest) value.
    limit = ramp[min(position, len(ramp) - 1)]
    # CJK characters carry much more audio each, so their chunks must be shorter.
    return min(MAX_CHUNK_CJK, limit // CJK_RAMP_DIVISOR) if cjk else limit


def chunk_limit(text: str) -> int:
    """Return the longest chunk (characters) a text may reach at the end of the ramp.

    Args:
        text: The text that is about to be chunked.

    Returns:
        ``MAX_CHUNK_CJK`` for CJK text, else ``MAX_CHUNK``.
    """
    # The ceiling is the ramp's last step.
    return limit_at(len(CHUNK_RAMP), is_cjk(text))


def min_fragment(text: str) -> int:
    """Return the shortest chunk (characters) worth sending on its own.

    Args:
        text: Chunk text (decides between Latin and CJK scale).

    Returns:
        ``MIN_FRAGMENT_CJK`` for CJK text, else ``MIN_FRAGMENT``.
    """
    # One CJK character is about three Latin ones.
    return MIN_FRAGMENT_CJK if is_cjk(text) else MIN_FRAGMENT


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
    # Prefer the last boundary that still fits; only the window can contain one (linear time).
    best = 0
    for match in CLAUSE_BOUNDARY.finditer(text[:limit + 2]):
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


def wrap_with(text: str, limit_for) -> list[str]:
    """Wrap text into pieces that each fit their own limit.

    Args:
        text: One sentence.
        limit_for: Function from the piece index (0 = first piece) to its character limit.

    Returns:
        One or more non-empty pieces; no piece but a short sentence is a fragment.
    """
    # Keep cutting until the remainder fits the limit of the piece it would become.
    pieces: list[str] = []
    rest = text
    fragment = min_fragment(text)
    while len(rest) > limit_for(len(pieces)):
        # The cut moves left when the remainder would be a fragment (never shorter than needed).
        reach = min(limit_for(len(pieces)), len(rest) - fragment)
        head, rest = cut_once(rest, reach, min(FIRST_CHUNK_MINIMUM, reach // 3))
        pieces.append(head)
    # The remainder is the last piece.
    pieces.append(rest)
    return [piece for piece in pieces if piece]


def wrap_long(text: str, limit: int = 0) -> list[str]:
    """Wrap a long sentence into pieces of at most one fixed length.

    Args:
        text: One sentence.
        limit: Largest allowed piece length (0 = the ceiling that fits the script of the text).

    Returns:
        One or more non-empty pieces.
    """
    # Every piece gets the same limit.
    fixed = limit or chunk_limit(text)
    return wrap_with(text, lambda _index: fixed)


def wrap_ramped(text: str, position: int, ramp: tuple[int, ...] = CHUNK_RAMP) -> list[str]:
    """Wrap a sentence along the chunk ramp, starting at a chunk position.

    Args:
        text: One sentence.
        position: Index the first piece will have in the output.
        ramp: The limits by position.

    Returns:
        One or more non-empty pieces; piece ``i`` fits the limit of position ``position + i``.
    """
    # The ramp grows with every piece, so a long sentence starts small and ends large.
    cjk = is_cjk(text)
    return wrap_with(text, lambda index: limit_at(position + index, cjk, ramp))


def clean_chunk(text: str) -> str:
    """Make chunk text safe for the one-line ``lang<TAB>text`` format.

    Args:
        text: Chunk text.

    Returns:
        Text with tabs and line breaks replaced by single spaces.
    """
    # Control whitespace would break the line-based output format.
    return " ".join(text.split())


def long_first(ramp: tuple[int, ...]) -> bool:
    """Tell whether a ramp starts with the long first chunk of a streamed run.

    Args:
        ramp: The limits by position.

    Returns:
        True when chunk 0 may exceed the short, non-streamed first-chunk limit.
    """
    # The ramps differ in their first step only.
    return ramp[0] > FIRST_CHUNK_LIMIT


def can_join(
    chunks: list[tuple[str, str]], lang: str, sentence: str, ramp: tuple[int, ...] = CHUNK_RAMP
) -> bool:
    """Decide whether a sentence may be appended to the last chunk.

    Args:
        chunks: The chunks built so far as ``(language, text)``.
        lang: Language of the sentence.
        sentence: The next sentence.
        ramp: The limits by position.

    Returns:
        True for a sentence of the same language that still fits the limit of that chunk:
        short ones for later chunks, any for the long streamed first chunk.
    """
    # Nothing to join, a language change, or a short first chunk (it stays alone).
    first_only = len(chunks) == 1
    if not chunks or chunks[-1][0] != lang or (first_only and not long_first(ramp)):
        return False
    # The result must fit the ramp limit of the chunk it extends.
    previous = chunks[-1][1]
    merged_length = len(previous) + 1 + len(sentence)
    fits = merged_length <= limit_at(len(chunks) - 1, is_cjk(previous), ramp)
    # Later chunks only take short sentences; the long first chunk takes any that fits.
    return fits and (first_only or len(sentence) <= SHORT_SENTENCE)


def fill_first_chunk(
    chunks: list[tuple[str, str]], lang: str, sentence: str, ramp: tuple[int, ...]
) -> str:
    """Top up the long first chunk with the opening clauses of a sentence that does not fit.

    Args:
        chunks: The chunks built so far (the first one is extended in place).
        lang: Language of the sentence.
        sentence: A sentence that is too long to join the first chunk as a whole.
        ramp: The limits by position.

    Returns:
        The rest of the sentence (all of it when nothing was moved).
    """
    # Only a long first chunk of the same language is topped up.
    if len(chunks) != 1 or chunks[0][0] != lang or not long_first(ramp):
        return sentence
    # The cut stays inside the free room and leaves a remainder that is no fragment.
    first = chunks[0][1]
    room = limit_at(0, is_cjk(first), ramp) - len(first) - 1
    reach = min(room, len(sentence) - min_fragment(sentence))
    # No room, or no clause boundary in it, leaves the sentence for the next chunk.
    cut = last_clause_cut(sentence, reach, FIRST_CHUNK_MINIMUM) if reach > 0 else 0
    if not cut:
        return sentence
    # The clauses move up (a short first sentence is no reason for a long wait later).
    chunks[0] = (lang, f"{first} {sentence[:cut].strip()}")
    return sentence[cut:].strip()


def place_sentence(
    chunks: list[tuple[str, str]], lang: str, sentence: str, ramp: tuple[int, ...] = CHUNK_RAMP
) -> None:
    """Append one sentence to the chunk list, merged or wrapped along the ramp.

    Args:
        chunks: The chunks built so far (extended in place).
        lang: Language of the sentence.
        sentence: Cleaned sentence text.
        ramp: The limits by position.

    Returns:
        None.
    """
    # A neighbour that fits joins its predecessor instead of costing a request of its own.
    if can_join(chunks, lang, sentence, ramp):
        chunks[-1] = (lang, f"{chunks[-1][1]} {sentence}")
        return
    # Otherwise the long first chunk is topped up and the rest starts new chunks on the ramp.
    sentence = fill_first_chunk(chunks, lang, sentence, ramp)
    pieces = wrap_ramped(sentence, len(chunks), ramp)
    chunks.extend((lang, piece) for piece in pieces if HAS_CONTENT.search(piece))


def is_fragment(text: str) -> bool:
    """Tell whether a chunk is too short to be worth its own request.

    Args:
        text: Chunk text.

    Returns:
        True when the chunk is shorter than the fragment minimum of its script.
    """
    # The minimum is counted in characters of the chunk's own script.
    return len(text) < min_fragment(text)


def absorb_one(
    merged: list[tuple[str, str]], waiting: tuple[str, str] | None, lang: str, text: str
) -> tuple[str, str] | None:
    """Place one chunk: merge a fragment back or forward, else keep it.

    Args:
        merged: The output list so far (extended in place).
        waiting: A fragment waiting for its successor, or None.
        lang: Language of the chunk.
        text: Text of the chunk.

    Returns:
        The fragment that waits for the next chunk, or None.
    """
    # The waiting fragment goes in front of this chunk when the language is the same.
    if waiting is not None and waiting[0] == lang:
        text = f"{waiting[1]} {text}"
    elif waiting is not None:
        merged.append(waiting)
    # The first chunk is never extended, so only a later fragment is merged away.
    if not is_fragment(text) or not merged:
        merged.append((lang, text))
        return None
    # Back into the previous chunk of the same language (not into the first one)...
    if len(merged) >= 2 and merged[-1][0] == lang:
        merged[-1] = (lang, f"{merged[-1][1]} {text}")
        return None
    # ...otherwise it waits to be put in front of the next chunk.
    return (lang, text)


def absorb_fragments(chunks: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Merge chunks that are too short into a neighbour of the same language.

    Args:
        chunks: Chunks from the ramp assembly.

    Returns:
        Chunks where only the first one (and a lonely language island) can be a fragment.
    """
    # Every chunk is placed in turn; at most one fragment waits at any time.
    merged: list[tuple[str, str]] = []
    waiting: tuple[str, str] | None = None
    for lang, text in chunks:
        waiting = absorb_one(merged, waiting, lang, text)
    # A fragment at the very end without a partner stays as it is.
    return merged + ([waiting] if waiting is not None else [])


def build_chunks(items: list[tuple[str, str]], stream_first: bool = False) -> list[tuple[str, str]]:
    """Turn labelled sentences into the final list of speakable chunks.

    Args:
        items: ``(language, sentence)`` pairs in reading order.
        stream_first: True when chunk 0 will be streamed: it is then long (sentences merge
            into it) because its length no longer delays the first sound.

    Returns:
        ``(language, text)`` chunks: a short first one (a long one when streamed), then a
        growing ramp, none empty, no tabs or newlines, no fragments, languages never mixed.
    """
    # Normalise whitespace and drop pieces without any letter or digit.
    cleaned = [(lang, clean_chunk(text)) for lang, text in items]
    meaningful = [(lang, text) for lang, text in cleaned if HAS_CONTENT.search(text)]
    # Sentences are placed one after the other so that every chunk knows its ramp position.
    ramp = STREAMED_RAMP if stream_first else CHUNK_RAMP
    chunks: list[tuple[str, str]] = []
    for lang, sentence in meaningful:
        place_sentence(chunks, lang, sentence, ramp)
    # Tiny chunks are merged away last, when all positions are known.
    return absorb_fragments(chunks)
