#!/usr/bin/env bash
# tests/test_model.sh — Piper voice manager: catalog, install, install-url security (https only,
# extensions, names, languages), list/default/fallback/remove bookkeeping and download failures.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# fake_curl — install a fake curl that logs its arguments and writes a fixture to the -o target.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT; exports FAKE_CURL_LOG; FAKE_CURL_FAIL=1 fails, FAKE_CURL_EMPTY=1 is empty
fake_curl() {
  export FAKE_CURL_LOG="$TEST_ROOT/curl.log"
  cat > "$TEST_ROOT/fakebin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_CURL_LOG"
[ -z "${FAKE_CURL_FAIL:-}" ] || exit 22
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    if [ -n "${FAKE_CURL_EMPTY:-}" ]; then : > "$2"; else printf 'fixture:%s' "${@: -1}" > "$2"; fi
  fi
  shift
done
FAKE
  chmod +x "$TEST_ROOT/fakebin/curl"
}

# make_model — create a fake installed Piper model with a small payload.
# Args:    $1 <lang>; $2 <model name>
# Returns: 0 always
# Globals: reads XDG_DATA_HOME
make_model() {
  mkdir -p "$XDG_DATA_HOME/piper-tts/$1"
  printf 'onnx-bytes' > "$XDG_DATA_HOME/piper-tts/$1/$2.onnx"
  printf '{}' > "$XDG_DATA_HOME/piper-tts/$1/$2.onnx.json"
}

# case_catalog_listing — plain and porcelain catalog, with the installed flag.
# Args:    none
# Returns: 0 always
# Globals: none
case_catalog_listing() {
  local plain porcelain
  plain="$(htts model catalog)"
  assert_contains "$plain" "Available voices (key — description):" "plain headline"
  assert_contains "$plain" "  en-ryan-high         English (US) — Ryan" "plain row"
  assert_eq 7 "$(htts model catalog --porcelain | wc -l)" "seven catalog entries"
  assert_eq "en-ryan-high	en	en_US-ryan-high	high	0	English (US) — Ryan" \
    "$(htts model catalog --porcelain | head -n1)" "porcelain row, not installed"
  make_model en en_US-ryan-high
  assert_contains "$(htts model catalog --porcelain | head -n1)" "high	1	English" "installed flag set"
  assert_contains "$(htts model catalog)" "English (US) — Ryan  ✓ installed" "plain installed mark"
}

# case_install_from_catalog — a catalog key downloads onnx + json over https into <lang>/.
# Args:    none
# Returns: 0 always
# Globals: none
case_install_from_catalog() {
  fake_curl
  local out; out="$(htts model install en-ryan-high 2>&1)"
  assert_rc 0 "$?" "install succeeds"
  assert_contains "$out" "Installed: en/en_US-ryan-high" "confirmation"
  assert_file "$XDG_DATA_HOME/piper-tts/en/en_US-ryan-high.onnx" "onnx stored"
  assert_file "$XDG_DATA_HOME/piper-tts/en/en_US-ryan-high.onnx.json" "json stored"
  assert_contains "$(cat "$FAKE_CURL_LOG")" "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high/en_US-ryan-high.onnx" "onnx URL"
  assert_contains "$(cat "$FAKE_CURL_LOG")" "-fL --retry 2 --connect-timeout 20" "curl flags"
  assert_eq 2 "$(wc -l < "$FAKE_CURL_LOG")" "two downloads"
  assert_eq "" "$(ls "$XDG_DATA_HOME/piper-tts/en" | grep -v '\.onnx' || true)" "no temp files left"
  htts model install nonsense >/dev/null 2>&1
  assert_rc 1 "$?" "unknown key refused"
  htts model install >/dev/null 2>&1
  assert_rc 1 "$?" "missing key refused"
}

