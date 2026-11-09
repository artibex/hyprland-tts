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


# Measured model of the Vulkan engine (Radeon 680M): seconds of fixed cost per request,
# render seconds per audio second, and spoken characters per second.
REQUEST_OVERHEAD_SECONDS = 1.1
RENDER_SECONDS_PER_AUDIO_SECOND = 0.68
SPEECH_RATE = 15.0


def render_seconds(characters):
    """Estimate how long the engine needs for a chunk.

    Args:
        characters: Length of the chunk text.

    Returns:
        Seconds from the request to the finished file.
    """
    # Fixed request cost plus the render time of the audio the text produces.
    audio = characters / SPEECH_RATE
    return REQUEST_OVERHEAD_SECONDS + RENDER_SECONDS_PER_AUDIO_SECOND * audio


def words_text(sentence_count, words=12):
    """Build a text of identical comma-free sentences.

    Args:
        sentence_count: Number of sentences.
        words: Words per sentence.

    Returns:
        List of (language, sentence) items.
    """
    # Distinct words keep the sentences readable in a failure message.
    return [("en", " ".join(f"w{number}x{index}" for index in range(words)) + ".")
            for number in range(sentence_count)]


def test_ramp_starts_at_the_first_chunk_limit_and_ends_at_the_ceiling():
    """The ramp begins with the streamed chunk's limit and ends at the old maximum.

    Returns:
        None.
    """
    # The first value is the unchanged 90, the last the unchanged 220.
    assert htts_split.CHUNK_RAMP[0] == htts_split.FIRST_CHUNK_LIMIT == 90
    assert htts_split.CHUNK_RAMP[-1] == htts_split.MAX_CHUNK == 220
    # After chunk 0 the limits never shrink and every one is a positive integer.
    later = htts_split.CHUNK_RAMP[1:]
    assert list(later) == sorted(later) and all(isinstance(limit, int) for limit in later)


def test_ramp_steps_are_ready_before_the_previous_chunk_has_finished_playing():
    """From chunk 1 on, rendering chunk n+1 takes less time than chunk n plays.

    Returns:
        None.
    """
    # The model: render(len_{n+1}) <= play(len_n); chunk 1 itself cannot be hidden (see module).
    ramp = htts_split.CHUNK_RAMP
    for previous, following in zip(ramp[1:], ramp[2:]):
        assert render_seconds(following) <= previous / SPEECH_RATE + 1e-9, (previous, following)


def test_limit_at_repeats_the_last_step_and_scales_for_cjk():
    """Positions beyond the ramp use its ceiling; CJK limits are a third, at most 60.

    Returns:
        None.
    """
    # Far beyond the table the ceiling applies.
    assert htts_split.limit_at(500, False) == htts_split.MAX_CHUNK
    # The CJK scale keeps the first chunk at 30 and the ceiling at 60 characters.
    assert htts_split.limit_at(0, True) == htts_split.FIRST_CHUNK_LIMIT_CJK
    assert htts_split.limit_at(500, True) == htts_split.MAX_CHUNK_CJK
    assert all(htts_split.limit_at(i, True) <= htts_split.MAX_CHUNK_CJK for i in range(20))


def test_every_chunk_fits_the_limit_of_its_position():
    """Long unpunctuated text is chunked along the ramp, growing chunk by chunk.

    Returns:
        None.
    """
    # 120 short words in one sentence need more chunks than the ramp has steps.
    text = " ".join(f"wort{index:03d}" for index in range(120)) + "."
    chunks = htts_split.build_chunks([("de", text)])
    # Chunk i never exceeds the limit of position i, and no word is lost or cut.
    for position, (_, chunk) in enumerate(chunks):
        assert len(chunk) <= htts_split.limit_at(position, False), (position, chunk)
    assert " ".join(chunk for _, chunk in chunks) == text
    # The ramp really is used: the second chunk is shorter than the ceiling.
    assert len(chunks[1][1]) <= htts_split.CHUNK_RAMP[1]


