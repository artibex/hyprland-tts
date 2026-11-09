#!/usr/bin/env bash
# tests/test_hardening.sh — regression tests for the reviewed robustness and security findings:
# stale ports, private directories, process cleanup, speak races, failure counting, variant
# handling, device fallback, in-flight requests and the user-visible notices.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

TWO_PARAGRAPHS='Das ist der erste Satz und er ist nicht lang.

This is the second paragraph and it is in English.'

# start_engine — install the fake Base engine and start its worker.
# Args:    none
# Returns: 0 always
# Globals: none
start_engine() {
  test_install_fake_engine base
  htts engine start >/dev/null 2>&1
}

# case_idle_exit_shuts_down_inside_the_lock — a client after the idle exit finds no half-dead worker.
# Args:    none
# Returns: 0 always
# Globals: none
case_idle_exit_shuts_down_inside_the_lock() {
  start_engine
  local server; server="$(cat "$HYPRLAND_TTS_WORKER_DIR/server.pid")"
  touch -d '2 hours ago' "$HYPRLAND_TTS_WORKER_DIR/last-use"
  lib_eval 'worker_confirm_idle'
  assert_rc 0 "$?" "idle exit confirmed"
  assert_no_file "$HYPRLAND_TTS_WORKER_DIR/pid" "pid file removed before the lock is released"
  assert_no_file "$HYPRLAND_TTS_WORKER_DIR/ready" "ready file removed"
  assert_no_file "$HYPRLAND_TTS_WORKER_DIR/port" "port file removed"
  test_pid_dead "$server"
  assert_rc 0 "$?" "server killed inside the lock"
  lib_eval 'worker_ensure'
  assert_rc 0 "$?" "a new client starts a fresh worker at once"
  assert_eq 2 "$(test_event_count start)" "second server started"
}

# case_stale_port_file_is_never_used — after a killed worker the leftover port gets no request.
# Args:    none
# Returns: 0 always
# Globals: none
case_stale_port_file_is_never_used() {
  start_engine
  kill -KILL "$(test_worker_pid)"
  sleep 0.3
  assert_file "$HYPRLAND_TTS_WORKER_DIR/port" "stale port file is still there"
  lib_eval "qwen3_render en 'Secret text.' '$TEST_ROOT/a.wav'"
  assert_rc 2 "$?" "worker gone -> status 2 although the server still answers"
  assert_eq 0 "$(test_event_count speech)" "no text was sent to the leftover server"
}

# case_unsafe_run_dir_is_refused — a symlinked runtime directory aborts speak without writing.
# Args:    none
# Returns: 0 always
# Globals: none
case_unsafe_run_dir_is_refused() {
  test_add_piper_voice en
  mkdir -p "$TEST_ROOT/elsewhere"
  ln -s "$TEST_ROOT/elsewhere" "$TEST_ROOT/linked-run"
  printf '%s' "Hello there, this is a test." > "$FAKE_SELECTION"
  local out; out="$(HYPRLAND_TTS_RUN_DIR="$TEST_ROOT/linked-run" htts speak 2>&1)"
  assert_rc 1 "$?" "speak refuses"
  assert_contains "$out" "unsafe runtime directory" "message"
  assert_eq "" "$(ls -A "$TEST_ROOT/elsewhere")" "nothing written through the symlink"
}

# case_run_dir_fallback_names_carry_the_uid — without XDG_RUNTIME_DIR the /tmp names are per user.
# Args:    none
# Returns: 0 always
# Globals: none
case_run_dir_fallback_names_carry_the_uid() {
  local out
  out="$(env -u XDG_RUNTIME_DIR -u HYPRLAND_TTS_RUN_DIR -u HYPRLAND_TTS_WORKER_DIR bash -c \
    "source '$TEST_LIB/common.sh'; echo \"\$RUN_DIR \$WORKER_DIR\"")"
  assert_eq "/tmp/hyprland-tts-$UID /tmp/hyprland-tts-worker-$UID" "$out" "per-user fallback names"
  out="$(env -u HYPRLAND_TTS_RUN_DIR -u HYPRLAND_TTS_WORKER_DIR XDG_RUNTIME_DIR=/run/user/1 bash -c \
    "source '$TEST_LIB/common.sh'; echo \"\$RUN_DIR\"")"
  assert_eq "/run/user/1/hyprland-tts" "$out" "runtime dir names unchanged"
}

