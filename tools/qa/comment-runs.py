#!/usr/bin/env python3
"""Find runs of uncommented statements (rule R4) in Python and JavaScript files.

`qa-precheck.py` enforces R4 only for shell; this checker closes the gap for
Python (AST-based: docstrings skipped, def/class reset the run) and JS (line
heuristic: closing braces skipped, any `//` line resets the run).

Usage: comment-runs.py [--limit N] FILE...   (rc 1 when a run exceeds N, default 3)
"""

from __future__ import annotations  # Modern type hints.

import argparse  # Command-line options.
import ast  # Python statement positions.
import io  # Feed source text to tokenize.
import re  # JS line classification.
import sys  # Exit code.
import tokenize  # Python comment positions.

# JS lines that only close a block do not count as statements.
JS_CLOSER = re.compile(r"[\}\)\]\;,]+")


def docstring_lines(tree: ast.AST) -> set[int]:
    """Collect line numbers covered by docstrings.

    Args:
        tree: Parsed module.

    Returns:
        Line numbers that belong to a module/class/function docstring.
    """
    # Docstrings document their owner and need no extra comment.
    covered: set[int] = set()
    # Only these node types can own a docstring.
    owners = (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
    # Walk every node once.
    for node in ast.walk(tree):
        # First statement must be a string expression.
        if isinstance(node, owners) and node.body:
            first = node.body[0]
            # Mark the whole docstring range.
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                covered.update(range(first.lineno, first.end_lineno + 1))
    # Done.
    return covered


def python_runs(source: str, limit: int) -> list[list[int]]:
    """Find uncommented statement runs longer than ``limit`` in Python source.

    Args:
        source: File content.
        limit: Allowed consecutive uncommented statements.

    Returns:
        Lists of start lines, one list per offending run.
    """
    # Statement spans keyed by start line.
    tree = ast.parse(source)
    spans = {
        node.lineno: node.end_lineno
        for node in ast.walk(tree)
        if isinstance(node, ast.stmt)
    }
    # Lines that carry a comment token.
    comments = {
        token.start[0]
        for token in tokenize.generate_tokens(io.StringIO(source).readline)
        if token.type == tokenize.COMMENT
    }
    # Docstrings and source lines for the def/class reset.
    skipped = docstring_lines(tree)
    lines = source.split("\n")
    offending: list[list[int]] = []
    current: list[int] = []
    # Statements in file order.
    for start in sorted(spans):
        # Docstrings are documentation already.
        if start in skipped:
            continue
        # A def/class line starts a new documented unit.
        if lines[start - 1].strip().startswith(("def ", "class ", "async def ")):
            offending += [current] if len(current) > limit else []
            current = []
            continue
        # Comment inside the statement or on the line above resets the run.
        span = range(start - 1, spans[start] + 1)
        if any(line_number in comments for line_number in span):
            offending += [current] if len(current) > limit else []
            current = []
        else:
            current.append(start)
    # Close the last run.
    offending += [current] if len(current) > limit else []
    return offending


def js_runs(source: str, limit: int) -> list[list[int]]:
    """Find uncommented statement runs longer than ``limit`` in JS source.

    Args:
        source: File content.
        limit: Allowed consecutive uncommented statement lines.

    Returns:
        Lists of line numbers, one list per offending run.
    """
    # Heuristic: every non-empty, non-closing line is a statement.
    offending: list[list[int]] = []
    current: list[int] = []
    # Lines in file order.
    for number, raw in enumerate(source.split("\n"), start=1):
        text = raw.strip()
        # Blank lines and pure closers are neutral.
        if not text or JS_CLOSER.fullmatch(text):
            continue
        # Any comment resets the run.
        if text.startswith(("//", "/*", "*")) or "//" in text:
            offending += [current] if len(current) > limit else []
            current = []
        else:
            current.append(number)
    # Close the last run.
    offending += [current] if len(current) > limit else []
    return offending


def main() -> int:
    """Check all given files and print ``path:line: R4 run of N``.

    Returns:
        0 when clean, 1 when any run exceeds the limit.
    """
    # Parse options.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=3)
    parser.add_argument("files", nargs="+")
    options = parser.parse_args()
    findings = 0
    # Dispatch by extension; other files are ignored.
    for path in options.files:
        source = open(path, encoding="utf-8").read()
        if path.endswith(".py"):
            runs = python_runs(source, options.limit)
        elif path.endswith(".js"):
            runs = js_runs(source, options.limit)
        else:
            continue
        # One line per offending run.
        for run in runs:
            print(f"{path}:{run[0]}: R4 run of {len(run)} uncommented statements")
            findings += 1
    # Summary like qa-precheck.
    print(f"TOTAL {findings} run(s)")
    return 1 if findings else 0


# Script entry point.
if __name__ == "__main__":
    sys.exit(main())
