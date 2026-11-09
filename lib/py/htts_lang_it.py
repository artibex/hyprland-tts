"""Italian normalisation rules: words, abbreviations, currency, units, dates and times."""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

import htts_numbers

# Language code of this rule set.
CODE = "it"
# Separators: comma is the decimal mark, period groups thousands.
DECIMAL_SEPARATOR = ","
THOUSANDS_SEPARATORS = "."
# Spoken words for numbers.
DECIMAL_WORD = "virgola"
MINUS_WORD = "meno"
PERCENT_WORD = "per cento"
# Italian writes ordinals as 1º, 2ª.
DOTTED_ORDINALS = False
ORDINAL_SUFFIX = r"[ºª°]"
# Italian years are plain cardinals.
YEAR_WORD_RANGE = None
YEAR_CONTEXT = frozenset()
# Month names, January first.
MONTHS = (
    "gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre"
).split()
# Unused for Italian (no case endings) but part of the shared interface.
OBLIQUE_CONTEXT = frozenset()
# Words for command-line and path symbols.
WORDS = {
    "dash": "trattino", "slash": "barra", "tilde": "tilde", "dot": "punto",
    "dollar": "dollaro", "equals": "uguale", "and": "e",
}
# Word that joins the major and minor currency amount.
CURRENCY_JOIN = "e"
# Currencies: singular, plural, minor singular, minor plural.
CURRENCIES = {
    "EUR": ("euro", "euro", "centesimo", "centesimi"),
    "USD": ("dollaro", "dollari", "centesimo", "centesimi"),
    "GBP": ("sterlina", "sterline", "penny", "penny"),
    "CHF": ("franco svizzero", "franchi svizzeri", "centesimo", "centesimi"),
}
# Units spoken after a number: symbol -> (singular, plural).
UNITS = {
    "km/h": ("chilometro orario", "chilometri orari"),
    "°C": ("grado Celsius", "gradi Celsius"),
    "km": ("chilometro", "chilometri"), "cm": ("centimetro", "centimetri"),
    "mm": ("millimetro", "millimetri"), "m": ("metro", "metri"),
    "kg": ("chilogrammo", "chilogrammi"), "g": ("grammo", "grammi"),
    "ml": ("millilitro", "millilitri"), "l": ("litro", "litri"),
    "TB": ("terabyte", "terabyte"), "GB": ("gigabyte", "gigabyte"),
    "MB": ("megabyte", "megabyte"), "min": ("minuto", "minuti"),
    "s": ("secondo", "secondi"), "h": ("ora", "ore"),
}
# Abbreviations: (regular expression, spoken form). Applied case-sensitively in order.
ABBREVIATIONS = (
    (r"ad\s?es\.", "ad esempio"), (r"ecc\.", "eccetera"), (r"Sig\.ra", "signora"),
    (r"Sig\.", "signor"), (r"Dott\.ssa", "dottoressa"), (r"Dott\.", "dottor"),
    (r"Prof\.", "professor"), (r"ca\.", "circa"), (r"pag\.", "pagina"),
    (r"n\.(?=\s?\d)", "numero"),
)
# Respellings for words the neural voice reads wrongly (none known for Italian).
PRONUNCIATIONS = ()


def inflect_ordinal(base: str, context_word: str, default_oblique: bool) -> str:
    """Return the ordinal unchanged (Italian ordinals keep the masculine form here).

    Args:
        base: Ordinal words.
        context_word: Unused.
        default_oblique: Unused.

    Returns:
        The same ordinal.
    """
    # Gender agreement would need a parser; the masculine form is the safe default.
    return base


def format_time(hour: int, minute: int, meridiem: str) -> str:
    """Speak a clock time ("le quattordici e trenta").

    Args:
        hour: Hour 0-24.
        minute: Minute 0-59.
        meridiem: Unused for Italian.

    Returns:
        The spoken time.
    """
    # One o'clock is singular ("l'una"), midnight has its own word.
    if hour in (0, 24) and minute == 0:
        return "mezzanotte"
    prefix, hour_words = ("l'", "una") if hour == 1 else ("le ", htts_numbers.cardinal(hour, CODE))
    # Full hours stand alone, others append the minutes.
    if minute == 0:
        return f"{prefix}{hour_words}"
    return f"{prefix}{hour_words} e {htts_numbers.cardinal(minute, CODE)}"


def format_date(day: int, month: int, year: str, context_word: str, day_first: bool) -> str:
    """Speak a date ("primo ottobre duemilaventisei").

    Args:
        day: Day of month.
        month: Month 1-12.
        year: Already spoken year, or empty.
        context_word: Unused for Italian.
        day_first: Unused for Italian.

    Returns:
        The spoken date.
    """
    # The first of the month is an ordinal, every other day a cardinal.
    day_words = "primo" if day == 1 else htts_numbers.cardinal(day, CODE)
    return " ".join(part for part in (day_words, MONTHS[month - 1], year) if part)
