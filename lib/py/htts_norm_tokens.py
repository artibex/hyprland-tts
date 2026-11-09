"""Language-independent text normalisation stages: abbreviations, command lines, acronyms.

These stages need the language rules only for word lists (abbreviation tables, the words
for "slash" and "dash"). Numeric stages live in ``htts_norm_numbers``.
"""

# Annotations stay lazy so no typing import is needed at runtime.
from __future__ import annotations

import re

# All-caps words that are read as words, not spelled out.
PRONOUNCEABLE_ACRONYMS = frozenset(
    "NASA NATO UNESCO UNICEF OPEC LASER RADAR SCUBA PIN TÜV DAX SEPA ASCII FIFA AIDS COVID "
    "BIOS RAM ROM LAN JSON GNOME ELSTER ZDF ARD".split()
)
# Acronym-like words that need an explicit pronunciation.
SPECIAL_ACRONYMS = {"OK": "okay"}
# Letters that form Roman numerals; such tokens are left alone.
ROMAN_ONLY = re.compile(r"[IVXLCDM]+")
# Two to five capital letters standing alone are acronyms.
ACRONYM = re.compile(r"(?<![\w])[A-ZÄÖÜ]{2,5}(?![\w])")
# A text without any lowercase letter is shouted; its caps are not acronyms.
LOWERCASE_LETTER = re.compile(r"[a-zäöüß]")

# Whitespace-delimited token with its trailing sentence punctuation split off.
TOKEN = re.compile(r"(?<!\S)(?P<core>\S*?)(?P<tail>[.,;:!?)]*)(?=\s|$)")
# A path starts with "/", "~/", "./" or "../" and has at least one segment.
PATH_TOKEN = re.compile(r"(?:~|\.{1,2})?(?:/[\w.@+%=~-]+)+/?|~/?")
# Long options (--no-cache, --color=auto) and short option clusters (-Syu, -rf).
LONG_OPTION = re.compile(r"--(?P<name>[A-Za-z][\w-]*)(?:=(?P<value>\S*))?")
SHORT_OPTION = re.compile(r"-(?P<name>[A-Za-z][A-Za-z0-9]{0,3})")
# Environment variables ($HOME, ${HOME}).
ENV_VARIABLE = re.compile(r"\$\{?(?P<name>[A-Za-z_]\w*)\}?")
# A standalone ampersand between words.
AMPERSAND = re.compile(r"(?<=\s)&(?=\s)")
# Currency symbols left over when no amount followed them.
LEFTOVER_SYMBOL = re.compile(r"[€$£]")
# Currency symbol to ISO code.
SYMBOL_CODES = {"€": "EUR", "$": "USD", "£": "GBP"}

_ABBREVIATION_CACHE: dict[str, tuple[re.Pattern[str], list[str]]] = {}


def compile_replacements(entries: tuple) -> tuple[re.Pattern[str], list[str]]:
    """Compile (pattern, replacement) pairs into one alternation regex.

    Args:
        entries: Pairs of regular expression and replacement text.

    Returns:
        The combined pattern and the replacement list (indexed by group number minus one).
    """
    # Every entry becomes one capturing group so the matching entry can be identified.
    parts = []
    for source, _ in entries:
        # A trailing letter needs a word boundary so "Kfz" does not match inside a word.
        guard = r"(?!\w)" if source[-1].isalpha() else ""
        parts.append(f"({source}{guard})")
    combined = re.compile(r"(?<![\w/~])(?:" + "|".join(parts) + ")")
    return combined, [replacement for _, replacement in entries]


def spoken_replacement(match: re.Match[str], replacements: list[str]) -> str:
    """Pick the replacement of the matched entry and keep a sentence-final period.

    Args:
        match: Match of the combined abbreviation pattern.
        replacements: Replacement texts indexed by group number minus one.

    Returns:
        The spoken form; a period that ended the sentence stays as punctuation.
    """
    # The index of the matched group selects the replacement.
    spoken = replacements[match.lastindex - 1]
    # "usw." at the end of a sentence must not lose its closing period.
    at_end = match.end() == len(match.string) and match.group(0).endswith(".")
    return spoken + "." if at_end else spoken


def expand_table(text: str, entries: tuple, cache_key: str) -> str:
    """Replace abbreviations or respellings from a rule table.

    Args:
        text: Sentence text.
        entries: Pairs of regular expression and spoken replacement.
        cache_key: Unique name used to cache the compiled pattern.

    Returns:
        The text with the table entries replaced.
    """
    # An empty table means nothing to do.
    if not entries:
        return text
    # Compile once per table and process.
    if cache_key not in _ABBREVIATION_CACHE:
        _ABBREVIATION_CACHE[cache_key] = compile_replacements(entries)
    pattern, replacements = _ABBREVIATION_CACHE[cache_key]
    return pattern.sub(lambda match: spoken_replacement(match, replacements), text)


