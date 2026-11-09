#!/usr/bin/env bash
# tests/test_router_prepare_chunks.sh — prepare_chunks contract, detect_lang and voice resolution.
#
# Self-contained: sources the libraries from the checkout, works in a throw-away sandbox
# and needs no network. Python-dependent checks run when an interpreter with fasttext +
# num2words and the model are reachable (HTTS_PYTHON / HTTS_LID_MODEL, the venv, or the
# AUR packages); otherwise they are reported as SKIP. The fallback checks always run.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
SKIP=0
# Remember the caller's Python/model overrides before the sandbox hides the real data dirs.
REAL_PYTHON="${HTTS_PYTHON:-}"
REAL_MODEL="${HTTS_LID_MODEL:-}"

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

# t_skip — record a skipped check.
# Args:    $1 description
# Returns: 0 always
# Globals: writes SKIP
t_skip() { SKIP=$((SKIP + 1)); printf '  SKIP: %s\n' "$1"; }

# assert_eq — compare two strings.
# Args:    $1 expected | $2 actual | $3 description
# Returns: 0 always
# Globals: none
assert_eq() {
  if [ "$1" = "$2" ]; then t_pass "$3"; else t_fail "$3" "(expected '$1', got '$2')"; fi
}

# assert_match — check that a string matches a regular expression.
# Args:    $1 text | $2 extended regex | $3 description
# Returns: 0 always
# Globals: none
assert_match() {
  if [[ "$1" =~ $2 ]]; then t_pass "$3"; else t_fail "$3" "('${1:0:200}' !~ $2)"; fi
}

# assert_le — check that a number is at most a limit.
# Args:    $1 number | $2 limit | $3 description
# Returns: 0 always
# Globals: none
assert_le() {
  if [ "$1" -le "$2" ]; then t_pass "$3"; else t_fail "$3" "($1 > $2)"; fi
}

# assert_rc — compare an exit status.
# Args:    $1 expected | $2 actual | $3 description
# Returns: 0 always
# Globals: none
assert_rc() { assert_eq "$1" "$2" "$3 (exit status)"; }

# setup_sandbox — create an isolated HOME/XDG tree and load the libraries.
# Args:    none
# Returns: 0 always
# Globals: writes SANDBOX and the XDG_* variables, MODELS_DIR etc. via common.sh
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home" XDG_DATA_HOME="$SANDBOX/data" XDG_STATE_HOME="$SANDBOX/state"
  export XDG_CONFIG_HOME="$SANDBOX/config" XDG_CACHE_HOME="$SANDBOX/cache"
  mkdir -p "$HOME"
  unset HTTS_PYTHON HTTS_LID_MODEL FALLBACK_VOICE
  # shellcheck source=/dev/null
  for module in common text pyenv router; do source "$REPO/lib/$module.sh"; done
}

# python_available — tell whether the Python path can run with the caller's overrides.
# Args:    none
# Returns: 0 when an interpreter and a model are configured; 1 otherwise
# Globals: reads REAL_PYTHON, REAL_MODEL
python_available() {
  [ -n "$REAL_PYTHON" ] && [ -x "$REAL_PYTHON" ] && [ -n "$REAL_MODEL" ] && [ -f "$REAL_MODEL" ]
}

# use_python — enable the Python path for the following checks.
# Args:    none
# Returns: 0 always
# Globals: writes HTTS_PYTHON, HTTS_LID_MODEL
use_python() {
  export HTTS_PYTHON="$REAL_PYTHON" HTTS_LID_MODEL="$REAL_MODEL"
}

# use_fallback — force the bash fallback (no interpreter, no model).
# Args:    none
# Returns: 0 always
# Globals: writes HTTS_PYTHON, HTTS_LID_MODEL
use_fallback() {
  export HTTS_PYTHON=/nonexistent/python3
  unset HTTS_LID_MODEL
}

# check_contract — validate the "lang<TAB>text" output contract of a prepare_chunks run.
# Args:    $1 output | $2 allowed csv | $3 description prefix
# Returns: 0 always
# Globals: none
check_contract() {
  local output="$1" allowed="$2" label="$3" line lang text bad_format=0 bad_lang=0 empty=0
  while IFS= read -r line; do
    lang="${line%%$'\t'*}"
    text="${line#*$'\t'}"
    # Exactly one tab, a valid allowed language and visible content.
    [[ "$line" == *$'\t'* && "$text" != *$'\t'* ]] || bad_format=$((bad_format + 1))
    [[ ",$allowed," == *",$lang,"* ]] || bad_lang=$((bad_lang + 1))
    [[ "$text" =~ [[:alnum:]] ]] || empty=$((empty + 1))
  done <<< "$output"
  assert_eq "0" "$bad_format" "$label: every line is lang<TAB>text"
  assert_eq "0" "$bad_lang" "$label: every language is in the allowed list"
  assert_eq "0" "$empty" "$label: no empty or punctuation-only chunk"
}

