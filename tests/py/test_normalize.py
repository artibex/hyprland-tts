"""Tests for the per-language text normaliser (htts_norm).

The big table in ``normalize_cases`` holds reviewed (language, input, expected) triples;
the tests below pin the measured Qwen3-TTS failures and the structural guarantees.
"""

import pytest

# Module under test and the reviewed case tables.
import htts_norm
from normalize_cases import ENGLISH_CASES, GERMAN_CASES, OTHER_LANGUAGE_CASES

ALL_CASES = GERMAN_CASES + ENGLISH_CASES + OTHER_LANGUAGE_CASES


@pytest.mark.parametrize("lang, text, expected", ALL_CASES)
def test_reviewed_normalisation_cases(number_words, lang, text, expected):
    """Every reviewed case produces exactly the pinned spoken form.

    Args:
        number_words: Fixture that skips without num2words.
        lang: Language of the sentence.
        text: Input sentence.
        expected: Pinned spoken form.

    Returns:
        None.
    """
    # The language decides number format, month names and units.
    assert htts_norm.normalize(text, lang) == expected


def test_case_table_is_large_enough():
    """The table covers at least 60 cases across all five languages.

    Returns:
        None.
    """
    # Count cases and distinct languages in the table.
    assert len(ALL_CASES) >= 60
    assert {lang for lang, _, _ in ALL_CASES} >= {"de", "en", "fr", "es", "it"}


def test_german_thousands_and_decimal_marks(number_words):
    """German 1.250,75 is one thousand two hundred fifty point seventy-five (measured failure).

    Args:
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # The same digits mean something different in English.
    german = htts_norm.normalize("1.250,75 Euro", "de")
    assert german == "eintausendzweihundertfünfzig Euro und fünfundsiebzig Cent"
    assert htts_norm.normalize("1,250.75 euros", "en").startswith("one thousand two hundred")


def test_kfz_is_expanded_instead_of_misread():
    """Kfz becomes Kraftfahrzeug (measured failure: read as 'Karfs-E').

    Returns:
        None.
    """
    # Needs no number words, so it also runs without num2words.
    assert htts_norm.normalize("Das Kfz-Kennzeichen", "de") == "Das Kraftfahrzeug-Kennzeichen"


def test_cli_command_is_spoken_sensibly():
    """sudo pacman -Syu becomes words with spelled flag letters (measured failure).

    Returns:
        None.
    """
    # The flag cluster is spelled letter by letter after "dash".
    spoken = htts_norm.normalize("sudo pacman -Syu", "en")
    assert spoken == "sudo pacman dash S y u"


def test_pull_request_is_respelled_for_german():
    """Pull Request gets a respelling in German (unverified against the engine).

    Returns:
        None.
    """
    # The respelling keeps "Pull" short and "Request" German-readable.
    assert htts_norm.normalize("Ein Pull Request", "de") == "Ein Pull Rikwest"
    assert htts_norm.normalize("a pull request", "en") == "a pull request"


@pytest.mark.parametrize("lang, text", [
    ("de", "Nichts zu ersetzen hier, nur Text."), ("en", "Plain text stays plain."),
    ("fr", "Du texte ordinaire."), ("es", "Texto normal."), ("it", "Testo normale."),
    ("nl", "Gewone tekst met 5 getallen."),
])
def test_plain_text_is_unchanged(lang, text):
    """Sentences without numbers or abbreviations pass through untouched.

    Args:
        lang: Language code.
        text: Plain sentence.

    Returns:
        None.
    """
    # Normalisation must be the identity on ordinary prose.
    assert htts_norm.normalize(text, lang) == text


@pytest.mark.parametrize("lang, text", [
    ("de", "Das war 1.250,75 Euro am 3. Oktober 2026 um 14:30 Uhr, d. h. 12 %."),
    ("en", "That was $1,250.75 on 3 October 2026 at 2:30 PM, i.e. 12%."),
    ("fr", "C'était 1 250,75 € le 3 octobre 2026 à 14h30."),
])
def test_normalisation_leaves_no_digits_behind(number_words, lang, text):
    """After normalisation a neural voice has nothing numeric left to garble.

    Args:
        number_words: Fixture that skips without num2words.
        lang: Language code.
        text: Sentence full of numbers.

    Returns:
        None.
    """
    # No ASCII digit may survive.
    assert not any(char.isdigit() for char in htts_norm.normalize(text, lang))


@pytest.mark.parametrize("lang", ["de", "en", "fr", "es", "it"])
def test_normalisation_is_idempotent_on_its_own_output(number_words, lang):
    """Running the normaliser twice changes nothing more.

    Args:
        number_words: Fixture that skips without num2words.
        lang: Language code.

    Returns:
        None.
    """
    # Normalise a messy sentence, then normalise the result again.
    once = htts_norm.normalize("Am 3. Oktober: 5 km, 12 %, 1.250,75 € und 14:30.", lang)
    assert htts_norm.normalize(once, lang) == once


def test_without_num2words_numbers_stay_as_digits(monkeypatch):
    """A missing num2words library degrades to digits instead of failing.

    Args:
        monkeypatch: pytest monkeypatch fixture.

    Returns:
        None.
    """
    # Force the library check to report "not installed".
    import htts_numbers
    monkeypatch.setattr(htts_numbers, "words_available", lambda: False)
    assert htts_norm.normalize("Es kostet 5 Euro.", "de") == "Es kostet 5 Euro."
    # Abbreviations do not need number words and keep working.
    assert htts_norm.normalize("z. B. Äpfel", "de") == "zum Beispiel Äpfel"
