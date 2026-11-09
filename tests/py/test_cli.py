"""Contract tests for the command-line helper (lib/py/htts_text.py).

The bash router and the player rely on this contract: ``lang<TAB>text`` lines, a short
first chunk, no empty chunks, valid language codes, UTF-8 safety and clear exit codes.
"""

import os
import subprocess
import sys

# Test framework.
import pytest

import htts_split  # lib/py is on the path via conftest.

FIVE = "de,en,fr,es,it"
# A mixed-language paragraph with numbers, code and an over-long first sentence.
MIXED_TEXT = (
    "Heute ist der 3. Oktober 2026, und wir haben endlich den neuen Pull Request gemergt, "
    "obwohl es lange gedauert hat und viele Leute gezweifelt haben. Der Preis liegt bei "
    "1.250,75 Euro. The quick brown fox jumps over the lazy dog near the river bank today. "
    "Je pense que c'est une très bonne idée de visiter Paris au printemps. "
    "Ciao a tutti, come state oggi? Ärger über Öl und Übung gibt es überall: 日本語 ✓.\n"
)


def run_helper(helper_script, args, text, extra_env=None):
    """Run the helper as the bash router does and capture its result.

    Args:
        helper_script: Path of htts_text.py.
        args: Command-line arguments after the script.
        text: Standard input text.
        extra_env: Environment overrides (optional).

    Returns:
        The completed process (stdout and stderr decoded as UTF-8).
    """
    # Inherit the environment but make the output deterministic.
    env = dict(os.environ, **(extra_env or {}))
    return subprocess.run(
        [sys.executable, helper_script, *args], input=text.encode("utf-8"),
        capture_output=True, env=env, timeout=60,
    )


def segment_lines(helper_script, text, allowed=FIVE, default="de"):
    """Run ``segment`` and split its output into (language, text) pairs.

    Args:
        helper_script: Path of htts_text.py.
        text: Input text.
        allowed: Allowed languages (comma-separated).
        default: Default language.

    Returns:
        List of (language, chunk) tuples.
    """
    # Every output line must have exactly one tab.
    result = run_helper(helper_script, ["segment", "--allowed", allowed, "--default", default],
                        text)
    assert result.returncode == 0, result.stderr.decode()
    lines = result.stdout.decode("utf-8").splitlines()
    return [tuple(line.split("\t")) for line in lines]


def test_output_lines_are_language_tab_text(helper_script, lid_model, number_words):
    """Each line is ``<lang>\\t<text>`` with an allowed language and no extra tabs.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # Unpacking into exactly two fields proves there is one tab per line.
    chunks = segment_lines(helper_script, MIXED_TEXT)
    assert chunks and all(len(pair) == 2 for pair in chunks)
    assert all(lang in FIVE.split(",") for lang, _ in chunks)


def test_first_chunk_is_short_and_later_chunks_are_bounded(helper_script, lid_model, number_words):
    """The first chunk stays near 90 characters; no chunk exceeds 220.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # The mixed text starts with a 150-character sentence.
    chunks = segment_lines(helper_script, MIXED_TEXT)
    assert len(chunks[0][1]) <= 90
    assert all(len(text) <= 220 for _, text in chunks)


# A German paragraph of long sentences, so that the ramp positions are all exercised.
LONG_GERMAN = (
    "Guten Tag und herzlich willkommen. Dies ist ein kurzer Test der neuen Sprachausgabe, die "
    "vollständig auf diesem Rechner läuft und keine Daten in das Netz sendet. Wir prüfen, ob "
    "mehrere Sätze nacheinander sauber gesprochen werden, und ob die Pausen dazwischen natürlich "
    "bleiben, auch wenn der Text länger wird und viele Nebensätze enthält, die man hören kann. "
    "Das Wetter war gestern sehr schön, heute regnet es jedoch den ganzen Tag, und die "
    "Temperaturen sind deutlich gesunken, sodass wir die Wanderung wohl verschieben müssen. Ja. "
    "Der Wetterbericht für morgen sagt voraus, dass es im Norden regnen wird, während im Süden "
    "die Sonne scheint, und dass es am Wochenende wieder wärmer werden soll.\n"
)


def test_chunks_follow_the_ramp_and_have_no_fragments(helper_script, number_words):
    """Chunk n fits ramp step n (plus a merged fragment); only the first chunk may be tiny.

    Args:
        helper_script: Path of htts_text.py.
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # One language needs no classifier model.
    chunks = segment_lines(helper_script, LONG_GERMAN, allowed="de")
    texts = [text for _, text in chunks]
    # The first chunk is the unchanged 90; later ones fit their ramp step plus one merged fragment.
    assert len(texts[0]) <= 90
    for position, text in enumerate(texts[1:], start=1):
        assert len(text) <= htts_split.limit_at(position, False) + htts_split.MIN_FRAGMENT - 1
        assert len(text) >= htts_split.MIN_FRAGMENT
    # The ramp breaks the long second sentence up: chunk 1 is well below the old 220.
    assert len(texts[1]) <= htts_split.CHUNK_RAMP[1]


def test_no_empty_or_punctuation_only_chunks(helper_script, lid_model):
    """Decorative lines and symbols never become chunks.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # Separator rows, bullets without text and a lone symbol are all noise.
    noisy = "Ein Satz.\n\n-----\n\n***\n\n...\n\nNoch ein Satz.\n"
    chunks = segment_lines(helper_script, noisy)
    assert [text for _, text in chunks] == ["Ein Satz.", "Noch ein Satz."]


