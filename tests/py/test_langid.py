"""Tests for language identification and smoothing (htts_langid).

Logic tests use a deterministic keyword scorer so they need no model. The tests marked
"real model" use fastText and are skipped when ``lid.176.ftz`` is not installed.
"""

import os

# Test framework.
import pytest

# Modules under test.
import htts_langid as lid
import htts_pipeline

FIVE = ("de", "en", "fr", "es", "it")
# Keyword -> language table that drives the fake scorer.
FAKE_KEYWORDS = {
    "hello": "en", "weather": "en", "nice": "en", "ich": "de", "und": "de", "haus": "de",
    "bonjour": "fr", "merci": "fr", "gracias": "es", "casa": "es",
}


def fake_scorer(text, allowed):
    """Score text by keyword lookup; unknown text gets a flat distribution.

    Args:
        text: Cleaned sentence text.
        allowed: Allowed language codes.

    Returns:
        Probability per allowed language.
    """
    # The first keyword found in the lowercase text decides.
    hits = [lang for word, lang in FAKE_KEYWORDS.items() if word in text.lower()]
    if hits and hits[0] in allowed:
        # The winner gets 99 percent; the rest share the remaining mass.
        others = 0.01 / max(len(allowed) - 1, 1)
        return {lang: 0.99 if lang == hits[0] else others for lang in allowed}
    return {lang: 1 / len(allowed) for lang in allowed}


def evidence(scores, letters):
    """Build sentence evidence for smoothing tests.

    Args:
        scores: Probability per language.
        letters: Letter count of the sentence.

    Returns:
        A SentenceEvidence instance.
    """
    # Thin wrapper that keeps the test bodies short.
    return lid.SentenceEvidence(scores, letters)


STRONG_DE = {"de": 0.99, "en": 0.01}
STRONG_EN = {"de": 0.01, "en": 0.99}


def test_clean_removes_code_urls_numbers_and_placeholders():
    """Cleaning keeps only language-bearing words.

    Returns:
        None.
    """
    # Digits, symbols and the (link)/(email) stand-ins must disappear.
    raw = "Run now (link) 42 times, mail (email) **please**"
    assert lid.clean_for_detection(raw) == "Run now times mail please"


def test_clean_lowercases_shouting():
    """All-caps text is lowercased so it is not scored as acronyms.

    Returns:
        None.
    """
    # Mixed case stays untouched; upper case is lowered.
    assert lid.clean_for_detection("WARNING: DO NOT DISTURB") == "warning do not disturb"
    assert lid.clean_for_detection("Hello World") == "Hello World"


def test_smoothing_short_sentence_inherits_surrounding_language():
    """A short wrong-looking sentence between two German ones stays German.

    Returns:
        None.
    """
    # A weak English "Okay." between strong German evidence.
    weak_en = evidence({"de": 0.1, "en": 0.9}, 4)
    labels = lid.smooth_labels([evidence(STRONG_DE, 60), weak_en, evidence(STRONG_DE, 60)],
                               ("de", "en"), "de")
    assert labels == ["de", "de", "de"]


def test_smoothing_keeps_long_confident_foreign_sentence():
    """A long, confident sentence in another language is a real switch.

    Returns:
        None.
    """
    # Strong English evidence in the middle must survive smoothing.
    sentences = [evidence(STRONG_DE, 60), evidence(STRONG_EN, 60), evidence(STRONG_DE, 60)]
    assert lid.smooth_labels(sentences, ("de", "en"), "de") == ["de", "en", "de"]


def test_smoothing_leading_weak_sentence_takes_next_language():
    """A weak first sentence inherits the language that follows it.

    Returns:
        None.
    """
    # No previous context exists, so the following strong sentence decides.
    weak = evidence({"de": 0.4, "en": 0.6}, 2)
    assert lid.smooth_labels([weak, evidence(STRONG_DE, 60)], ("de", "en"), "en") == ["de", "de"]


def test_smoothing_without_evidence_uses_default_language():
    """Sentences without letters fall back to the default language.

    Returns:
        None.
    """
    # Empty score dicts mean no evidence; the default wins the tie.
    empty = evidence({}, 0)
    assert lid.smooth_labels([empty, empty], ("de", "en"), "en") == ["en", "en"]


