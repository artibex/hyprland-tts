"""Tests for sentence splitting and chunk assembly (htts_split)."""

import pytest

import htts_split

# Texts that must stay one sentence, with their expected single piece.
NO_SPLIT_CASES = [
    "Am 3. Mai kam Dr. Meier z. B. nach Berlin.",
    "Das gilt u. a. für Äpfel, d. h. für Obst.",
    "Mr. Smith vs. Mrs. Jones, i.e. both, e.g. today.",
    "Das kostet 1.250,75 Euro und 3,5 % mehr.",
    "Version 3.14.8 ist da.",
    "A. B. Meier schrieb es.",
]


@pytest.mark.parametrize("text", NO_SPLIT_CASES)
def test_abbreviations_ordinals_and_numbers_do_not_end_sentences(text):
    """Abbreviations, initials, ordinals and decimals stay inside their sentence.

    Args:
        text: A sentence containing a period that must not split it.

    Returns:
        None.
    """
    # The whole text must come back as exactly one sentence.
    assert htts_split.split_sentences(text) == [text]


def test_real_sentence_ends_split_after_abbreviation_free_text():
    """Normal sentence ends split, including the next sentence's quote or bracket.

    Returns:
        None.
    """
    # Three sentences, one starting with a quote and one with an opening bracket.
    text = 'Es regnet. "Wirklich?" fragte er. (Ja.) Dann ging er.'
    assert len(htts_split.split_sentences(text)) == 4


def test_spanish_inverted_marks_start_new_sentences():
    """Spanish question and exclamation openers begin a new sentence.

    Returns:
        None.
    """
    # The period before the inverted mark is a real sentence end.
    assert len(htts_split.split_sentences("Mira esto. ¿Dónde está? Ahora.")) == 3


def test_every_line_break_is_a_hard_boundary():
    """Code lines are separated by newlines and must stay separate.

    Returns:
        None.
    """
    # Two lines without punctuation still give two sentences.
    assert htts_split.split_sentences("zeile eins\nzeile zwei") == ["zeile eins", "zeile zwei"]


def test_empty_text_gives_no_sentences():
    """Empty and whitespace-only input yields nothing.

    Returns:
        None.
    """
    # Neither the empty string nor blanks may produce a sentence.
    assert htts_split.split_sentences("") == []
    assert htts_split.split_sentences("  \n \n") == []


def test_short_first_sentence_stays_one_chunk():
    """A first sentence below the limit is not touched.

    Returns:
        None.
    """
    # Short text passes through unchanged.
    assert htts_split.build_chunks([("de", "Kurzer Satz.")]) == [("de", "Kurzer Satz.")]


def test_long_first_sentence_is_cut_at_a_clause_boundary():
    """A first sentence over 90 characters is cut at a comma, not mid-clause.

    Returns:
        None.
    """
    # The comma after "Garten" lies inside the first 90 characters.
    text = ("Wir sitzen heute im Garten und lesen ein Buch, während die Sonne scheint "
            "und die Vögel singen und der Wind weht.")
    chunks = htts_split.build_chunks([("de", text)])
    assert chunks[0][1].endswith("Buch,") and len(chunks[0][1]) <= htts_split.FIRST_CHUNK_LIMIT


def test_first_chunk_without_clause_boundary_is_cut_at_a_word():
    """Without commas the cut falls on a space within the limit.

    Returns:
        None.
    """
    # Forty words without any punctuation.
    text = " ".join(["wort"] * 40)
    first = htts_split.build_chunks([("de", text)])[0][1]
    assert len(first) <= htts_split.FIRST_CHUNK_LIMIT and not first.endswith(" ")


def test_later_chunks_never_exceed_the_chunk_limit():
    """Very long later sentences are wrapped to at most 220 characters.

    Returns:
        None.
    """
    # A 700-character sentence after a short first one.
    long_sentence = " ".join(["wort"] * 140)
    chunks = htts_split.build_chunks([("de", "Start."), ("de", long_sentence)])
    assert all(len(text) <= htts_split.MAX_CHUNK for _, text in chunks)


def test_short_neighbours_of_the_same_language_are_merged():
    """Short sentences join their predecessor but never the first chunk.

    Returns:
        None.
    """
    # "Ja." and "Nein." merge into the sentence before them; the first chunk stays alone.
    items = [("de", "Erster Satz."), ("de", "Zweiter etwas längerer Satz hier."),
             ("de", "Ja."), ("de", "Nein.")]
    assert htts_split.build_chunks(items) == [
        ("de", "Erster Satz."), ("de", "Zweiter etwas längerer Satz hier. Ja. Nein."),
    ]


