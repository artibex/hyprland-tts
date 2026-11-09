"""Numeric normalisation stages: numbers, currency, percent, units, dates, times, years.

Every stage takes the sentence and the language rule module and returns the rewritten
sentence. The language (and with it the number format: German ``1.250,75`` versus English
``1,250.75``) is decided before these stages run, once per sentence.
"""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

import re

import htts_numbers

# Characters that may not touch a number from the left (identifiers, other numbers).
LEFT_GUARD = r"(?<![\w.,])"
# Characters that may not touch a number from the right.
RIGHT_GUARD = r"(?![\w]|[.,]?\d)"
# Plain digit strings of this length or more are identifiers (phone numbers), not quantities.
LONG_DIGIT_STRING = 7
# The word for "+" in front of an international phone number.
PLUS_WORDS = {"de": "plus", "en": "plus", "fr": "plus", "es": "más", "it": "più"}
# Integer strings longer than this are data (hashes, dumps), not quantities; they stay as written.
MAX_QUANTITY_DIGITS = 30
# Leading articles of a spoken time that duplicate a preposition already in the text.
TIME_ARTICLES = {"las": "las ", "la": "la ", "alle": "le ", "dalle": "le ", "delle": "le "}
# Currency name or symbol (as written in the text) to ISO code.
CURRENCY_WORDS = {
    "€": "EUR", "EUR": "EUR", "Euro": "EUR", "Euros": "EUR", "euro": "EUR", "euros": "EUR",
    "$": "USD", "USD": "USD", "Dollar": "USD", "Dollars": "USD", "dollar": "USD",
    "dollars": "USD", "£": "GBP", "GBP": "GBP", "Pfund": "GBP", "pounds": "GBP",
    "CHF": "CHF", "Franken": "CHF",
}
# Longest names first so "Euros" wins over "Euro".
CURRENCY_ALTERNATION = "|".join(
    re.escape(word) for word in sorted(CURRENCY_WORDS, key=len, reverse=True)
)
# English writes 3/10/2026 as month/day/year unless the first value cannot be a month.
MONTH_FIRST_LANGUAGES = frozenset({"en"})

_PATTERN_CACHE: dict[tuple[str, str], re.Pattern[str]] = {}


class ParsedNumber:
    """A number split into sign, integer digits and fraction digits.

    Attributes:
        negative: True when a minus sign preceded the number.
        digits: Integer part without separators.
        fraction: Digits after the decimal mark (empty for integers).
        grouped: True when the integer part used thousands separators.
    """

    __slots__ = ("negative", "digits", "fraction", "grouped")

    def __init__(self, negative: bool, digits: str, fraction: str, grouped: bool) -> None:
        """Store the parts of the number.

        Args:
            negative: Whether the number is negative.
            digits: Integer digits.
            fraction: Fraction digits.
            grouped: Whether the integer part had thousands separators.

        Returns:
            None.
        """
        # Plain attributes keep the class cheap.
        self.negative = negative
        self.digits = digits
        self.fraction = fraction
        self.grouped = grouped

    @property
    def is_one(self) -> bool:
        """Return True for exactly the value one (singular noun forms)."""
        # Fractions and signs make the value something other than one.
        return self.digits == "1" and not self.fraction and not self.negative


def number_core(rules) -> str:
    """Build the regular expression that matches one locale-formatted number.

    Args:
        rules: Language rule module (supplies the thousands separators).

    Returns:
        A pattern with the named groups sign, int, dsep and frac.
    """
    # Thousands separators of the language plus (narrow) no-break spaces.
    group_chars = re.escape(rules.THOUSANDS_SEPARATORS) + "\u00a0\u202f"
    grouped_integer = r"\d{1,3}(?:[" + group_chars + r"]\d{3})+"
    # A lone period or comma followed by digits is a decimal mark.
    return (
        r"(?P<sign>[-−](?=\d))?(?P<int>" + grouped_integer + r"|\d+)"
        r"(?:(?P<dsep>[.,])(?P<frac>\d+))?"
    )