# case_worker_dir_is_tightened_and_symlinks_refused — mode 700 is enforced, symlinks are refused.
# Args:    none
# Returns: 0 always
# Globals: none
case_worker_dir_is_tightened_and_symlinks_refused() {
  mkdir -p "$HYPRLAND_TTS_WORKER_DIR"
  chmod 755 "$HYPRLAND_TTS_WORKER_DIR"
  lib_eval 'worker_prepare_dir'
  assert_rc 0 "$?" "existing directory accepted"
  assert_eq 700 "$(stat -c %a "$HYPRLAND_TTS_WORKER_DIR")" "mode tightened to 700"
  rm -rf "$HYPRLAND_TTS_WORKER_DIR"
  mkdir "$TEST_ROOT/target"
  ln -s "$TEST_ROOT/target" "$HYPRLAND_TTS_WORKER_DIR"
  lib_eval 'worker_prepare_dir'
  assert_rc 1 "$?" "symlinked worker directory refused"
}

# case_stop_kills_the_in_flight_renderer — stopping also ends the running piper child.
# Args:    none
# Returns: 0 always
# Globals: none
case_stop_kills_the_in_flight_renderer() {
  test_add_piper_voice en
  printf '#!/usr/bin/env bash\necho $$ > "%s/piper.pid"\nsleep 30\n' "$TEST_ROOT" > "$TEST_ROOT/fakebin/piper-tts"
  chmod +x "$TEST_ROOT/fakebin/piper-tts"
  printf '%s' "This is one English sentence for the test." > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 10 test -s "$TEST_ROOT/piper.pid"
  local piper_pid; piper_pid="$(cat "$TEST_ROOT/piper.pid")"
  htts stop >/dev/null 2>&1
  test_wait_until 5 test_pid_dead "$piper_pid"
  assert_rc 0 "$?" "piper child ended with the daemon"
}

# case_quick_double_speak_starts_one_daemon — two racing speaks leave exactly one player.
# Args:    none
# Returns: 0 always
# Globals: none
case_quick_double_speak_starts_one_daemon() {
  test_add_piper_voice en
  printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 3\ncp "$FAKE_WAV" "$3"\n' > "$TEST_ROOT/fakebin/piper-tts"
  sed -i 's|cp "\$FAKE_WAV" "\$3"|cp "$FAKE_WAV" "${@: -1}"|' "$TEST_ROOT/fakebin/piper-tts"
  chmod +x "$TEST_ROOT/fakebin/piper-tts"
  printf '%s' "This is one English sentence for the test." > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1 &
  htts speak >/dev/null 2>&1 &
  wait
  sleep 0.5
  # Each daemon owns exactly one mpv with this run directory's socket.
  assert_eq 1 "$(pgrep -fc -- "input-ipc-server=$HYPRLAND_TTS_RUN_DIR" || true)" "one player after two speaks"
  htts stop >/dev/null 2>&1
}

# case_stale_pid_file_does_not_kill_strangers — a reused pid of another program is left alone.
# Args:    none
# Returns: 0 always
# Globals: none
case_stale_pid_file_does_not_kill_strangers() {
  sleep 60 &
  local stranger=$!
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  printf '%s\n' "$stranger" > "$HYPRLAND_TTS_RUN_DIR/daemon.pid"
  lib_eval 'kill_existing_daemon'
  kill -0 "$stranger" 2>/dev/null
  assert_rc 0 "$?" "unrelated process survives"
  lib_eval 'daemon_alive'
  assert_rc 1 "$?" "a foreign pid is not a daemon"
  kill "$stranger" 2>/dev/null
}

# case_cold_start_shows_a_loading_notice — a slow model load is announced after two seconds.
# Args:    none
# Returns: 0 always
# Globals: none
case_cold_start_shows_a_loading_notice() {
  test_install_fake_engine base
  export FAKE_TTS_STARTUP_DELAY=3
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  lib_eval 'engine_prepare'
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "loading voice" "notice shown"
  assert_eq 1 "$(grep -c 'loading voice' "$FAKE_NOTIFY_LOG")" "shown once"
}

# case_warm_worker_shows_no_loading_notice — nothing to announce when the worker is already up.
# Args:    none
# Returns: 0 always
# Globals: none
case_warm_worker_shows_no_loading_notice() {
  start_engine
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  lib_eval 'engine_prepare'
  assert_no_file "$FAKE_NOTIFY_LOG" "no notification"
}

