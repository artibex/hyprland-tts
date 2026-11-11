"""English normalisation rules: words, abbreviations, currency, units, dates and times."""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

import htts_numbers

# Language code of this rule set.
CODE = "en"
# Separators: period is the decimal mark, comma groups thousands.
DECIMAL_SEPARATOR = "."
THOUSANDS_SEPARATORS = ","
# Spoken words for numbers.
DECIMAL_WORD = "point"
MINUS_WORD = "minus"
PERCENT_WORD = "percent"
# English has no "3." ordinals; it writes 3rd.
DOTTED_ORDINALS = False
# English writes clock times with AM/PM.
MERIDIEM = True
ORDINAL_SUFFIX = r"(?:st|nd|rd|th)"
# Years from 1100 to 2099 are spoken in pairs ("twenty twenty-six").
YEAR_WORD_RANGE = (1100, 2099)
# Words that precede a year and therefore mark a number as a year.
YEAR_CONTEXT = frozenset(
    "in since until till by from year before after during circa around of through between".split()
)
# Month names, January first.
MONTHS = (
    "January February March April May June July August September October November December"
).split()
# Unused for English (no case endings) but part of the shared interface.
OBLIQUE_CONTEXT = frozenset()
# Words for command-line and path symbols.
WORDS = {
    "dash": "dash", "slash": "slash", "tilde": "tilde", "dot": "dot",
    "dollar": "dollar", "equals": "equals", "and": "and",
}
# Word that joins the major and minor currency amount.
CURRENCY_JOIN = "and"
# Currencies: singular, plural, minor singular, minor plural.
CURRENCIES = {
    "EUR": ("euro", "euros", "cent", "cents"),
    "USD": ("dollar", "dollars", "cent", "cents"),
    "GBP": ("pound", "pounds", "penny", "pence"),
    "CHF": ("Swiss franc", "Swiss francs", "rappen", "rappen"),
    "JPY": ("yen", "yen", "sen", "sen"),
}
# Units spoken after a number: symbol -> (singular, plural).
UNITS = {
    "km/h": ("kilometer per hour", "kilometers per hour"),
    "mph": ("mile per hour", "miles per hour"),
    "m/s": ("meter per second", "meters per second"),
    "MB/s": ("megabyte per second", "megabytes per second"),
    "km²": ("square kilometer", "square kilometers"),
    "m²": ("square meter", "square meters"),
    "m³": ("cubic meter", "cubic meters"),
    "°C": ("degree Celsius", "degrees Celsius"),
    "°F": ("degree Fahrenheit", "degrees Fahrenheit"),
    "km": ("kilometer", "kilometers"), "cm": ("centimeter", "centimeters"),
    "mm": ("millimeter", "millimeters"), "m": ("meter", "meters"),
    "kg": ("kilogram", "kilograms"), "mg": ("milligram", "milligrams"),
    "g": ("gram", "grams"), "t": ("ton", "tons"),
    "ml": ("milliliter", "milliliters"), "l": ("liter", "liters"),
    "TB": ("terabyte", "terabytes"), "GB": ("gigabyte", "gigabytes"),
    "MB": ("megabyte", "megabytes"), "kB": ("kilobyte", "kilobytes"),
    "KB": ("kilobyte", "kilobytes"), "GHz": ("gigahertz", "gigahertz"),
    "MHz": ("megahertz", "megahertz"), "kHz": ("kilohertz", "kilohertz"),
    "Hz": ("hertz", "hertz"), "kW": ("kilowatt", "kilowatts"), "W": ("watt", "watts"),
    "V": ("volt", "volts"), "mA": ("milliamp", "milliamps"),
    "ms": ("millisecond", "milliseconds"), "min": ("minute", "minutes"),
    "s": ("second", "seconds"), "h": ("hour", "hours"),
    "px": ("pixel", "pixels"), "dpi": ("dpi", "dpi"),
}
# Abbreviations: (regular expression, spoken form). Applied case-sensitively in order.
ABBREVIATIONS = (
    (r"e\.g\.", "for example"), (r"i\.e\.", "that is"), (r"etc\.", "et cetera"),
    (r"a\.k\.a\.", "also known as"), (r"Dr\.", "Doctor"), (r"Mr\.", "Mister"),
    (r"Mrs\.", "Missus"), (r"Ms\.", "Miss"), (r"Prof\.", "Professor"),
    (r"vs\.", "versus"), (r"approx\.", "approximately"), (r"cf\.", "compare"),
    (r"Fig\.", "Figure"), (r"No\.(?=\s?\d)", "Number"), (r"w/o\b", "without"),
    (r"w/(?=\s)", "with"),
)
# Respellings for words the neural voice reads wrongly (none known for English).
PRONUNCIATIONS = ()


def inflect_ordinal(base: str, context_word: str, default_oblique: bool) -> str:
    """Return the ordinal unchanged (English has no case endings).

    Args:
        base: Ordinal words.
        context_word: Unused.
        default_oblique: Unused.

    Returns:
        The same ordinal.
    """
    # English ordinals never change with the grammatical case.
    return base


def spell_meridiem(meridiem: str) -> str:
    """Spell AM/PM letter by letter.

    Args:
        meridiem: "AM", "PM" (any case, dots allowed) or empty.

    Returns:
        "A M", "P M" or an empty string.
    """
    # Keep only the letters so "p.m." and "PM" are treated alike.
    letters = [char.upper() for char in meridiem if char.isalpha()]
    return " ".join(letters)


def spell_full_hour(hour: int, suffix: str) -> str:
    """Speak a time without minutes ("two P M", "fourteen hundred", "nine o'clock").

    Args:
        hour: Hour 0-24.
        suffix: Spelled AM/PM letters, or empty.

    Returns:
        The spoken full hour.
    """
    # With AM/PM the hour is simply followed by the letters.
    hour_words = htts_numbers.cardinal(hour, CODE)
    if suffix:
        return f"{hour_words} {suffix}"
    # 24-hour times use "hundred", 12-hour clock hours use "o'clock".
    return f"{hour_words} hundred" if hour >= 13 or hour == 0 else f"{hour_words} o'clock"


def format_time(hour: int, minute: int, meridiem: str) -> str:
    """Speak a clock time ("two thirty P M", "nine oh five", "fourteen hundred").

    Args:
        hour: Hour 0-24 (1-12 when a meridiem is given).
        minute: Minute 0-59.
        meridiem: "AM"/"PM" or empty.

    Returns:
        The spoken time.
    """
    # Full hours have their own phrasing.
    suffix = spell_meridiem(meridiem)
    if minute == 0:
        return spell_full_hour(hour, suffix)
    # Minutes below ten are read with "oh" (nine oh five).
    minute_words = htts_numbers.cardinal(minute, CODE)
    minute_words = f"oh {minute_words}" if minute < 10 else minute_words
    return f"{htts_numbers.cardinal(hour, CODE)} {minute_words} {suffix}".strip()


def format_date(day: int, month: int, year: str, context_word: str, day_first: bool) -> str:
    """Speak a date ("October third, twenty twenty-six").

    Args:
        day: Day of month.
        month: Month 1-12.
        year: Already spoken year, or empty.
        context_word: Unused for English.
        day_first: True for "the third of October" (British) order.

    Returns:
        The spoken date.
    """
    # The day is an ordinal; the order depends on the writing convention.
    ordinal = htts_numbers.ordinal(day, CODE)
    month_name = MONTHS[month - 1]
    core = f"the {ordinal} of {month_name}" if day_first else f"{month_name} {ordinal}"
    # A year is separated by a comma pause.
    return f"{core}, {year}" if year else core