def cached_pattern(rules, name: str, builder) -> re.Pattern[str]:
    """Compile a language-specific pattern once per process.

    Args:
        rules: Language rule module.
        name: Pattern name, unique per stage.
        builder: Function that receives ``rules`` and returns the pattern text.

    Returns:
        The compiled pattern.
    """
    # Build and compile on first use only.
    key = (rules.CODE, name)
    if key not in _PATTERN_CACHE:
        _PATTERN_CACHE[key] = re.compile(builder(rules))
    return _PATTERN_CACHE[key]


def parse_number(match: re.Match[str]) -> ParsedNumber:
    """Convert a match of ``number_core`` into a ``ParsedNumber``.

    Args:
        match: Regex match with the groups sign, int and frac.

    Returns:
        The parsed number.
    """
    # Separators are dropped from the integer part; any leftover mark is a decimal point.
    integer_text = match.group("int")
    digits = re.sub(r"\D", "", integer_text)
    return ParsedNumber(
        negative=bool(match.group("sign")),
        digits=digits,
        fraction=match.group("frac") or "",
        grouped=len(digits) != len(integer_text),
    )


def reads_as_digits(number: ParsedNumber) -> bool:
    """Decide whether a number is an identifier that is read digit by digit.

    Args:
        number: The parsed number.

    Returns:
        True for leading zeros ("0170") and long plain digit strings (phone numbers).
    """
    # Grouped numbers and decimals are always real quantities.
    if number.grouped or number.fraction:
        return False
    leading_zero = len(number.digits) > 1 and number.digits.startswith("0")
    return leading_zero or len(number.digits) >= LONG_DIGIT_STRING


def keeps_digits(number: ParsedNumber) -> bool:
    """Tell whether a number is too long to be a quantity (left as written).

    Args:
        number: The parsed number.

    Returns:
        True above ``MAX_QUANTITY_DIGITS`` integer digits; such strings are data, not amounts,
        and Python refuses to convert integers beyond 4300 digits at all.
    """
    # The integer and fraction parts are both bounded: a huge fraction is spelled digit by digit.
    return len(number.digits) > MAX_QUANTITY_DIGITS


def speak_number(number: ParsedNumber, rules, attributive: bool = False) -> str:
    """Spell a parsed number in the language of ``rules``.

    Args:
        number: The parsed number.
        rules: Language rule module.
        attributive: True when a noun follows ("ein Euro" instead of "eins Euro").

    Returns:
        The number as words.
    """
    # Absurdly long digit strings stay as they are instead of crashing the whole text.
    if keeps_digits(number):
        fraction = f",{number.fraction}" if number.fraction else ""
        return f"{'-' if number.negative else ''}{number.digits}{fraction}"
    # Decimals read the fraction digit by digit; identifiers read every digit.
    if number.fraction:
        words = htts_numbers.decimal(
            int(number.digits), number.fraction, rules.CODE, rules.DECIMAL_WORD
        )
    elif reads_as_digits(number):
        words = htts_numbers.spell_digits(number.digits, rules.CODE)
    else:
        # Plain quantities are cardinals; "one" shortens before a noun.
        words = htts_numbers.cardinal(int(number.digits), rules.CODE)
        words = htts_numbers.before_noun(words, rules.CODE) if attributive else words
    # A minus sign is spoken in front.
    return f"{rules.MINUS_WORD} {words}" if number.negative else words


def previous_word(text: str, position: int) -> str:
    """Return the lowercase word in front of a position (empty at the start).

    Args:
        text: The sentence.
        position: Index where the match starts.

    Returns:
        The previous word without punctuation.
    """
    # Only a short window in front of the match matters.
    window = text[max(0, position - 40):position]
    found = re.search(r"(\w+)[\s,]*$", window)
    return found.group(1).lower() if found else ""


