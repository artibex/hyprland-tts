#!/usr/bin/env bash
# tests/test_keybind.sh — modmask math, combo splitting, tts.conf/tts.lua generation, the
# keybind CLI (list/set/check/reset), conflict detection against a fake `hyprctl binds -j`
# and the self-healing of a hand-edited tts.conf.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# fake_hyprctl — install a fake hyprctl: `binds -j` prints $FAKE_BINDS_JSON, `reload` is logged.
# Args:    $1 <JSON text served for `binds -j`>
# Returns: 0 always
# Globals: reads TEST_ROOT; exports FAKE_BINDS_JSON and FAKE_HYPRCTL_LOG
fake_hyprctl() {
  export FAKE_BINDS_JSON="$1" FAKE_HYPRCTL_LOG="$TEST_ROOT/hyprctl.log"
  cat > "$TEST_ROOT/fakebin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
echo "hyprctl $*" >> "$FAKE_HYPRCTL_LOG"
[ "$1 $2" != "binds -j" ] || printf '%s\n' "$FAKE_BINDS_JSON"
exit 0
FAKE
  chmod +x "$TEST_ROOT/fakebin/hyprctl"
}

# bind_json — print one Hyprland-style bind object as JSON.
# Args:    $1 <modmask>; $2 <key>; $3 <dispatcher>; $4 <arg>; $5 <description, optional>
# Returns: 0 always
# Globals: none
bind_json() {
  printf '{"locked": false, "mouse": false, "modmask": %s, "submap": "", "key": "%s", ' "$1" "$2"
  printf '"description": "%s", "dispatcher": "%s", "arg": "%s"}' "${5:-}" "$3" "$4"
}

# case_mask_math — modifier names map to the Hyprland modmask bits and sum up.
# Args:    none
# Returns: 0 always
# Globals: none
case_mask_math() {
  assert_eq 64 "$(lib_eval '_mods_to_mask SUPER')" "SUPER"
  assert_eq 72 "$(lib_eval '_mods_to_mask "SUPER ALT"')" "SUPER ALT"
  assert_eq 5 "$(lib_eval '_mods_to_mask "ctrl shift"')" "lowercase CTRL SHIFT"
  assert_eq 0 "$(lib_eval '_mods_to_mask ""')" "no modifiers"
  assert_eq 0 "$(lib_eval '_mods_to_mask "BOGUS"')" "unknown modifier ignored"
  assert_eq 64 "$(lib_eval '_mods_to_mask "WIN"')" "WIN is SUPER"
  assert_eq 4 "$(lib_eval '_mods_to_mask "CONTROL"')" "CONTROL is CTRL"
}

# case_combo_splitting — "MODS, KEY" splits at the last comma and trims blanks.
# Args:    none
# Returns: 0 always
# Globals: none
case_combo_splitting() {
  assert_eq "[SUPER ALT][right]" "$(lib_eval '_split_combo "SUPER ALT, right"; echo "[$_KB_MODS][$_KB_KEY]"')" "plain"
  assert_eq "[SUPER][A]" "$(lib_eval '_split_combo "SUPER,A"; echo "[$_KB_MODS][$_KB_KEY]"')" "no space after comma"
  assert_eq "[][F5]" "$(lib_eval '_split_combo "F5"; echo "[$_KB_MODS][$_KB_KEY]"')" "no modifiers"
  assert_eq "[SUPER][B]" "$(lib_eval '_split_combo "  SUPER  , B "; echo "[$_KB_MODS][$_KB_KEY]"')" "padding trimmed"
  assert_eq "SUPER + ALT + right" "$(lib_eval '_combo_to_lua_key "SUPER ALT, right"')" "lua key string"
  assert_eq "F5" "$(lib_eval '_combo_to_lua_key "F5"')" "lua key without modifiers"
  assert_eq 'a\"b\\c' "$(lib_eval '_lua_string_escape "a\"b\\c"')" "lua escaping"
}

# case_generated_files — tts.conf and tts.lua list every action with its marker.
# Args:    none
# Returns: 0 always
# Globals: none
case_generated_files() {
  lib_eval 'generate_tts_conf'
  local conf="$XDG_CONFIG_HOME/hypr/tts.conf" lua="$XDG_CONFIG_HOME/hypr/tts.lua"
  assert_eq 8 "$(grep -c '^bind = ' "$conf")" "eight binds in tts.conf"
  assert_contains "$(cat "$conf")" "bind = SUPER ALT, A, exec, hyprland-tts speak   # @tts:speak (Speak selection)" "speak line"
  assert_contains "$(cat "$conf")" "bind = SUPER CTRL ALT, right, exec, hyprland-tts ctl next   # @tts:next (Next sentence)" "next line"
  assert_eq 8 "$(grep -c '^hl.bind(' "$lua")" "eight binds in tts.lua"
  assert_contains "$(cat "$lua")" 'hl.bind("SUPER + ALT + A", hl.dsp.exec_cmd("hyprland-tts speak"), { description = "@tts:speak (Speak selection)" })' "lua speak line"
  assert_contains "$(cat "$lua")" 'hl.bind("SUPER + CTRL + ALT + space", hl.dsp.exec_cmd("hyprland-tts ctl toggle")' "lua toggle line"
}

