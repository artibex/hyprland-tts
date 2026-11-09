#!/usr/bin/env bash
# tests/test_setup.sh — per-user Hyprland wiring: setup/uninstall idempotency for hyprland.conf and
# hyprland.lua, the generated key files, the shortcut summary, and what purge removes.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# fake_hyprctl — install a fake hyprctl that only logs its calls.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT; exports FAKE_HYPRCTL_LOG
fake_hyprctl() {
  export FAKE_HYPRCTL_LOG="$TEST_ROOT/hyprctl.log"
  printf '#!/bin/sh\necho "hyprctl $*" >> "$FAKE_HYPRCTL_LOG"\n' > "$TEST_ROOT/fakebin/hyprctl"
  chmod +x "$TEST_ROOT/fakebin/hyprctl"
}

# case_setup_without_main_config — standalone files plus a warning, never an error.
# Args:    none
# Returns: 0 always
# Globals: none
case_setup_without_main_config() {
  local out; out="$(htts setup 2>&1)"
  assert_rc 0 "$?" "setup succeeds"
  assert_contains "$out" "warning: no hyprland.conf/hyprland.lua found; wrote" "standalone warning"
  assert_file "$XDG_CONFIG_HOME/hypr/tts.conf" "tts.conf written"
  assert_file "$XDG_CONFIG_HOME/hypr/tts.lua" "tts.lua written"
  assert_contains "$out" "hyprland-tts setup complete. Default shortcuts:" "summary headline"
  assert_contains "$out" "  Speak selection    SUPER, A" "summary lists the speak key"
  assert_contains "$out" "  Replay sentence    SUPER ALT, R" "summary lists the last action"
  assert_contains "$out" "Manage voices/keys : hyprland-tts gui" "gui hint"
  assert_contains "$out" "No voice models yet. Install one, e.g.:  hyprland-tts model install en-ryan-high" "voice hint"
}

# case_setup_conf_is_idempotent — the legacy source line is added once and survives a second run.
# Args:    none
# Returns: 0 always
# Globals: none
case_setup_conf_is_idempotent() {
  fake_hyprctl
  mkdir -p "$XDG_CONFIG_HOME/hypr"
  printf 'monitor=,preferred,auto,1\n' > "$XDG_CONFIG_HOME/hypr/hyprland.conf"
  local first second
  first="$(htts setup 2>&1)"
  assert_contains "$first" "Linked tts.conf into hyprland.conf." "first run links"
  second="$(htts setup 2>&1)"
  assert_contains "$second" "hyprland.conf already sources tts.conf — left untouched." "second run detects"
  assert_eq 1 "$(grep -c '^source = ~/.config/hypr/tts.conf$' "$XDG_CONFIG_HOME/hypr/hyprland.conf")" "one source line"
  assert_eq 1 "$(grep -c '^# hyprland-tts (Text-to-Speech) module$' "$XDG_CONFIG_HOME/hypr/hyprland.conf")" "one marker"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/hyprland.conf")" "monitor=,preferred,auto,1" "user content kept"
  assert_eq 2 "$(grep -c '^hyprctl reload' "$FAKE_HYPRCTL_LOG")" "reload after every setup"
  assert_not_contains "$first" "warning: no hyprland.conf" "no standalone warning when linked"
}

# case_setup_lua_is_idempotent — the Lua dofile include is added once.
# Args:    none
# Returns: 0 always
# Globals: none
case_setup_lua_is_idempotent() {
  mkdir -p "$XDG_CONFIG_HOME/hypr"
  printf -- '-- user config\nhl.monitor({})\n' > "$XDG_CONFIG_HOME/hypr/hyprland.lua"
  assert_contains "$(htts setup 2>&1)" "Linked tts.lua into hyprland.lua." "first run links"
  assert_contains "$(htts setup 2>&1)" "hyprland.lua already loads tts.lua — left untouched." "second run detects"
  assert_eq 1 "$(grep -c '^dofile(' "$XDG_CONFIG_HOME/hypr/hyprland.lua")" "one dofile line"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/hyprland.lua")" "dofile(\"$XDG_CONFIG_HOME/hypr/tts.lua\")" "absolute path in dofile"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/hyprland.lua")" "hl.monitor({})" "user content kept"
}

