#!/usr/bin/env bash
# tests/test_text_markup.sh — bash fallback text path: normalize_text, looks_like_code, chunk_text.
#
# Self-contained and offline. Pins the behaviour of lib/text.sh (including the fix that list
# markers are only stripped at the start of a line) and, when an interpreter is configured
# through HTTS_PYTHON, checks that the Python port gives byte-identical output.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
SKIP=0
# shellcheck source=/dev/null
source "$REPO/lib/text.sh"

# t_pass — record a passing check.
# Args:    $1 description
# Returns: 0 always
# Globals: writes PASS
t_pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }

# t_fail — record a failing check.
# Args:    $1 description | $2 detail (optional)
# Returns: 0 always
# Globals: writes FAIL
t_fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s %s\n' "$1" "${2:-}"; }

# assert_eq — compare two strings.
# Args:    $1 expected | $2 actual | $3 description
# Returns: 0 always
# Globals: none
assert_eq() {
  if [ "$1" = "$2" ]; then t_pass "$3"; else t_fail "$3" "(expected '$1', got '$2')"; fi
}

# norm — run normalize_text on a string.
# Args:    $1 raw text
# Returns: 0 always; stdout: cleaned text
# Globals: none
norm() { printf '%s' "$1" | normalize_text; }

# test_prose_cleanup — markdown, links, e-mail, decoration and invisible characters.
# Args:    none
# Returns: 0 always
# Globals: none
test_prose_cleanup() {
  assert_eq "Titel. Text mit fett und kursiv." "$(norm $'# Titel\n\nText mit **fett** und *kursiv*.')" "heading and emphasis"
  assert_eq "Ein Link hier." "$(norm 'Ein [Link](https://x.org/a) hier.')" "markdown link keeps its label"
  assert_eq "Bild: Katze ok" "$(norm 'Bild: ![Katze](cat.png) ok')" "image keeps its alt text"
  assert_eq "Siehe (link) und (link)" "$(norm 'Siehe https://example.com/pfad und www.test.de.')" "bare URLs become (link)"
  assert_eq "Mail an (email) bitte." "$(norm 'Mail an max.mustermann@firma.de bitte.')" "e-mail becomes (email)"
  assert_eq "Punkt eins Punkt zwei" "$(norm $'- Punkt eins\n- Punkt zwei')" "bullet markers at line start"
  assert_eq "Erster Zweiter" "$(norm $'1. Erster\n2. Zweiter')" "numbered markers at line start"
  assert_eq "Zitat noch eins" "$(norm $'> Zitat\n> noch eins')" "quote markers"
  assert_eq "Wort" "$(norm $'----\nWort\n.....\n!!!!')" "decorative rows are dropped"
  assert_eq "Hallo Welt mitSilben" "$(norm $'Hallo\xc2\xa0Welt\xe2\x80\x8b mit\xc2\xadSilben\xef\xbb\xbf')" "invisible characters"
  assert_eq "Absatz eins. Absatz zwei" "$(norm $'Absatz eins\n\nAbsatz zwei')" "paragraphs join with a period"
  assert_eq "Endet mit Punkt. Nächster" "$(norm $'Endet mit Punkt.\n\nNächster')" "no double period at joins"
  assert_eq "" "$(norm '')" "empty input"
}

# test_mid_line_markers_survive — dates and arithmetic keep their dots and dashes.
# Args:    none
# Returns: 0 always
# Globals: none
test_mid_line_markers_survive() {
  assert_eq "Wir feiern am 3. Oktober." "$(norm 'Wir feiern am 3. Oktober.')" "ordinal date is not eaten"
  assert_eq "Preis: 5 - 3 = 2" "$(norm 'Preis: 5 - 3 = 2')" "mid-line dash is not a bullet"
  assert_eq "Ein - Satz und dann" "$(norm 'Ein - Satz und - - - dann')" "spaced separators collapse"
}