def previous_abbreviation(text: str, position: int) -> str:
    """Return the lowercase word in front of a position, allowing one trailing period ("S. ").

    Args:
        text: The sentence.
        position: Index where the match starts.

    Returns:
        The previous word without its period (empty at the start).
    """
    # Same short window as previous_word; the optional period lets "S." count as "s".
    found = re.search(r"(\w+)\.?\s*$", text[max(0, position - 40):position])
    return found.group(1).lower() if found else ""


def spoken_year(value: int, rules) -> str:
    """Speak a year with the language's year convention.

    Args:
        value: The year.
        rules: Language rule module.

    Returns:
        Year words ("nineteen ninety-nine") or the plain cardinal.
    """
    # Languages with a year convention use it inside their word range only.
    year_range = rules.YEAR_WORD_RANGE
    if year_range and year_range[0] <= value <= year_range[1]:
        return htts_numbers.year(value, rules.CODE)
    return htts_numbers.cardinal(value, rules.CODE)


def number_with_unit_pattern(rules, tail: str) -> str:
    """Build a pattern for a number followed by ``tail``.

    Args:
        rules: Language rule module.
        tail: Pattern text that must follow the number.

    Returns:
        The combined pattern text.
    """
    # The left guard stops matches inside identifiers; the tail decides the rest.
    return LEFT_GUARD + number_core(rules) + tail


def attributive_cardinal(value: int, rules) -> str:
    """Spell an integer in the form used in front of a noun ("ein Euro").

    Args:
        value: Non-negative integer.
        rules: Language rule module.

    Returns:
        The cardinal words with the attributive "one".
    """
    # The attributive form only differs for the final "one".
    return htts_numbers.before_noun(htts_numbers.cardinal(value, rules.CODE), rules.CODE)


def expand_currency_amount(match: re.Match[str], rules) -> str:
    """Speak a currency amount ("1.250,75 €" -> "... Euro und fünfundsiebzig Cent").

    Args:
        match: Match with ``code`` and the number groups.
        rules: Language rule module.

    Returns:
        The spoken amount, or the original text for unknown currencies.
    """
    # Unknown currencies stay untouched.
    code = CURRENCY_WORDS[match.group("code")]
    if code not in rules.CURRENCIES:
        return match.group(0)
    # The currency table supplies the major and minor word forms.
    number = parse_number(match)
    major_one, major_many, minor_one, minor_many = rules.CURRENCIES[code]
    # Amounts beyond any real price stay untouched, like every over-long digit string.
    if keeps_digits(number):
        return match.group(0)
    # More than two fraction digits is not money-like; read it as a decimal.
    if len(number.fraction) > 2:
        return f"{speak_number(number, rules)} {major_many}"
    # Integer and minor units are spoken separately ("zwölf Euro und fünfzig Cent").
    minor = int(number.fraction.ljust(2, "0")) if number.fraction else 0
    major_value = int(number.digits)
    pieces = []
    # A zero major amount is skipped when cents exist ("fünfzig Cent").
    if major_value or not minor:
        major_words = attributive_cardinal(major_value, rules)
        pieces.append(f"{major_words} {major_one if major_value == 1 else major_many}")
    if minor:
        # Cents follow the same singular/plural rule.
        minor_words = attributive_cardinal(minor, rules)
        pieces.append(f"{minor_words} {minor_one if minor == 1 else minor_many}")
    # Join the parts ("zwölf Euro und fünfzig Cent") and put a minus sign in front.
    spoken = f" {rules.CURRENCY_JOIN} ".join(pieces)
    return f"{rules.MINUS_WORD} {spoken}" if number.negative else spoken


def currency_patterns(rules) -> tuple[str, str]:
    """Build the prefix and suffix currency patterns.

    Args:
        rules: Language rule module.

    Returns:
        Pattern text for "€ 12,50" and for "12,50 €".
    """
    # The currency may stand before the number (symbol or code) or after it.
    prefix = r"(?<!\w)(?P<code>[€$£]|EUR|USD|GBP|CHF)\s?" + number_core(rules) + RIGHT_GUARD
    suffix = (
        LEFT_GUARD + number_core(rules) + r"\s?(?P<code>" + CURRENCY_ALTERNATION + r")(?!\w)"
    )
    return prefix, suffix


