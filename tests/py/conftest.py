"""Shared pytest setup for the hyprland-tts text helpers.

Puts ``lib/py`` on the import path and provides fixtures for the optional fastText
model so that model-dependent tests are skipped (not failed) when it is not installed.
"""

# Standard-library helpers for paths and subprocesses.
import os
import sys

import pytest

# Repository root and the helper package directory.
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LIB_PY = os.path.join(REPO_ROOT, "lib", "py")
# Tests import the helper modules by their plain names, exactly like htts_text.py does.
sys.path.insert(0, LIB_PY)

import htts_langid  # noqa: E402  (needs the path set above)


@pytest.fixture(scope="session")
def helper_script() -> str:
    """Return the path of the command-line helper.

    Returns:
        Absolute path of lib/py/htts_text.py.
    """
    # The CLI tests run the script in a subprocess, like the bash router does.
    return os.path.join(LIB_PY, "htts_text.py")


@pytest.fixture(scope="session")
def lid_model() -> str:
    """Skip the test unless fastText and the language model are available.

    Returns:
        Path of the fastText model file.
    """
    # The library import is the first prerequisite.
    pytest.importorskip("fasttext")
    # The model file is searched in the override, user and system locations.
    try:
        return htts_langid.find_model_path()
    except htts_langid.LanguageModelUnavailable:
        pytest.skip("lid.176.ftz not installed (set HTTS_LID_MODEL)")


@pytest.fixture(scope="session")
def number_words() -> bool:
    """Skip the test unless num2words is installed.

    Returns:
        True when number words can be produced.
    """
    # Numeric normalisation degrades to digits without the library.
    pytest.importorskip("num2words")
    return True