# sample_mixed_text — print a mixed German/English/French paragraph with a long first sentence.
# Args:    none
# Returns: 0 always; stdout: the text
# Globals: none
sample_mixed_text() {
  printf '%s\n\n' "Heute ist der 3. Oktober, und wir haben endlich den neuen Pull Request gemergt, obwohl es lange gedauert hat und viele Leute gezweifelt haben."
  printf '%s\n\n' "The quick brown fox jumps over the lazy dog near the river bank today."
  printf '%s\n' "Je pense que c'est une très bonne idée de visiter Paris au printemps. Ärger über Öl: 日本語."
}

# test_fallback_contract — the regex/bash path emits a valid contract.
# Args:    none
# Returns: 0 always
# Globals: none
test_fallback_contract() {
  local output first_text
  use_fallback
  output="$(sample_mixed_text | prepare_chunks de,en,fr de)"
  check_contract "$output" "de,en,fr" "fallback"
  first_text="$(head -n1 <<< "$output" | cut -f2)"
  # The long first sentence is cut for a fast start.
  assert_le "${#first_text}" 90 "fallback: first chunk <= 90 chars"
  assert_match "$output" $'en\tThe quick brown fox' "fallback: English sentence is labelled en"
  assert_match "$output" $'fr\tJe pense' "fallback: French sentence is labelled fr"
  assert_match "$output" "日本語" "fallback: non-Latin characters survive"
}

# test_fallback_single_language — one allowed language labels everything with it.
# Args:    none
# Returns: 0 always
# Globals: none
test_fallback_single_language() {
  local output
  use_fallback
  output="$(printf 'Hello there. Das ist ein Satz.\n' | prepare_chunks en en)"
  assert_eq $'en\tHello there.\nen\tDas ist ein Satz.' "$output" "single language: all chunks use it"
}

# test_fallback_default_and_invalid_arguments — default handling and input validation.
# Args:    none
# Returns: 0 always
# Globals: none
test_fallback_default_and_invalid_arguments() {
  local output rc
  use_fallback
  output="$(printf 'Zzz qqq.\n' | prepare_chunks de,en fr)"
  assert_eq $'de\tZzz qqq.' "$output" "undecidable text uses the first language when the default is not allowed"
  output="$(printf 'Zzz qqq.\n' | prepare_chunks de,en en)"
  assert_eq $'en\tZzz qqq.' "$output" "undecidable text uses the requested default"
  printf 'x\n' | prepare_chunks 'de;rm' de > /dev/null 2>&1
  rc=$?
  assert_rc 1 "$rc" "unsafe language list is rejected"
  printf 'x\n' | prepare_chunks '' de > /dev/null 2>&1
  rc=$?
  assert_rc 1 "$rc" "empty language list is rejected"
  # shellcheck disable=SC2016
  output="$(printf 'Hallo Welt.\n' | prepare_chunks de 'x$(id)')"
  assert_eq $'de\tHallo Welt.' "$output" "unsafe default language is ignored"
}

# test_empty_and_noise_input — empty input and decoration produce no chunks.
# Args:    none
# Returns: 0 always
# Globals: none
test_empty_and_noise_input() {
  local output
  use_fallback
  output="$(printf '' | prepare_chunks de,en de)"
  assert_eq "" "$output" "empty input gives no output"
  output="$(printf '\n---\n***\n...\n' | prepare_chunks de,en de)"
  assert_eq "" "$output" "decoration only gives no output"
}