def expand_currency(text: str, rules) -> str:
    """Speak currency amounts in front of or behind a number.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with amounts spoken.
    """
    # Both notations share the same renderer.
    prefix = cached_pattern(rules, "currency-prefix", lambda r: currency_patterns(r)[0])
    suffix = cached_pattern(rules, "currency-suffix", lambda r: currency_patterns(r)[1])
    for pattern in (prefix, suffix):
        # Both notations are replaced with the same renderer.
        text = pattern.sub(lambda match: expand_currency_amount(match, rules), text)
    return text


def expand_percent(text: str, rules) -> str:
    """Speak percentages ("12,5 %" -> "zwölf Komma fünf Prozent").

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with percentages spoken.
    """
    # The percent sign may be separated from the number by one space.
    pattern = cached_pattern(rules, "percent", lambda r: number_with_unit_pattern(r, r"\s?%"))
    return pattern.sub(
        lambda match: f"{speak_number(parse_number(match), rules)} {rules.PERCENT_WORD}", text
    )


def unit_tail(rules) -> str:
    """Build the pattern part that matches any known unit symbol.

    Args:
        rules: Language rule module.

    Returns:
        Pattern text with a named group ``unit``.
    """
    # Longest symbols first so "min" wins over "m" and "km/h" over "km".
    symbols = sorted(rules.UNITS, key=len, reverse=True)
    alternation = "|".join(re.escape(symbol) for symbol in symbols)
    return r"\s?(?P<unit>" + alternation + r")(?![\w/²³-])"


def expand_units(text: str, rules) -> str:
    """Speak numbers followed by a unit ("5 km" -> "fünf Kilometer").

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with units spoken.
    """
    # One pattern per language covers every unit of its table.
    pattern = cached_pattern(rules, "units", lambda r: number_with_unit_pattern(r, unit_tail(r)))

    def speak(match: re.Match[str]) -> str:
        """Render one number and its unit name.

        Args:
            match: Match with the number groups and ``unit``.

        Returns:
            Number words followed by the unit name (singular for exactly one).
        """
        # The unit name agrees with the value (singular only for exactly one).
        number = parse_number(match)
        singular, plural = rules.UNITS[match.group("unit")]
        words = speak_number(number, rules, attributive=True)
        # Singular only for exactly one (ein Kilometer, five kilometers).
        return f"{words} {singular if number.is_one else plural}"

    return pattern.sub(speak, text)


def expand_suffix_ordinals(text: str, rules) -> str:
    """Speak ordinals written with a suffix (3rd, 1er, 2º).

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with ordinals spoken.
    """
    # Languages without suffix ordinals (German) skip this stage.
    if not rules.ORDINAL_SUFFIX:
        return text
    pattern = cached_pattern(
        rules, "suffix-ordinal",
        lambda r: LEFT_GUARD + r"(?P<num>\d{1,3})" + r.ORDINAL_SUFFIX + r"(?!\w)",
    )
    return pattern.sub(lambda m: htts_numbers.ordinal(int(m.group("num")), rules.CODE), text)


def expand_dotted_ordinals(text: str, rules) -> str:
    """Speak German-style ordinals ("3. Platz" -> "dritte Platz" with case ending).

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with dotted ordinals spoken.
    """
    # Only languages that write ordinals with a period use this stage.
    if not rules.DOTTED_ORDINALS:
        return text
    pattern = cached_pattern(
        rules, "dotted-ordinal", lambda r: LEFT_GUARD + r"(?P<num>\d{1,3})\.(?=\s+[^\W\d_])"
    )

    def speak(match: re.Match[str]) -> str:
        """Render one dotted ordinal with the case ending demanded by the context.

        Args:
            match: Match with the group ``num``.

        Returns:
            The inflected ordinal words.
        """
        previous = previous_word(match.string, match.start())
        # "S. 5." and "Seite 5." name a page: a cardinal, with the period kept as sentence end.
        reference_words = getattr(rules, "REFERENCE_WORDS", ())
        if previous_abbreviation(match.string, match.start()) in reference_words:
            return htts_numbers.cardinal(int(match.group("num")), rules.CODE) + "."
        # The preceding word decides between "dritte" and "dritten".
        base = htts_numbers.ordinal(int(match.group("num")), rules.CODE)
        return rules.inflect_ordinal(base, previous, False)

    return pattern.sub(speak, text)