# case_request_timeouts_disable_qwen3 — two slow chunks in a row stop the 120 s waits.
# Args:    none
# Returns: 0 always
# Globals: none
case_request_timeouts_disable_qwen3() {
  start_engine
  test_add_piper_voice en
  echo "slow=4" > "$FAKE_TTS_CONTROL"
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  QWEN_REQUEST_TIMEOUT=1 lib_eval "for i in 1 2 3 4; do engine_render en \"Sentence number \$i.\" '$TEST_ROOT/o\$i.wav'; done"
  assert_eq 2 "$(test_event_count speech)" "qwen3 asked twice, then written off"
  assert_eq 4 "$(wc -l < "$FAKE_PIPER_LOG")" "piper rendered every chunk"
}

# case_configured_voice_must_fit_the_variant — a preset on Base (or a clone on CustomVoice) is ignored.
# Args:    none
# Returns: 0 always
# Globals: none
case_configured_voice_must_fit_the_variant() {
  test_install_fake_engine base
  test_set_config "QWEN_VOICE_de=aiden"
  assert_eq "base-default" "$(lib_eval 'voice_for_lang de')" "preset aiden ignored on base"
  export HYPRLAND_TTS_SYSTEM_VOICES="$TEST_ROOT/shipped"
  mkdir -p "$TEST_ROOT/shipped/de-x"; printf s > "$TEST_ROOT/shipped/de-x/ref.spk"; printf r > "$TEST_ROOT/shipped/de-x/ref.rvq"
  test_set_config "QWEN_VOICE_de=de-x"
  assert_eq "de-x" "$(lib_eval 'voice_for_lang de')" "a matching clone is used"
  test_set_config "QWEN_VARIANT=customvoice"
  assert_eq "ryan" "$(lib_eval 'voice_for_lang de')" "clone ignored on customvoice"
}

# case_voice_add_cleans_up_after_a_missing_licence — nothing of the user's WAV is left behind.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_add_cleans_up_after_a_missing_licence() {
  test_install_fake_engine base
  printf 'RIFFfake' > "$TEST_ROOT/ref.wav"; printf 'text\n' > "$TEST_ROOT/ref.txt"
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" --license "$TEST_ROOT/nope.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "missing licence file refused"
  assert_eq "" "$(ls -A "$XDG_DATA_HOME/hyprland-tts/voices" 2>/dev/null)" "no scratch directory left"
}

# case_audio_is_removed_after_playback — chunks and WAVs do not outlive the playback.
# Args:    none
# Returns: 0 always
# Globals: none
case_audio_is_removed_after_playback() {
  test_add_piper_voice en
  printf '%s' "This is one English sentence for the test." > "$FAKE_SELECTION"
  HTTS_KEEP_AUDIO=0 htts speak >/dev/null 2>&1
  test_wait_until 30 test -f "$HYPRLAND_TTS_RUN_DIR/render.done"
  test_wait_until 10 test ! -f "$HYPRLAND_TTS_RUN_DIR/daemon.pid"
  assert_eq "" "$(ls "$HYPRLAND_TTS_RUN_DIR" | grep -E '^s[0-9]+\.wav$|^chunks$' || true)" "text and audio files gone"
}

# case_install_keeps_the_active_variant — a second install does not silently switch voices.
# Args:    none
# Returns: 0 always
# Globals: none
case_install_keeps_the_active_variant() {
  test_install_fake_engine base
  lib_eval 'qwen3_select_after_install customvoice' 2>&1
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VARIANT=base" "base stays active"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VARIANT=customvoice" "not flipped"
  rm -f "$XDG_CONFIG_HOME/piper-tts/config"
  lib_eval 'qwen3_select_after_install customvoice'
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VARIANT=customvoice" "first install selects"
}

# case_engine_variant_command — switching needs an installed model and validates the name.
# Args:    none
# Returns: 0 always
# Globals: none
case_engine_variant_command() {
  test_install_fake_engine "base"
  htts engine variant customvoice >/dev/null 2>&1
  assert_rc 1 "$?" "not installed -> refused"
  htts engine variant bogus >/dev/null 2>&1
  assert_rc 1 "$?" "unknown variant refused"
  htts engine variant codec >/dev/null 2>&1
  assert_rc 1 "$?" "codec is no talker"
  test_install_fake_engine "customvoice base"
  test_set_config "QWEN_VARIANT=base"
  htts engine variant customvoice >/dev/null 2>&1
  assert_rc 0 "$?" "installed variant accepted"
  assert_contains "$(htts engine status --porcelain)" "qwen3_variant=customvoice" "switched"
}

