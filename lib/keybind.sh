#!/usr/bin/env bash
# lib/keybind.sh — data-driven keybinds + conflict detection.
#
# Binds are generated from the ACTION_* tables (lib/common.sh) plus user
# overrides KEY_<action> in the config file. This makes rebinding safe and
# scriptable: change one config var, regenerate tts.conf, reload. The GUI drives
# exactly these subcommands.
#
# A combo is written Hyprland-style: "MODS, KEY" e.g. "SUPER ALT, right".

# Hyprland modmask bits (xkb/libinput order used by hyprctl binds -j)
_mod_bit() {
  case "${1^^}" in
    SHIFT) echo 1 ;; CAPS) echo 2 ;; CTRL|CONTROL) echo 4 ;; ALT|MOD1) echo 8 ;;
    MOD2) echo 16 ;; MOD3) echo 32 ;; SUPER|LOGO|MOD4|WIN) echo 64 ;; MOD5) echo 128 ;;
    *) echo 0 ;;
  esac
}
# "SUPER ALT" -> summed modmask
_mods_to_mask() {
  local mask=0 m
  for m in $1; do mask=$((mask + $(_mod_bit "$m"))); done
  echo "$mask"
}

# split "MODS, KEY" into globals _KB_MODS / _KB_KEY
_split_combo() {
  local combo="$1"
  _KB_KEY="${combo##*,}"; _KB_KEY="${_KB_KEY## }"; _KB_KEY="${_KB_KEY%% }"
  _KB_MODS="${combo%,*}"; [ "$_KB_MODS" = "$combo" ] && _KB_MODS=""
  _KB_MODS="$(printf '%s' "$_KB_MODS" | sed -E 's/^ +| +$//g')"
}

generate_tts_conf() {
  load_config
  mkdir -p "$HYPR_DIR"
  {
    echo "# ============================================================================"
    echo "# hyprland-tts — Text-to-Speech keybinds (generated; edit via 'hyprland-tts"
    echo "# keybind set <action> \"MODS, KEY\"' or the GUI. Manual edits are overwritten"
    echo "# on the next keybind change.)"
    echo "# ============================================================================"
    local a
    for a in "${ACTION_ORDER[@]}"; do
      printf 'bind = %s, exec, hyprland-tts %s   # @tts:%s (%s)\n' \
        "$(key_for_action "$a")" "${ACTION_CMD[$a]}" "$a" "${ACTION_LABEL[$a]}"
    done
  } > "$TTS_CONF"
}

# conflicts for a combo against CURRENTLY ACTIVE Hyprland binds (excludes our own
# hyprland-tts binds). Prints "MODMASK KEY -> dispatcher arg" lines; empty = free.
keybind_conflicts() {
  local combo="$1" mask key
  _split_combo "$combo"; mask="$(_mods_to_mask "$_KB_MODS")"; key="$_KB_KEY"
  have hyprctl || return 0
  hyprctl binds -j 2>/dev/null | awk -v RS='}' -v mask="$mask" -v key="$key" '
    /"modmask"/ {
      m=""; k=""; d=""; a=""
      if (match($0, /"modmask": *[0-9]+/))  { m=substr($0,RSTART,RLENGTH); sub(/.*: */,"",m) }
      if (match($0, /"key": *"[^"]*"/))     { k=substr($0,RSTART,RLENGTH); sub(/.*"key": *"/,"",k); sub(/"$/,"",k) }
      if (match($0, /"dispatcher": *"[^"]*"/)) { d=substr($0,RSTART,RLENGTH); sub(/.*: *"/,"",d); sub(/"$/,"",d) }
      if (match($0, /"arg": *"[^"]*"/))     { a=substr($0,RSTART,RLENGTH); sub(/.*: *"/,"",a); sub(/"$/,"",a) }
      if (m==mask && tolower(k)==tolower(key) && a !~ /hyprland-tts/)
        printf "%s %s -> %s %s\n", m, k, d, a
    }'
}

cmd_keybind() {
  load_config
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      local porcelain=0; [ "${1:-}" = "--porcelain" ] && porcelain=1
      local a
      for a in "${ACTION_ORDER[@]}"; do
        if [ "$porcelain" -eq 1 ]; then
          printf '%s\t%s\t%s\n' "$a" "${ACTION_LABEL[$a]}" "$(key_for_action "$a")"
        else
          printf '  %-9s %-18s %s\n' "$a" "${ACTION_LABEL[$a]}" "$(key_for_action "$a")"
        fi
      done ;;
    check)
      # keybind check "MODS, KEY"  -> prints conflicts (empty if none)
      local combo="${1:-}"; [ -n "$combo" ] || die "usage: hyprland-tts keybind check \"MODS, KEY\""
      keybind_conflicts "$combo" ;;
    set)
      # keybind set <action> "MODS, KEY" [--force]
      local action="${1:-}" combo="${2:-}" force="${3:-}"
      [ -n "$action" ] && [ -n "$combo" ] || die "usage: hyprland-tts keybind set <action> \"MODS, KEY\" [--force]"
      [ -n "${ACTION_CMD[$action]:-}" ] || die "unknown action: $action (see 'keybind list')"
      _split_combo "$combo"; [ -n "$_KB_KEY" ] || die "combo must be \"MODS, KEY\" (e.g. \"SUPER, B\")"
      if [ "$force" != "--force" ]; then
        local conflict; conflict="$(keybind_conflicts "$combo")"
        [ -z "$conflict" ] || die "combo already in use:\n$conflict\n(use --force to bind anyway)"
      fi
      set_config_var "KEY_${action}" "$combo"
      generate_tts_conf
      have hyprctl && hyprctl reload >/dev/null 2>&1 || true
      log "Bound '$action' to: $combo" ;;
    reset)
      # reset one action or all to defaults
      local action="${1:-}"
      if [ -n "$action" ]; then
        [ -n "${ACTION_CMD[$action]:-}" ] || die "unknown action: $action"
        unset_config_var "KEY_${action}"; log "Reset '$action' to default"
      else
        local a; for a in "${ACTION_ORDER[@]}"; do unset_config_var "KEY_${a}"; done
        log "Reset all keybinds to defaults"
      fi
      generate_tts_conf
      have hyprctl && hyprctl reload >/dev/null 2>&1 || true ;;
    *) die "unknown keybind subcommand: $sub" ;;
  esac
}
