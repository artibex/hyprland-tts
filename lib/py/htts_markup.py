"""Markdown and source-code clean-up before text is read aloud.

This is the Python port of the bash ``normalize_text`` / ``normalize_prose`` /
``normalize_code`` / ``looks_like_code`` functions in ``lib/text.sh``. The text is
processed per paragraph: prose loses markdown syntax, links and e-mail addresses,
code gets operators turned into words and braces turned into sentence breaks.

One deliberate difference from the first bash version: list, quote and heading
markers are only removed at the START of a line. The old rules also fired in the
middle of a line and turned "am 3. Oktober" into "am Oktober". ``lib/text.sh`` got
the same fix so both paths stay identical.
"""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

# Regular expressions drive every rewrite rule in this module.
import re

# Alphanumeric characters without the underscore (the bash [[:alnum:]] class).
ALNUM = r"[^\W_]"
# Letters only (the bash [[:alpha:]] class).
ALPHA = r"[^\W\d_]"

# Invisible characters removed from prose: NBSP becomes a space, the rest vanishes.
NBSP = "\u00a0"
INVISIBLE_CHARACTERS = ("\u200b", "\u200c", "\u200d", "\ufeff", "\u00ad")

# Markdown code-fence marker lines (``` or ```lang) turn into blank lines.
FENCE_LINE = re.compile(r"^\s*```.*$", re.M)
# Paragraphs are separated by one or more completely empty lines (gawk RS="").
PARAGRAPH_SEPARATOR = re.compile(r"\n{2,}")

# Characters whose density marks code: braces, parens and operators.
CODE_SYMBOLS = frozenset("{}();=<>!&|")
# Share of code symbols above which the symbol-density signal fires.
CODE_SYMBOL_RATIO = 0.04
# Keywords common to mainstream programming languages.
CODE_KEYWORDS = re.compile(
    r"\b(function|def|class|return|import|export|const|let|var|public|private|static"
    r"|void|struct|impl|fn|package|namespace|elif|elsif|endif|foreach)\b"
)
# Lines that start with two spaces or a tab are block bodies.
INDENTED_LINE = re.compile(r"^(?:[ \t\n\r\f\v]{2,}|\t)\S", re.M)
# camelCase or snake_case identifiers.
IDENTIFIER_STYLE = re.compile(r"[a-z][A-Z]|[a-zA-Z][0-9]*_[a-zA-Z]")
# Number of agreeing signals needed to call a paragraph code.
CODE_SIGNALS_NEEDED = 2

# Multi-character code operators spoken as words, applied strictly in this order.
OPERATOR_WORDS: list[tuple[str, str]] = [
    ("===", " strictly equals "),
    ("!==", " strictly not equal to "),
    ("==", " equals "),
    ("!=", " not equal to "),
    ("<=", " less than or equal to "),
    (">=", " greater than or equal to "),
    ("=>", " arrow "),
    ("->", " arrow "),
    ("&&", " and "),
    ("||", " or "),
    ("+=", " plus equals "),
    ("-=", " minus equals "),
    ("::", " scope "),
]
# Comment markers are dropped while the comment text stays.
LINE_COMMENT = re.compile(r"^(\s*)//+\s?")
HASH_COMMENT = re.compile(r"^(\s*)#+\s?")
BLOCK_COMMENT_OPEN = re.compile(r"/\*+\s?")
BLOCK_COMMENT_CLOSE = re.compile(r"\s?\*+/")
# camelCase boundaries become word breaks.
CAMEL_BOUNDARY = re.compile(r"([a-z0-9])([A-Z])")
# Braces and semicolons become sentence breaks, brackets become spaces.
STRUCTURE_BREAKS = re.compile(r"[{};]")
BRACKETS = re.compile(r"[\[\]()]")
# A code line that is only periods and whitespace says nothing.
EMPTY_CODE_LINE = re.compile(r"[.\s]*")

# Whitespace tidy-up shared by the code and prose paths.
WHITESPACE_RUN = re.compile(r"\s+")
SPACE_BEFORE_PUNCTUATION = re.compile(r"\s+([.!?,;:])")
PERIOD_RUN = re.compile(r"\.{2,}")
EDGE_SPACE = re.compile(r"^\s+|\s+$")