def expand_international_phone(text: str, rules) -> str:
    """Speak international phone numbers digit by digit ("+49 30 1234" -> "plus vier neun ...").

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with ``+<country> ...`` numbers of at least seven digits spoken.
    """
    pattern = cached_pattern(
        rules, "phone", lambda r: r"(?<![\w+])\+\d[\d ()/\-]{5,}\d(?!\d)"
    )

    def speak(match: re.Match[str]) -> str:
        """Render one phone number, or keep short matches such as "+5 - 3" untouched.

        Args:
            match: Match of the phone pattern.

        Returns:
            The spoken number or the original text.
        """
        digits = re.sub(r"\D", "", match.group(0))
        # Fewer than seven digits is arithmetic or a short code, not a phone number.
        if len(digits) < 7:
            return match.group(0)
        plus = PLUS_WORDS.get(rules.CODE, "plus")
        return f"{plus} {htts_numbers.spell_digits(digits, rules.CODE)}"

    # Every phone-like match goes through the same speaker above.
    return pattern.sub(speak, text)


def date_parts_valid(day: int, month: int) -> bool:
    """Check that day and month are calendar-plausible.

    Args:
        day: Day of month.
        month: Month number.

    Returns:
        True when 1 <= day <= 31 and 1 <= month <= 12.
    """
    # Day-of-month limits per month are not checked; plausibility is enough here.
    return 1 <= day <= 31 and 1 <= month <= 12


def speak_date(match: re.Match[str], rules, day: int, month: int, day_first: bool) -> str:
    """Render a date match, or return it unchanged when it is not a real date.

    Args:
        match: The regex match (used for the year group and the context).
        rules: Language rule module.
        day: Day of month.
        month: Month number.
        day_first: Whether the writing convention puts the day first.

    Returns:
        The spoken date or the original text.
    """
    # Implausible values mean this was not a date after all.
    if not date_parts_valid(day, month):
        return match.group(0)
    year_text = match.groupdict().get("year") or ""
    # The year is optional and spoken in the language's year style.
    year_words = spoken_year(int(year_text), rules) if year_text else ""
    context = previous_word(match.string, match.start())
    return rules.format_date(day, month, year_words, context, day_first)


def month_alternation(rules) -> str:
    """Build a case-insensitive alternation of the language's month names.

    Args:
        rules: Language rule module.

    Returns:
        Pattern text such as ``(?i:Januar|Februar|...)``.
    """
    # Longer names first so "Mai" cannot shadow a longer month.
    names = sorted(rules.MONTHS, key=len, reverse=True)
    return "(?i:" + "|".join(names) + ")"


def month_number(name: str, rules) -> int:
    """Return the 1-based month number for a month name.

    Args:
        name: Month name in any case.
        rules: Language rule module.

    Returns:
        Month number 1-12.
    """
    # The match is case-insensitive, so compare lowercase.
    return [month.lower() for month in rules.MONTHS].index(name.lower()) + 1


def textual_date_patterns(rules) -> list[str]:
    """Build the patterns for dates with a written month name.

    Args:
        rules: Language rule module.

    Returns:
        Pattern texts (day-first always; month-first for English).
    """
    # Day-first: "3. Oktober 2026", "3rd of October", "1er octobre", "3 de octubre de 2026".
    months = month_alternation(rules)
    day_first = (
        LEFT_GUARD + r"(?P<day>\d{1,2})(?:\.|er|º|ª|st|nd|rd|th)?\s?(?:of\s|de\s|d')?"
        r"(?P<month>" + months + r")(?:,?\s(?:de\s)?(?P<year>\d{4}))?(?![\w])"
    )
    patterns = [day_first]
    # English also writes "October 3rd, 2026".
    if rules.CODE in MONTH_FIRST_LANGUAGES:
        patterns.append(
            r"(?<![\w])(?P<month>" + months + r")\s(?P<day>\d{1,2})(?:st|nd|rd|th)?"
            r"(?:,?\s(?P<year>\d{4}))?(?![\w])"
        )
    return patterns