# case_list_formats — plain and porcelain listings show the effective keys.
# Args:    none
# Returns: 0 always
# Globals: none
case_list_formats() {
  test_set_config "KEY_stop=SUPER\\,\\ Q"
  local plain porcelain
  plain="$(htts keybind list)"
  porcelain="$(htts keybind list --porcelain)"
  assert_eq 8 "$(printf '%s\n' "$plain" | wc -l)" "eight rows"
  assert_contains "$plain" "  stop      Stop speech        SUPER, Q" "plain row with override"
  assert_contains "$plain" "  speak     Speak selection    SUPER ALT, A" "plain row with default"
  assert_eq "speak	Speak selection	SUPER ALT, A" "$(printf '%s\n' "$porcelain" | head -n1)" "porcelain first row"
  assert_contains "$porcelain" "stop	Stop speech	SUPER, Q" "porcelain override"
  assert_eq 8 "$(printf '%s\n' "$porcelain" | wc -l)" "eight porcelain rows"
}

# case_list_self_heals_stale_conf — a hand-edited tts.conf is regenerated and Hyprland reloaded once.
# Args:    none
# Returns: 0 always
# Globals: none
case_list_self_heals_stale_conf() {
  fake_hyprctl '[]'
  htts keybind list >/dev/null 2>&1
  : > "$FAKE_HYPRCTL_LOG"
  sed -i 's/^bind = SUPER ALT, A,/bind = SUPER, Q,/' "$XDG_CONFIG_HOME/hypr/tts.conf"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/tts.conf")" "bind = SUPER, Q," "drift planted"
  htts keybind list >/dev/null 2>&1
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/tts.conf")" "bind = SUPER ALT, A, exec" "stale bind regenerated"
  assert_eq 1 "$(grep -c '^hyprctl reload' "$FAKE_HYPRCTL_LOG")" "reloaded because content changed"
  htts keybind list >/dev/null 2>&1
  assert_eq 1 "$(grep -c '^hyprctl reload' "$FAKE_HYPRCTL_LOG")" "no reload when nothing changed"
}

# case_set_persists_and_regenerates — set stores the override, rewrites both files, reloads.
# Args:    none
# Returns: 0 always
# Globals: none
case_set_persists_and_regenerates() {
  fake_hyprctl '[]'
  local out
  out="$(htts keybind set speak "SUPER, B" 2>&1)"
  assert_rc 0 "$?" "set accepted"
  assert_contains "$out" "Bound 'speak' to: SUPER, B" "confirmation"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" 'KEY_speak=SUPER\,\ B' "override stored"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/tts.conf")" "bind = SUPER, B, exec, hyprland-tts speak" "tts.conf updated"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/tts.lua")" 'hl.bind("SUPER + B", hl.dsp.exec_cmd("hyprland-tts speak")' "tts.lua updated"
  assert_contains "$(cat "$FAKE_HYPRCTL_LOG")" "hyprctl reload" "Hyprland reloaded"
  htts keybind set speak "SUPER, C" >/dev/null 2>&1
  assert_eq 1 "$(grep -c '^KEY_speak=' "$XDG_CONFIG_HOME/piper-tts/config")" "one override line only"
}

# case_set_validation — bad actions, empty keys and characters unsafe for Lua are refused.
# Args:    none
# Returns: 0 always
# Globals: none
case_set_validation() {
  local out
  htts keybind set >/dev/null 2>&1;                       assert_rc 1 "$?" "no arguments"
  out="$(htts keybind set bogus "SUPER, B" 2>&1)";         assert_rc 1 "$?" "unknown action"
  assert_contains "$out" "unknown action: bogus (see 'keybind list')" "message"
  out="$(htts keybind set speak "SUPER," 2>&1)";           assert_rc 1 "$?" "empty key"
  assert_contains "$out" 'combo must be "MODS, KEY"' "empty key message"
  out="$(htts keybind set speak 'SUPER, a"b' 2>&1)";       assert_rc 1 "$?" "double quote refused"
  assert_contains "$out" "combo contains characters not allowed" "quote message"
  htts keybind set speak 'SUPER, a\b' >/dev/null 2>&1;     assert_rc 1 "$?" "backslash refused"
  htts keybind set speak "SUPER, $(printf 'a\tb')" >/dev/null 2>&1; assert_rc 1 "$?" "control char refused"
  assert_no_file "$XDG_CONFIG_HOME/piper-tts/config" "nothing persisted"
}