# Prose rules applied to every line in this exact order (markdown to spoken text).
PROSE_RULES: list[tuple[re.Pattern[str], str]] = [
    # Images keep their alt text, links keep their label.
    (re.compile(r"!\[([^\]]*)\]\([^)]*\)"), r"\1"),
    (re.compile(r"\[([^\]]*)\]\([^)]*\)"), r"\1"),
    # Bare URLs and e-mail addresses become short spoken stand-ins.
    (re.compile(r"https?://\S+"), "(link)"),
    (re.compile(r"www\.\S+"), "(link)"),
    (re.compile(r"[\w.%+-]+@(?:" + ALNUM + r"|[.-])+\." + ALPHA + r"{2,}"), "(email)"),
    # Code ticks and emphasis markers vanish; underscores stay for snake_case.
    (re.compile(r"`+"), ""),
    (re.compile(r"(\*\*|\*|~~)"), ""),
    # Heading, quote, bullet and numbered-list markers go, but only at line start.
    (re.compile(r"^(\s*)#{1,6}\s+"), r"\1"),
    (re.compile(r"^(\s*)>\s+"), r"\1"),
    (re.compile(r"^(\s*)[-*+•]\s+"), r"\1"),
    (re.compile(r"^(\s*)[0-9]+[.)]\s+"), r"\1"),
    # Table pipes become pauses.
    (re.compile(r"\s*\|\s*"), ", "),
    # Runs of the same decorative character collapse.
    (re.compile(r"([-=*.#~])\1{2,}"), " "),
    (re.compile(r"([.!?,;:])\1+"), r"\1"),
    # Spaced-out separators such as " - - - " collapse.
    (re.compile(r"(?:\s[-–—]){2,}\s"), " "),
]
# Sentence-ending punctuation that lets a paragraph join with a plain space.
CLAUSE_END = re.compile(r"[.!?:;,]$")
# Final prose tidy-up rules, applied in order.
PROSE_CLEANUP: list[tuple[re.Pattern[str], str]] = [
    (WHITESPACE_RUN, " "),
    (SPACE_BEFORE_PUNCTUATION, r"\1"),
    (re.compile(r"([.!?])[.]+"), r"\1"),
    (re.compile(r"(\. ){2,}"), ". "),
    (re.compile(r"^[ ,]+|\s+$"), ""),
]


def strip_invisible(text: str) -> str:
    """Remove zero-width characters and turn tabs and other whitespace controls into spaces.

    Args:
        text: Raw paragraph text.

    Returns:
        Text without invisible characters.
    """
    # NBSP must become a space so the words around it stay apart.
    cleaned = text.replace(NBSP, " ")
    # Zero-width characters, BOM and soft hyphens carry no sound.
    for invisible in INVISIBLE_CHARACTERS:
        cleaned = cleaned.replace(invisible, "")
    # Tabs, carriage returns and vertical tabs/form feeds become plain spaces.
    return re.sub(r"[\t\r\v\f]", " ", cleaned)


def apply_rules(line: str, rules: list[tuple[re.Pattern[str], str]]) -> str:
    """Apply substitution rules to one line, in order.

    Args:
        line: One line of text.
        rules: Compiled pattern and replacement pairs.

    Returns:
        The rewritten line.
    """
    # Every rule sees the output of the previous one, like a sed pipeline.
    for pattern, replacement in rules:
        line = pattern.sub(replacement, line)
    return line


def join_prose_lines(lines: list[str]) -> str:
    """Join prose lines into one string; blank lines become sentence breaks.

    Args:
        lines: Prose lines after rule application.

    Returns:
        A single line of text.
    """
    # Build the output incrementally and remember when a blank line was seen.
    output = ""
    pending_break = False
    for raw_line in lines:
        # Surrounding whitespace never matters.
        line = raw_line.strip()
        if not line:
            pending_break = True
            continue
        # Lines made only of symbols (decorative separators) are skipped.
        if not re.search(ALNUM, line):
            continue
        # Blank-line breaks end the sentence, other joins use one space.
        if output:
            separator = ". " if pending_break and not CLAUSE_END.search(output) else " "
            output += separator
        # Append the line and reset the break marker.
        output += line
        pending_break = False
    return output


def normalize_prose(block: str) -> str:
    """Turn a markdown paragraph into plain speakable prose.

    Args:
        block: One paragraph (may contain several lines).

    Returns:
        A single line of cleaned text.
    """
    # Strip invisible characters first, then rewrite every line independently.
    lines = strip_invisible(block).split("\n")
    rewritten = [apply_rules(line, PROSE_RULES) for line in lines]
    # Join the lines and run the final whitespace tidy-up.
    return apply_rules(join_prose_lines(rewritten), PROSE_CLEANUP)