def test_second_chunk_is_shorter_than_it_used_to_be():
    """A 150-character second sentence is cut at its comma so chunk 1 stays small.

    Returns:
        None.
    """
    # Previously the whole sentence became chunk 1 (limit 220).
    second = ("Dies ist ein kurzer Test der neuen Sprachausgabe, die vollständig auf diesem "
              "Rechner läuft und keine Daten ins Netz sendet, auch wenn man es nicht glaubt.")
    chunks = htts_split.build_chunks([("de", "Guten Tag."), ("de", second)])
    # The cut falls on a comma and keeps the clause intact.
    assert len(chunks[1][1]) <= htts_split.CHUNK_RAMP[1] and chunks[1][1].endswith(",")


def test_clause_boundaries_are_preferred_over_word_boundaries_in_later_chunks():
    """Later chunks end at commas when one lies in range, not mid-clause.

    Returns:
        None.
    """
    # Clauses of about 40 characters, so a comma is always inside the window.
    clause = "und dann gehen wir gemeinsam in den Park"
    sentence = ", ".join([clause] * 8) + "."
    chunks = htts_split.build_chunks([("de", "Start hier."), ("de", sentence)])
    # Every chunk but the last ends at a comma.
    assert all(chunk.endswith(",") for _, chunk in chunks[1:-1])


def test_no_chunk_but_the_first_is_a_fragment():
    """Cutting never leaves a tail shorter than the fragment minimum.

    Returns:
        None.
    """
    # Sweep the sentence length around every ramp limit, where a tiny tail used to appear.
    for limit in htts_split.CHUNK_RAMP[:4]:
        for extra in range(1, htts_split.MIN_FRAGMENT + 3):
            text = " ".join(["abcdefgh"] * 60)[: limit + extra].rstrip()
            # The first sentence is deliberately tiny; only the chunks after it are checked.
            chunks = htts_split.build_chunks([("de", "Anfang hier."), ("de", text)])
            assert all(len(chunk) >= htts_split.MIN_FRAGMENT for _, chunk in chunks[1:]), chunks


def test_a_fragment_sentence_joins_the_neighbour_of_its_language_only():
    """A tiny sentence is merged forward when it cannot go back, never across languages.

    Returns:
        None.
    """
    # "Ok." follows the first chunk (never extended), so it waits for the next German sentence.
    items = [("de", "Erster Satz hier."), ("de", "Ok."),
             ("de", "Und dann folgt ein deutlich längerer zweiter Satz, der weitergeht.")]
    chunks = htts_split.build_chunks(items)
    assert chunks[1][1].startswith("Ok. Und dann")
    # A tiny sentence between two languages stays alone rather than mixing them.
    mixed = htts_split.build_chunks([("de", "Erster Satz hier."), ("en", "Ok."),
                                     ("de", "Und dann folgt wieder ein längerer deutscher Satz.")])
    assert [lang for lang, _ in mixed] == ["de", "en", "de"] and mixed[1][1] == "Ok."


def test_short_sentences_are_merged_only_up_to_the_ramp_limit_of_their_chunk():
    """Merging stops at the limit of the chunk position, not at the old 220.

    Returns:
        None.
    """
    # Chunk 1 (limit 70) takes two 24-character sentences (49) but not a third (74).
    medium = "Ein ganz kurzer Satz ok."
    chunks = htts_split.build_chunks([("de", "Anfang hier."), ("de", medium), ("de", medium),
                                      ("de", medium)])
    # Every chunk stays within its own ramp limit.
    for position, (_, chunk) in enumerate(chunks):
        assert len(chunk) <= htts_split.limit_at(position, False), (position, chunk)
    assert len(chunks) == 3


def test_first_chunk_is_unchanged_by_the_ramp():
    """Chunk 0 is still the first sentence (cut at 90), exactly as before the ramp.

    Returns:
        None.
    """
    # A first sentence below 90 characters is one chunk, even when much is left to say.
    short = "Dies ist ein Satz mit etwa vierzig Zeichen."
    assert htts_split.build_chunks([("de", short), ("de", short + " Mehr Text.")])[0][1] == short
    # A longer one is cut at its last clause within 90 characters.
    long_first = ("Wir sitzen heute im Garten und lesen ein Buch, während die Sonne scheint "
                  "und die Vögel singen und der Wind weht.")
    head = htts_split.build_chunks([("de", long_first)])[0][1]
    assert head.endswith("Buch,") and len(head) <= 90