# ramp_text — print a German paragraph whose sentences are long enough to use every ramp step.
# Args:    none
# Returns: 0 always; stdout: the text
# Globals: none
ramp_text() {
  printf '%s ' "Guten Tag und herzlich willkommen." \
    "Dies ist ein kurzer Test der neuen Sprachausgabe, die vollständig auf diesem Rechner läuft" \
    "und keine Daten in das Netz sendet, auch wenn man es zuerst nicht glauben will." \
    "Wir prüfen, ob mehrere Sätze nacheinander sauber gesprochen werden, und ob die Pausen" \
    "dazwischen natürlich bleiben, auch wenn der Text länger wird und viele Nebensätze enthält." \
    "Ja." "Der Wetterbericht für morgen sagt voraus, dass es im Norden regnen wird, während" \
    "im Süden die Sonne scheint, und dass es am Wochenende wieder wärmer werden soll."
}

# test_ramp_limit_and_cut — the ramp table and the cut helper of the bash path.
# Args:    none
# Returns: 0 always
# Globals: none
test_ramp_limit_and_cut() {
  local text cut
  assert_eq "90" "$(ramp_limit 0)" "ramp: chunk 0 keeps the 90 character limit"
  assert_eq "70" "$(ramp_limit 1)" "ramp: chunk 1 is kept small (the unavoidable gap)"
  assert_eq "220" "$(ramp_limit 99)" "ramp: positions beyond the table use the ceiling"
  # A comma lies inside the first 60 characters: the cut is made after it.
  text="Dies ist ein Satz mit vielen Wörtern, der an einem Komma enden soll und dann weitergeht."
  cut="$(ramp_cut "$text" 60)"
  assert_eq "Dies ist ein Satz mit vielen Wörtern," "${text:0:cut}" "cut: clause boundary preferred"
  # Without any comma the cut falls on a space inside the limit.
  text="eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn"
  cut="$(ramp_cut "$text" 40)"
  assert_le "$cut" 40 "cut: word boundary within the limit"
  assert_eq " " "${text:cut:1}" "cut: lands on a space"
  # A remainder that would be a fragment moves the cut left.
  text="$(printf 'abcdefgh %.0s' {1..10})"
  text="${text% }"
  cut="$(ramp_cut "$text" 75)"
  assert_le "$cut" "$((${#text} - MIN_FRAGMENT))" "cut: the tail keeps at least the fragment minimum"
}

# test_fallback_follows_the_ramp — every fallback chunk fits its ramp step, none is a fragment.
# Args:    none
# Returns: 0 always
# Globals: none
test_fallback_follows_the_ramp() {
  local output position=0 lang text bad_limit=0 bad_fragment=0 second=""
  use_fallback
  output="$(ramp_text | prepare_chunks de de)"
  while IFS=$'\t' read -r lang text; do
    # One merged fragment may exceed the step by less than the fragment minimum.
    [ "${#text}" -le "$(($(ramp_limit "$position") + MIN_FRAGMENT - 1))" ] ||
      bad_limit=$((bad_limit + 1))
    [ "$position" -eq 0 ] || [ "${#text}" -ge "$MIN_FRAGMENT" ] || bad_fragment=$((bad_fragment + 1))
    [ "$position" -ne 1 ] || second="$text"
    position=$((position + 1))
  done <<< "$output"
  assert_eq "0" "$bad_limit" "fallback ramp: every chunk fits the limit of its position"
  assert_eq "0" "$bad_fragment" "fallback ramp: no fragment after the first chunk"
  assert_le "${#second}" 70 "fallback ramp: chunk 1 stays small"
  assert_match "$output" $'\n?de\tGuten Tag und herzlich willkommen\.\n' "fallback ramp: first sentence alone"
}

# test_fallback_merges_fragments — tiny sentences join a neighbour of their own language.
# Args:    none
# Returns: 0 always
# Globals: none
test_fallback_merges_fragments() {
  local output
  use_fallback
  # "Ok." cannot go back into the first chunk, so it is put in front of the next sentence.
  output="$(printf 'Erster Satz hier. Ok. Und dann folgt ein deutlich längerer Satz, der weitergeht.\n' |
    prepare_chunks de de)"
  assert_eq $'de\tErster Satz hier.\nde\tOk. Und dann folgt ein deutlich längerer Satz, der weitergeht.' \
    "$output" "fallback: fragment moves forward, first chunk stays alone"
  # Short sentences after chunk 1 are merged back as long as they fit its limit.
  output="$(printf 'Erster Satz hier. Zweiter etwas längerer Satz hier. Ja. Nein.\n' |
    prepare_chunks de de)"
  assert_eq $'de\tErster Satz hier.\nde\tZweiter etwas längerer Satz hier. Ja. Nein.' "$output" \
    "fallback: short sentences join their predecessor"
  # Different languages are never glued together, even for a fragment.
  output="$(printf 'Das ist der erste Satz hier. The cat is on the table. Ja.\n' |
    prepare_chunks de,en de)"
  assert_match "$output" $'en\tThe cat is on the table\.' "fallback: other language stays separate"
}

