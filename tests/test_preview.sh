#!/usr/bin/env bash
# tests/test_preview.sh — `hyprland-tts preview`: the built-in sample sentence goes through the
# normal player (real mpv via the --ao=null wrapper, fake tts-server, fake piper) in exactly the
# requested language, with forced engine / Piper voice, and every refusal path.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# daemon_finished — succeed once the daemon of the last preview has exited after rendering.
# Args:    none
# Returns: 0 when finished; 1 otherwise
# Globals: reads HYPRLAND_TTS_RUN_DIR
daemon_finished() {
  [ -f "$HYPRLAND_TTS_RUN_DIR/render.done" ] && [ ! -f "$HYPRLAND_TTS_RUN_DIR/daemon.pid" ]
}

# preview_speech_log — print the fake server's speech requests as "<voice>|<language>|<input>".
# Args:    none
# Returns: 0 always; stdout: one line per request
# Globals: reads FAKE_TTS_LOG
preview_speech_log() {
  [ -f "$FAKE_TTS_LOG" ] || return 0
  python3 - "$FAKE_TTS_LOG" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    event = json.loads(line)
    if event["event"] == "speech":
        print("%s|%s|%s" % (event["voice"], event["language"], event["input"]))
PY
}

# add_named_piper_voice — create an empty fake Piper voice with a given name.
# Args:    $1 <language code>; $2 <voice name>
# Returns: 0 always; stdout: the onnx path
# Globals: reads XDG_DATA_HOME
add_named_piper_voice() {
  mkdir -p "$XDG_DATA_HOME/piper-tts/$1"
  : > "$XDG_DATA_HOME/piper-tts/$1/$2.onnx"
  printf '%s' "$XDG_DATA_HOME/piper-tts/$1/$2.onnx"
}

# preview_and_wait — run `preview` with the given arguments and wait for the player to finish.
# Args:    $1.. <preview arguments>
# Returns: 0 when the command printed its line and playback finished; 1 otherwise
# Globals: writes PREVIEW_OUT
preview_and_wait() {
  PREVIEW_OUT="$(htts preview "$@" 2>&1)" || return 1
  test_wait_until 40 daemon_finished
}

# expect_refusal — run `preview` and check that it fails with a message and starts nothing.
# Args:    $1 <expected message part>; $2.. <preview arguments>
# Returns: 0 always
# Globals: reads HYPRLAND_TTS_RUN_DIR, FAKE_NOTIFY_LOG, FAKE_PIPER_LOG
expect_refusal() {
  local expected="$1" out
  shift
  out="$(htts preview "$@" 2>&1)"
  assert_rc 1 "$?" "preview $* refused"
  assert_contains "$out" "$expected" "preview $* says why"
  assert_not_contains "$out" "preview:" "preview $* prints no success line"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/daemon.pid" "preview $* started no player"
  assert_no_file "$FAKE_PIPER_LOG" "preview $* rendered nothing"
  assert_no_file "$FAKE_NOTIFY_LOG" "preview $* sent no desktop notification"
}

# case_qwen3_preview_speaks_the_sample_in_the_language — French sample, French voice, French only.
# Args:    none
# Returns: 0 always
# Globals: none
case_qwen3_preview_speaks_the_sample_in_the_language() {
  test_install_fake_engine
  test_set_config "QWEN_VOICE_fr=aiden"
  test_set_config "DEFAULT_LANG=de"
  preview_and_wait fr
  assert_rc 0 "$?" "preview fr finished"
  assert_eq "preview: fr" "$PREVIEW_OUT" "confirmation line"
  local log; log="$(preview_speech_log)"
  assert_contains "$log" "aiden|French|Bonjour" "sample spoken by the configured French voice"
  assert_contains "$log" "plaît" "the whole sample sentence was rendered"
  assert_eq "" "$(printf '%s\n' "$log" | grep -v '^aiden|French|')" "no chunk in another language"
  assert_contains "$(cat "$TEST_ROOT/mpv-argv.log")" "--audio-client-name=hyprland-tts" \
    "played by the normal reader"
  assert_no_file "$FAKE_PIPER_LOG" "piper not used"
}

# case_qwen3_preview_of_a_cjk_language — Japanese has a sample and reaches the server as Japanese.
# Args:    none
# Returns: 0 always
# Globals: none
case_qwen3_preview_of_a_cjk_language() {
  test_install_fake_engine
  preview_and_wait ja
  assert_rc 0 "$?" "preview ja finished"
  local log; log="$(preview_speech_log)"
  assert_contains "$log" "|Japanese|こんにちは" "Japanese sample, Japanese language"
  assert_eq "" "$(printf '%s\n' "$log" | grep -v '|Japanese|')" "no chunk in another language"
}