def test_cjk_ramp_keeps_the_cjk_rules():
    """CJK chunks follow a third of the ramp: first 30, second at most 23, never above 60.

    Returns:
        None.
    """
    # Eighty clauses of ten characters without any sentence end.
    text = "，".join(["这是一个很长的句子啊"] * 40) + "。"
    chunks = htts_split.build_chunks([("zh", text)])
    # Every chunk fits the CJK limit of its position, and nothing is lost.
    for position, (_, chunk) in enumerate(chunks):
        assert len(chunk) <= htts_split.limit_at(position, True), (position, len(chunk))
    assert "".join(chunk for _, chunk in chunks) == text
    assert len(chunks[1][1]) <= 23


@pytest.mark.parametrize("sentence_count", [1, 2, 5, 40])
def test_no_text_is_lost_or_reordered_by_the_ramp(sentence_count):
    """Whatever the ramp does, joining the chunks reproduces the sentences in order.

    Args:
        sentence_count: Number of identical-shaped sentences.

    Returns:
        None.
    """
    # Words are unique, so a lost or duplicated piece shows up in the comparison.
    items = words_text(sentence_count)
    chunks = htts_split.build_chunks(items)
    assert " ".join(text for _, text in chunks) == " ".join(text for _, text in items)


# The two paragraphs of the real-engine measurement: a short first sentence, then longer ones.
SAMPLE_SENTENCES = [
    "Guten Tag und herzlich willkommen.",
    "Dies ist ein kurzer Test der neuen Sprachausgabe, die vollständig auf diesem Rechner läuft.",
    "Wir prüfen, ob mehrere Sätze nacheinander sauber gesprochen werden.",
    "Alles läuft lokal und ohne Netz.",
]
# Measured model of a streamed chunk 0: its generation ends after this share of its audio
# length, chunk 1 then renders at RENDER_RATIO and the request adds a fixed overhead.
GENERATION_RATIO = 0.62
RENDER_RATIO = 0.8
GAP_OVERHEAD_SECONDS = 0.2
# The pause after the streamed first chunk must stay below this (the aim is about 0.5 s).
GAP_TARGET_SECONDS = 0.7


def streamed_gap_seconds(first_length, second_length):
    """Estimate the pause between a streamed chunk 0 and chunk 1.

    Args:
        first_length: Characters of chunk 0.
        second_length: Characters of chunk 1.

    Returns:
        Seconds of silence (negative when chunk 1 is ready before chunk 0 ends).
    """
    # Chunk 1 is ready at 0.62 L0 + 0.8 L1 + overhead, chunk 0 stops playing at L0.
    first_audio = first_length / SPEECH_RATE
    second_audio = second_length / SPEECH_RATE
    ready = GENERATION_RATIO * first_audio + RENDER_RATIO * second_audio
    return ready + GAP_OVERHEAD_SECONDS - first_audio


def sample_items():
    """Label the measurement sentences as German.

    Returns:
        List of (language, sentence) items.
    """
    # One language keeps the merge rules in play.
    return [("de", sentence) for sentence in SAMPLE_SENTENCES]


def test_streamed_ramp_differs_from_the_short_ramp_in_the_first_step_only():
    """The streamed first chunk is long, every later step is the unchanged ramp.

    Returns:
        None.
    """
    # Chunk 0 grows from 90 to 200; the steps from chunk 1 on are shared.
    assert htts_split.STREAMED_RAMP[0] == htts_split.STREAMED_FIRST_CHUNK_LIMIT == 200
    assert htts_split.STREAMED_RAMP[1:] == htts_split.CHUNK_RAMP[1:]
    # The long limit is what makes a streamed run tell itself apart from a short one.
    assert htts_split.long_first(htts_split.STREAMED_RAMP)
    assert not htts_split.long_first(htts_split.CHUNK_RAMP)


