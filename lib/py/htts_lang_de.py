"""German normalisation rules: words, abbreviations, currency, units, dates and times."""

# Annotations stay lazy so no typing import is needed at runtime.
from __future__ import annotations

import htts_numbers

# Language code of this rule set.
CODE = "de"
# Separators: comma is the decimal mark, period (and spaces) group thousands.
DECIMAL_SEPARATOR = ","
THOUSANDS_SEPARATORS = "."
# Spoken words for numbers.
DECIMAL_WORD = "Komma"
MINUS_WORD = "minus"
PERCENT_WORD = "Prozent"
# German writes ordinals as a number followed by a period ("3. Oktober").
DOTTED_ORDINALS = True
# Suffix notation for ordinals does not exist in German.
ORDINAL_SUFFIX = None
# Years from 1100 to 1999 are spoken in hundreds ("neunzehnhundert...").
YEAR_WORD_RANGE = (1100, 1999)
# Words that precede a year and therefore mark a number as a year.
YEAR_CONTEXT = frozenset(
    "in im seit bis von vor nach ab jahr jahre jahres anfang ende mitte um".split()
)
# Month names, January first.
MONTHS = (
    "Januar Februar März April Mai Juni Juli August September Oktober November Dezember"
).split()
# Prepositions after which a date ordinal is in the dative or accusative ("am dritten").
OBLIQUE_CONTEXT = frozenset(
    "am vom zum bis seit ab den im dem vor nach um für gegen zwischen".split()
)
# Words for command-line and path symbols.
WORDS = {
    "dash": "minus", "slash": "Slash", "tilde": "Tilde", "dot": "Punkt",
    "dollar": "Dollar", "equals": "gleich", "and": "und",
}
# Word that joins the major and minor currency amount.
CURRENCY_JOIN = "und"
# Currencies: singular, plural, minor singular, minor plural.
CURRENCIES = {
    "EUR": ("Euro", "Euro", "Cent", "Cent"),
    "USD": ("Dollar", "Dollar", "Cent", "Cent"),
    "GBP": ("Pfund", "Pfund", "Penny", "Pence"),
    "CHF": ("Franken", "Franken", "Rappen", "Rappen"),
    "JPY": ("Yen", "Yen", "Sen", "Sen"),
}
# Units spoken after a number: symbol -> (singular, plural).
UNITS = {
    "km/h": ("Kilometer pro Stunde", "Kilometer pro Stunde"),
    "m/s": ("Meter pro Sekunde", "Meter pro Sekunde"),
    "MB/s": ("Megabyte pro Sekunde", "Megabyte pro Sekunde"),
    "km²": ("Quadratkilometer", "Quadratkilometer"),
    "m²": ("Quadratmeter", "Quadratmeter"),
    "m³": ("Kubikmeter", "Kubikmeter"),
    "°C": ("Grad Celsius", "Grad Celsius"),
    "°F": ("Grad Fahrenheit", "Grad Fahrenheit"),
    "km": ("Kilometer", "Kilometer"), "cm": ("Zentimeter", "Zentimeter"),
    "mm": ("Millimeter", "Millimeter"), "m": ("Meter", "Meter"),
    "kg": ("Kilogramm", "Kilogramm"), "mg": ("Milligramm", "Milligramm"),
    "g": ("Gramm", "Gramm"), "t": ("Tonne", "Tonnen"),
    "ml": ("Milliliter", "Milliliter"), "l": ("Liter", "Liter"), "Cent": ("Cent", "Cent"),
    "TB": ("Terabyte", "Terabyte"), "GB": ("Gigabyte", "Gigabyte"),
    "MB": ("Megabyte", "Megabyte"), "kB": ("Kilobyte", "Kilobyte"),
    "KB": ("Kilobyte", "Kilobyte"), "GHz": ("Gigahertz", "Gigahertz"),
    "MHz": ("Megahertz", "Megahertz"), "kHz": ("Kilohertz", "Kilohertz"),
    "Hz": ("Hertz", "Hertz"), "kW": ("Kilowatt", "Kilowatt"), "W": ("Watt", "Watt"),
    "V": ("Volt", "Volt"), "mA": ("Milliampere", "Milliampere"),
    "ms": ("Millisekunde", "Millisekunden"), "min": ("Minute", "Minuten"),
    "s": ("Sekunde", "Sekunden"), "h": ("Stunde", "Stunden"),
    "px": ("Pixel", "Pixel"), "dpi": ("dpi", "dpi"),
}
# Abbreviations: (regular expression, spoken form). Applied case-sensitively in order.
ABBREVIATIONS = (
    (r"z\.\s?B\.", "zum Beispiel"), (r"u\.\s?a\.", "unter anderem"),
    (r"d\.\s?h\.", "das heißt"), (r"o\.\s?Ä\.", "oder Ähnliches"),
    (r"i\.\s?d\.\s?R\.", "in der Regel"), (r"z\.\s?T\.", "zum Teil"),
    (r"s\.\s?o\.", "siehe oben"), (r"s\.\s?u\.", "siehe unten"),
    (r"u\.\s?v\.\s?m\.", "und vieles mehr"), (r"v\.\s?a\.", "vor allem"),
    (r"bzw\.", "beziehungsweise"), (r"ca\.", "circa"), (r"Nr\.", "Nummer"),
    (r"Dr\.", "Doktor"), (r"Prof\.", "Professor"), (r"usw\.", "und so weiter"),
    (r"etc\.", "et cetera"), (r"vgl\.", "vergleiche"), (r"evtl\.", "eventuell"),
    (r"ggf\.", "gegebenenfalls"), (r"inkl\.", "inklusive"), (r"zzgl\.", "zuzüglich"),
    (r"bspw\.", "beispielsweise"), (r"Hr\.", "Herr"), (r"Str\.", "Straße"),
    (r"Tel\.", "Telefon"), (r"Mio\.", "Millionen"), (r"Mrd\.", "Milliarden"),
    (r"Abb\.", "Abbildung"), (r"Std\.", "Stunden"), (r"sog\.", "sogenannten"),
    (r"max\.", "maximal"), (r"Kfz", "Kraftfahrzeug"), (r"Pkw", "Personenkraftwagen"),
    (r"Lkw", "Lastkraftwagen"), (r"§", "Paragraph"),
)
# Respellings for English loanwords the neural voice reads wrongly in German.
PRONUNCIATIONS = (
    (r"Pull[- ]Request", "Pull Rikwest"),
)


