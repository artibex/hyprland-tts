#!/usr/bin/env bash
# tests/test_say.sh — `hyprland-tts say`: text from the arguments or stdin goes through the normal
# player (real mpv via the --ao=null wrapper, fake tts-server, fake piper); forced language,
# --wait (ends with playback, stop or a replacing reading), option parsing and refusals.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

GERMAN_TEXT='Das ist der erste Satz und er ist nicht lang.'
ENGLISH_TEXT='This is the second paragraph and it is in English.'

# daemon_finished — succeed once the daemon of the last reading has exited after rendering.
# Args:    none
# Returns: 0 when finished; 1 otherwise
# Globals: reads HYPRLAND_TTS_RUN_DIR
daemon_finished() {
  [ -f "$HYPRLAND_TTS_RUN_DIR/render.done" ] && [ ! -f "$HYPRLAND_TTS_RUN_DIR/daemon.pid" ]
}

# daemon_running — succeed while the daemon of the last reading is alive.
# Args:    none
# Returns: 0 when alive; 1 otherwise
# Globals: reads HYPRLAND_TTS_RUN_DIR
daemon_running() {
  [ -f "$HYPRLAND_TTS_RUN_DIR/daemon.pid" ] &&
    kill -0 "$(cat "$HYPRLAND_TTS_RUN_DIR/daemon.pid")" 2>/dev/null
}

# daemon_pid — print the pid of the running daemon (empty when none).
# Args:    none
# Returns: 0 always
# Globals: reads HYPRLAND_TTS_RUN_DIR
daemon_pid() { cat "$HYPRLAND_TTS_RUN_DIR/daemon.pid" 2>/dev/null || true; }

# say_speech_log — print the fake server's speech requests as "<voice>|<language>|<input>".
# Args:    none
# Returns: 0 always; stdout: one line per request
# Globals: reads FAKE_TTS_LOG
say_speech_log() {
  [ -f "$FAKE_TTS_LOG" ] || return 0
  python3 - "$FAKE_TTS_LOG" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    event = json.loads(line)
    if event["event"] == "speech":
        print("%s|%s|%s" % (event["voice"], event["language"], event["input"]))
PY
}

# say_and_wait — run `say` with the given arguments (stdin passes through) and wait for the end.
# Args:    $1.. <say arguments>
# Returns: 0 when the command succeeded and playback finished; 1 otherwise
# Globals: writes SAY_OUT (the command's stdout)
say_and_wait() {
  SAY_OUT="$(htts say "$@" 2>/dev/null)" || return 1
  test_wait_until 40 daemon_finished
}

# expect_refusal — run `say` and check that it fails with a message and starts nothing.
# Args:    $1 <expected message part>; $2.. <say arguments> (stdin passes through)
# Returns: 0 always
# Globals: reads HYPRLAND_TTS_RUN_DIR, FAKE_NOTIFY_LOG, FAKE_PIPER_LOG
expect_refusal() {
  local expected="$1" out
  shift
  out="$(htts say "$@" 2>&1)"
  assert_rc 1 "$?" "say $* refused"
  assert_contains "$out" "$expected" "say $* says why"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/daemon.pid" "say $* started no player"
  assert_no_file "$FAKE_PIPER_LOG" "say $* rendered nothing"
  assert_no_file "$FAKE_NOTIFY_LOG" "say $* sent no desktop notification"
}

# reap_say_job — collect a background say's exit status; a job still running is killed first,
# so a broken --wait fails the case instead of hanging the suite.
# Args:    $1 <job pid>
# Returns: the job's exit status (143 when it had to be killed)
# Globals: none
reap_say_job() {
  kill -0 "$1" 2>/dev/null && kill "$1" 2>/dev/null
  wait "$1"
}

# case_argument_text_is_spoken — the words are joined, detected and spoken; stdout stays empty.
# Args:    none
# Returns: 0 always
# Globals: none
case_argument_text_is_spoken() {
  test_install_fake_engine
  say_and_wait Das ist der erste Satz "und er" ist nicht lang.
  assert_rc 0 "$?" "say with words finished"
  assert_eq "" "$SAY_OUT" "nothing on stdout"
  assert_contains "$(say_speech_log)" "|German|$GERMAN_TEXT" \
    "words joined with single spaces, detected as German"
  assert_contains "$(cat "$TEST_ROOT/mpv-argv.log")" "--audio-client-name=hyprland-tts" \
    "played by the normal reader"
}