# case_conflict_detection — a foreign bind on the same modmask+key blocks `set` unless --force.
# Args:    none
# Returns: 0 always
# Globals: none
case_conflict_detection() {
  fake_hyprctl "[$(bind_json 64 B exec firefox), $(bind_json 72 b exec foot), $(bind_json 64 C exec "hyprland-tts speak"), $(bind_json 64 D __lua 12 '@tts:next (Next sentence)'), $(bind_json 4 B exec other)]"
  local out
  out="$(htts keybind set speak "SUPER, B" 2>&1)"
  assert_rc 1 "$?" "conflict blocks set"
  assert_contains "$out" "combo already in use:" "conflict headline"
  assert_contains "$out" "64 B -> exec firefox" "conflicting bind listed"
  assert_contains "$out" "use --force to bind anyway" "force hint"
  assert_not_contains "$out" "foot" "other modmask not reported"
  assert_no_file "$XDG_CONFIG_HOME/piper-tts/config" "nothing persisted on conflict"
  htts keybind set speak "SUPER, B" --force >/dev/null 2>&1
  assert_rc 0 "$?" "--force overrides"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" 'KEY_speak=SUPER\,\ B' "forced bind stored"
  assert_eq "" "$(htts keybind check "SUPER, C")" "own legacy bind is not a conflict"
  assert_eq "" "$(htts keybind check "SUPER, D")" "own Lua bind is not a conflict"
  assert_eq "" "$(htts keybind check "SUPER, Z")" "free combo reports nothing"
  assert_eq "64 B -> exec firefox" "$(htts keybind check "SUPER, b")" "key compared case-insensitively"
  assert_eq "4 B -> exec other" "$(htts keybind check "CTRL, B")" "ctrl modmask"
  # Lua binds only carry a numeric id, so the description must name them.
  fake_hyprctl "[$(bind_json 64 A __lua 70 'Select all')]"
  assert_eq "64 A -> __lua 70 (Select all)" "$(htts keybind check "SUPER, A")" "description shown"
}

# case_defaults_avoid_omarchy_binds — no default shortcut takes a key Omarchy binds itself.
# Args:    none
# Returns: 0 always
# Globals: reads tests/data/omarchy-default-binds.txt
# Notes:   An add-on must not bend the desktop (Agent.md §5); SUPER+A was Omarchy's "Select all".
case_defaults_avoid_omarchy_binds() {
  local snapshot taken
  snapshot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/data/omarchy-default-binds.txt"
  assert_file "$snapshot" "omarchy snapshot present"
  # The snapshot must still catch the old collision, else an empty or broken file would pass.
  assert_contains "$(cat "$snapshot")" "64 A  # Select all" "snapshot knows Select all"
  taken="$(lib_eval '
    for action in "${ACTION_ORDER[@]}"; do
      _split_combo "${ACTION_DEFAULT_KEY[$action]}"
      mask="$(_mods_to_mask "$_KB_MODS")"
      grep -i -m1 "^$mask ${_KB_KEY} " "'"$snapshot"'" | sed "s/^/$action: /"
    done')"
  assert_eq "" "$taken" "no default collides with an Omarchy bind"
}

# case_check_without_hyprctl_and_usage — no hyprctl means no conflicts; check needs an argument.
# Args:    none
# Returns: 0 always
# Globals: none
case_check_without_hyprctl_and_usage() {
  assert_eq "" "$(lib_eval 'PATH=/usr/bin:/bin; have hyprctl && exit 3; keybind_conflicts "SUPER, B"')" "no hyprctl"
  local out; out="$(htts keybind check 2>&1)"
  assert_rc 1 "$?" "check without combo"
  assert_contains "$out" 'usage: hyprland-tts keybind check "MODS, KEY"' "usage text"
}

# case_reset — one action or all overrides go back to the defaults.
# Args:    none
# Returns: 0 always
# Globals: none
case_reset() {
  fake_hyprctl '[]'
  htts keybind set speak "SUPER, B" >/dev/null 2>&1
  htts keybind set stop "SUPER, Q" >/dev/null 2>&1
  local out; out="$(htts keybind reset speak 2>&1)"
  assert_contains "$out" "Reset 'speak' to default" "confirmation"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "KEY_speak" "speak override gone"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "KEY_stop" "stop override kept"
  assert_contains "$(cat "$XDG_CONFIG_HOME/hypr/tts.conf")" "bind = SUPER ALT, A, exec, hyprland-tts speak" "tts.conf regenerated"
  out="$(htts keybind reset 2>&1)"
  assert_contains "$out" "Reset all keybinds to defaults" "reset all message"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "KEY_stop" "all overrides gone"
  htts keybind reset bogus >/dev/null 2>&1
  assert_rc 1 "$?" "unknown action refused"
  htts keybind bogus >/dev/null 2>&1
  assert_rc 1 "$?" "unknown subcommand refused"
}

test_run_cases