# case_codec_is_not_a_variant — QWEN_VARIANT=codec must not count as an installed engine.
# Args:    none
# Returns: 0 always
# Globals: none
case_codec_is_not_a_variant() {
  test_install_fake_engine base
  test_set_config "QWEN_VARIANT=codec"
  assert_contains "$(htts engine status)" "active:   piper" "codec as variant -> piper"
}

# case_failed_header_preparation_is_fatal — a die inside the header step stops the build.
# Args:    none
# Returns: 0 always
# Globals: none
case_failed_header_preparation_is_fatal() {
  local out
  out="$(lib_eval 'qwen3_prepare_vulkan_headers() { return 1; }; extra=(); qwen3_collect_header_args /x extra; echo SURVIVED' 2>&1)"
  assert_not_contains "$out" "SURVIVED" "the build did not continue"
  assert_contains "$out" "could not prepare the Vulkan headers" "message"
}

# case_failed_device_is_skipped_next_time — a crashed Vulkan start is not retried at once.
# Args:    none
# Returns: 0 always
# Globals: none
case_failed_device_is_skipped_next_time() {
  test_install_fake_engine base
  export FAKE_TTS_BAD_DEVICE=Vulkan0
  htts engine start >/dev/null 2>&1
  assert_rc 0 "$?" "CPU took over"
  assert_eq 2 "$(test_event_count start)" "one Vulkan attempt, one CPU start (no 3x retry)"
  assert_contains "$(cat "$HYPRLAND_TTS_WORKER_DIR/failed-device")" "Vulkan0" "failure remembered"
  kill -KILL "$(test_worker_pid)" "$(cat "$HYPRLAND_TTS_WORKER_DIR/server.pid")"
  sleep 0.3
  htts engine start >/dev/null 2>&1
  assert_eq 3 "$(test_event_count start)" "second start went straight to CPU"
  htts engine stop >/dev/null 2>&1
  assert_no_file "$HYPRLAND_TTS_WORKER_DIR/failed-device" "engine stop forgets the failure"
}

# case_speak_checks_curl_and_flock_for_qwen3 — missing tools are reported before anything starts.
# Args:    none
# Returns: 0 always
# Globals: none
case_speak_checks_curl_and_flock_for_qwen3() {
  local out
  out="$(lib_eval 'have() { [ "$1" != flock ] && command -v "$1" >/dev/null 2>&1; }; speak_check_tools qwen3' 2>&1)"
  assert_rc 1 "$?" "missing flock refused"
  assert_contains "$out" "flock not found (install util-linux)" "message"
  out="$(lib_eval 'have() { [ "$1" != curl ] && command -v "$1" >/dev/null 2>&1; }; speak_check_tools qwen3' 2>&1)"
  assert_contains "$out" "curl not found (install curl)" "curl message"
}

# case_mpv_start_failure_is_reported — a player that cannot start tells the user.
# Args:    none
# Returns: 0 always
# Globals: none
case_mpv_start_failure_is_reported() {
  test_add_piper_voice en
  printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/fakebin/mpv"
  printf '%s' "This is one English sentence for the test." > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 10 test -s "$FAKE_NOTIFY_LOG"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "mpv did not start" "notification"
  assert_contains "$(cat "$HYPRLAND_TTS_RUN_DIR/daemon.log")" "mpv did not start" "daemon log"
}

# case_vanished_renderer_is_detected — without a done marker the monitor takes over the count.
# Args:    none
# Returns: 0 always
# Globals: none
case_vanished_renderer_is_detected() {
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  lib_eval 'sleep 0 & DAEMON_RENDER_PID=$!; wait $!; _player_paths; mpv_get() { echo 3; }
    daemon_render_crashed; echo "rc=$?"; cat "$COUNTFILE"; test -f "$DONEFILE" && echo done' > "$TEST_ROOT/out.txt" 2>&1
  assert_contains "$(cat "$TEST_ROOT/out.txt")" "rc=0" "crash recognised"
  assert_contains "$(cat "$TEST_ROOT/out.txt")" "done" "marker written"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "renderer stopped unexpectedly" "user told"
}

# case_in_flight_request_blocks_idle_exit — a long synthesis is not cut off by the idle timer.
# Args:    none
# Returns: 0 always
# Globals: none
case_in_flight_request_blocks_idle_exit() {
  start_engine
  touch -d '2 hours ago' "$HYPRLAND_TTS_WORKER_DIR/last-use"
  sleep 30 &
  local requester=$!
  : > "$HYPRLAND_TTS_WORKER_DIR/inflight.$requester"
  lib_eval 'worker_idle_expired'
  assert_rc 1 "$?" "idle exit postponed while a request runs"
  kill "$requester"; wait "$requester" 2>/dev/null
  lib_eval 'worker_idle_expired'
  assert_rc 0 "$?" "idle exit allowed once the requester is gone"
  assert_no_file "$HYPRLAND_TTS_WORKER_DIR/inflight.$requester" "stale mark removed"
}

