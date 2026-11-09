"""French normalisation rules: words, abbreviations, currency, units, dates and times."""

# Annotations stay lazy so no typing import is needed at runtime.
from __future__ import annotations

import htts_numbers

# Language code of this rule set.
CODE = "fr"
# Separators: comma is the decimal mark, spaces and periods group thousands.
DECIMAL_SEPARATOR = ","
THOUSANDS_SEPARATORS = " ."
# Spoken words for numbers.
DECIMAL_WORD = "virgule"
MINUS_WORD = "moins"
PERCENT_WORD = "pour cent"
# French writes ordinals as 1er, 2e, 3ème.
DOTTED_ORDINALS = False
ORDINAL_SUFFIX = r"(?:er|re|ère|e|ème|eme|nd|nde)"
# French years are plain cardinals.
YEAR_WORD_RANGE = None
YEAR_CONTEXT = frozenset()
# Month names, January first.
MONTHS = (
    "janvier février mars avril mai juin juillet août septembre octobre novembre décembre"
).split()
# Unused for French (no case endings) but part of the shared interface.
OBLIQUE_CONTEXT = frozenset()
# Words for command-line and path symbols.
WORDS = {
    "dash": "tiret", "slash": "slash", "tilde": "tilde", "dot": "point",
    "dollar": "dollar", "equals": "égal", "and": "et",
}
# Word that joins the major and minor currency amount.
CURRENCY_JOIN = "et"
# Currencies: singular, plural, minor singular, minor plural.
CURRENCIES = {
    "EUR": ("euro", "euros", "centime", "centimes"),
    "USD": ("dollar", "dollars", "cent", "cents"),
    "GBP": ("livre sterling", "livres sterling", "penny", "pence"),
    "CHF": ("franc suisse", "francs suisses", "centime", "centimes"),
}
# Units spoken after a number: symbol -> (singular, plural).
UNITS = {
    "km/h": ("kilomètre par heure", "kilomètres par heure"),
    "°C": ("degré Celsius", "degrés Celsius"),
    "km": ("kilomètre", "kilomètres"), "cm": ("centimètre", "centimètres"),
    "mm": ("millimètre", "millimètres"), "m": ("mètre", "mètres"),
    "kg": ("kilogramme", "kilogrammes"), "g": ("gramme", "grammes"),
    "ml": ("millilitre", "millilitres"), "l": ("litre", "litres"),
    "TB": ("téraoctet", "téraoctets"), "GB": ("gigaoctet", "gigaoctets"),
    "MB": ("mégaoctet", "mégaoctets"), "Go": ("gigaoctet", "gigaoctets"),
    "Mo": ("mégaoctet", "mégaoctets"), "min": ("minute", "minutes"),
    "s": ("seconde", "secondes"), "h": ("heure", "heures"),
}
# Abbreviations: (regular expression, spoken form). Applied case-sensitively in order.
ABBREVIATIONS = (
    (r"p\.\s?ex\.", "par exemple"), (r"c\.-à-d\.", "c'est-à-dire"),
    (r"etc\.", "et cetera"), (r"Mme", "Madame"), (r"Mlle", "Mademoiselle"),
    (r"M\.(?=\s[A-ZÉ])", "Monsieur"), (r"Dr\.?(?=\s[A-ZÉ])", "Docteur"),
    (r"Pr\.(?=\s[A-ZÉ])", "Professeur"), (r"env\.", "environ"), (r"n°", "numéro"),
)
# Respellings for words the neural voice reads wrongly (none known for French).
PRONUNCIATIONS = ()


def inflect_ordinal(base: str, context_word: str, default_oblique: bool) -> str:
    """Return the ordinal unchanged (French has no case endings).

    Args:
        base: Ordinal words.
        context_word: Unused.
        default_oblique: Unused.

    Returns:
        The same ordinal.
    """
    # French ordinals do not inflect for case.
    return base


def format_time(hour: int, minute: int, meridiem: str) -> str:
    """Speak a clock time ("quatorze heures trente").

    Args:
        hour: Hour 0-24.
        minute: Minute 0-59.
        meridiem: Unused for French.

    Returns:
        The spoken time.
    """
    # One o'clock is feminine ("une heure"), everything else uses the cardinal.
    hour_words = "une" if hour == 1 else htts_numbers.cardinal(hour, CODE)
    unit = "heure" if hour in (0, 1) else "heures"
    # Full hours omit the minutes.
    if minute == 0:
        return f"{hour_words} {unit}"
    return f"{hour_words} {unit} {htts_numbers.cardinal(minute, CODE)}"


def format_date(day: int, month: int, year: str, context_word: str, day_first: bool) -> str:
    """Speak a date ("premier octobre deux mille vingt-six").

    Args:
        day: Day of month.
        month: Month 1-12.
        year: Already spoken year, or empty.
        context_word: Unused for French.
        day_first: Unused for French.

    Returns:
        The spoken date.
    """
    # The first of the month is an ordinal, every other day a cardinal.
    day_words = "premier" if day == 1 else htts_numbers.cardinal(day, CODE)
    return " ".join(part for part in (day_words, MONTHS[month - 1], year) if part)