def test_smoothing_single_short_sentence_uses_its_own_best_guess():
    """A lone short snippet is classified by its own scores, not the default.

    Returns:
        None.
    """
    # With no context, weak evidence still beats an empty prior.
    merci = evidence({"fr": 0.9, "de": 0.1}, 5)
    assert lid.smooth_labels([merci], ("de", "fr"), "de") == ["fr"]


def test_smoothing_empty_input():
    """No sentences give no labels.

    Returns:
        None.
    """
    # Guard against index errors on empty input.
    assert lid.smooth_labels([], ("de",), "de") == []


def test_label_sentences_follow_real_language_changes():
    """Long keyword sentences give de / en / de with the fake scorer.

    Returns:
        None.
    """
    # Strong evidence in each sentence under the fake scorer.
    sentences = ["Ich habe ein Haus und einen großen Garten hinter dem Haus.",
                 "Hello, what a nice weather we have today in the city.",
                 "Ich glaube, das Haus gefällt dir und deiner Familie sehr."]
    assert lid.label_sentences(sentences, ("de", "en"), "de", fake_scorer) == ["de", "en", "de"]


def test_loanword_sentence_does_not_flip_the_language():
    """A short sentence with one English keyword inside German stays German.

    Returns:
        None.
    """
    # "Hello!" alone is weak evidence (5 letters) between strong German sentences.
    sentences = ["Ich habe ein Haus und einen großen Garten hinter dem Haus.", "Hello!",
                 "Ich glaube, das Haus gefällt dir und deiner Familie sehr."]
    assert set(lid.label_sentences(sentences, ("de", "en"), "de", fake_scorer)) == {"de"}


def test_single_allowed_language_never_calls_the_scorer():
    """With one allowed language nothing is classified or loaded.

    Returns:
        None.
    """
    # The scorer explodes when called, so any call would fail the test.
    def explode(text, allowed):
        """Fail when called.

        Args:
            text: Ignored.
            allowed: Ignored.

        Returns:
            Never returns.
        """
        # A call here means the single-language shortcut is broken.
        raise AssertionError("scorer must not be called")

    assert lid.label_sentences(["a b", "c d"], ("de",), "de", explode) == ["de", "de"]


def test_dominant_language_is_weighted_by_length():
    """The language with the most characters wins, not the one with most sentences.

    Returns:
        None.
    """
    # One long English sentence outweighs two short German ones.
    sentences = ["Ja.", "Gut.", "This is a very long English sentence indeed."]
    assert lid.dominant_language(sentences, ["de", "de", "en"], "de") == "en"


def test_dominant_language_of_nothing_is_the_default():
    """An empty text falls back to the default language.

    Returns:
        None.
    """
    # No sentences, no weights.
    assert lid.dominant_language([], [], "fr") == "fr"


def test_detect_without_letters_returns_the_callers_default():
    """Text without letters yields the default (or an empty string).

    Returns:
        None.
    """
    # Digits and symbols carry no language.
    assert htts_pipeline.detect("123 !!!", ("de", "en"), "") == ""
    assert htts_pipeline.detect("123 !!!", ("de", "en"), "en") == "en"


@pytest.mark.parametrize("csv, expected", [
    ("de,en", ("de", "en")), (" DE , en ,de", ("de", "en")), ("deu", ("deu",)),
])
def test_parse_language_list_accepts_valid_lists(csv, expected):
    """Valid lists are lowercased, trimmed and deduplicated.

    Args:
        csv: Comma-separated input.
        expected: Parsed tuple.

    Returns:
        None.
    """
    # Order is preserved and duplicates vanish.
    assert lid.parse_language_list(csv) == expected


@pytest.mark.parametrize("csv", ["", ",", "de;rm", "../etc", "d", "german", "de en", "de,$(x)"])
def test_parse_language_list_rejects_unsafe_or_malformed_codes(csv):
    """Anything that is not a two or three letter code is rejected.

    Args:
        csv: Malformed input.

    Returns:
        None.
    """
    # The error is a ValueError the CLI turns into exit code 2.
    with pytest.raises(ValueError):
        lid.parse_language_list(csv)