def test_chunks_are_never_merged_across_languages():
    """A language change always starts a new chunk, even for tiny sentences.

    Returns:
        None.
    """
    # Alternating languages stay alternating.
    items = [("de", "Eins."), ("en", "Two."), ("de", "Drei."), ("en", "Four.")]
    assert [lang for lang, _ in htts_split.build_chunks(items)] == ["de", "en", "de", "en"]


def test_empty_and_punctuation_only_chunks_are_dropped():
    """Pieces without a letter or digit are never emitted.

    Returns:
        None.
    """
    # Only the middle item carries content.
    items = [("de", "..."), ("de", "Echt."), ("de", "—"), ("de", "   ")]
    assert htts_split.build_chunks(items) == [("de", "Echt.")]


def test_tabs_and_newlines_inside_chunks_become_spaces():
    """The line-based output format must never see tabs or newlines.

    Returns:
        None.
    """
    # Control whitespace is collapsed to single spaces.
    assert htts_split.build_chunks([("de", "a\tb\nc  d")]) == [("de", "a b c d")]


def test_symbol_before_a_period_still_ends_the_sentence():
    """A percent sign or euro sign is not an initial, so the sentence ends there.

    Returns:
        None.
    """
    # "12 %." and "5 €." end sentences; "A." (an initial) does not.
    assert len(htts_split.split_sentences("Es sind 12 %. Ciao a tutti, come state?")) == 2
    assert len(htts_split.split_sentences("Das kostet 5 €. Danach gehen wir heim.")) == 2


# CJK text with full-width punctuation and no spaces.
CJK_TEXT = "今天天气很好。我们去公园散步吧！你觉得怎么样？好的，那就出发。"


def test_cjk_sentence_ends_split_without_spaces():
    """Full-width terminators end sentences although no space follows them.

    Returns:
        None.
    """
    # Four sentences, each ending in its own full stop, exclamation or question mark.
    assert htts_split.split_sentences(CJK_TEXT) == [
        "今天天气很好。", "我们去公园散步吧！", "你觉得怎么样？", "好的，那就出发。"]


def test_cjk_closing_quote_stays_with_its_sentence():
    """A closing corner bracket after the full stop belongs to the sentence before.

    Returns:
        None.
    """
    # The bracket must not start the next sentence.
    assert htts_split.split_sentences("他说「走吧。」然后离开了。") == ["他说「走吧。」", "然后离开了。"]


def test_cjk_chunks_are_short_and_cut_at_commas():
    """A long CJK sentence without spaces is wrapped at full-width commas, never past 60.

    Returns:
        None.
    """
    # Twenty clauses of ten characters each form one 220-character sentence.
    text = "，".join(["这是一个很长的句子啊"] * 20) + "。"
    chunks = htts_split.build_chunks([("zh", text)])
    # Every chunk fits the CJK limit and no text is lost.
    assert all(len(chunk) <= htts_split.MAX_CHUNK_CJK for _, chunk in chunks)
    assert "".join(chunk for _, chunk in chunks) == text
    # The first chunk is short for a fast start and ends at a comma boundary.
    assert len(chunks[0][1]) <= htts_split.FIRST_CHUNK_LIMIT_CJK
    assert chunks[0][1].endswith("，")


def test_latin_limits_are_unchanged_for_latin_text():
    """Latin text keeps the 220-character chunk limit.

    Returns:
        None.
    """
    # A text of 200 characters in one sentence is not wrapped.
    sentence = ("word " * 40).strip() + "."
    assert htts_split.wrap_long(sentence) == [sentence]


def test_very_long_single_line_is_linear():
    """A 1 MB line without sentence ends is chunked in well under a few seconds.

    Returns:
        None.
    """
    import time
    # 200k words on one line used to take minutes (quadratic clause search).
    text = "wort " * 200_000
    started = time.perf_counter()
    chunks = htts_split.build_chunks([("de", text)])
    # Linear time: far below the old behaviour; the bound is generous for slow CI machines.
    assert time.perf_counter() - started < 8
    assert all(len(chunk) <= htts_split.MAX_CHUNK for _, chunk in chunks)


def test_long_line_with_many_sentences_is_linear():
    """100k short sentences on one line are split in reasonable time.

    Returns:
        None.
    """
    import time
    text = "Das ist ein Satz. " * 100_000
    started = time.perf_counter()
    sentences = htts_split.split_sentences(text)
    # Every sentence is found, in linear time.
    assert len(sentences) == 100_000
    assert time.perf_counter() - started < 8


def test_closing_quote_after_the_period_stays_with_its_sentence():
    """A closing quote or bracket after the final period is kept, not dropped.

    Returns:
        None.
    """
    # The quote used to vanish because the boundary match consumed it.
    assert htts_split.split_sentences('Er sagte "Hallo." Dann ging er. (Ja.) Ende.') == [
        'Er sagte "Hallo."', "Dann ging er.", "(Ja.)", "Ende."]