# test_code_cleanup — operators, comments, identifiers and braces in code paragraphs.
# Args:    none
# Returns: 0 always
# Globals: none
test_code_cleanup() {
  assert_eq $'function foo a, b.\nreturn a equals b.' "$(norm $'function foo(a, b) {\n  return a == b;\n}')" "JS function"
  assert_eq $'def hello name:\nsay hi\nreturn name' "$(norm $'def hello(name):\n    # say hi\n    return name')" "Python function"
  assert_eq "const camel Case Name = snake case value." "$(norm 'const camelCaseName = snake_case_value;')" "identifiers are split"
  assert_eq "Vorher. const a = 1. Nachher." "$(norm $'Vorher.\n```js\nconst a = 1;\n```\nNachher.')" "fenced code is its own paragraph"
}

# test_looks_like_code — the two-of-four signal rule.
# Args:    none
# Returns: 0 always
# Globals: none
test_looks_like_code() {
  looks_like_code 'Das ist (fast) nur Text.'
  assert_eq "1" "$?" "prose with a bracket is not code"
  looks_like_code $'def parse_value(x):\n    return x'
  assert_eq "0" "$?" "function body is code"
  looks_like_code ''
  assert_eq "1" "$?" "empty text is not code"
}

# test_chunk_text — sentence splitting and wrapping.
# Args:    none
# Returns: 0 always
# Globals: none
test_chunk_text() {
  local long wrapped
  assert_eq $'Erster Satz.\nZweiter Satz!\nDritter?' "$(printf 'Erster Satz. Zweiter Satz! Dritter?' | chunk_text)" "split at sentence ends"
  assert_eq $'Liste:\nEins;\nzwei' "$(printf 'Liste: Eins; zwei' | chunk_text)" "colon and semicolon end a chunk"
  long="$(printf 'wort %.0s' $(seq 1 100))"
  wrapped="$(printf '%s' "$long" | CHUNK_MAX=60 chunk_text | awk '{ if (length($0) > m) m = length($0) } END { print m }')"
  if [ "$wrapped" -le 60 ]; then t_pass "long lines are wrapped at CHUNK_MAX"; else t_fail "long lines are wrapped at CHUNK_MAX" "($wrapped)"; fi
}

# test_no_grep_warnings — looks_like_code must not make grep print warnings.
# Args:    none
# Returns: 0 always
# Globals: none
test_no_grep_warnings() {
  local warnings
  warnings="$(looks_like_code $'a\n  b\n\tc' 2>&1 >/dev/null)"
  assert_eq "" "$warnings" "no stray-backslash warning from grep"
}

# test_python_parity — Python htts_markup equals bash normalize_text on a mixed corpus.
# Args:    none
# Returns: 0 always
# Globals: reads HTTS_PYTHON
test_python_parity() {
  local python="${HTTS_PYTHON:-}" case_text bash_out py_out mismatches=0
  if [ -z "$python" ] || [ ! -x "$python" ]; then printf '  SKIP: python parity (set HTTS_PYTHON)\n'; SKIP=$((SKIP + 1)); return 0; fi
  for case_text in $'# T\n\nA **b** [l](http://x)' $'- a\n- b\n\n1. c' $'x == y;\n{ z }' $'Am 3. Mai - ok' "Tab	text" $'a\n\n\nb'; do
    bash_out="$(printf '%s' "$case_text" | normalize_text)"
    py_out="$(printf '%s' "$case_text" | "$python" "$REPO/lib/py/htts_text.py" markup)"
    [ "$bash_out" = "${py_out%$'\n'}" ] || mismatches=$((mismatches + 1))
  done
  assert_eq "0" "$mismatches" "python port is identical to bash on the corpus"
}

# main — run every check and print a summary.
# Args:    none
# Returns: 0 when nothing failed; 1 otherwise
# Globals: reads PASS, FAIL, SKIP
main() {
  test_prose_cleanup
  test_mid_line_markers_survive
  test_code_cleanup
  test_looks_like_code
  test_chunk_text
  test_no_grep_warnings
  test_python_parity
  printf '\ntest_text_markup: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

main "$@"