# test_fallback_matches_python_chunking — both paths cut plain text into identical chunks.
# Args:    none
# Returns: 0 always
# Globals: none
test_fallback_matches_python_chunking() {
  local text via_python via_bash
  if ! python_available; then t_skip "python/bash chunking parity"; return 0; fi
  text="$(ramp_text)"
  use_python
  via_python="$(printf '%s\n' "$text" | prepare_chunks de de)"
  use_fallback
  via_bash="$(printf '%s\n' "$text" | prepare_chunks de de)"
  assert_eq "$via_python" "$via_bash" "ramp text: bash fallback chunks exactly like Python"
  # A long comma-free sentence is the hardest case for the word-boundary cuts.
  text="$(printf 'wort%03d ' {1..90})"
  use_python
  via_python="$(printf '%s\n' "$text" | prepare_chunks de de)"
  use_fallback
  via_bash="$(printf '%s\n' "$text" | prepare_chunks de de)"
  assert_eq "$via_python" "$via_bash" "comma-free text: bash fallback chunks exactly like Python"
}

# test_python_contract — the Python path emits a valid contract and normalised numbers.
# Args:    none
# Returns: 0 always
# Globals: none
test_python_contract() {
  local output first_text
  if ! python_available; then t_skip "python path (set HTTS_PYTHON and HTTS_LID_MODEL)"; return 0; fi
  use_python
  output="$(sample_mixed_text | prepare_chunks de,en,fr,es,it de)"
  check_contract "$output" "de,en,fr,es,it" "python"
  first_text="$(head -n1 <<< "$output" | cut -f2)"
  assert_le "${#first_text}" 90 "python: first chunk <= 90 chars"
  assert_match "$output" $'de\t' "python: German chunk present"
  assert_match "$output" $'en\tThe quick brown fox' "python: English sentence labelled en"
  assert_match "$output" $'fr\tJe pense' "python: French sentence labelled fr"
  assert_match "$output" "dritten Oktober|dritte Oktober" "python: ordinal date is spoken"
  assert_match "$output" "日本語" "python: non-Latin characters survive"
}

# test_python_single_language_needs_no_model — one language never needs the model.
# Args:    none
# Returns: 0 always
# Globals: none
test_python_single_language_needs_no_model() {
  local output
  if ! python_available; then t_skip "single language without model"; return 0; fi
  export HTTS_PYTHON="$REAL_PYTHON" HTTS_LID_MODEL=/nonexistent/model
  output="$(printf 'Es kostet 5 Euro.\n' | prepare_chunks de de)"
  assert_eq $'de\tEs kostet fünf Euro.' "$output" "single language: normalised without a model"
}

# test_python_missing_model_falls_back — Python present but model missing uses the bash path.
# Args:    none
# Returns: 0 always
# Globals: none
test_python_missing_model_falls_back() {
  local output
  if ! python_available; then t_skip "missing-model fallback"; return 0; fi
  export HTTS_PYTHON="$REAL_PYTHON" HTTS_LID_MODEL=/nonexistent/model
  output="$(printf 'The cat is on the table and you are here.\n' | prepare_chunks de,en de)"
  assert_eq $'en\tThe cat is on the table and you are here.' "$output" "model missing: regex path answers"
}

# test_detect_lang — detect_lang answers with regex and (when available) with fastText.
# Args:    none
# Returns: 0 always
# Globals: none
test_detect_lang() {
  use_fallback
  assert_eq "de" "$(detect_lang 'Das ist ein Haus und nicht mein Auto')" "regex: German"
  assert_eq "en" "$(detect_lang 'The cat is on the table')" "regex: English"
  assert_eq "" "$(detect_lang 'Zzz')" "regex: undecided is empty"
  if ! python_available; then t_skip "fastText detect_lang"; return 0; fi
  use_python
  assert_eq "de" "$(detect_lang 'Bitte öffne den Pull Request im Main Branch')" "fastText: loanword German"
  assert_eq "it" "$(detect_lang 'Grazie mille per tutto')" "fastText: Italian (regex has no Italian)"
}

