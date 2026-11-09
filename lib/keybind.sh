#!/usr/bin/env bash
# lib/keybind.sh — data-driven keybinds + conflict detection.
#
# Binds are generated from the ACTION_* tables (lib/common.sh) plus user overrides KEY_<action>
# in the config file. Rebinding is therefore safe and scriptable: change one config variable,
# regenerate tts.conf, reload. The GUI drives exactly these subcommands.
# A combo is written Hyprland-style: "MODS, KEY", e.g. "SUPER ALT, right".

# Split-combo results (set by _split_combo): the modifier words and the key.
_KB_MODS=""
_KB_KEY=""

# _mod_bit — print the Hyprland modmask bit of one modifier name.
# Args:    $1 <modifier name, any case, e.g. SUPER>
# Returns: 0 always; stdout: the bit value (0 for unknown names)
# Globals: none
_mod_bit() {
  # The bit values follow the xkb order that `hyprctl binds -j` reports.
  case "${1^^}" in
    SHIFT) echo 1 ;;
    CAPS) echo 2 ;;
    # Ctrl has two spellings in Hyprland configs.
    CTRL|CONTROL) echo 4 ;;
    ALT|MOD1) echo 8 ;;
    MOD2) echo 16 ;;
    # The remaining modifier bits follow the same doubling.
    MOD3) echo 32 ;;
    SUPER|LOGO|MOD4|WIN) echo 64 ;;
    MOD5) echo 128 ;;
    # Unknown names count as no modifier.
    *) echo 0 ;;
  esac
}

# _mods_to_mask — sum the modmask bits of a list of modifier names.
# Args:    $1 <modifier names separated by blanks, e.g. "SUPER ALT">
# Returns: 0 always; stdout: the summed mask
# Globals: none
_mods_to_mask() {
  local mask=0 modifier
  # Word splitting is intended: the argument is a blank-separated list.
  for modifier in $1; do
    mask=$((mask + $(_mod_bit "$modifier")))
  done
  echo "$mask"
}

# _split_combo — split "MODS, KEY" into _KB_MODS and _KB_KEY.
# Args:    $1 <combo>
# Returns: 0 always
# Globals: writes _KB_MODS, _KB_KEY
_split_combo() {
  local combo="$1"
  # The key is everything after the last comma, trimmed of one blank on each side.
  _KB_KEY="${combo##*,}"
  _KB_KEY="${_KB_KEY## }"
  _KB_KEY="${_KB_KEY%% }"
  # Without a comma there are no modifiers at all.
  _KB_MODS="${combo%,*}"
  [ "$_KB_MODS" != "$combo" ] || _KB_MODS=""
  _KB_MODS="$(printf '%s' "$_KB_MODS" | sed -E 's/^ +| +$//g')"
}

# keybind_conf_header — print the comment banner of the generated tts.conf.
# Args:    none
# Returns: 0 always
# Globals: none
keybind_conf_header() {
  cat <<'TEXT'
# ============================================================================
# hyprland-tts — Text-to-Speech keybinds (generated; edit via 'hyprland-tts
# keybind set <action> "MODS, KEY"' or the GUI. Manual edits are overwritten
# on the next keybind change.)
# ============================================================================
TEXT
}

# generate_tts_conf — write tts.conf (and tts.lua) from the action table and user overrides.
# Args:    none
# Returns: 0 always
# Globals: reads ACTION_*; writes TTS_CONF, TTS_LUA
generate_tts_conf() {
  local action
  load_config
  # The Hyprland config directory may not exist on a fresh system.
  mkdir -p "$HYPR_DIR"
  # The braces send banner and bind lines through a single redirection.
  {
    keybind_conf_header
    for action in "${ACTION_ORDER[@]}"; do
      printf 'bind = %s, exec, hyprland-tts %s   # @tts:%s (%s)\n' \
        "$(key_for_action "$action")" "${ACTION_CMD[$action]}" "$action" "${ACTION_LABEL[$action]}"
    done
  } > "$TTS_CONF"
  generate_tts_lua
}

# _combo_to_lua_key — turn "MODS, KEY" into the "MODS + KEY" form of Hyprland's Lua config.
# Args:    $1 <combo>
# Returns: 0 always; stdout: the key string (just the key when there are no modifiers)
# Globals: writes _KB_MODS, _KB_KEY
_combo_to_lua_key() {
  local mods key
  _split_combo "$1"
  # Copied out before the next call overwrites the shared split result.
  key="$_KB_KEY"
  # Every modifier and the key are joined with " + ".
  mods="$(printf '%s' "$_KB_MODS" | sed 's/ / + /g')"
  if [ -n "$mods" ]; then
    printf '%s + %s\n' "$mods" "$key"
  else
    # Without modifiers the key stands alone.
    printf '%s\n' "$key"
  fi
}

