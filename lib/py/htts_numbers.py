"""Number words for the text normaliser, backed by the ``num2words`` library.

``num2words`` (pure Python, LGPL-2.1) was checked for de/en/fr/es/it and produces correct
cardinals, ordinals and years including the irregular forms (French "quatre-vingt-dix",
Spanish "veintiuno", Italian "milleduecento"). Writing five such grammars by hand would
be more code and more bugs, so this module only adds the small fixes the library lacks:
English commas, "ein" before a noun, and a graceful fallback when the library is absent.
"""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

# Import machinery used to load a single num2words language module.
import importlib
import importlib.util
import sys
import types

# Languages the library can handle; everything else keeps digits.
NUM2WORDS_LANGUAGES = frozenset({"de", "en", "fr", "es", "it", "nl", "pt"})
# "one" before a masculine noun is shortened in these languages.
ONE_BEFORE_NOUN = {
    "de": (("eins", "ein"),),
    "es": (("veintiuno", "veintiún"), ("uno", "un")),
    "it": (("ventuno", "ventun"), ("uno", "un")),
}

_CONVERTERS: dict = {}


def num2words_installed() -> bool:
    """Tell whether the ``num2words`` package can be found (without importing it).

    Returns:
        True when the package is importable.
    """
    # An already registered (real or stub) package counts as installed.
    if "num2words" in sys.modules:
        return True
    # find_spec only locates the package; it does not execute its slow __init__.
    return importlib.util.find_spec("num2words") is not None


def import_language_module(lang: str):
    """Import one ``num2words.lang_XX`` module without loading all 30+ languages.

    The package ``__init__`` imports every language table (about 25 ms). A stub parent
    package with the real search path lets the single needed module import itself.

    Args:
        lang: ISO 639-1 code.

    Returns:
        The language module.
    """
    # Register a stub parent once so relative imports inside the module resolve.
    if "num2words" not in sys.modules:
        spec = importlib.util.find_spec("num2words")
        stub = types.ModuleType("num2words")
        # The stub carries the real search path so the language module imports normally.
        stub.__path__ = list(spec.submodule_search_locations)
        stub.__spec__ = spec
        # Registering the stub first lets relative imports inside the module resolve.
        sys.modules["num2words"] = stub
    return importlib.import_module(f"num2words.lang_{lang.upper()}")


def load_converter(lang: str):
    """Create (once) the num2words converter object of one language.

    Args:
        lang: ISO 639-1 code.

    Returns:
        The converter instance, or None when the language or the library is unsupported.
    """
    # Unsupported languages and a missing library keep the digits.
    if lang not in NUM2WORDS_LANGUAGES or not words_available():
        return None
    if lang not in _CONVERTERS:
        # Import only this language and build its converter once.
        module = import_language_module(lang)
        _CONVERTERS[lang] = getattr(module, f"Num2Word_{lang.upper()}")()
    return _CONVERTERS[lang]


def words_available() -> bool:
    """Tell whether number words can be produced at all.

    Returns:
        True when ``num2words`` is installed.
    """
    # Tests replace this function to simulate a missing library.
    return num2words_installed()


def convert(value: int, lang: str, kind: str) -> str:
    """Convert an integer with ``num2words`` and fall back to digits.

    Args:
        value: Non-negative integer.
        lang: ISO 639-1 code.
        kind: ``cardinal``, ``ordinal`` or ``year``.

    Returns:
        Number words, or the plain digits when the language or library is unsupported.
    """
    # Without a converter the digits stay as they are.
    converter = load_converter(lang)
    if converter is None:
        return str(value)
    # Library failures (overflow, odd values) also keep the digits.
    try:
        return getattr(converter, f"to_{kind}")(value)
    except (OverflowError, NotImplementedError, ValueError, KeyError, IndexError):
        return str(value)


def cardinal(value: int, lang: str) -> str:
    """Spell an integer as a cardinal number.

    Args:
        value: Non-negative integer.
        lang: ISO 639-1 code.

    Returns:
        Words such as "twenty-one"; English commas are removed for smoother speech.
    """
    # English output contains commas ("one thousand, two hundred") that cause pauses.
    return convert(value, lang, "cardinal").replace(",", "")


def ordinal(value: int, lang: str) -> str:
    """Spell an integer as an ordinal number.

    Args:
        value: Positive integer.
        lang: ISO 639-1 code.

    Returns:
        Words such as "third" or German "dritte" (base form).
    """
    # The library returns the base form; callers inflect it when the grammar needs it.
    return convert(value, lang, "ordinal").replace(",", "")


def year(value: int, lang: str) -> str:
    """Spell a number as a year ("nineteen ninety-nine", German "neunzehnhundert...").

    Args:
        value: Year between 1000 and 2099.
        lang: ISO 639-1 code.

    Returns:
        The spoken year.
    """
    # The library knows the language-specific year grouping.
    return convert(value, lang, "year").replace(",", "")


def before_noun(words: str, lang: str) -> str:
    """Shorten a trailing "one" when a noun follows ("ein Euro", "un euro").

    Args:
        words: Cardinal words.
        lang: ISO 639-1 code.

    Returns:
        The words with the final "one" in its attributive form.
    """
    # Only languages with a distinct attributive form have replacement rules.
    for full, short in ONE_BEFORE_NOUN.get(lang, ()):
        if words.endswith(full):
            return words[: -len(full)] + short
    return words


def spell_digits(digits: str, lang: str) -> str:
    """Read a digit string digit by digit (phone numbers, codes, leading zeros).

    Args:
        digits: Characters 0-9 only.
        lang: ISO 639-1 code.

    Returns:
        Space-separated digit words.
    """
    # Each digit is a cardinal on its own.
    return " ".join(cardinal(int(digit), lang) for digit in digits)


def decimal(integer: int, fraction: str, lang: str, point_word: str) -> str:
    """Spell a decimal number with the fraction read digit by digit.

    Args:
        integer: Integer part.
        fraction: Fraction digits as text (may have leading zeros).
        lang: ISO 639-1 code.
        point_word: The word for the decimal separator ("Komma", "point").

    Returns:
        Words such as "drei Komma fünf".
    """
    # The integer part is a normal cardinal, the fraction is spelled digit by digit.
    return f"{cardinal(integer, lang)} {point_word} {spell_digits(fraction, lang)}"