# case_setup_with_both_configs_and_a_model — both files linked, no voice hint with a model.
# Args:    none
# Returns: 0 always
# Globals: none
case_setup_with_both_configs_and_a_model() {
  mkdir -p "$XDG_CONFIG_HOME/hypr" "$XDG_DATA_HOME/piper-tts/en"
  : > "$XDG_CONFIG_HOME/hypr/hyprland.conf"
  : > "$XDG_CONFIG_HOME/hypr/hyprland.lua"
  : > "$XDG_DATA_HOME/piper-tts/en/en_US-x.onnx"
  local out; out="$(htts setup 2>&1)"
  assert_contains "$out" "Linked tts.lua into hyprland.lua." "lua linked"
  assert_contains "$out" "Linked tts.conf into hyprland.conf." "conf linked"
  assert_not_contains "$out" "No voice models yet" "no hint when a model exists"
}

# case_setup_round_trip — uninstall removes every trace of our lines and files, nothing else.
# Args:    none
# Returns: 0 always
# Globals: none
case_setup_round_trip() {
  fake_hyprctl
  mkdir -p "$XDG_CONFIG_HOME/hypr"
  printf 'general { gaps_in = 5 }\n' > "$XDG_CONFIG_HOME/hypr/hyprland.conf"
  printf -- 'hl.config({})\n' > "$XDG_CONFIG_HOME/hypr/hyprland.lua"
  htts setup >/dev/null 2>&1
  htts setup >/dev/null 2>&1
  local out; out="$(htts uninstall 2>&1)"
  assert_rc 0 "$?" "uninstall succeeds"
  assert_contains "$out" "Removed $XDG_CONFIG_HOME/hypr/tts.conf" "tts.conf removal reported"
  assert_contains "$out" "Removed $XDG_CONFIG_HOME/hypr/tts.lua" "tts.lua removal reported"
  assert_contains "$out" "Downloaded voice models kept at" "models kept notice"
  assert_no_file "$XDG_CONFIG_HOME/hypr/tts.conf" "tts.conf gone"
  assert_no_file "$XDG_CONFIG_HOME/hypr/tts.lua" "tts.lua gone"
  assert_eq 0 "$(grep -c 'tts' "$XDG_CONFIG_HOME/hypr/hyprland.conf")" "no tts reference left in the conf"
  assert_eq 0 "$(grep -c 'tts' "$XDG_CONFIG_HOME/hypr/hyprland.lua")" "no tts reference left in the lua"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/hyprland.conf")" "general { gaps_in = 5 }" "conf content kept"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/hyprland.lua")" "hl.config({})" "lua content kept"
  htts uninstall >/dev/null 2>&1
  assert_rc 0 "$?" "second uninstall is harmless"
  htts setup >/dev/null 2>&1
  assert_eq 1 "$(grep -c 'tts.conf' "$XDG_CONFIG_HOME/hypr/hyprland.conf")" "setup works again after uninstall"
}

# case_uninstall_keeps_foreign_source_lines — only our own tts.conf line pattern is removed.
# Args:    none
# Returns: 0 always
# Globals: none
case_uninstall_keeps_foreign_source_lines() {
  mkdir -p "$XDG_CONFIG_HOME/hypr"
  printf 'source = ~/.config/hypr/other.conf\nsource = ~/.config/hypr/tts.conf\n' > "$XDG_CONFIG_HOME/hypr/hyprland.conf"
  htts uninstall >/dev/null 2>&1
  assert_eq "source = ~/.config/hypr/other.conf" "$(cat "$XDG_CONFIG_HOME/hypr/hyprland.conf")" "only the tts.conf source removed"
}