# case_install_url_security — only well-formed https URLs with the right extensions are fetched.
# Args:    none
# Returns: 0 always
# Globals: none
case_install_url_security() {
  fake_curl
  local good="https://example.com/v/x.onnx" bad
  for bad in "http://example.com/x.onnx" "ftp://example.com/x.onnx" "file:///etc/passwd.onnx" \
    "https://example.com/a b.onnx" 'https://example.com/a`id`.onnx' "https://example.com/a|b.onnx" \
    'https://example.com/a"b.onnx' "https://example.com/a<b.onnx" "https://exämple.com/x.onnx" \
    "https://example.com/x.wav"; do
    htts model install-url en "$bad" >/dev/null 2>&1
    assert_rc 1 "$?" "refused: $bad"
  done
  htts model install-url en "$good" "http://example.com/x.onnx.json" >/dev/null 2>&1
  assert_rc 1 "$?" "http json URL refused"
  htts model install-url en "$good" "https://example.com/x.json" >/dev/null 2>&1
  assert_rc 1 "$?" "json URL needs .onnx.json"
  htts model install-url EN "$good" >/dev/null 2>&1
  assert_rc 1 "$?" "uppercase language refused"
  htts model install-url english "$good" >/dev/null 2>&1
  assert_rc 1 "$?" "language of 7 letters refused"
  htts model install-url "../x" "$good" >/dev/null 2>&1
  assert_rc 1 "$?" "traversal as language refused"
  htts model install-url en >/dev/null 2>&1
  assert_rc 1 "$?" "missing URL refused"
  assert_no_file "$FAKE_CURL_LOG" "curl never ran for any refused request"
  htts model install-url en "$good" >/dev/null 2>&1
  assert_rc 0 "$?" "well-formed https URL accepted"
  assert_file "$XDG_DATA_HOME/piper-tts/en/x.onnx" "model stored by file name"
  assert_file "$XDG_DATA_HOME/piper-tts/en/x.onnx.json" "json derived from the onnx URL"
}

# case_download_failures — failed or empty downloads leave nothing behind.
# Args:    none
# Returns: 0 always
# Globals: none
case_download_failures() {
  fake_curl
  local out
  out="$(FAKE_CURL_FAIL=1 htts model install en-ryan-high 2>&1)"
  assert_rc 1 "$?" "failed download"
  assert_contains "$out" "download failed: https://huggingface.co" "message names the URL"
  assert_eq "" "$(ls -A "$XDG_DATA_HOME/piper-tts/en" 2>/dev/null)" "no partial files"
  out="$(FAKE_CURL_EMPTY=1 htts model install en-ryan-high 2>&1)"
  assert_rc 1 "$?" "empty model refused"
  assert_contains "$out" "downloaded model is empty" "message"
  assert_eq "" "$(ls -A "$XDG_DATA_HOME/piper-tts/en" 2>/dev/null)" "empty files removed"
}

# case_list_formats_and_marks — plain/porcelain lists with default, fallback and last-used marks.
# Args:    none
# Returns: 0 always
# Globals: none
case_list_formats_and_marks() {
  assert_eq "No models installed." "$(htts model list)" "empty plain list"
  assert_eq "" "$(htts model list --porcelain)" "empty porcelain list"
  make_model de de_DE-thorsten-high
  make_model en en_US-ryan-high
  local de_file="$XDG_DATA_HOME/piper-tts/de/de_DE-thorsten-high.onnx"
  local en_file="$XDG_DATA_HOME/piper-tts/en/en_US-ryan-high.onnx"
  mkdir -p "$XDG_STATE_HOME/piper-tts"; printf '%s\n' "$en_file" > "$XDG_STATE_HOME/piper-tts/last-model"
  htts model default de/de_DE-thorsten-high >/dev/null 2>&1
  htts model fallback en/en_US-ryan-high >/dev/null 2>&1
  local plain porcelain
  plain="$(htts model list)"
  porcelain="$(htts model list --porcelain)"
  assert_contains "$plain" "de_DE-thorsten-high" "German voice listed"
  assert_contains "$plain" "[default]" "default mark"
  assert_contains "$plain" "[fallback] [last used]" "fallback and last-used marks"
  assert_eq "de/de_DE-thorsten-high	de	de_DE-thorsten-high	10	1	0	0" "$(printf '%s\n' "$porcelain" | head -n1)" "porcelain seven fields"
  assert_eq "en/en_US-ryan-high	en	en_US-ryan-high	10	0	1	1" "$(printf '%s\n' "$porcelain" | tail -n1)" "porcelain flags last+fallback"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "VOICE_de=" "default persisted"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "FALLBACK_VOICE=" "fallback persisted"
  : "$de_file"
}

