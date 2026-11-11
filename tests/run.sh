#!/usr/bin/env bash
# tests/run.sh — run every bash test suite (tests/test_*.sh) and, when pytest is available,
# the Python tests in tests/py. Exit status is non-zero if any suite fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# detect_helper_python — export HTTS_PYTHON and HTTS_LID_MODEL when the helper venv exists.
# Args:    none
# Returns: 0 always
# Globals: reads XDG_DATA_HOME, HTTS_PYTHON, HTTS_LID_MODEL; may export both
detect_helper_python() {
  local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/hyprland-tts"
  # Without this the 13 Python-path tests of the bash suites silently skip.
  if [ -z "${HTTS_PYTHON:-}" ] && [ -x "$data_dir/venv/bin/python3" ]; then
    export HTTS_PYTHON="$data_dir/venv/bin/python3"
  fi
  # The language model sits next to the venv after `deps install`.
  if [ -z "${HTTS_LID_MODEL:-}" ] && [ -f "$data_dir/langid/lid.176.ftz" ]; then
    export HTTS_LID_MODEL="$data_dir/langid/lid.176.ftz"
  fi
}

# run_bash_suites — run all bash suites and count the failing ones.
# Args:    none
# Returns: 0 when every suite passed; 1 otherwise; stdout: each suite's output
# Globals: reads TESTS_DIR
run_bash_suites() {
  local suite failed=0
  for suite in "$TESTS_DIR"/test_*.sh; do
    # A glob without matches stays literal; skip it instead of "running" it.
    [ -f "$suite" ] || continue
    printf '\n##### %s\n' "$(basename "$suite")"
    # One failing suite must not hide the results of the others.
    bash "$suite" || failed=$((failed + 1))
  done
  printf '\nbash suites failed: %d\n' "$failed"
  [ "$failed" -eq 0 ]
}

# run_python_suites — run pytest on tests/py when pytest and the directory exist.
# Args:    none
# Returns: 0 when pytest passed or was skipped; 1 when it failed
# Globals: reads TESTS_DIR
run_python_suites() {
  # The Python tests belong to the language-ID package and are optional here.
  [ -d "$TESTS_DIR/py" ] || return 0
  if ! command -v pytest >/dev/null 2>&1; then
    printf '\npytest not installed: skipping tests/py\n'
    # CI sets REQUIRE_PYTEST=1 so that skipped Python tests can never pass unnoticed.
    [ "${REQUIRE_PYTEST:-0}" != "1" ] || { printf 'REQUIRE_PYTEST=1: failing\n'; return 1; }
    return 0
  fi
  printf '\n##### pytest tests/py\n'
  # Quiet output; failures still print in full.
  pytest -q "$TESTS_DIR/py"
}

# main — run both kinds of suites and combine their verdicts.
# Args:    none
# Returns: 0 when everything passed; 1 otherwise
# Globals: none
main() {
  local status=0
  detect_helper_python
  # Both kinds always run so a bash failure still shows the Python result.
  run_bash_suites || status=1
  run_python_suites || status=1
  exit "$status"
}

# Both kinds of suites run before the status is returned.
main "$@"
