#!/usr/bin/env bash
# tests/test_engine_worker.sh — on-demand worker: start/reuse, idle exit, stale recovery,
# concurrent start race, device fallback, failure marker, privacy of the state directory.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# server_pid — print the tts-server pid recorded by the worker.
# Args:    none
# Returns: 0 always
# Globals: reads HYPRLAND_TTS_WORKER_DIR
server_pid() { cat "$HYPRLAND_TTS_WORKER_DIR/server.pid" 2>/dev/null || true; }

# case_start_and_reuse — first start spawns one loopback server, later starts reuse it.
# Args:    none
# Returns: 0 always
# Globals: none
case_start_and_reuse() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  assert_rc 0 "$?" "engine start"
  local first_pid; first_pid="$(test_worker_pid)"
  assert_contains "$(htts engine status)" "worker:   running" "status says running"
  htts engine start >/dev/null 2>&1
  assert_eq "$first_pid" "$(test_worker_pid)" "second start reuses the same worker"
  assert_eq 1 "$(test_event_count start)" "exactly one tts-server was started"
  assert_contains "$(cat "$FAKE_TTS_LOG")" '"--host", "127.0.0.1"' "server bound to 127.0.0.1"
  assert_contains "$(cat "$FAKE_TTS_LOG")" '"--device", "Vulkan0"' "device from engine.conf"
  assert_file "$HYPRLAND_TTS_WORKER_DIR/port" "port recorded"
}

# case_state_dir_is_private — the worker directory is mode 700.
# Args:    none
# Returns: 0 always
# Globals: none
case_state_dir_is_private() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  assert_eq 700 "$(stat -c %a "$HYPRLAND_TTS_WORKER_DIR")" "state dir mode"
}

# case_idle_exit — without requests the worker and its server exit after the idle limit.
# Args:    none
# Returns: 0 always
# Globals: none
case_idle_exit() {
  test_install_fake_engine
  export WORKER_IDLE_SECONDS=2
  htts engine start >/dev/null 2>&1
  local worker_pid server; worker_pid="$(test_worker_pid)"; server="$(server_pid)"
  assert_contains "$(htts engine status)" "idle limit 2s" "idle limit visible"
  test_wait_until 10 test_pid_dead "$worker_pid"
  assert_rc 0 "$?" "worker exited by itself"
  test_wait_until 5 test_pid_dead "$server"
  assert_rc 0 "$?" "server exited with it"
  assert_contains "$(htts engine status)" "worker:   stopped" "status says stopped"
  assert_no_file "$HYPRLAND_TTS_WORKER_DIR/port" "port file removed"
}

# case_requests_keep_worker_alive — traffic restarts the idle timer.
# Args:    none
# Returns: 0 always
# Globals: none
case_requests_keep_worker_alive() {
  test_install_fake_engine
  export WORKER_IDLE_SECONDS=3
  htts engine start >/dev/null 2>&1
  local worker_pid i; worker_pid="$(test_worker_pid)"
  for i in 1 2 3 4 5; do
    sleep 1
    lib_eval "qwen3_render en 'keep alive $i' '$TEST_ROOT/o$i.wav'" >/dev/null 2>&1
  done
  test_pid_dead "$worker_pid"
  assert_rc 1 "$?" "worker still alive after 5 s of traffic with a 3 s limit"
  test_wait_until 10 test_pid_dead "$worker_pid"
  assert_rc 0 "$?" "worker exits once traffic stops"
}

# case_stale_pid_recovery — a SIGKILLed worker leaves an orphan server; the next start cleans up.
# Args:    none
# Returns: 0 always
# Globals: none
case_stale_pid_recovery() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  local old_worker old_server; old_worker="$(test_worker_pid)"; old_server="$(server_pid)"
  kill -KILL "$old_worker"
  sleep 0.3
  htts engine start >/dev/null 2>&1
  assert_rc 0 "$?" "start after a crashed worker"
  test_pid_dead "$old_server"
  assert_rc 0 "$?" "orphaned server was reaped"
  [ "$(test_worker_pid)" != "$old_worker" ] && test_pass "new worker pid" || test_fail "new worker pid"
  assert_eq 2 "$(test_event_count start)" "a fresh server was started"
}