def test_model_path_prefers_the_environment_override(monkeypatch, tmp_path):
    """HTTS_LID_MODEL wins; a missing model raises LanguageModelUnavailable.

    Args:
        monkeypatch: pytest monkeypatch fixture.
        tmp_path: Per-test temporary directory.

    Returns:
        None.
    """
    # An existing override file is returned as it is.
    model = tmp_path / "lid.176.ftz"
    model.write_bytes(b"x")
    monkeypatch.setenv("HTTS_LID_MODEL", str(model))
    assert lid.find_model_path() == str(model)
    # Without any candidate the dedicated error is raised.
    monkeypatch.setenv("HTTS_LID_MODEL", str(tmp_path / "missing"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "no-data"))
    if not os.path.exists("/usr/share/hyprland-tts/lid.176.ftz"):
        # Without any candidate file the dedicated error is raised.
        with pytest.raises(lid.LanguageModelUnavailable):
            lid.find_model_path()


# ---------------------------------------------------------------- real model


@pytest.mark.parametrize("text, expected", [
    ("Bitte öffne den Pull Request im Main Branch und prüfe den Merge Conflict.", "de"),
    ("Angela Merkel met Olaf Scholz in Berlin to discuss the new highway tolls.", "en"),
    ("Guten Morgen zusammen", "de"), ("Good morning everyone", "en"),
    ("Merci beaucoup pour votre aide", "fr"), ("Muchas gracias por su ayuda", "es"),
    ("Grazie mille per l'aiuto", "it"),
])
def test_real_whole_text_detection(lid_model, text, expected):
    """The real classifier gets loanword-rich and short texts right (real model).

    Args:
        lid_model: Fixture that skips without the model.
        text: Input text.
        expected: Gold language.

    Returns:
        None.
    """
    # Five-language allow-list, as in the evaluation.
    assert htts_pipeline.detect(text, FIVE, "de") == expected


def test_real_mixed_paragraph_is_labelled_by_language(lid_model):
    """A German paragraph with an English quote yields de / en / de (real model).

    Args:
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # The English quote sits in the middle.
    sentences = ["Der Autor beginnt seinen Essay mit einem bekannten Zitat.",
                 "It was the best of times, it was the worst of times.",
                 "Damit will er zeigen, dass jede Epoche ihre eigenen Widersprüche hat."]
    assert lid.label_sentences(sentences, FIVE, "de") == ["de", "en", "de"]


def test_real_short_interjection_inherits_context(lid_model):
    """A short ambiguous "Okay." inside German stays German (real model).

    Args:
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # "Okay." alone looks English but belongs to the German conversation.
    sentences = ["Das Projekt ist fast fertig und wir liegen gut im Zeitplan.", "Okay.",
                 "Morgen präsentieren wir die Ergebnisse dem gesamten Vorstand."]
    assert set(lid.label_sentences(sentences, FIVE, "de")) == {"de"}


def test_real_result_is_always_an_allowed_language(lid_model):
    """Portuguese text maps to an allowed language unless Portuguese is allowed (real model).

    Args:
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # With de/en/es allowed the answer must come from that set.
    text = "Ontem comprei um livro sobre a história da navegação marítima."
    assert htts_pipeline.detect(text, ("de", "en", "es"), "de") in {"de", "en", "es"}
    assert htts_pipeline.detect(text, ("de", "en", "es", "pt"), "de") == "pt"


def test_real_loanwords_do_not_flip_german(lid_model):
    """Technical German full of English loanwords stays German as one chunk run (real model).

    Args:
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # Every sentence contains English tech terms but is German.
    text = ("Öffne bitte den Pull Request im Main Branch. Danach machst du einen Commit. "
            "Der Merge Conflict muss vorher gelöst werden.")
    chunks = htts_pipeline.prepare(text, FIVE, "de")
    assert {lang for lang, _ in chunks} == {"de"}
