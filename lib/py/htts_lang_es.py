"""Spanish normalisation rules: words, abbreviations, currency, units, dates and times."""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

import htts_numbers

# Language code of this rule set.
CODE = "es"
# Separators: comma is the decimal mark, period groups thousands.
DECIMAL_SEPARATOR = ","
THOUSANDS_SEPARATORS = "."
# Spoken words for numbers.
DECIMAL_WORD = "coma"
MINUS_WORD = "menos"
PERCENT_WORD = "por ciento"
# Spanish writes ordinals as 1º, 2ª.
DOTTED_ORDINALS = False
ORDINAL_SUFFIX = r"\.?[ºª°]"
# Spanish years are plain cardinals.
YEAR_WORD_RANGE = None
YEAR_CONTEXT = frozenset()
# Month names, January first.
MONTHS = (
    "enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre"
).split()
# Unused for Spanish (no case endings) but part of the shared interface.
OBLIQUE_CONTEXT = frozenset()
# Words for command-line and path symbols.
WORDS = {
    "dash": "guion", "slash": "barra", "tilde": "tilde", "dot": "punto",
    "dollar": "dólar", "equals": "igual", "and": "y",
}
# Word that joins the major and minor currency amount.
CURRENCY_JOIN = "con"
# Currencies: singular, plural, minor singular, minor plural.
CURRENCIES = {
    "EUR": ("euro", "euros", "céntimo", "céntimos"),
    "USD": ("dólar", "dólares", "centavo", "centavos"),
    "GBP": ("libra", "libras", "penique", "peniques"),
    "CHF": ("franco suizo", "francos suizos", "céntimo", "céntimos"),
}
# Units spoken after a number: symbol -> (singular, plural).
UNITS = {
    "km/h": ("kilómetro por hora", "kilómetros por hora"),
    "°C": ("grado Celsius", "grados Celsius"),
    "km": ("kilómetro", "kilómetros"), "cm": ("centímetro", "centímetros"),
    "mm": ("milímetro", "milímetros"), "m": ("metro", "metros"),
    "kg": ("kilogramo", "kilogramos"), "g": ("gramo", "gramos"),
    "ml": ("mililitro", "mililitros"), "l": ("litro", "litros"),
    "TB": ("terabyte", "terabytes"), "GB": ("gigabyte", "gigabytes"),
    "MB": ("megabyte", "megabytes"), "min": ("minuto", "minutos"),
    "s": ("segundo", "segundos"), "h": ("hora", "horas"),
}
# Abbreviations: (regular expression, spoken form). Applied case-sensitively in order.
ABBREVIATIONS = (
    (r"p\.\s?ej\.", "por ejemplo"), (r"EE\.\s?UU\.", "Estados Unidos"),
    (r"etc\.", "etcétera"), (r"Sra\.", "señora"), (r"Srta\.", "señorita"),
    (r"Sr\.", "señor"), (r"Dra\.", "doctora"), (r"Dr\.", "doctor"),
    (r"Ud\.", "usted"), (r"núm\.", "número"), (r"aprox\.", "aproximadamente"),
    (r"pág\.", "página"),
)
# Respellings for words the neural voice reads wrongly (none known for Spanish).
PRONUNCIATIONS = ()


def inflect_ordinal(base: str, context_word: str, default_oblique: bool) -> str:
    """Return the ordinal unchanged (Spanish ordinals keep the masculine form here).

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
    """Speak a clock time ("las catorce y treinta").

    Args:
        hour: Hour 0-24.
        minute: Minute 0-59.
        meridiem: Unused for Spanish.

    Returns:
        The spoken time.
    """
    # One o'clock is singular ("la una"), all other hours are "las ...".
    prefix, hour_words = ("la", "una") if hour == 1 else ("las", htts_numbers.cardinal(hour, CODE))
    # Full hours get "en punto", others append the minutes.
    if minute == 0:
        return f"{prefix} {hour_words} en punto"
    return f"{prefix} {hour_words} y {htts_numbers.cardinal(minute, CODE)}"


def format_date(day: int, month: int, year: str, context_word: str, day_first: bool) -> str:
    """Speak a date ("primero de octubre de dos mil veintiséis").

    Args:
        day: Day of month.
        month: Month 1-12.
        year: Already spoken year, or empty.
        context_word: Unused for Spanish.
        day_first: Unused for Spanish.

    Returns:
        The spoken date.
    """
    # The first of the month is an ordinal, every other day a cardinal.
    day_words = "primero" if day == 1 else htts_numbers.cardinal(day, CODE)
    core = f"{day_words} de {MONTHS[month - 1]}"
    return f"{core} de {year}" if year else core
