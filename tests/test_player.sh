#!/usr/bin/env bash
# tests/test_player.sh — the full speak pipeline with real mpv (--ao=null wrapper), the fake
# tts-server and fake piper: per-chunk voices, worker lifetime vs. player, fallback, controls.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

TWO_PARAGRAPHS='Das ist der erste Satz und er ist nicht lang.

This is the second paragraph and it is in English.'

# daemon_finished — succeed once the daemon of the last speak has exited after rendering.
# Args:    none
# Returns: 0 when finished; 1 otherwise
# Globals: reads HYPRLAND_TTS_RUN_DIR
daemon_finished() {
  [ -f "$HYPRLAND_TTS_RUN_DIR/render.done" ] && [ ! -f "$HYPRLAND_TTS_RUN_DIR/daemon.pid" ]
}

# daemon_running — succeed while the daemon of the last speak is alive.
# Args:    none
# Returns: 0 when alive; 1 otherwise
# Globals: reads HYPRLAND_TTS_RUN_DIR
daemon_running() {
  [ -f "$HYPRLAND_TTS_RUN_DIR/daemon.pid" ] && kill -0 "$(cat "$HYPRLAND_TTS_RUN_DIR/daemon.pid")" 2>/dev/null
}

# speak_and_wait — put text on the fake selection, run `speak` and wait for the player to finish.
# Args:    $1 <text>
# Returns: 0 when playback finished within 40 s; 1 otherwise
# Globals: reads FAKE_SELECTION
speak_and_wait() {
  printf '%s' "$1" > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 40 daemon_finished
}

# case_qwen3_voices_switch_per_chunk — German and English chunks get their own configured voices.
# Args:    none
# Returns: 0 always
# Globals: none
case_qwen3_voices_switch_per_chunk() {
  test_install_fake_engine
  test_set_config "QWEN_VOICE_de=aiden"
  speak_and_wait "$TWO_PARAGRAPHS"
  assert_rc 0 "$?" "player finished"
  local log; log="$(test_speech_log)"
  assert_eq "2" "$(printf '%s\n' "$log" | wc -l)" "two chunks rendered"
  assert_contains "$log" "aiden German" "German chunk -> aiden / German"
  assert_contains "$log" "ryan English" "English chunk -> ryan / English"
  assert_eq "2" "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "both chunks appended to mpv"
  assert_file "$HYPRLAND_TTS_RUN_DIR/s00000.pcm" "first chunk (streamed) copy non-empty"
  assert_file "$HYPRLAND_TTS_RUN_DIR/s00001.wav" "second wav non-empty"
  assert_no_file "$FAKE_PIPER_LOG" "piper not used"
}

# case_worker_survives_next_speak — the per-speak RUN_DIR wipe does not touch the worker.
# Args:    none
# Returns: 0 always
# Globals: none
case_worker_survives_next_speak() {
  test_install_fake_engine
  speak_and_wait "$TWO_PARAGRAPHS"
  local worker_pid; worker_pid="$(test_worker_pid)"
  [ -n "$worker_pid" ] && test_pass "worker started by speak" || test_fail "worker started by speak"
  speak_and_wait "$TWO_PARAGRAPHS"
  assert_eq "$worker_pid" "$(test_worker_pid)" "same worker for the second speak"
  assert_eq 1 "$(test_event_count start)" "one server for two speaks"
  assert_eq 4 "$(test_event_count speech)" "four requests total"
}

# case_stop_keeps_worker_warm — `stop` ends playback only; `engine stop` ends the worker.
# Args:    none
# Returns: 0 always
# Globals: none
case_stop_keeps_worker_warm() {
  test_install_fake_engine
  echo "dur=4" > "$FAKE_TTS_CONTROL"
  printf '%s' "$TWO_PARAGRAPHS" > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 20 daemon_running
  # Stopping while the model still loads would only prove the worker is "starting".
  test_wait_until 20 test_worker_is_running
  htts stop >/dev/null 2>&1
  test_wait_until 5 test_pid_dead "$(cat "$HYPRLAND_TTS_RUN_DIR/daemon.pid" 2>/dev/null)"
  assert_rc 0 "$?" "daemon stopped"
  assert_contains "$(htts engine status)" "worker:   running" "worker still running"
  htts engine stop >/dev/null 2>&1
  assert_contains "$(htts engine status)" "worker:   stopped" "engine stop stops it"
}

# case_piper_only_voices_per_language — without qwen3 each chunk uses its language's Piper voice.
# Args:    none
# Returns: 0 always
# Globals: none
case_piper_only_voices_per_language() {
  test_add_piper_voice de
  test_add_piper_voice en
  speak_and_wait "$TWO_PARAGRAPHS"
  assert_rc 0 "$?" "player finished"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "/de/de-test.onnx	Das ist der erste Satz" "German chunk -> de voice"
  assert_contains "$(cat "$FAKE_PIPER_LOG")" "/en/en-test.onnx	This is the second" "English chunk -> en voice"
  assert_eq 0 "$(test_event_count start)" "no qwen3 server involved"
}

