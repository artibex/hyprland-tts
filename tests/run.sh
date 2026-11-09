#!/usr/bin/env bash
# tests/run.sh — run every bash test suite (tests/test_*.sh) and, when pytest is available,
# the Python tests in tests/py. Exit status is non-zero if any suite fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    # Report even when nothing failed, so the log always ends with a verdict.
    return 0
  fi
  printf '\n##### pytest tests/py\n'
  pytest -q "$TESTS_DIR/py"
}

# main — run both kinds of suites and combine their verdicts.
# Args:    none
# Returns: 0 when everything passed; 1 otherwise
# Globals: none
main() {
  local status=0
  # Both kinds always run so a bash failure still shows the Python result.
  run_bash_suites || status=1
  run_python_suites || status=1
  exit "$status"
}

# Both kinds of suites run before the status is returned.
main "$@"