# case_dead_server_makes_worker_exit — if the server crashes the worker follows and restarts work.
# Args:    none
# Returns: 0 always
# Globals: none
case_dead_server_makes_worker_exit() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  local old_worker; old_worker="$(test_worker_pid)"
  kill -KILL "$(server_pid)"
  test_wait_until 6 test_pid_dead "$old_worker"
  assert_rc 0 "$?" "worker notices the dead server"
  htts engine start >/dev/null 2>&1
  assert_rc 0 "$?" "restart works"
}

# case_concurrent_start_single_server — five simultaneous starts share one worker (flock).
# Args:    none
# Returns: 0 always
# Globals: none
case_concurrent_start_single_server() {
  test_install_fake_engine
  export FAKE_TTS_STARTUP_DELAY=1
  local i status_dir="$TEST_ROOT/status"; mkdir -p "$status_dir"
  for i in 1 2 3 4 5; do
    ( htts engine start >/dev/null 2>&1; echo "$?" > "$status_dir/$i" ) &
  done
  wait
  assert_eq "0 0 0 0 0" "$(cat "$status_dir"/* | tr '\n' ' ' | sed 's/ $//')" "all starts succeeded"
  assert_eq 1 "$(test_event_count start)" "only one server started"
}

# case_engine_stop — `engine stop` ends worker and server and is repeatable.
# Args:    none
# Returns: 0 always
# Globals: none
case_engine_stop() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  local worker_pid server; worker_pid="$(test_worker_pid)"; server="$(server_pid)"
  htts engine stop >/dev/null 2>&1
  assert_rc 0 "$?" "engine stop"
  test_pid_dead "$worker_pid"; assert_rc 0 "$?" "worker gone"
  test_pid_dead "$server"; assert_rc 0 "$?" "server gone"
  htts engine stop >/dev/null 2>&1
  assert_rc 0 "$?" "stop when nothing runs is fine"
}

# case_variant_switch_restarts_worker — a worker serving customvoice is replaced after the switch.
# Args:    none
# Returns: 0 always
# Globals: none
case_variant_switch_restarts_worker() {
  test_install_fake_engine "customvoice base"
  htts engine start >/dev/null 2>&1
  local old_server; old_server="$(server_pid)"
  test_set_config "QWEN_VARIANT=base"
  htts engine start >/dev/null 2>&1
  assert_rc 0 "$?" "start after the variant switch"
  assert_eq 2 "$(test_event_count start)" "a second server was started"
  assert_contains "$(tail -n1 "$FAKE_TTS_LOG")" "qwen-talker-0.6b-base" "new server loads the base talker"
  test_pid_dead "$old_server"; assert_rc 0 "$?" "old server stopped"
}

# case_vulkan_failure_falls_back_to_cpu — a server that cannot use Vulkan0 is retried on CPU.
# Args:    none
# Returns: 0 always
# Globals: none
case_vulkan_failure_falls_back_to_cpu() {
  test_install_fake_engine
  export FAKE_TTS_BAD_DEVICE=Vulkan0
  htts engine start >/dev/null 2>&1
  assert_rc 0 "$?" "start succeeds on CPU"
  assert_contains "$(cat "$FAKE_TTS_LOG")" '"--device", "CPU"' "CPU server was started"
}

# case_unstartable_worker_fails_fast — a server that always dies reports failure quickly.
# Args:    none
# Returns: 0 always
# Globals: none
case_unstartable_worker_fails_fast() {
  test_install_fake_engine
  export FAKE_TTS_BAD_DEVICE=any
  local begin end; begin="$(date +%s)"
  htts engine start >/dev/null 2>&1
  assert_rc 1 "$?" "start reports failure"
  end="$(date +%s)"
  [ $((end - begin)) -lt 15 ] && test_pass "failure came fast" || test_fail "failure came fast"
  assert_file "$HYPRLAND_TTS_WORKER_DIR/failed" "failure marker written"
}

# case_start_without_install_dies — engine start needs an installed engine.
# Args:    none
# Returns: 0 always
# Globals: none
case_start_without_install_dies() {
  local out; out="$(htts engine start 2>&1)"
  assert_rc 1 "$?" "engine start without install"
  assert_contains "$out" "engine install qwen3" "message names the fix"
}

test_run_cases