def test_the_streamed_ramp_meets_the_gap_target_once_chunk_zero_is_filled():
    """Chunk 1 at its ramp limit leaves a short pause after any chunk 0 of >= 128 characters.

    Returns:
        None.
    """
    # The formula: the pause shrinks as chunk 0 grows, so the worst case is the smallest fill.
    second = htts_split.STREAMED_RAMP[1]
    needed = next(n for n in range(1, 400) if streamed_gap_seconds(n, second) <= GAP_TARGET_SECONDS)
    assert needed <= 128
    # The long limit leaves headroom above that fill (speech rates vary by +-20 % per render).
    assert htts_split.STREAMED_FIRST_CHUNK_LIMIT >= needed * 1.5
    # The old short first chunk could never get there.
    assert streamed_gap_seconds(htts_split.FIRST_CHUNK_LIMIT, second) > GAP_TARGET_SECONDS


def test_streamed_first_chunk_merges_whole_sentences_and_halves_the_pause():
    """The sample selection: chunk 0 holds three sentences, the pause is gone (was ~2 s).

    Returns:
        None.
    """
    # Streamed: the first three sentences (194 characters) form chunk 0, the fourth is chunk 1.
    streamed = htts_split.build_chunks(sample_items(), stream_first=True)
    assert [text for _, text in streamed] == [
        " ".join(SAMPLE_SENTENCES[:3]), SAMPLE_SENTENCES[3],
    ]
    assert streamed_gap_seconds(len(streamed[0][1]), len(streamed[1][1])) <= GAP_TARGET_SECONDS
    # Not streamed: the short first chunk and the old ramp, with the long pause the fix removes.
    short = htts_split.build_chunks(sample_items(), stream_first=False)
    assert [len(text) for _, text in short] == [34, 49, 41, 67, 32]
    assert streamed_gap_seconds(len(short[0][1]), len(short[1][1])) > 1.5


def test_default_chunking_is_the_short_first_chunk():
    """Without the streaming decision the first chunk stays short and alone, as before.

    Returns:
        None.
    """
    # Both spellings of "not streamed" agree, and no sentence is merged into chunk 0.
    items = sample_items()
    assert htts_split.build_chunks(items) == htts_split.build_chunks(items, stream_first=False)
    assert htts_split.build_chunks(items)[0][1] == SAMPLE_SENTENCES[0]


def test_streamed_first_chunk_takes_the_opening_clauses_of_a_long_sentence():
    """A short heading plus a long sentence: chunk 0 is topped up at a clause boundary.

    Returns:
        None.
    """
    # The second sentence cannot join as a whole (over 200), but its first clauses fit.
    long_sentence = ("Dies ist ein langer Satz mit vielen Wörtern, der nicht in die erste Gruppe "
                     "passt, weil er sehr lang ist, und danach geht er noch weiter mit "
                     "Nebensätzen, die sich hinziehen, bis niemand mehr zuhört.")
    chunks = htts_split.build_chunks([("de", "Kurz."), ("de", long_sentence)], stream_first=True)
    first = chunks[0][1]
    # Chunk 0 starts with the heading, ends on a comma and stays within the streamed limit.
    assert first.startswith("Kurz. Dies ist") and first.endswith(",")
    assert len(first) <= htts_split.STREAMED_FIRST_CHUNK_LIMIT and len(first) > 120
    # Nothing is lost, and the rest is a proper (non-fragment) chunk 1.
    assert " ".join(text for _, text in chunks) == "Kurz. " + long_sentence
    assert len(chunks[1][1]) >= htts_split.MIN_FRAGMENT