# _lua_string_escape — escape a value for a Lua double-quoted string.
# Args:    $1 <raw value>
# Returns: 0 always; stdout: the escaped value
# Globals: none
# Notes:   A hand-edited KEY_<action> must never turn tts.lua into invalid Lua.
_lua_string_escape() {
  # Backslashes first, then quotes; the worst case is one rejected keysym, not a broken file.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# keybind_lua_header — print the comment banner of the generated tts.lua.
# Args:    none
# Returns: 0 always
# Globals: none
keybind_lua_header() {
  cat <<'TEXT'
-- ============================================================================
-- hyprland-tts — Text-to-Speech keybinds for Hyprland's Lua config (generated;
-- edit via 'hyprland-tts keybind set <action> "MODS, KEY"' or the GUI. Manual
-- edits are overwritten on the next keybind change.)
-- ============================================================================
TEXT
}

# keybind_lua_line — print the hl.bind line of one action.
# Args:    $1 <action name>
# Returns: 0 always
# Globals: reads ACTION_CMD, ACTION_LABEL
keybind_lua_line() {
  local key
  key="$(_lua_string_escape "$(_combo_to_lua_key "$(key_for_action "$1")")")"
  # The "@tts:<action>" description marks our binds for keybind_conflicts.
  printf 'hl.bind("%s", hl.dsp.exec_cmd("hyprland-tts %s"), { description = "@tts:%s (%s)" })\n' \
    "$key" "${ACTION_CMD[$1]}" "$1" "${ACTION_LABEL[$1]}"
}

# generate_tts_lua — write tts.lua, the Lua counterpart of tts.conf (Hyprland 0.55+).
# Args:    none
# Returns: 0 always
# Globals: reads ACTION_ORDER; writes TTS_LUA
# Notes:   Lua dispatchers expose a numeric id as arg, so our binds carry the @tts marker instead.
generate_tts_lua() {
  local action
  load_config
  # The Hyprland config directory may not exist on a fresh system.
  mkdir -p "$HYPR_DIR"
  {
    keybind_lua_header
    for action in "${ACTION_ORDER[@]}"; do
      # One hl.bind line per action.
      keybind_lua_line "$action"
    done
  } > "$TTS_LUA"
}