# case_server_failure_falls_back_to_piper — a failing server yields Piper audio and one notice.
# Args:    none
# Returns: 0 always
# Globals: none
case_server_failure_falls_back_to_piper() {
  test_install_fake_engine
  test_add_piper_voice de
  test_add_piper_voice en
  echo fail500 > "$FAKE_TTS_CONTROL"
  speak_and_wait "$TWO_PARAGRAPHS"
  assert_rc 0 "$?" "player finished"
  assert_eq 2 "$(wc -l < "$FAKE_PIPER_LOG")" "both chunks fell back to piper"
  assert_eq 2 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "both chunks still played"
  assert_eq 1 "$(wc -l < "$FAKE_NOTIFY_LOG")" "one notification only"
}

# case_unstartable_worker_falls_back_to_piper — no worker at all: the whole text is spoken by Piper.
# Args:    none
# Returns: 0 always
# Globals: none
case_unstartable_worker_falls_back_to_piper() {
  test_install_fake_engine
  test_add_piper_voice de
  test_add_piper_voice en
  export FAKE_TTS_BAD_DEVICE=any
  speak_and_wait "$TWO_PARAGRAPHS"
  assert_rc 0 "$?" "player finished"
  assert_eq 2 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "both chunks played"
  assert_eq 2 "$(wc -l < "$FAKE_PIPER_LOG")" "piper spoke them"
}

# case_forced_qwen3_without_install_speaks_with_piper_and_notifies — missing engine, still speech.
# Args:    none
# Returns: 0 always
# Globals: none
case_forced_qwen3_without_install_speaks_with_piper_and_notifies() {
  test_add_piper_voice de
  test_add_piper_voice en
  test_set_config "ENGINE=qwen3"
  speak_and_wait "$TWO_PARAGRAPHS"
  assert_eq 2 "$(wc -l < "$FAKE_PIPER_LOG")" "piper spoke"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "Qwen3 not installed" "user was told"
}

# case_no_voice_at_all_is_an_error — neither engine usable: a clear failure, no daemon.
# Args:    none
# Returns: 0 always
# Globals: none
case_no_voice_at_all_is_an_error() {
  printf '%s' "$TWO_PARAGRAPHS" > "$FAKE_SELECTION"
  local out; out="$(htts speak 2>&1)"
  assert_rc 1 "$?" "speak without any voice"
  assert_contains "$out" "No voice installed" "message"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "No voice installed" "notification"
}

# case_slow_render_resumes_playback — mpv idles between slow chunks and still plays every one.
# Args:    none
# Returns: 0 always
# Globals: none
case_slow_render_resumes_playback() {
  test_install_fake_engine
  echo "slow=1.5" > "$FAKE_TTS_CONTROL"
  speak_and_wait "$TWO_PARAGRAPHS"
  assert_rc 0 "$?" "player finished after the slow chunks"
  assert_eq 2 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "playlist-count reached the rendered total"
}

# case_controls_work_on_a_live_player — status/pause/speed/skip all act on the same mpv.
# Args:    none
# Returns: 0 always
# Globals: none
case_controls_work_on_a_live_player() {
  test_install_fake_engine
  echo "dur=6" > "$FAKE_TTS_CONTROL"
  printf '%s' "$TWO_PARAGRAPHS" > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 20 test_status_has_two_items
  assert_contains "$(htts ctl status)" "pos=0/2" "status before skipping"
  htts ctl pause; sleep 0.3
  assert_contains "$(htts ctl status)" "paused=true" "paused"
  htts ctl resume; sleep 0.3
  assert_contains "$(htts ctl status)" "paused=false" "resumed"
  htts ctl faster; sleep 0.3
  assert_contains "$(htts ctl status)" "speed=1.2" "faster"
  htts ctl slower; sleep 0.3
  assert_contains "$(htts ctl status)" "speed=1" "slower"
  htts ctl next; sleep 0.4
  assert_contains "$(htts ctl status)" "pos=1/2" "next"
  htts ctl prev; sleep 0.4
  assert_contains "$(htts ctl status)" "pos=0/2" "prev"
  htts ctl bogus >/dev/null 2>&1
  assert_rc 1 "$?" "unknown control command"
  htts stop >/dev/null 2>&1
  sleep 0.5
  assert_eq "idle" "$(htts ctl status)" "idle after stop"
}

# test_worker_is_running — succeed once the engine status reports a serving worker.
# Args:    none
# Returns: 0 when the worker is running; 1 otherwise
# Globals: none
test_worker_is_running() { [[ "$(htts engine status --porcelain)" == *"worker=running"* ]]; }

# test_status_has_two_items — succeed once mpv reports both chunks in its playlist.
# Args:    none
# Returns: 0 when pos=*/2 is reported; 1 otherwise
# Globals: none
test_status_has_two_items() { [[ "$(htts ctl status)" == *"/2 "* ]]; }