def test_languages_are_never_merged_into_one_chunk(helper_script, lid_model, number_words):
    """The mixed paragraph yields chunks in several languages, each uniform.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # German, English, French and Italian all occur in the sample.
    languages = {lang for lang, _ in segment_lines(helper_script, MIXED_TEXT)}
    assert {"de", "en", "fr", "it"} <= languages


def test_unicode_survives_and_numbers_are_spoken(helper_script, lid_model, number_words):
    """Umlauts and non-Latin characters pass through; digits become words.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # The sample contains umlauts, Japanese text and a check mark.
    joined = " ".join(text for _, text in segment_lines(helper_script, MIXED_TEXT))
    assert "Ärger über Öl" in joined and "日本語" in joined
    assert "dritte" in joined and "eintausendzweihundertfünfzig" in joined


def test_c_locale_does_not_break_utf8(helper_script, lid_model):
    """A C locale (as in a Hyprland exec) must not corrupt UTF-8 text.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # Force the C locale and PYTHONUTF8 off to mimic a bare compositor environment.
    result = run_helper(helper_script, ["segment", "--allowed", "de", "--default", "de"],
                        "Schöne Grüße aus Köln.", {"LC_ALL": "C", "LANG": "C"})
    assert result.stdout.decode("utf-8") == "de\tSchöne Grüße aus Köln.\n"


def test_single_language_needs_no_model(helper_script, tmp_path):
    """With one allowed language the helper never touches the model.

    Args:
        helper_script: Path of htts_text.py.
        tmp_path: Per-test temporary directory.

    Returns:
        None.
    """
    # Point every model location at nothing; the run must still succeed.
    env = {"HTTS_LID_MODEL": str(tmp_path / "none"), "XDG_DATA_HOME": str(tmp_path)}
    result = run_helper(helper_script, ["segment", "--allowed", "en", "--default", "en"],
                        "Hello world. Second sentence here.", env)
    assert result.returncode == 0 and result.stdout.decode().startswith("en\tHello world.")


def test_missing_model_with_several_languages_exits_with_code_3(helper_script, tmp_path):
    """No model plus several languages means exit code 3 (the bash fallback signal).

    Args:
        helper_script: Path of htts_text.py.
        tmp_path: Per-test temporary directory.

    Returns:
        None.
    """
    # The bash router treats exit code 3 as "use the regex path".
    env = {"HTTS_LID_MODEL": str(tmp_path / "none"), "XDG_DATA_HOME": str(tmp_path)}
    result = run_helper(helper_script, ["segment", "--allowed", "de,en"], "Hallo Welt.", env)
    if os.path.exists("/usr/share/hyprland-tts/lid.176.ftz"):
        # A system-wide model would make the missing-model case unreachable.
        pytest.skip("a system-wide model is installed")
    assert result.returncode == 3


@pytest.mark.parametrize("args", [
    [], ["bogus"], ["segment"], ["segment", "--allowed"], ["segment", "--allowed", "de;ls"],
    ["segment", "--allowed", "../x"], ["segment", "--allowed", "de", "--unknown", "x"],
    ["normalize", "--lang"],
])
def test_invalid_arguments_exit_with_usage_error(helper_script, args):
    """Malformed commands and unsafe language codes are rejected with exit code 2.

    Args:
        helper_script: Path of htts_text.py.
        args: Invalid argument list.

    Returns:
        None.
    """
    # Usage errors must never reach the classifier or the shell.
    assert run_helper(helper_script, args, "text").returncode == 2


def test_detect_command_prints_one_language_code(helper_script, lid_model):
    """``detect`` prints the dominant language and nothing else.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # A clearly German sentence under the five-language allow-list.
    result = run_helper(helper_script, ["detect", "--allowed", FIVE, "--default", ""],
                        "Das Wetter ist heute sehr schön, deshalb gehen wir spazieren.")
    assert result.stdout.decode() == "de\n"


def test_normalize_and_markup_commands(helper_script, number_words):
    """``normalize`` and ``markup`` expose the two single stages.

    Args:
        helper_script: Path of htts_text.py.
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # Normalise one sentence, then clean one markdown line.
    spoken = run_helper(helper_script, ["normalize", "--lang", "de"], "Das kostet 5 Euro.")
    cleaned = run_helper(helper_script, ["markup"], "# Titel **fett**")
    assert spoken.stdout.decode() == "Das kostet fünf Euro.\n"
    assert cleaned.stdout.decode() == "Titel fett\n"


def test_empty_input_produces_no_output(helper_script, lid_model):
    """Empty and whitespace-only input yields no lines and success.

    Args:
        helper_script: Path of htts_text.py.
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # Nothing to read means nothing to print.
    result = run_helper(helper_script, ["segment", "--allowed", FIVE, "--default", "de"], " \n\n")
    assert result.returncode == 0 and result.stdout == b""