# keybind_awk_program — print the awk program that lists foreign binds on one modmask and key.
# Args:    none
# Returns: 0 always; stdout: the awk source
# Globals: none
keybind_awk_program() {
  cat <<'AWK'
function grab(record, pattern, strip,   value) {
  value = ""
  if (match(record, pattern)) {
    value = substr(record, RSTART, RLENGTH)
    sub(strip, "", value)
    sub(/"$/, "", value)
  }
  return value
}
/"modmask"/ {
  m = grab($0, "\"modmask\": *[0-9]+", ".*: *")
  k = grab($0, "\"key\": *\"[^\"]*\"", ".*\"key\": *\"")
  d = grab($0, "\"dispatcher\": *\"[^\"]*\"", ".*: *\"")
  a = grab($0, "\"arg\": *\"[^\"]*\"", ".*: *\"")
  desc = grab($0, "\"description\": *\"[^\"]*\"", ".*: *\"")
  # Our own binds are skipped: legacy exec binds name the command in arg, Lua binds carry the
  # "@tts:<action>" marker in description (their arg is a numeric id).
  if (m == mask && tolower(k) == tolower(key) && a !~ /hyprland-tts/ && desc !~ /@tts:/)
    printf "%s %s -> %s %s\n", m, k, d, a
}
AWK
}

# keybind_conflicts — list currently active foreign Hyprland binds on a combo.
# Args:    $1 <combo, e.g. "SUPER, B">
# Returns: 0 always; stdout: "MODMASK KEY -> dispatcher arg" lines (empty = free)
# Globals: writes _KB_MODS, _KB_KEY
keybind_conflicts() {
  local mask key
  _split_combo "$1"
  # Hyprland reports modifiers as a summed mask, so compare in that form.
  mask="$(_mods_to_mask "$_KB_MODS")"
  key="$_KB_KEY"
  # Without hyprctl there is nothing to compare against.
  have hyprctl || return 0
  # Records are split at "}" so each bind object is one awk record.
  hyprctl binds -j 2>/dev/null |
    awk -v RS='}' -v mask="$mask" -v key="$key" -f <(keybind_awk_program)
}

# keybind_refresh_files — regenerate tts.conf/tts.lua and reload Hyprland only if they changed.
# Args:    none
# Returns: 0 always
# Globals: reads TTS_CONF, TTS_LUA
# Notes:   Self-heals a tts.conf edited by hand (Agent.md §3: `keybind list` used to report lies).
keybind_refresh_files() {
  local before after
  before="$(cat "$TTS_CONF" "$TTS_LUA" 2>/dev/null || true)"
  # Regenerating from the config is what heals a stale file.
  generate_tts_conf
  after="$(cat "$TTS_CONF" "$TTS_LUA" 2>/dev/null || true)"
  # A reload on every call would flicker; only a real change needs one.
  if [ "$before" != "$after" ]; then hyprland_reload; fi
}

# command_keybind_list — implement `keybind list [--porcelain]`.
# Args:    $1 <optional --porcelain>
# Returns: 0 always; stdout: one row per action
# Globals: reads ACTION_ORDER, ACTION_LABEL
command_keybind_list() {
  local porcelain=0 action
  # Reporting follows the regeneration, so the output always matches what is live.
  keybind_refresh_files
  [ "${1:-}" != "--porcelain" ] || porcelain=1
  for action in "${ACTION_ORDER[@]}"; do
    # Tab-separated rows for the GUI, aligned columns for people.
    if [ "$porcelain" -eq 1 ]; then
      printf '%s\t%s\t%s\n' "$action" "${ACTION_LABEL[$action]}" "$(key_for_action "$action")"
    else
      printf '  %-9s %-18s %s\n' "$action" "${ACTION_LABEL[$action]}" "$(key_for_action "$action")"
    fi
  done
}

# command_keybind_check — implement `keybind check "MODS, KEY"`.
# Args:    $1 <combo>
# Returns: 0 on success; exits 1 via die without a combo; stdout: conflicts (empty if none)
# Globals: none
command_keybind_check() {
  [ -n "${1:-}" ] || die "usage: hyprland-tts keybind check \"MODS, KEY\""
  keybind_conflicts "$1"
}

# keybind_validate_set_args — check the arguments of `keybind set`, die on any problem.
# Args:    $1 <action>; $2 <combo>
# Returns: 0 when valid; exits 1 via die otherwise
# Globals: writes _KB_MODS, _KB_KEY
keybind_validate_set_args() {
  if [ -z "$1" ] || [ -z "$2" ]; then
    die "usage: hyprland-tts keybind set <action> \"MODS, KEY\" [--force]"
  fi
  # Only known actions can be bound.
  [ -n "${ACTION_CMD[$1]:-}" ] || die "unknown action: $1 (see 'keybind list')"
  _split_combo "$2"
  [ -n "$_KB_KEY" ] || die "combo must be \"MODS, KEY\" (e.g. \"SUPER, B\")"
  # Quotes, backslashes and control characters cannot be in a Hyprland key string and would
  # break out of the generated Lua string.
  case "$2" in
    *\\*|*\"*|*[[:cntrl:]]*)
      die "combo contains characters not allowed in a Hyprland key string: $2" ;;
  esac
}

# command_keybind_set — implement `keybind set <action> "MODS, KEY" [--force]`.
# Args:    $1 <action>; $2 <combo>; $3 <optional --force>
# Returns: 0 on success; exits 1 via die on bad input or a conflict
# Globals: writes KEY_<action> in the config file, tts.conf, tts.lua
command_keybind_set() {
  local action="${1:-}" combo="${2:-}" force="${3:-}" conflict
  keybind_validate_set_args "$action" "$combo"
  # Binding over a foreign shortcut needs an explicit --force.
  if [ "$force" != "--force" ]; then
    conflict="$(keybind_conflicts "$combo")"
    [ -z "$conflict" ] || die "combo already in use:\n$conflict\n(use --force to bind anyway)"
  fi
  # The override is persisted before the files are regenerated from it.
  set_config_var "KEY_${action}" "$combo"
  generate_tts_conf
  hyprland_reload
  # Confirm the new binding to the user.
  log "Bound '$action' to: $combo"
}

# command_keybind_reset — implement `keybind reset [<action>]`.
# Args:    $1 <optional action; all actions when empty>
# Returns: 0 on success; exits 1 via die for an unknown action
# Globals: removes KEY_<action> from the config file; rewrites tts.conf, tts.lua
command_keybind_reset() {
  local action="${1:-}" each
  if [ -n "$action" ]; then
    # A typo must not silently reset nothing.
    [ -n "${ACTION_CMD[$action]:-}" ] || die "unknown action: $action"
    unset_config_var "KEY_${action}"
    log "Reset '$action' to default"
  else
    # Dropping every override restores the defaults.
    for each in "${ACTION_ORDER[@]}"; do unset_config_var "KEY_${each}"; done
    log "Reset all keybinds to defaults"
  fi
  generate_tts_conf
  # The reload makes the new defaults live.
  hyprland_reload
}

# cmd_keybind — dispatch the `keybind` subcommands.
# Args:    $1 <list|check|set|reset>; $2.. <subcommand arguments>
# Returns: 0 on success; exits 1 via die on an unknown subcommand
# Globals: reads the config file via load_config
cmd_keybind() {
  local sub="${1:-list}"
  load_config
  # The subcommand word is consumed; a bare call has nothing to shift.
  shift || true
  case "$sub" in
    list)  command_keybind_list "$@" ;; # show the effective keys (self-healing)
    check) command_keybind_check "$@" ;; # report conflicts for a combo
    set)   command_keybind_set "$@" ;; # rebind one action
    reset) command_keybind_reset "$@" ;; # back to the defaults
    *) die "unknown keybind subcommand: $sub" ;;
  esac
}
