#!/usr/bin/env bash
# lib/setup.sh — per-user Hyprland wiring (idempotent). Never run from PKGBUILD.

SOURCE_LINE="source = ~/.config/hypr/tts.conf"
SOURCE_MARK="# hyprland-tts (Text-to-Speech) module"
# Hyprland 0.55+ uses the Lua config (hyprland.lua) when present; the
# dofile include below is the Lua equivalent of the legacy source line.
LUA_SOURCE_LINE="dofile(\"$TTS_LUA\")"
LUA_SOURCE_MARK="-- hyprland-tts (Text-to-Speech) module"

cmd_setup() {
  generate_tts_conf   # writes ~/.config/hypr/tts.conf + tts.lua from the keybind table
  local linked=0
  if [ -f "$MAIN_LUA" ]; then
    if grep -qE '^[[:space:]]*dofile\([^)]*tts\.lua[[:space:]]*\)' "$MAIN_LUA"; then
      log "hyprland.lua already loads tts.lua — left untouched."
    else
      printf '\n%s\n%s\n' "$LUA_SOURCE_MARK" "$LUA_SOURCE_LINE" >> "$MAIN_LUA"
      log "Linked tts.lua into hyprland.lua."
    fi
    linked=1
  fi
  if [ -f "$MAIN_CONF" ]; then
    if grep -qE '^[[:space:]]*source[[:space:]]*=.*tts\.conf[[:space:]]*$' "$MAIN_CONF"; then
      log "hyprland.conf already sources tts.conf — left untouched."
    else
      printf '\n%s\n%s\n' "$SOURCE_MARK" "$SOURCE_LINE" >> "$MAIN_CONF"
      log "Linked tts.conf into hyprland.conf."
    fi
    linked=1
  fi
  if [ "$linked" -eq 0 ]; then
    log "warning: no hyprland.conf/hyprland.lua found; wrote $TTS_CONF + $TTS_LUA standalone."
  fi
  have hyprctl && hyprctl reload >/dev/null 2>&1 || true

  { echo ""; echo "hyprland-tts setup complete. Default shortcuts:"
    local a; for a in "${ACTION_ORDER[@]}"; do
      printf '  %-18s %s\n' "${ACTION_LABEL[$a]}" "$(key_for_action "$a")"
    done
    echo "  Manage voices/keys : hyprland-tts gui"
  } >&2

  if [ -z "$(find "$MODELS_DIR" -type f -name '*.onnx' 2>/dev/null | head -n1)" ]; then
    log ""; log "No voice models yet. Install one, e.g.:  hyprland-tts model install en-ryan-high"
  fi
}

remove_source_link() {
  if [ -f "$MAIN_CONF" ]; then
    local tmp="${MAIN_CONF}.ttstmp" rc=0
    grep -vF "$SOURCE_MARK" "$MAIN_CONF" > "$tmp" 2>/dev/null || rc=$?
    if [ "$rc" -le 1 ]; then mv -f "$tmp" "$MAIN_CONF"; else rm -f "$tmp"; fi
    sed -i -E '\#^[[:space:]]*source[[:space:]]*=.*tts\.conf[[:space:]]*$#d' "$MAIN_CONF" 2>/dev/null || true
  fi
  if [ -f "$MAIN_LUA" ]; then
    local tmp="${MAIN_LUA}.ttstmp" rc=0
    grep -vF "$LUA_SOURCE_MARK" "$MAIN_LUA" > "$tmp" 2>/dev/null || rc=$?
    if [ "$rc" -le 1 ]; then mv -f "$tmp" "$MAIN_LUA"; else rm -f "$tmp"; fi
    sed -i -E '\#^[[:space:]]*dofile\([^)]*tts\.lua[[:space:]]*\)#d' "$MAIN_LUA" 2>/dev/null || true
  fi
}

cmd_uninstall() {
  cmd_stop 2>/dev/null || true
  [ -f "$TTS_CONF" ] && rm -f "$TTS_CONF" && log "Removed $TTS_CONF"
  [ -f "$TTS_LUA" ] && rm -f "$TTS_LUA" && log "Removed $TTS_LUA"
  remove_source_link
  log "Removed tts.conf/tts.lua source links from hyprland.conf and hyprland.lua (if present)."
  have hyprctl && hyprctl reload >/dev/null 2>&1 || true
  log "Downloaded voice models kept at $MODELS_DIR (use 'hyprland-tts purge' to remove them)."
}

cmd_purge() {
  cmd_uninstall
  [ -d "$MODELS_DIR" ] && rm -rf "$MODELS_DIR" && log "Removed models: $MODELS_DIR"
  [ -d "$STATE_DIR" ]  && rm -rf "$STATE_DIR"  && log "Removed state: $STATE_DIR"
  [ -d "$CONFIG_DIR" ] && rm -rf "$CONFIG_DIR" && log "Removed config: $CONFIG_DIR"
}
