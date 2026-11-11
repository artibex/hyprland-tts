"""Tests for the markdown and code clean-up (htts_markup), including parity with bash."""

import shutil
import subprocess

# Test framework.
import pytest

import htts_markup
from conftest import REPO_ROOT

# (input, expected) pairs for prose paragraphs.
MARKUP_CASES = [
    ("# Titel\n\nText mit **fett** und *kursiv*.", "Titel. Text mit fett und kursiv."),
    ("Ein [Link](https://x.org/a) hier.", "Ein Link hier."),
    ("Bild: ![Katze](cat.png) ok", "Bild: Katze ok"),
    ("Siehe https://example.com/pfad und www.test.de.", "Siehe (link) und (link)"),
    ("Mail an max.mustermann@firma.de bitte.", "Mail an (email) bitte."),
    ("- Punkt eins\n- Punkt zwei", "Punkt eins Punkt zwei"),
    ("1. Erster\n2. Zweiter", "Erster Zweiter"),
    ("> Zitat\n> noch eins", "Zitat noch eins"),
    ("| a | b |\n|---|---|\n| 1 | 2 |", "a, b,, 1, 2,"),
    ("Hallo\u00a0Welt\u200b mit\u00adSilben\ufeff", "Hallo Welt mitSilben"),
    ("----\nWort\n.....\n!!!!", "Wort"),
    ("Am 3. Oktober war es so.", "Am 3. Oktober war es so."),
    ("Preis: 5 - 3 = 2 und Zeit 10:30", "Preis: 5 - 3 = 2 und Zeit 10:30"),
    ("Ein - Satz und - - - dann", "Ein - Satz und dann"),
    ("Absatz eins\n\nAbsatz zwei", "Absatz eins. Absatz zwei"),
    ("Endet mit Punkt.\n\nNächster", "Endet mit Punkt. Nächster"),
    ("", ""),
    ("\n\n\n", ""),
]
# Code paragraphs: operators become words, braces become sentence breaks.
CODE_CASES = [
    ("function foo(a, b) {\n  return a == b;\n}", "function foo a, b.\nreturn a equals b."),
    ("def hello(name):\n    # say hi\n    return name", "def hello name:\nsay hi\nreturn name"),
    ("const x = a && b || c; // note\nlet y = x >= 3;",
     "const x = a and b or c. // note\nlet y = x greater than or equal to 3."),
    ("const camelCaseName = snake_case_value;", "const camel Case Name = snake case value."),
]


@pytest.mark.parametrize("raw, expected", MARKUP_CASES + CODE_CASES)
def test_markup_cleanup(raw, expected):
    """Markdown, links, decoration and code are cleaned as documented.

    Args:
        raw: Raw selected text.
        expected: Cleaned text.

    Returns:
        None.
    """
    # The expected strings pin the behaviour ported from bash.
    assert htts_markup.normalize_text(raw) == expected


def test_fenced_code_is_its_own_paragraph():
    """A fenced snippet inside prose is cleaned as code, not as prose.

    Returns:
        None.
    """
    # The fence markers vanish and the code line is split into words.
    raw = "Vorher.\n```js\nconst a = 1;\n```\nNachher."
    assert htts_markup.normalize_text(raw) == "Vorher. const a = 1. Nachher."


def test_code_classification_needs_two_signals():
    """Plain prose with one bracket is not code; a function body is.

    Returns:
        None.
    """
    # One symbol signal alone is not enough; keyword plus identifier style is.
    assert not htts_markup.looks_like_code("Das ist (fast) nur Text.")
    assert htts_markup.looks_like_code("def parse_value(x):\n    return x")


def test_mid_line_markers_are_kept():
    """Bullet and number markers are only stripped at the start of a line.

    Returns:
        None.
    """
    # The old rules turned this into "am Oktober".
    assert htts_markup.normalize_text("Wir feiern am 3. Oktober.") == "Wir feiern am 3. Oktober."


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash not available")
@pytest.mark.parametrize("raw, _expected", MARKUP_CASES + CODE_CASES)
def test_python_markup_is_identical_to_the_bash_fallback(raw, _expected):
    """lib/text.sh normalize_text and the Python port give identical output.

    Args:
        raw: Raw selected text.
        _expected: Unused (the bash output is the reference).

    Returns:
        None.
    """
    # Source the bash module and pipe the same text through it.
    script = f'source "{REPO_ROOT}/lib/text.sh"; normalize_text'
    result = subprocess.run(["bash", "-c", script], input=raw, capture_output=True, text=True)
    assert result.stdout == htts_markup.normalize_text(raw)