def inflect_ordinal(base: str, context_word: str, default_oblique: bool) -> str:
    """Add the case ending to a German ordinal ("dritte" -> "dritten").

    Args:
        base: Nominative form from num2words ("dritte").
        context_word: Lowercase word in front of the number ("am").
        default_oblique: Ending to use when the context word gives no hint.

    Returns:
        The inflected ordinal.
    """
    # Articles that introduce the nominative keep the base form.
    if context_word in ("der", "die", "das", "ist", "war"):
        return base
    # Prepositions (and the date default) require the "-n" ending.
    if context_word in OBLIQUE_CONTEXT or default_oblique:
        return base + "n"
    return base


def format_time(hour: int, minute: int, meridiem: str) -> str:
    """Speak a clock time the German way ("vierzehn Uhr dreißig").

    Args:
        hour: Hour 0-24.
        minute: Minute 0-59.
        meridiem: Unused for German; always empty.

    Returns:
        The spoken time.
    """
    # "ein Uhr" needs the attributive form of one.
    hour_words = htts_numbers.before_noun(htts_numbers.cardinal(hour, CODE), CODE)
    # Full hours omit the minutes.
    if minute == 0:
        return f"{hour_words} Uhr"
    return f"{hour_words} Uhr {htts_numbers.cardinal(minute, CODE)}"


def format_date(day: int, month: int, year: str, context_word: str, day_first: bool) -> str:
    """Speak a date ("dritten Oktober zweitausendsechsundzwanzig").

    Args:
        day: Day of month.
        month: Month 1-12.
        year: Already spoken year, or empty.
        context_word: Lowercase word in front of the date.
        day_first: Unused for German (always day first).

    Returns:
        The spoken date.
    """
    # The ordinal takes the case that the preceding word demands.
    ordinal = inflect_ordinal(htts_numbers.ordinal(day, CODE), context_word, True)
    return " ".join(part for part in (ordinal, MONTHS[month - 1], year) if part)