def expand_textual_dates(text: str, rules) -> str:
    """Speak dates with a written month name.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with those dates spoken.
    """
    # The first pattern is day-first, the optional second one month-first.
    for index, source in enumerate(textual_date_patterns(rules)):
        pattern = cached_pattern(rules, f"textual-date-{index}", lambda r, s=source: s)
        text = pattern.sub(
            lambda m, first=(index == 0): speak_date(
                m, rules, int(m.group("day")), month_number(m.group("month"), rules), first
            ),
            text,
        )
    return text


def expand_numeric_dates(text: str, rules) -> str:
    """Speak ISO (2026-10-03), dotted (03.10.2026) and slashed (10/03/2026) dates.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with those dates spoken.
    """
    # ISO dates are unambiguous: year-month-day.
    iso = re.compile(r"(?<![\w.,-])(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})(?![\w-])")
    text = iso.sub(
        lambda m: speak_date(m, rules, int(m.group("day")), int(m.group("month")), True), text
    )
    # Dotted dates are day.month.year in every supported language.
    dotted = re.compile(LEFT_GUARD + r"(?P<day>\d{1,2})\.(?P<month>\d{1,2})\.(?P<year>\d{4})(?!\w)")
    text = dotted.sub(
        lambda m: speak_date(m, rules, int(m.group("day")), int(m.group("month")), True), text
    )
    # Slashed dates depend on the convention of the language.
    slashed = re.compile(
        r"(?<![\w.,/])(?P<first>\d{1,2})/(?P<second>\d{1,2})/(?P<year>\d{4})(?![\w/])"
    )
    return slashed.sub(lambda m: speak_slashed_date(m, rules), text)


def speak_slashed_date(match: re.Match[str], rules) -> str:
    """Speak a ``a/b/yyyy`` date using month-first order only where that is the convention.

    Args:
        match: Match with the groups first, second and year.
        rules: Language rule module.

    Returns:
        The spoken date or the original text.
    """
    # English reads month/day unless the first number cannot be a month.
    first, second = int(match.group("first")), int(match.group("second"))
    month_first = rules.CODE in MONTH_FIRST_LANGUAGES and first <= 12
    day, month = (second, first) if month_first else (first, second)
    return speak_date(match, rules, day, month, not month_first)


def time_pattern(rules) -> str:
    """Build the clock-time pattern for a language.

    Args:
        rules: Language rule module.

    Returns:
        Pattern text with the groups hour, minute and (English only) meridiem.
    """
    # AM/PM only exists in English; elsewhere "am" would be a German preposition.
    meridiem = (
        r"(?:\s?(?P<meridiem>[AP]M|[ap]m|[ap]\.m\.|[AP]\.M\.))?"
        if getattr(rules, "MERIDIEM", False) else ""
    )
    return (
        r"(?<![\w.,:])(?P<hour>\d{1,2})[:h](?P<minute>\d{2})" + meridiem
        + r"(?:\s?Uhr)?(?![\w:]|[.,]\d)"
    )


def speak_time(match: re.Match[str], rules) -> str:
    """Render a clock-time match, or return it unchanged when it is not a time.

    Args:
        match: Match with hour, minute and optional meridiem.
        rules: Language rule module.

    Returns:
        The spoken time or the original text.
    """
    # Hours above 24 or minutes above 59 are not times (scores, ratios).
    hour, minute = int(match.group("hour")), int(match.group("minute"))
    meridiem = match.groupdict().get("meridiem") or ""
    if hour > 24 or minute > 59 or (meridiem and not 1 <= hour <= 12):
        return match.group(0)
    # Hand the numbers to the language's own time phrasing.
    spoken = rules.format_time(hour, minute, meridiem)
    # "a las 14:30" already contains the article that the spoken form starts with.
    article = TIME_ARTICLES.get(previous_word(match.string, match.start()), "")
    return spoken[len(article):] if article and spoken.startswith(article) else spoken