# case_stdin_text_is_spoken — without words the whole of stdin is read and detected.
# Args:    none
# Returns: 0 always
# Globals: none
case_stdin_text_is_spoken() {
  test_install_fake_engine
  printf '%s\n\n%s\n' "$GERMAN_TEXT" "$ENGLISH_TEXT" | say_and_wait
  assert_rc 0 "$?" "say from stdin finished"
  assert_eq "" "$SAY_OUT" "nothing on stdout"
  local log; log="$(say_speech_log)"
  assert_contains "$log" "|German|$GERMAN_TEXT" "German paragraph detected as German"
  assert_contains "$log" "|English|$ENGLISH_TEXT" "English paragraph detected as English"
}

# case_dash_reads_stdin — a lone "-" means stdin, it is not spoken itself.
# Args:    none
# Returns: 0 always
# Globals: none
case_dash_reads_stdin() {
  test_install_fake_engine
  printf '%s' "$ENGLISH_TEXT" | say_and_wait -
  assert_rc 0 "$?" "say - finished"
  local log; log="$(say_speech_log)"
  assert_contains "$log" "|English|$ENGLISH_TEXT" "stdin text spoken"
  assert_eq 1 "$(printf '%s\n' "$log" | wc -l)" "only the stdin text was spoken"
}

# case_lang_fixes_the_language — --lang de speaks English-looking text as German, no detection.
# Args:    none
# Returns: 0 always
# Globals: none
case_lang_fixes_the_language() {
  test_install_fake_engine
  test_set_config "QWEN_VOICE_de=aiden"
  say_and_wait --lang de "$ENGLISH_TEXT"
  assert_rc 0 "$?" "say --lang de finished"
  local log; log="$(say_speech_log)"
  assert_contains "$log" "aiden|German|$ENGLISH_TEXT" "English text spoken by the German voice"
  assert_eq "" "$(printf '%s\n' "$log" | grep -v '|German|')" "no chunk in another language"
}

# case_lang_with_piper_uses_that_voice — the forced language picks its Piper voice.
# Args:    none
# Returns: 0 always
# Globals: none
case_lang_with_piper_uses_that_voice() {
  test_add_piper_voice de
  test_add_piper_voice en
  say_and_wait --wait --lang de -- "$ENGLISH_TEXT"
  assert_rc 0 "$?" "say --wait --lang de -- finished"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "/de/de-test.onnx	$ENGLISH_TEXT" "German voice spoke"
  assert_eq "" "$(grep -v '/de/de-test.onnx' "$FAKE_PIPER_LOG")" "English voice not used"
}

# case_lang_refusals — a malformed code, a missing value or a language without a voice fail.
# Args:    none
# Returns: 0 always
# Globals: none
case_lang_refusals() {
  test_add_piper_voice de
  expect_refusal "no Piper voice installed for 'fr'" --lang fr "Bonjour à tous."
  expect_refusal "invalid language code: 'DE'" --lang DE "Hallo"
  expect_refusal "invalid language code: ''" --lang "" "Hallo"
  expect_refusal "--lang needs a value" --lang
  test_install_fake_engine
  expect_refusal "Qwen3 cannot speak 'nl'" --lang nl "Goedemorgen allemaal."
  assert_eq 0 "$(test_event_count speech)" "nothing reached the server"
}

# case_nothing_to_say — whitespace-only words or stdin fail with a message and start nothing.
# Args:    none
# Returns: 0 always
# Globals: none
case_nothing_to_say() {
  test_add_piper_voice en
  expect_refusal "error: nothing to say" "   "
  expect_refusal "error: nothing to say" < /dev/null
  printf ' \n\t\n' | expect_refusal "error: nothing to say" -
  printf ' \n\t\n' | expect_refusal "error: nothing to say" --wait --lang en
}

# case_unknown_option_and_double_dash — an unknown option fails; after -- a dash is text.
# Args:    none
# Returns: 0 always
# Globals: none
case_unknown_option_and_double_dash() {
  test_add_piper_voice en
  expect_refusal "unknown option: --fast" --fast "$ENGLISH_TEXT"
  expect_refusal "usage: hyprland-tts say [--lang <code>] [--wait]" --fast "$ENGLISH_TEXT"
  expect_refusal "unknown option: -x" -x marks the spot
  say_and_wait -- -x marks the spot.
  assert_rc 0 "$?" "say -- -x ... finished"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "marks the spot" "text after -- was spoken"
}