# case_purge_removes_models_state_and_config — purge goes beyond uninstall.
# Args:    none
# Returns: 0 always
# Globals: none
case_purge_removes_models_state_and_config() {
  mkdir -p "$XDG_DATA_HOME/piper-tts/en" "$XDG_STATE_HOME/piper-tts" "$XDG_CONFIG_HOME/piper-tts"
  : > "$XDG_DATA_HOME/piper-tts/en/x.onnx"
  : > "$XDG_STATE_HOME/piper-tts/last-model"
  : > "$XDG_CONFIG_HOME/piper-tts/config"
  htts setup >/dev/null 2>&1
  local out; out="$(htts purge 2>&1)"
  assert_rc 0 "$?" "purge succeeds"
  assert_contains "$out" "Removed models: $XDG_DATA_HOME/piper-tts" "models message"
  assert_contains "$out" "Removed state: $XDG_STATE_HOME/piper-tts" "state message"
  assert_contains "$out" "Removed config: $XDG_CONFIG_HOME/piper-tts" "config message"
  assert_no_file "$XDG_DATA_HOME/piper-tts" "models gone"
  assert_no_file "$XDG_STATE_HOME/piper-tts" "state gone"
  assert_no_file "$XDG_CONFIG_HOME/piper-tts" "config gone"
  assert_no_file "$XDG_CONFIG_HOME/hypr/tts.conf" "wiring gone as well"
}

# case_purge_removes_engine_data_caches_and_runtime_files — nothing of ours is left behind.
# Args:    none
# Returns: 0 always
# Globals: none
case_purge_removes_engine_data_caches_and_runtime_files() {
  local data="$XDG_DATA_HOME/hyprland-tts"
  mkdir -p "$data/engines/qwentts" "$data/venv" "$data/langid" "$data/voices/mine"
  mkdir -p "$XDG_CACHE_HOME/hyprland-tts/pycache" "$HYPRLAND_TTS_RUN_DIR" "$HYPRLAND_TTS_WORKER_DIR"
  mkdir -p "$XDG_STATE_HOME/hyprland-tts" && printf 'ryan\t8.00\n' > "$XDG_STATE_HOME/hyprland-tts/stream-gain"
  local out; out="$(htts purge 2>&1 < /dev/null)"
  assert_rc 0 "$?" "purge succeeds"
  assert_contains "$out" "Removed engine data: $data/engines" "engines message"
  assert_contains "$out" "Removed cloned voices: $data/voices" "voices message"
  assert_no_file "$data" "data directory gone (nothing left in it)"
  assert_no_file "$XDG_CACHE_HOME/hyprland-tts" "cache gone"
  assert_no_file "$XDG_STATE_HOME/hyprland-tts" "learned stream gains gone"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR" "runtime directory gone"
  assert_no_file "$HYPRLAND_TTS_WORKER_DIR" "worker directory gone"
}

# case_purge_can_keep_the_users_voices — --keep-voices protects the recordings, the rest goes.
# Args:    none
# Returns: 0 always
# Globals: none
case_purge_can_keep_the_users_voices() {
  local data="$XDG_DATA_HOME/hyprland-tts"
  mkdir -p "$data/engines" "$data/voices/mine"
  printf 's' > "$data/voices/mine/ref.spk"
  local out; out="$(htts purge --keep-voices 2>&1 < /dev/null)"
  assert_contains "$out" "Kept your cloned voices in $data/voices" "notice"
  assert_file "$data/voices/mine/ref.spk" "voice kept"
  assert_no_file "$data/engines" "engines removed"
}

# case_purge_stops_the_worker — purge and uninstall end the warm engine first.
# Args:    none
# Returns: 0 always
# Globals: none
case_purge_stops_the_worker() {
  test_install_fake_engine base
  htts engine start >/dev/null 2>&1
  local worker server
  worker="$(test_worker_pid)"; server="$(cat "$HYPRLAND_TTS_WORKER_DIR/server.pid")"
  htts uninstall >/dev/null 2>&1
  test_wait_until 5 test_pid_dead "$worker"
  assert_rc 0 "$?" "worker ended by uninstall"
  test_pid_dead "$server"
  assert_rc 0 "$?" "server ended by uninstall"
}

test_run_cases