# make_models — create fake Piper models for the given languages.
# Args:    $1.. language codes
# Returns: 0 always
# Globals: reads MODELS_DIR
make_models() {
  local lang
  for lang in "$@"; do
    mkdir -p "$MODELS_DIR/$lang"
    : > "$MODELS_DIR/$lang/voice-$lang.onnx"
  done
}

# test_model_resolution_chain — language voice, fallback voice, last-used, English, any.
# Args:    none
# Returns: 0 always
# Globals: writes FALLBACK_VOICE, VOICE_de
test_model_resolution_chain() {
  local fallback="$SANDBOX/fallback.onnx" last="$SANDBOX/last.onnx"
  use_fallback
  rm -rf "$MODELS_DIR"
  piper_model_for_lang de > /dev/null
  assert_rc 1 "$?" "no model installed -> failure"
  make_models fr
  assert_eq "$MODELS_DIR/fr/voice-fr.onnx" "$(piper_model_for_lang xx)" "unknown language -> any model"
  make_models en
  assert_eq "$MODELS_DIR/en/voice-en.onnx" "$(piper_model_for_lang xx)" "unknown language -> English"
  : > "$last"
  remember_model "$last"
  assert_eq "$last" "$(piper_model_for_lang xx)" "unknown language -> last-used model"
  : > "$fallback"
  FALLBACK_VOICE="$fallback"
  assert_eq "$fallback" "$(piper_model_for_lang xx)" "unknown language -> fallback voice beats last-used"
  assert_eq "$MODELS_DIR/fr/voice-fr.onnx" "$(piper_model_for_lang fr)" "language voice beats fallback voice"
  # shellcheck disable=SC2034
  VOICE_fr="$last"
  assert_eq "$last" "$(piper_model_for_lang fr)" "VOICE_<lang> overrides the first model"
  unset VOICE_fr FALLBACK_VOICE
  assert_eq "$(piper_model_for_lang '')" "$(piper_model_for_lang xx)" "empty language behaves like unknown"
  model_for_lang 'de;x' > /dev/null
  assert_rc 1 "$?" "model_for_lang rejects an unsafe language code"
}

# test_resolve_model_and_remember — resolve_model detects then resolves; remember_model persists.
# Args:    none
# Returns: 0 always
# Globals: none
test_resolve_model_and_remember() {
  use_fallback
  rm -rf "$MODELS_DIR"
  make_models de en
  assert_eq "$MODELS_DIR/de/voice-de.onnx" "$(resolve_model 'Das ist ein Haus und nicht mein Auto')" "resolve_model: German text"
  assert_eq "$MODELS_DIR/en/voice-en.onnx" "$(resolve_model 'The cat is on the table')" "resolve_model: English text"
  remember_model "$SANDBOX/x.onnx"
  assert_eq "$SANDBOX/x.onnx" "$(cat "$LAST_MODEL_FILE")" "remember_model writes the last-model file"
}

# test_language_lists — installed_langs and supported_langs_csv.
# Args:    none
# Returns: 0 always
# Globals: none
test_language_lists() {
  rm -rf "$MODELS_DIR"
  make_models de nl
  mkdir -p "$MODELS_DIR/empty" "$MODELS_DIR/BAD"
  assert_eq "de,nl" "$(installed_langs)" "installed_langs lists only languages with a model"
  assert_eq "de,en,fr,es,it,nl" "$(supported_langs_csv)" "supported_langs_csv adds installed extras"
  valid_lang_csv "de,en"
  assert_rc 0 "$?" "valid_lang_csv accepts de,en"
  valid_lang_csv "de,,en"
  assert_rc 1 "$?" "valid_lang_csv rejects empty entries"
}

# main — run every check and print a summary.
# Args:    none
# Returns: 0 when nothing failed; 1 otherwise
# Globals: reads PASS, FAIL, SKIP, SANDBOX
main() {
  setup_sandbox
  trap 'rm -rf "$SANDBOX"' EXIT
  test_fallback_contract
  test_fallback_single_language
  test_fallback_default_and_invalid_arguments
  test_empty_and_noise_input
  test_ramp_limit_and_cut
  test_fallback_follows_the_ramp
  test_fallback_merges_fragments
  test_python_contract
  test_fallback_matches_python_chunking
  test_python_single_language_needs_no_model
  test_python_missing_model_falls_back
  test_detect_lang
  test_model_resolution_chain
  test_resolve_model_and_remember
  test_language_lists
  printf '\ntest_router_prepare_chunks: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

main "$@"