# case_without_wait_returns_while_speaking — like speak: back as soon as the daemon runs.
# Args:    none
# Returns: 0 always
# Globals: none
case_without_wait_returns_while_speaking() {
  test_install_fake_engine
  echo "dur=4" > "$FAKE_TTS_CONTROL"
  htts say "$GERMAN_TEXT" >/dev/null 2>&1
  assert_rc 0 "$?" "say returned"
  daemon_running && test_pass "daemon still playing after say returned" ||
    test_fail "daemon still playing after say returned"
}

# case_wait_returns_after_playback — --wait blocks while the reading plays, then the daemon is gone.
# Args:    none
# Returns: 0 always
# Globals: none
case_wait_returns_after_playback() {
  local say_job reading_pid say_rc
  test_install_fake_engine
  echo "dur=2" > "$FAKE_TTS_CONTROL"
  htts say --wait "$GERMAN_TEXT" >/dev/null 2>&1 &
  say_job=$!
  test_wait_until 20 daemon_running
  reading_pid="$(daemon_pid)"
  sleep 0.5
  kill -0 "$say_job" 2>/dev/null && test_pass "say --wait still waiting during playback" ||
    test_fail "say --wait still waiting during playback"
  test_wait_until 30 test_pid_dead "$say_job"
  reap_say_job "$say_job"
  say_rc=$?
  assert_rc 0 "$say_rc" "say --wait"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/daemon.pid" "no daemon.pid right after it returned"
  [ -e "$HYPRLAND_TTS_RUN_DIR/render.done" ] && test_pass "rendering had finished" ||
    test_fail "rendering had finished" "(no render.done)"
  test_pid_dead "$reading_pid" && test_pass "daemon process gone" ||
    test_fail "daemon process gone" "(pid $reading_pid)"
  assert_contains "$(say_speech_log)" "|German|$GERMAN_TEXT" "the text was spoken"
}

# case_wait_ends_when_stopped — `stop` from another process ends the wait with status 0.
# Args:    none
# Returns: 0 always
# Globals: none
case_wait_ends_when_stopped() {
  local say_job
  test_install_fake_engine
  echo "dur=6" > "$FAKE_TTS_CONTROL"
  htts say --wait "$GERMAN_TEXT" >/dev/null 2>&1 &
  say_job=$!
  test_wait_until 20 daemon_running
  sleep 0.5
  kill -0 "$say_job" 2>/dev/null && test_pass "waiting before stop" ||
    test_fail "waiting before stop"
  htts stop >/dev/null 2>&1
  test_wait_until 5 test_pid_dead "$say_job"
  assert_rc 0 "$?" "say --wait returned soon after stop"
  reap_say_job "$say_job"
  assert_rc 0 "$?" "say --wait after stop"
}

# case_say_replaces_a_running_reading — a new say stops the old reading and ends its wait.
# Args:    none
# Returns: 0 always
# Globals: none
case_say_replaces_a_running_reading() {
  local say_job first_pid
  test_install_fake_engine
  echo "dur=6" > "$FAKE_TTS_CONTROL"
  htts say --wait "$GERMAN_TEXT" >/dev/null 2>&1 &
  say_job=$!
  test_wait_until 20 daemon_running
  first_pid="$(daemon_pid)"
  # Two paragraphs in two languages are two chunks of 6 s each (a longer reply would be a runaway).
  printf '%s\n\n%s\n' "$GERMAN_TEXT" "$ENGLISH_TEXT" | htts say >/dev/null 2>&1
  assert_rc 0 "$?" "second say started"
  test_pid_dead "$first_pid" && test_pass "first reading stopped" ||
    test_fail "first reading stopped"
  # The second reading lasts 12 s: the first wait must end with its own daemon, not this one.
  test_wait_until 5 test_pid_dead "$say_job"
  assert_rc 0 "$?" "the first say's wait ended"
  reap_say_job "$say_job"
  assert_rc 0 "$?" "first say --wait"
  daemon_running && test_pass "second reading still playing" ||
    test_fail "second reading still playing"
  test_wait_until 10 english_text_requested
  assert_rc 0 "$?" "second text spoken"
}

# english_text_requested — succeed once the fake server was asked for the English text.
# Args:    none
# Returns: 0 when the request is logged; 1 otherwise
# Globals: reads ENGLISH_TEXT
english_text_requested() { [[ "$(say_speech_log)" == *"|English|$ENGLISH_TEXT"* ]]; }

test_run_cases