# case_fallback_commands — show, set, clear and validation of the fallback voice.
# Args:    none
# Returns: 0 always
# Globals: none
case_fallback_commands() {
  assert_contains "$(htts model fallback)" "No fallback voice set" "nothing set"
  make_model en en_US-ryan-high
  assert_contains "$(htts model fallback en/en_US-ryan-high 2>&1)" "Fallback voice set to en/en_US-ryan-high" "set"
  assert_contains "$(htts model fallback)" "Fallback voice: $XDG_DATA_HOME/piper-tts/en/en_US-ryan-high.onnx" "shown"
  assert_contains "$(htts model fallback --clear 2>&1)" "Cleared fallback voice" "cleared"
  assert_contains "$(htts model fallback)" "No fallback voice set" "nothing set again"
  htts model fallback en/missing >/dev/null 2>&1;  assert_rc 1 "$?" "unknown model refused"
  htts model fallback noslash >/dev/null 2>&1;      assert_rc 1 "$?" "id without slash refused"
}

# case_default_and_remove — remove clears default, fallback and last-used references.
# Args:    none
# Returns: 0 always
# Globals: none
case_default_and_remove() {
  make_model en en_US-ryan-high
  make_model en en_US-amy-medium
  local ryan="$XDG_DATA_HOME/piper-tts/en/en_US-ryan-high.onnx"
  htts model default en/en_US-ryan-high >/dev/null 2>&1
  htts model fallback en/en_US-ryan-high >/dev/null 2>&1
  mkdir -p "$XDG_STATE_HOME/piper-tts"; printf '%s\n' "$ryan" > "$XDG_STATE_HOME/piper-tts/last-model"
  assert_contains "$(htts model default en/en_US-amy-medium 2>&1)" "Default voice for 'en' set to en_US-amy-medium" "default message"
  htts model default en/en_US-ryan-high >/dev/null 2>&1
  local out; out="$(htts model remove en/en_US-ryan-high 2>&1)"
  assert_rc 0 "$?" "remove succeeds"
  assert_contains "$out" "Removed: en/en_US-ryan-high" "message"
  assert_no_file "$ryan" "onnx gone"
  assert_no_file "$ryan.json" "json gone"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "VOICE_en" "default dropped"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "FALLBACK_VOICE" "fallback dropped"
  assert_no_file "$XDG_STATE_HOME/piper-tts/last-model" "last-used dropped"
  assert_file "$XDG_DATA_HOME/piper-tts/en/en_US-amy-medium.onnx" "other model kept"
  htts model remove en/en_US-amy-medium >/dev/null 2>&1
  assert_no_file "$XDG_DATA_HOME/piper-tts/en" "empty language directory removed"
  htts model remove en/en_US-amy-medium >/dev/null 2>&1;  assert_rc 1 "$?" "removing twice fails"
  htts model remove noslash >/dev/null 2>&1;              assert_rc 1 "$?" "id without slash refused"
  htts model remove "../x/y" >/dev/null 2>&1;             assert_rc 1 "$?" "traversal refused"
  htts model remove "en/a b" >/dev/null 2>&1;             assert_rc 1 "$?" "unsafe model name refused"
  htts model default noslash >/dev/null 2>&1;             assert_rc 1 "$?" "default id without slash refused"
  htts model default en/nothere >/dev/null 2>&1;          assert_rc 1 "$?" "default for a missing model refused"
  htts model bogus >/dev/null 2>&1;                       assert_rc 1 "$?" "unknown subcommand refused"
}

test_run_cases