# case_mpv_ignores_desktop_media_control — the reader's mpv loads no scripts (no MPRIS).
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT
case_mpv_ignores_desktop_media_control() {
  test_add_piper_voice de
  speak_and_wait "Ein kurzer Satz."
  # Omarchy's shell paused the reader over MPRIS within seconds; mpris.so must stay unloaded.
  assert_contains "$(cat "$TEST_ROOT/mpv-argv.log" 2>/dev/null)" "--load-scripts=no" \
    "mpv starts without scripts"
  # A user mpv.conf with keep-open=yes would break the idle-based end detection.
  assert_contains "$(cat "$TEST_ROOT/mpv-argv.log" 2>/dev/null)" "--keep-open=no" \
    "mpv keep-open is forced off"
}

# case_mpv_has_own_client_name_and_volume — the reader's stream is not "mpv" and starts at VOLUME.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT
case_mpv_has_own_client_name_and_volume() {
  test_add_piper_voice de
  test_set_config "VOLUME=55"
  speak_and_wait "Ein kurzer Satz."
  local argv; argv="$(cat "$TEST_ROOT/mpv-argv.log" 2>/dev/null)"
  # As plain "mpv" WirePlumber gave the reader the volume stored for every other mpv (videos).
  assert_contains "$argv" "--audio-client-name=hyprland-tts" "mpv has its own client name"
  assert_contains "$argv" "--volume=55" "mpv starts at the configured volume"
  assert_eq "55" "$(htts volume)" "volume shows the stored value"
}

# case_junk_volume_falls_back_to_full — a hand-edited junk VOLUME plays at 100, never fails.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT
case_junk_volume_falls_back_to_full() {
  test_add_piper_voice de
  test_set_config "VOLUME=loud"
  speak_and_wait "Ein kurzer Satz."
  assert_rc 0 "$?" "player finished"
  assert_contains "$(cat "$TEST_ROOT/mpv-argv.log" 2>/dev/null)" "--volume=100" "junk -> 100"
  assert_eq "100" "$(htts volume)" "volume shows 100 for junk"
  test_set_config "VOLUME=250"
  assert_eq "100" "$(htts volume)" "volume shows 100 above the cap"
}

# case_volume_default_and_leading_zero — 100 without a config; "070" is stored as 70.
# Args:    none
# Returns: 0 always
# Globals: reads XDG_CONFIG_HOME
case_volume_default_and_leading_zero() {
  local out
  assert_eq "100" "$(htts volume)" "default volume"
  htts volume >/dev/null 2>&1
  assert_rc 0 "$?" "volume query"
  out="$(htts volume 070 2>&1)"
  assert_rc 0 "$?" "volume 070"
  assert_eq "volume: 70%" "$out" "confirmation line"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "VOLUME=70" "stored without the zero"
  assert_eq "70" "$(htts volume)" "stored value read back"
  htts volume 0 >/dev/null 2>&1
  assert_eq "0" "$(htts volume)" "zero is a valid volume"
}

# case_invalid_volumes_fail — out of range, signed, non-numeric, empty or extra arguments fail.
# Args:    none
# Returns: 0 always
# Globals: reads XDG_CONFIG_HOME
case_invalid_volumes_fail() {
  local bad out
  htts volume 30 >/dev/null 2>&1
  for bad in 101 -1 abc "" 1.5 1000 "+5"; do
    out="$(htts volume "$bad" 2>&1 >/dev/null)"
    assert_rc 1 "$?" "volume '$bad' rejected"
    assert_contains "$out" "invalid volume" "volume '$bad' explains the range"
  done
  htts volume 40 50 >/dev/null 2>&1
  assert_rc 1 "$?" "two values rejected"
  assert_eq "30" "$(htts volume)" "the stored value survived every bad call"
}

# test_status_shows_volume — succeed once the live player reports a given volume.
# Args:    $1 <volume>
# Returns: 0 when `ctl status` contains volume=<n>; 1 otherwise
# Globals: none
test_status_shows_volume() { [[ "$(htts ctl status)" == *"volume=$1" ]]; }

# case_volume_changes_a_live_player — `volume 40` reaches the running mpv at once.
# Args:    none
# Returns: 0 always
# Globals: reads FAKE_SELECTION, FAKE_TTS_CONTROL, XDG_CONFIG_HOME
case_volume_changes_a_live_player() {
  test_install_fake_engine
  echo "dur=6" > "$FAKE_TTS_CONTROL"
  printf '%s' "$TWO_PARAGRAPHS" > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 20 test_status_has_two_items
  assert_contains "$(htts ctl status)" " volume=100" "status reports the start volume"
  local out; out="$(htts volume 40)"
  assert_rc 0 "$?" "volume 40 on a live player"
  assert_eq "volume: 40%" "$out" "confirmation line"
  test_wait_until 3 test_status_shows_volume 40
  assert_rc 0 "$?" "live player now at volume=40"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "VOLUME=40" "value stored"
  htts stop >/dev/null 2>&1
}

test_run_cases
