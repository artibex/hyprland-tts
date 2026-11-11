#!/usr/bin/env python3
"""Command-line front end of the hyprland-tts text helpers (reads stdin, writes stdout).

Commands:
  segment --allowed de,en [--default de] [--stream-first 1]
                                           print ``lang<TAB>chunk`` lines (a long first
                                           chunk with ``--stream-first 1``)
  detect  --allowed de,en [--default de]   print the dominant language code
  normalize --lang de                      print one text normalised for that language
  markup                                   print the markdown/code clean-up only

Exit codes: 0 success, 2 usage error, 3 language model or fastText unavailable (the
bash caller then falls back to its regex path).
"""

# Postponed annotations let list[str] and X | None work on Python 3.9 too.
from __future__ import annotations

import os
import sys

# Make sibling modules importable when the file is executed by path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import htts_langid  # noqa: E402  (needs the path set above)
import htts_markup  # noqa: E402
import htts_norm  # noqa: E402
import htts_pipeline  # noqa: E402

EXIT_USAGE = 2
EXIT_NO_MODEL = 3
USAGE = (
    "usage: htts_text.py segment|detect --allowed de,en [--default de] [--stream-first 1]\n"
    "       htts_text.py normalize --lang de\n"
    "       htts_text.py markup"
)
# Options accepted per command (flag name without dashes).
COMMAND_OPTIONS = {
    "segment": ("allowed", "default", "stream-first"),
    "detect": ("allowed", "default"),
    "normalize": ("lang",),
    "markup": (),
}


def parse_options(argv: list[str]) -> tuple[str, dict[str, str]]:
    """Parse ``command --flag value`` pairs by hand (argparse costs startup time).

    Args:
        argv: Arguments without the program name.

    Returns:
        The command and its options.

    Raises:
        ValueError: With the usage text when the arguments are invalid (exit code 2).
    """
    # The command word decides which options are legal.
    if not argv or argv[0] not in COMMAND_OPTIONS:
        raise ValueError(USAGE)
    command, rest = argv[0], argv[1:]
    # Flags and values must come in pairs.
    if len(rest) % 2:
        raise ValueError(USAGE)
    # Consume the flag/value pairs and reject anything unknown.
    options: dict[str, str] = {}
    for flag, value in zip(rest[::2], rest[1::2]):
        name = flag[2:] if flag.startswith("--") else ""
        # Flags this command does not know are usage errors.
        if name not in COMMAND_OPTIONS[command]:
            raise ValueError(USAGE)
        # The value is stored under the flag name without its dashes.
        options[name] = value
    return command, options


def read_stdin() -> str:
    """Read all of stdin as UTF-8 regardless of the locale.

    Returns:
        The input text (undecodable bytes are replaced).
    """
    # Hyprland may start the tool with a C locale, so decoding is explicit.
    return sys.stdin.buffer.read().decode("utf-8", errors="replace")


def write_stdout(text: str) -> None:
    """Write UTF-8 text to stdout.

    Args:
        text: Text to print; no newline is added, callers include their own.

    Returns:
        None.
    """
    # Encode explicitly for the same locale reason as the input.
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


def run_segment(options: dict[str, str]) -> int:
    """Run the ``segment`` command.

    Args:
        options: Parsed options with ``allowed``, optional ``default`` and ``stream-first``.

    Returns:
        Exit code.
    """
    # Validate the language lists before any heavy work.
    allowed = htts_langid.parse_language_list(options.get("allowed", ""))
    default_lang = options.get("default", "").strip().lower()
    # The player says whether chunk 0 will be streamed; only "1" means yes.
    stream_first = options.get("stream-first", "0").strip() == "1"
    chunks = htts_pipeline.prepare(read_stdin(), allowed, default_lang, None, stream_first)
    # One line per chunk; tabs and newlines inside chunks were removed earlier.
    write_stdout("".join(f"{lang}\t{text}\n" for lang, text in chunks))
    return 0


def run_detect(options: dict[str, str]) -> int:
    """Run the ``detect`` command.

    Args:
        options: Parsed options with ``allowed`` and optional ``default``.

    Returns:
        Exit code.
    """
    # Same validation as segment; the answer is a single code.
    allowed = htts_langid.parse_language_list(options.get("allowed", ""))
    default_lang = options.get("default", "").strip().lower()
    write_stdout(htts_pipeline.detect(read_stdin(), allowed, default_lang) + "\n")
    return 0


def run_normalize(options: dict[str, str]) -> int:
    """Run the ``normalize`` command (one text, one language).

    Args:
        options: Parsed options with ``lang``.

    Returns:
        Exit code.
    """
    # The language selects the rule set; unknown languages only get a whitespace tidy-up.
    lang = options.get("lang", "").strip().lower()
    write_stdout(htts_norm.normalize(read_stdin().rstrip("\n"), lang) + "\n")
    return 0


def run_markup(options: dict[str, str]) -> int:
    """Run the ``markup`` command (markdown and code clean-up only).

    Args:
        options: Parsed options (none are used).

    Returns:
        Exit code.
    """
    # No options exist for this command; the text goes straight through the clean-up.
    del options
    write_stdout(htts_markup.normalize_text(read_stdin()) + "\n")
    return 0


# Command word to runner function.
RUNNERS = {
    "segment": run_segment, "detect": run_detect, "normalize": run_normalize,
    "markup": run_markup,
}


def run_command(command: str, options: dict[str, str]) -> int:
    """Dispatch a parsed command.

    Args:
        command: Command word (already validated by ``parse_options``).
        options: Parsed options.

    Returns:
        Exit code.
    """
    # Each command maps to one small runner.
    return RUNNERS[command](options)


def main(argv: list[str] | None = None) -> int:
    """Run the command-line interface.

    Args:
        argv: Argument list, defaults to ``sys.argv[1:]``.

    Returns:
        Process exit code.
    """
    # Usage and validation errors end with code 2 and a message on stderr.
    try:
        command, options = parse_options(sys.argv[1:] if argv is None else argv)
        return run_command(command, options)
    except ValueError as error:
        # Both error kinds go to stderr; the exit code tells the caller what happened.
        sys.stderr.write(f"htts_text.py: {error}\n")
        return EXIT_USAGE
    except htts_langid.LanguageModelUnavailable as error:
        # The caller treats this code as "use the regex fallback".
        sys.stderr.write(f"htts_text.py: {error}\n")
        return EXIT_NO_MODEL


if __name__ == "__main__":
    sys.exit(main())
