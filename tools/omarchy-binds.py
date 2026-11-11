#!/usr/bin/env python3
"""Snapshot Omarchy's default Hyprland binds as "MODMASK KEY" lines.

hyprland-tts is an add-on: its default shortcuts must never take a key that
Omarchy itself binds (Agent.md §5). This tool reads Omarchy's Lua binding files
(a local checkout or a GitHub branch) and prints every literal combo in the
modmask form `hyprctl binds -j` uses, for tests/data/omarchy-default-binds.txt.

Usage: omarchy-binds.py [--branch NAME ...] [--dir PATH ...] > snapshot.txt
"""

from __future__ import annotations  # Modern type hints.

import argparse  # Command-line options.
import pathlib  # Local binding files.
import re  # Combo extraction from Lua source.
import sys  # Error output.
import urllib.error  # Missing files on a branch.
import urllib.request  # Branch downloads.

# Raw file base of the upstream Omarchy repository (renamed from basecamp/omarchy).
RAW_BASE = "https://raw.githubusercontent.com/omacom/omarchy"
# Binding files under default/hypr/ across the Omarchy 4 branches (absent ones are skipped).
BINDING_FILES = (
    "bindings/applications.lua",
    "bindings/clipboard.lua",
    "bindings/dictation.lua",
    "bindings/input-method.lua",
    "bindings/jis.lua",
    "bindings/media.lua",
    "bindings/tiling.lua",
    "bindings/tiling-v2.lua",
    "bindings/utilities.lua",
)
# Hyprland's modifier bits, as summed into the "modmask" field of `hyprctl binds -j`.
MOD_BITS = {"SHIFT": 1, "CAPS": 2, "CTRL": 4, "CONTROL": 4, "ALT": 8, "SUPER": 64, "WIN": 64}
# A literal first argument of o.bind(...) / hl.bind(...); loop-built combos ("SUPER + " .. key)
# only cover digits and keycodes, which no hyprland-tts default uses.
BIND_CALL = re.compile(r'\b(?:o|hl)\.bind\(\s*"([^"]+)"\s*(?:,|\))')
# The description argument that Omarchy's o.bind helper takes second.
DESCRIPTION = re.compile(r'\s*"([^"]*)"')


def combo_to_mask_key(combo: str) -> tuple[int, str] | None:
    """Convert a Lua combo such as "SUPER + ALT + A" to (modmask, KEY).

    Args:
        combo: Combo text joined with "+".

    Returns:
        (modmask, upper-case key), or None for a combo with an unknown modifier.
    """
    # The key is the last part; everything before it is a modifier.
    parts = [part.strip().upper() for part in combo.split("+") if part.strip()]
    # An empty combo cannot be a bind.
    if not parts:
        return None
    # An unknown modifier means this is no plain key combo, so it is not comparable.
    if any(modifier not in MOD_BITS for modifier in parts[:-1]):
        return None
    # The modifier bits add up to the mask Hyprland reports.
    mask = sum(MOD_BITS[modifier] for modifier in parts[:-1])
    return mask, parts[-1]


def extract_binds(source: str) -> list[tuple[int, str, str]]:
    """List every literal bind in one Lua file.

    Args:
        source: Lua source text.

    Returns:
        (modmask, KEY, description) per bind; the description is "" when absent.
    """
    binds = []
    # Every literal bind call becomes one entry.
    for match in BIND_CALL.finditer(source):
        converted = combo_to_mask_key(match.group(1))
        # Combos with unknown modifiers are left out.
        if converted is None:
            continue
        # Omarchy's o.bind takes the description second; hl.bind has none.
        described = DESCRIPTION.match(source, match.end())
        label = described.group(1) if described else ""
        binds.append((converted[0], converted[1], label))
    return binds


def read_branch_file(branch: str, relative: str) -> str | None:
    """Download one binding file from an upstream branch.

    Args:
        branch: Branch name such as "quattro".
        relative: Path below default/hypr/.

    Returns:
        The file text, or None when the branch has no such file.
    """
    url = f"{RAW_BASE}/{branch}/default/hypr/{relative}"
    # A 404 only means the branch does not ship this file; anything else is a real error.
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        # Re-raised unless it is the harmless "file not on this branch" case.
        if error.code == 404:
            return None
        raise


def read_sources(branches: list[str], directories: list[str]) -> list[tuple[str, str]]:
    """Read every binding file of the requested sources.

    Args:
        branches: Upstream branches to download.
        directories: Local default/hypr directories to read.

    Returns:
        (origin label, Lua source) per file found.
    """
    sources = []
    # Upstream branches show what Omarchy ships next; absent files are skipped.
    for branch in branches:
        for relative in BINDING_FILES:
            text = read_branch_file(branch, relative)
            # Only files the branch really has are kept.
            if text is not None:
                sources.append((branch, text))
    # Local checkouts cover the version a user really runs.
    for directory in directories:
        for path in sorted(pathlib.Path(directory).glob("bindings/*.lua")):
            sources.append(("local", path.read_text(encoding="utf-8")))
    return sources


def snapshot_lines(sources: list[tuple[str, str]]) -> list[str]:
    """Merge the binds of all sources into one line per combo.

    Args:
        sources: (origin label, Lua source) pairs.

    Returns:
        Lines "MODMASK KEY  # descriptions (origins)", sorted by modmask and key.
    """
    labels: dict[tuple[int, str], set[str]] = {}
    origins: dict[tuple[int, str], set[str]] = {}
    # The same combo in several branches collapses into one line.
    for origin, text in sources:
        for mask, key, label in extract_binds(text):
            # Descriptions and origins are both collected per combo.
            labels.setdefault((mask, key), set()).add(label)
            origins.setdefault((mask, key), set()).add(origin)
    lines = []
    # Empty descriptions are dropped from the merged label list.
    for combo in sorted(labels):
        described = ", ".join(sorted(label for label in labels[combo] if label))
        lines.append(f"{combo[0]} {combo[1]}  # {described} ({', '.join(sorted(origins[combo]))})")
    return lines


def main() -> int:
    """Print the snapshot for the requested sources.

    Returns:
        Process exit code (0 ok, 1 when no bind was found).
    """
    parser = argparse.ArgumentParser(description="Snapshot Omarchy's default Hyprland binds.")
    # Several branches and directories can be merged into one snapshot.
    parser.add_argument("--branch", action="append", default=[], help="upstream branch")
    parser.add_argument("--dir", action="append", default=[], help="local default/hypr dir")
    arguments = parser.parse_args()
    # Reading and merging are separate steps, so each stays testable on its own.
    lines = snapshot_lines(read_sources(arguments.branch, arguments.dir))
    # An empty result means the file layout changed; a silent empty snapshot would pass tests.
    if not lines:
        print("error: no binds found (did Omarchy move its binding files?)", file=sys.stderr)
        return 1
    # The snapshot goes to stdout, ready to be redirected into the test data file.
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