def expand_abbreviations(text: str, rules) -> str:
    """Expand abbreviations and respell known loanwords for one language.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with abbreviations spoken out.
    """
    # Respellings go first so "Pull-Request" is not split by other rules.
    respelled = expand_table(text, rules.PRONUNCIATIONS, rules.CODE + ":pronunciation")
    return expand_table(respelled, rules.ABBREVIATIONS, rules.CODE + ":abbreviation")


def speak_path(path: str, rules) -> str:
    """Turn a file path into words ("~/.config/a_b" -> "tilde slash dot config slash a b").

    Args:
        path: A path token such as ``/etc/hosts`` or ``~/.config/hypr``.
        rules: Language rule module (supplies the words for slash, tilde, dot).

    Returns:
        The spoken path.
    """
    # Replace each path symbol by its word, surrounded by spaces.
    spoken = path.replace("/", f" {rules.WORDS['slash']} ")
    spoken = spoken.replace("~", f" {rules.WORDS['tilde']} ")
    spoken = spoken.replace(".", f" {rules.WORDS['dot']} ")
    # Underscores and hyphens inside names become plain spaces.
    return " ".join(spoken.replace("_", " ").replace("-", " ").split())


def speak_option(match: re.Match[str], dashes: int, rules) -> str:
    """Turn a command-line option into words ("-Syu" -> "dash S y u").

    Args:
        match: Regex match with ``name`` (and for long options ``value``).
        dashes: Number of leading dashes (1 or 2).
        rules: Language rule module.

    Returns:
        The spoken option.
    """
    # Short clusters are spelled letter by letter, long names are read as words.
    name = match.group("name")
    body = " ".join(name) if dashes == 1 else name.replace("-", " ").replace("_", " ")
    spoken = " ".join([rules.WORDS["dash"]] * dashes + [body])
    # A "=value" suffix is kept after the word for equals.
    value = match.groupdict().get("value")
    return f"{spoken} {rules.WORDS['equals']} {value}" if value else spoken


def speak_token(core: str, rules) -> str:
    """Convert one whitespace-delimited token when it is a path, option or variable.

    Args:
        core: The token without trailing punctuation.
        rules: Language rule module.

    Returns:
        The spoken form, or the token unchanged.
    """
    # Paths are recognised by their leading slash, tilde or dots.
    if PATH_TOKEN.fullmatch(core):
        return speak_path(core, rules)
    # Long options need two dashes and a letter, short ones one dash and at most 4 chars.
    long_match = LONG_OPTION.fullmatch(core)
    if long_match:
        return speak_option(long_match, 2, rules)
    # Short option clusters such as -Syu are spelled letter by letter.
    short_match = SHORT_OPTION.fullmatch(core)
    if short_match:
        return speak_option(short_match, 1, rules)
    # Environment variables read as "dollar home".
    variable = ENV_VARIABLE.fullmatch(core)
    if variable:
        return f"{rules.WORDS['dollar']} {variable.group('name').lower().replace('_', ' ')}"
    return core


def expand_command_line(text: str, rules) -> str:
    """Speak paths, options and environment variables inside a sentence.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with command-line syntax spelled out.
    """
    # Only tokens that start with a symbol can be command-line syntax.
    if not re.search(r"(?<!\S)[-~/.$]", text):
        return text
    # Convert token by token and keep trailing punctuation outside the conversion.
    return TOKEN.sub(lambda m: speak_token(m.group("core"), rules) + m.group("tail"), text)


def spell_acronym(match: re.Match[str]) -> str:
    """Spell one all-caps token letter by letter unless it is pronounceable.

    Args:
        match: Regex match of an all-caps token.

    Returns:
        The spaced letters, a special reading, or the token unchanged.
    """
    # Known words and Roman numerals are left as they are.
    token = match.group(0)
    if token in SPECIAL_ACRONYMS:
        return SPECIAL_ACRONYMS[token]
    # Pronounceable acronyms and Roman numerals keep their reading.
    if token in PRONOUNCEABLE_ACRONYMS or ROMAN_ONLY.fullmatch(token):
        return token
    return " ".join(token)


def spell_acronyms(text: str) -> str:
    """Spell acronyms such as CPU or USB, but not shouted sentences.

    Args:
        text: Sentence text.

    Returns:
        The text with acronyms spelled letter by letter.
    """
    # A sentence with no lowercase letter is shouting, not a list of acronyms.
    if not LOWERCASE_LETTER.search(text):
        return text
    return ACRONYM.sub(spell_acronym, text)


def expand_symbols(text: str, rules) -> str:
    """Speak leftover symbols: standalone "&" and currency signs without an amount.

    Args:
        text: Sentence text.
        rules: Language rule module.

    Returns:
        The text with the symbols spoken.
    """
    # "&" between words is the language's "and".
    text = AMPERSAND.sub(rules.WORDS["and"], text)
    # A currency sign without an amount reads as the currency name.
    return LEFTOVER_SYMBOL.sub(
        lambda match: " " + rules.CURRENCIES[SYMBOL_CODES[match.group(0)]][0] + " "
        if SYMBOL_CODES[match.group(0)] in rules.CURRENCIES else match.group(0),
        text,
    )