# case_finish_needs_two_idle_polls — a single idle reading right after an append does not quit.
# Args:    none
# Returns: 0 always
# Globals: none
case_finish_needs_two_idle_polls() {
  lib_eval 'DAEMON_MPV_PID=$$; polls=0; sent=0
    daemon_render_crashed() { return 1; }
    daemon_playback_finished() { polls=$((polls + 1)); [ "$polls" -eq 1 ] || [ "$polls" -ge 3 ]; }
    mpv_ipc() { sent=$polls; }
    daemon_monitor; echo "quit sent at poll $sent"' > "$TEST_ROOT/out.txt" 2>&1
  assert_contains "$(cat "$TEST_ROOT/out.txt")" "quit sent at poll 4" "idle, busy, idle, idle -> quit on the 4th poll"
}

# case_unusable_qwen3_notice_names_the_reason — the notice is no longer always "not installed".
# Args:    none
# Returns: 0 always
# Globals: none
case_unusable_qwen3_notice_names_the_reason() {
  test_install_fake_engine customvoice
  test_add_piper_voice en
  test_set_config "ENGINE=qwen3"
  test_set_config "QWEN_VARIANT=base"
  printf '%s' "This is one English sentence for the test." > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 10 test -s "$FAKE_NOTIFY_LOG"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "Using Piper: variant base is not installed" "reason shown"
  assert_not_contains "$(cat "$FAKE_NOTIFY_LOG")" "Qwen3 not installed" "no misleading title"
}

# case_bad_numeric_settings_are_sanitised — junk timeouts fall back to the defaults.
# Args:    none
# Returns: 0 always
# Globals: none
case_bad_numeric_settings_are_sanitised() {
  assert_eq 120 "$(QWEN_REQUEST_TIMEOUT=junk lib_eval 'qwen3_request_timeout')" "junk request timeout"
  assert_eq 120 "$(QWEN_REQUEST_TIMEOUT=0 lib_eval 'qwen3_request_timeout')" "zero request timeout"
  assert_eq 30 "$(QWEN_REQUEST_TIMEOUT=30 lib_eval 'qwen3_request_timeout')" "valid value kept"
}

# case_selection_is_capped — an enormous selection is shortened with a notice.
# Args:    none
# Returns: 0 always
# Globals: none
case_selection_is_capped() {
  test_add_piper_voice en
  test_set_config "SELECTION_MAX_CHARS=60"
  python3 -c 'print("This is a sentence. " * 50, end="")' > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
  test_wait_until 10 test -s "$FAKE_NOTIFY_LOG"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "selection shortened" "notice"
  test_wait_until 10 test -s "$HYPRLAND_TTS_RUN_DIR/chunks"
  [ "$(wc -c < "$HYPRLAND_TTS_RUN_DIR/chunks")" -lt 200 ] && test_pass "only the beginning is read" ||
    test_fail "only the beginning is read"
}

# case_regex_fallback_matches_characters_not_bytes — "naïve" is not German in a C locale.
# Args:    none
# Returns: 0 always
# Globals: none
case_regex_fallback_matches_characters_not_bytes() {
  assert_eq "fr" "$(LC_ALL=C lib_eval 'detect_lang_regex "a naïve plan"')" "accent class is character-wise"
}

# case_helper_errors_are_logged_not_hidden — a crashing text helper leaves a log and a notice.
# Args:    none
# Returns: 0 always
# Globals: none
case_helper_errors_are_logged_not_hidden() {
  test_add_piper_voice en
  printf '#!/bin/sh\necho "Traceback: boom" >&2\nexit 1\n' > "$TEST_ROOT/crashing-python"
  chmod +x "$TEST_ROOT/crashing-python"
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  printf 'Hello there.' | HTTS_PYTHON="$TEST_ROOT/crashing-python" lib_eval 'prepare_chunks en en' > "$TEST_ROOT/chunks.txt"
  assert_contains "$(cat "$TEST_ROOT/chunks.txt")" "Hello there." "the fallback still produced chunks"
  assert_contains "$(cat "$XDG_STATE_HOME/piper-tts/helper.log")" "Traceback: boom" "error kept in the log"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "text helper failed" "user told once"
}

test_run_cases