def code_line_to_speech(line: str) -> str:
    """Rewrite one source-code line into listenable text.

    Args:
        line: One line of code.

    Returns:
        The line with operators as words, comment markers removed and identifiers split.
    """
    # Operators first, in the documented order (longest match wins by ordering).
    for operator, words in OPERATOR_WORDS:
        line = line.replace(operator, words)
    # Comment markers go but their text stays.
    for marker in (LINE_COMMENT, HASH_COMMENT):
        line = marker.sub(r"\1", line)
    line = BLOCK_COMMENT_CLOSE.sub("", BLOCK_COMMENT_OPEN.sub("", line))
    # Split identifiers, then turn structure characters into breaks or spaces.
    line = CAMEL_BOUNDARY.sub(r"\1 \2", line).replace("_", " ")
    return BRACKETS.sub(" ", STRUCTURE_BREAKS.sub(".", line))


def tidy_code_line(line: str) -> str:
    """Collapse whitespace and stray punctuation in a rewritten code line.

    Args:
        line: A line produced by ``code_line_to_speech``.

    Returns:
        The tidy line.
    """
    # Collapse whitespace and remove spaces in front of punctuation.
    line = SPACE_BEFORE_PUNCTUATION.sub(r"\1", WHITESPACE_RUN.sub(" ", line))
    # Collapse period runs and trim the edges.
    return EDGE_SPACE.sub("", PERIOD_RUN.sub(".", line))


def normalize_code(block: str) -> str:
    """Make a source-code paragraph listenable.

    Args:
        block: One paragraph of code.

    Returns:
        Newline-separated speakable lines without empty ones.
    """
    # Rewrite every line, then drop the ones that say nothing.
    spoken = [code_line_to_speech(line) for line in block.split("\n")]
    meaningful = [line for line in spoken if not EMPTY_CODE_LINE.fullmatch(line)]
    return "\n".join(tidy_code_line(line) for line in meaningful)


def looks_like_code(block: str) -> bool:
    """Decide whether a paragraph is source code (needs two of four signals).

    Args:
        block: One paragraph.

    Returns:
        True when at least two independent code signals agree.
    """
    # An empty paragraph is never code.
    if not block:
        return False
    # Symbol density is the first signal.
    symbol_count = sum(1 for char in block if char in CODE_SYMBOLS)
    signals = int(symbol_count / len(block) > CODE_SYMBOL_RATIO)
    # Keywords, indented bodies and identifier styles are the other signals.
    signals += int(bool(CODE_KEYWORDS.search(block)))
    signals += int(len(INDENTED_LINE.findall(block)) >= 2)
    signals += int(bool(IDENTIFIER_STYLE.search(block)))
    return signals >= CODE_SIGNALS_NEEDED


def split_paragraphs(text: str) -> list[str]:
    """Split text into paragraphs after turning code fences into blank lines.

    Args:
        text: Raw selected text.

    Returns:
        Non-blank paragraphs in reading order.
    """
    # Trailing newlines never count and fence lines become paragraph boundaries.
    unfenced = FENCE_LINE.sub("", text.rstrip("\n"))
    blocks = PARAGRAPH_SEPARATOR.split(unfenced.lstrip("\n"))
    # Whitespace-only blocks are dropped.
    return [block for block in blocks if block.strip()]


def join_paragraphs(cleaned: list[str]) -> str:
    """Join cleaned paragraphs, adding a period where none ends the previous one.

    Args:
        cleaned: Cleaned non-empty paragraphs.

    Returns:
        The joined text.
    """
    # Start from the first paragraph and append the rest with the right separator.
    output = ""
    for paragraph in cleaned:
        if not output:
            output = paragraph
        # Join with a space when the previous paragraph already ends a clause.
        elif re.search(r"[.!?:;]$", output):
            output = f"{output} {paragraph}"
        else:
            # Otherwise a period marks the paragraph break.
            output = f"{output}. {paragraph}"
    return output


def normalize_text(text: str) -> str:
    """Clean a whole selection per paragraph (prose vs. code), like bash ``normalize_text``.

    Args:
        text: Raw selected text.

    Returns:
        Cleaned text; code lines stay on separate lines.
    """
    # Classify and clean every paragraph on its own.
    cleaned: list[str] = []
    for block in split_paragraphs(text):
        # Code and prose paragraphs take different paths.
        result = normalize_code(block) if looks_like_code(block) else normalize_prose(block)
        # Paragraphs that clean to nothing are dropped.
        if result.strip():
            cleaned.append(result)
    return join_paragraphs(cleaned)