def expand_times(text: str, rules) -> str:
    """Speak clock times ("14:30 Uhr" -> "vierzehn Uhr dreißig").

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with times spoken.
    """
    # Colons and "h" are only times when two minute digits follow.
    pattern = cached_pattern(rules, "time", time_pattern)
    text = pattern.sub(lambda match: speak_time(match, rules), text)
    # English also writes "2 PM" without minutes.
    if not getattr(rules, "MERIDIEM", False):
        return text
    bare = cached_pattern(
        rules, "time-bare",
        lambda r: LEFT_GUARD + r"(?P<hour>\d{1,2})\s?(?P<meridiem>[AP]M|[ap]\.m\.|[AP]\.M\.)(?!\w)",
    )
    return bare.sub(
        lambda match: rules.format_time(int(match.group("hour")), 0, match.group("meridiem")),
        text,
    )


def expand_years(text: str, rules) -> str:
    """Speak four-digit years after year-marking words ("in 1999", "since 2020").

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with such years spoken in year style.
    """
    # Languages whose years equal their cardinals need no special stage.
    if not rules.YEAR_WORD_RANGE:
        return text
    pattern = cached_pattern(
        rules, "year", lambda r: LEFT_GUARD + r"(?P<year>1[1-9]\d{2}|20\d{2})" + RIGHT_GUARD
    )
    months = {month.lower() for month in rules.MONTHS}

    def speak(match: re.Match[str]) -> str:
        """Render a year when the preceding word marks it as one.

        Args:
            match: Match with the group ``year``.

        Returns:
            Year words, or the text unchanged for other numbers.
        """
        # Without a year-marking word the number stays a plain quantity.
        context = previous_word(match.string, match.start())
        if context not in rules.YEAR_CONTEXT and context not in months:
            return match.group(0)
        # A year-marking word was found, so the number is a year.
        return spoken_year(int(match.group("year")), rules)

    return pattern.sub(speak, text)


def expand_plain_numbers(text: str, rules) -> str:
    """Speak every remaining number with the language's separators.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with numbers as words.
    """
    # Numbers directly followed by letters (3D, 20er) are left alone by the guard.
    pattern = cached_pattern(rules, "plain", lambda r: LEFT_GUARD + number_core(r) + RIGHT_GUARD)
    return pattern.sub(lambda match: speak_number(parse_number(match), rules), text)


def expand_versions(text: str, rules) -> str:
    """Speak dotted version numbers and IP addresses ("1.2.3" -> "one dot two dot three").

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with dotted sequences spoken group by group.
    """
    # At least three dot-separated groups; shorter ones are decimals.
    pattern = re.compile(LEFT_GUARD + r"\d+(?:\.\d+){2,}(?![\w]|[.,]?\d)")
    joiner = f" {rules.WORDS['dot']} "
    return pattern.sub(
        lambda m: joiner.join(
            htts_numbers.cardinal(int(group), rules.CODE) for group in m.group(0).split(".")
        ),
        text,
    )


def expand_numeric(text: str, rules) -> str:
    """Run every numeric stage in the order that keeps compound patterns intact.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with dates, times, money, units, ordinals and numbers spoken.
    """
    # Text without digits has nothing numeric to expand.
    if not any(char.isdigit() for char in text) or not htts_numbers.words_available():
        return text
    # Compound patterns (dates, times, money) must run before plain numbers.
    for stage in (
        expand_international_phone,
        expand_textual_dates, expand_numeric_dates, expand_times, expand_currency,
        expand_percent, expand_units, expand_suffix_ordinals, expand_dotted_ordinals,
        expand_years, expand_plain_numbers, expand_versions,
    ):
        text = stage(text, rules)
    return text