# case_forced_qwen3_beats_a_piper_config — --engine qwen3 wins over ENGINE=piper in the daemon.
# Args:    none
# Returns: 0 always
# Globals: none
case_forced_qwen3_beats_a_piper_config() {
  test_install_fake_engine
  test_add_piper_voice de
  test_set_config "ENGINE=piper"
  preview_and_wait de --engine qwen3
  assert_rc 0 "$?" "preview de --engine qwen3 finished"
  assert_contains "$(preview_speech_log)" "|German|Hallo! So klingt" "rendered by Qwen3 in German"
  assert_no_file "$FAKE_PIPER_LOG" "piper not used"
  assert_contains "$(htts engine status --porcelain)" "selected=piper" "config left unchanged"
}

# case_piper_preview_uses_the_configured_voice — the voice chosen for German speaks the sample.
# Args:    none
# Returns: 0 always
# Globals: none
case_piper_preview_uses_the_configured_voice() {
  local chosen
  test_add_piper_voice de
  test_add_piper_voice en
  chosen="$(add_named_piper_voice de de-zzchosen)"
  test_set_config "VOICE_de=$chosen"
  preview_and_wait de
  assert_rc 0 "$?" "preview de finished"
  assert_eq "preview: de" "$PREVIEW_OUT" "confirmation line"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "$chosen	Hallo!" \
    "configured German voice speaks the German sample"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "$chosen	So klingt diese Stimme auf Deutsch." \
    "the whole sample was rendered (short first chunk, then the rest)"
  assert_eq "" "$(grep -v "^$chosen	" "$FAKE_PIPER_LOG")" "no other voice involved"
}

# case_model_option_previews_that_voice_only — --model speaks with exactly that file, Piper only,
# and leaves the "last used voice" memory alone.
# Args:    none
# Returns: 0 always
# Globals: reads XDG_STATE_HOME
case_model_option_previews_that_voice_only() {
  local other last_file="$XDG_STATE_HOME/piper-tts/last-model"
  test_install_fake_engine
  test_add_piper_voice de
  other="$(add_named_piper_voice de de-other)"
  test_set_config "VOICE_de=$XDG_DATA_HOME/piper-tts/de/de-test.onnx"
  mkdir -p "$(dirname "$last_file")"
  printf '%s' "$XDG_DATA_HOME/piper-tts/de/de-test.onnx" > "$last_file"
  preview_and_wait de --model de/de-other
  assert_rc 0 "$?" "preview de --model de/de-other finished"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "$other	Hallo!" "the named voice speaks the sample"
  assert_eq "" "$(grep -v "^$other	" "$FAKE_PIPER_LOG")" "no other voice involved"
  assert_eq 0 "$(test_event_count speech)" "an installed Qwen3 does not take over"
  assert_eq "$XDG_DATA_HOME/piper-tts/de/de-test.onnx" "$(cat "$last_file")" \
    "last-used voice unchanged"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "de-other" "config unchanged"
}

# case_forced_piper_needs_no_qwen3_notice — --engine piper with ENGINE=qwen3 is no failure notice.
# Args:    none
# Returns: 0 always
# Globals: none
case_forced_piper_needs_no_qwen3_notice() {
  test_install_fake_engine
  test_add_piper_voice de
  test_set_config "ENGINE=qwen3"
  preview_and_wait de --engine piper
  assert_rc 0 "$?" "preview de --engine piper finished"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "de-test.onnx	Hallo!" "piper spoke the sample"
  assert_eq 0 "$(test_event_count speech)" "qwen3 not asked"
  assert_no_file "$FAKE_NOTIFY_LOG" "no 'Qwen3 unavailable' notification"
}

# case_preview_refusals — every invalid request fails with a reason, no player, no notification.
# Args:    none
# Returns: 0 always
# Globals: none
case_preview_refusals() {
  test_add_piper_voice de
  test_add_piper_voice en
  test_add_piper_voice nl
  expect_refusal "usage: hyprland-tts preview"
  expect_refusal "invalid language code" DE
  expect_refusal "invalid language code" "../de"
  expect_refusal "no sample sentence for 'nl'" nl
  expect_refusal "no Piper voice installed for 'it'" it
  expect_refusal "Qwen3 is not usable: not installed" de --engine qwen3
  expect_refusal "speaks 'en', not 'de'" de --model en/en-test
  expect_refusal "no such model" de --model de/missing
  expect_refusal "invalid model name" de --model "de/../en/en-test"
  expect_refusal "cannot be used with --engine qwen3" de --model de/de-test --engine qwen3
  expect_refusal "cannot be used with --engine qwen3" de --engine qwen3 --model de/de-test
  expect_refusal "unknown engine" de --engine espeak
  expect_refusal "--engine needs a value" de --engine
  expect_refusal "unknown option: --fast" de --fast
}

# case_qwen3_refusals — an installed Qwen3 refuses a language outside its list.
# Args:    none
# Returns: 0 always
# Globals: none
case_qwen3_refusals() {
  test_install_fake_engine
  expect_refusal "no sample sentence for 'nl'" nl
  expect_refusal "no Piper voice installed for 'it'" it --engine piper
  assert_eq 0 "$(test_event_count speech)" "nothing reached the server"
}

test_run_cases