def test_streamed_first_chunk_is_not_topped_up_without_a_clause_boundary():
    """A long sentence without any comma is left whole for chunk 1 (no mid-clause cut).

    Returns:
        None.
    """
    # Eighteen plain words: no clause boundary, so chunk 0 stays the heading alone.
    sentence = " ".join(f"wort{index}" for index in range(30)) + "."
    chunks = htts_split.build_chunks([("de", "Kurz."), ("de", sentence)], stream_first=True)
    assert chunks[0][1] == "Kurz."
    assert " ".join(text for _, text in chunks[1:]) == sentence


def test_streamed_first_chunk_never_mixes_languages():
    """A sentence of another language starts its own chunk even though chunk 0 has room.

    Returns:
        None.
    """
    # The English sentence is short and would fit chunk 0, but languages are never merged.
    items = [("de", "Guten Tag und herzlich willkommen."), ("en", "This is English."),
             ("en", "And this is more English text.")]
    chunks = htts_split.build_chunks(items, stream_first=True)
    assert [lang for lang, _ in chunks] == ["de", "en"]
    assert chunks[0][1] == "Guten Tag und herzlich willkommen."


def test_streamed_first_sentence_over_the_limit_is_cut_at_the_streamed_limit():
    """A first sentence longer than 200 characters is cut at a clause within 200.

    Returns:
        None.
    """
    # Clauses of ~30 characters up to 300 characters.
    text = ", ".join(f"und dann kam der Teil Nummer {number}" for number in range(10)) + "."
    chunks = htts_split.build_chunks([("de", text)], stream_first=True)
    limit = htts_split.STREAMED_FIRST_CHUNK_LIMIT
    assert 90 < len(chunks[0][1]) <= limit and chunks[0][1].endswith(",")
    # The ramp continues with the unchanged second step.
    assert len(chunks[1][1]) <= htts_split.CHUNK_RAMP[1]
    assert " ".join(text for _, text in chunks) == text


def test_streamed_cjk_first_chunk_follows_the_cjk_scale():
    """A streamed CJK first chunk holds up to 60 characters, later chunks stay a third.

    Returns:
        None.
    """
    # Forty clauses of ten characters.
    text = "，".join(["这是一个很长的句子啊"] * 40) + "。"
    chunks = htts_split.build_chunks([("zh", text)], stream_first=True)
    ramp = htts_split.STREAMED_RAMP
    # The first chunk is clearly longer than the old 30, but never above the CJK ceiling.
    assert htts_split.FIRST_CHUNK_LIMIT_CJK < len(chunks[0][1]) <= htts_split.MAX_CHUNK_CJK
    for position, (_, chunk) in enumerate(chunks):
        assert len(chunk) <= htts_split.limit_at(position, True, ramp), (position, len(chunk))
    assert "".join(chunk for _, chunk in chunks) == text


@pytest.mark.parametrize("sentence_count", [1, 2, 5, 40])
def test_no_text_is_lost_or_reordered_when_the_first_chunk_is_streamed(sentence_count):
    """Merging into chunk 0 never drops, duplicates or reorders text.

    Args:
        sentence_count: Number of identical-shaped sentences.

    Returns:
        None.
    """
    # Unique words make any damage visible; every chunk must fit its streamed ramp step.
    items = words_text(sentence_count)
    chunks = htts_split.build_chunks(items, stream_first=True)
    assert " ".join(text for _, text in chunks) == " ".join(text for _, text in items)
    for position, (_, chunk) in enumerate(chunks):
        limit = htts_split.limit_at(position, False, htts_split.STREAMED_RAMP)
        assert len(chunk) <= limit + htts_split.MIN_FRAGMENT - 1, (position, len(chunk))


def test_only_the_first_chunk_may_be_a_fragment_when_streamed():
    """Sweeping the first sentence's length never leaves a tiny chunk after chunk 0.

    Returns:
        None.
    """
    # Sentences of every length around the streamed limit follow a tiny first one.
    for length in range(40, 260, 7):
        text = " ".join(["wort"] * (length // 5)) + "."
        chunks = htts_split.build_chunks([("de", "Anfang."), ("de", text)], stream_first=True)
        assert all(len(chunk) >= htts_split.MIN_FRAGMENT for _, chunk in chunks[1:]), length
