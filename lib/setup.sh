#!/usr/bin/env bash
# lib/setup.sh — per-user Hyprland wiring (idempotent). Never run from the PKGBUILD.
# `setup` links the generated key files into the user's Hyprland config; `uninstall` removes the
# links; `purge` additionally deletes every piece of data the tool created (see Agent.md).

SOURCE_LINE="source = ~/.config/hypr/tts.conf"
SOURCE_MARK="# hyprland-tts (Text-to-Speech) module"
# Hyprland 0.55+ uses the Lua config (hyprland.lua) when present; the
# dofile include below is the Lua equivalent of the legacy source line.
LUA_SOURCE_LINE="dofile(\"$TTS_LUA\")"
LUA_SOURCE_MARK="-- hyprland-tts (Text-to-Speech) module"
# Include lines as extended regexes: the Lua form may quote the path ("...tts.lua").
CONF_INCLUDE_PATTERN='^[[:space:]]*source[[:space:]]*=.*tts\.conf[[:space:]]*$'
LUA_INCLUDE_PATTERN='^[[:space:]]*dofile\([^)]*tts\.lua["'"'"']?[[:space:]]*\)'

# setup_link_lua — add the dofile include to hyprland.lua unless it is already there.
# Args:    none
# Returns: 0 when hyprland.lua exists (linked or already linked); 1 when there is no such file
# Globals: reads MAIN_LUA, LUA_SOURCE_MARK, LUA_SOURCE_LINE, LUA_INCLUDE_PATTERN
setup_link_lua() {
  [ -f "$MAIN_LUA" ] || return 1
  # An existing include (ours or hand-written) must not be duplicated.
  if grep -qE "$LUA_INCLUDE_PATTERN" "$MAIN_LUA"; then
    log "hyprland.lua already loads tts.lua — left untouched."
  else
    printf '\n%s\n%s\n' "$LUA_SOURCE_MARK" "$LUA_SOURCE_LINE" >> "$MAIN_LUA"
    # The user sees what changed in their Hyprland config.
    log "Linked tts.lua into hyprland.lua."
  fi
}

# setup_link_conf — add the source line to hyprland.conf unless it is already there.
# Args:    none
# Returns: 0 when hyprland.conf exists (linked or already linked); 1 when there is no such file
# Globals: reads MAIN_CONF, SOURCE_MARK, SOURCE_LINE, CONF_INCLUDE_PATTERN
setup_link_conf() {
  [ -f "$MAIN_CONF" ] || return 1
  # An existing source line (ours or hand-written) must not be duplicated.
  if grep -qE "$CONF_INCLUDE_PATTERN" "$MAIN_CONF"; then
    log "hyprland.conf already sources tts.conf — left untouched."
  else
    printf '\n%s\n%s\n' "$SOURCE_MARK" "$SOURCE_LINE" >> "$MAIN_CONF"
    # The user sees what changed in their Hyprland config.
    log "Linked tts.conf into hyprland.conf."
  fi
}

# setup_print_summary — tell the user the effective shortcuts after a setup run.
# Args:    none
# Returns: 0 always; stderr: the shortcut table
# Globals: reads ACTION_ORDER, ACTION_LABEL
setup_print_summary() {
  local action
  # One block on stderr, so it never mixes into machine-readable stdout.
  {
    echo ""
    echo "hyprland-tts setup complete. Default shortcuts:"
    for action in "${ACTION_ORDER[@]}"; do
      # Labels and keys are aligned in two columns.
      printf '  %-18s %s\n' "${ACTION_LABEL[$action]}" "$(key_for_action "$action")"
    done
    echo "  Manage voices/keys : hyprland-tts gui"
  } >&2
}

# installed_binaries — list every distinct hyprland-tts binary on PATH.
# Args:    none
# Returns: 0 always; stdout: resolved paths, first one = the one keybinds run
# Globals: reads PATH
installed_binaries() {
  # /bin and /usr/bin are often one directory, so resolved paths are de-duplicated.
  type -ap hyprland-tts 2>/dev/null | xargs -r -d '\n' readlink -f | awk '!seen[$0]++'
}

# setup_report_other_installs — warn when PATH holds more than one hyprland-tts install.
# Args:    none
# Returns: 0 always; stderr: the installs and how to keep only one
# Globals: none
# Notes:   An older second install ran from keybinds and the menu and rewrote tts.lua with its
#          own defaults (README troubleshooting).
setup_report_other_installs() {
  local installs
  installs="$(installed_binaries || true)"
  # One install (or none on PATH) is the healthy case.
  [ "$(printf '%s\n' "$installs" | grep -c .)" -gt 1 ] || return 0
  log "warning: several hyprland-tts installs on PATH; keybinds and the menu run the first:"
  printf '%s\n' "$installs" | sed 's/^/           /' >&2
  # Both ways out, and the re-run that restores the wiring afterwards.
  log "         Keep one: sudo pacman -R hyprland-tts, or ./uninstall-tts.sh in the checkout;"
  log "         then run 'hyprland-tts setup' again."
}

# hyprland_reload — ask a running Hyprland to re-read its configuration (best effort).
# Args:    none
# Returns: 0 always
# Globals: none
hyprland_reload() {
  # Missing hyprctl or a failing reload (no session) must never fail setup.
  if have hyprctl; then hyprctl reload >/dev/null 2>&1 || true; fi
}

# cmd_setup — generate the key files and link them into the Hyprland configuration.
# Args:    none
# Returns: 0 always
# Globals: reads MAIN_CONF, MAIN_LUA, MODELS_DIR; writes tts.conf and tts.lua
cmd_setup() {
  local linked=0
  # The generated files come first, so the include lines always point at existing files.
  generate_tts_conf
  # Lua config (Hyprland 0.55+) and legacy config are both wired when present.
  if setup_link_lua; then linked=1; fi
  if setup_link_conf; then linked=1; fi
  if [ "$linked" -eq 0 ]; then
    # Without a main config the key files still exist for manual inclusion.
    log "warning: no hyprland.conf/hyprland.lua found; wrote $TTS_CONF + $TTS_LUA standalone."
  fi
  hyprland_reload
  setup_print_summary
  # The reload made every bind live, so clashes with the desktop's own keys are visible now.
  keybind_report_conflicts
  # A second install would undo this setup the next time it runs.
  setup_report_other_installs
  # Without any Piper model the user still has no voice (unless the Qwen3 engine is installed).
  if [ -z "$(find "$MODELS_DIR" -type f -name '*.onnx' 2>/dev/null | head -n1)" ]; then
    log ""
    log "No voice models yet. Install one, e.g.:  hyprland-tts model install en-ryan-high"
  fi
}

# setup_strip_link — remove our marker comment and include line from one config file.
# Args:    $1 <config file>; $2 <marker text>; $3 <include line regex (extended, no '#')>
# Returns: 0 always
# Globals: none
# Notes:   Fixed-string grep for the marker, '#' as sed delimiter (patterns never contain it).
setup_strip_link() {
  local file="$1" temp_file="${1}.ttstmp" status=0
  [ -f "$file" ] || return 0
  # -e: the Lua marker starts with dashes and would be read as an option.
  grep -vF -e "$2" "$file" > "$temp_file" 2>/dev/null || status=$?
  # grep exits 1 when nothing is left (fine); only a status above 1 is a real error.
  if [ "$status" -le 1 ]; then mv -f "$temp_file" "$file"; else rm -f "$temp_file"; fi
  sed -i -E "\\#$3#d" "$file" 2>/dev/null || true
}

# remove_source_link — remove the tts include from hyprland.conf and hyprland.lua.
# Args:    none
# Returns: 0 always
# Globals: reads MAIN_CONF, MAIN_LUA and the marker/pattern constants
remove_source_link() {
  setup_strip_link "$MAIN_CONF" "$SOURCE_MARK" "$CONF_INCLUDE_PATTERN"
  setup_strip_link "$MAIN_LUA" "$LUA_SOURCE_MARK" "$LUA_INCLUDE_PATTERN"
}

# setup_remove_generated — delete one generated key file and say so.
# Args:    $1 <file path>
# Returns: 0 always
# Globals: none
setup_remove_generated() {
  # Nothing to report for a file that was never generated.
  if [ -f "$1" ]; then
    rm -f "$1"
    log "Removed $1"
  fi
}

# cmd_uninstall — stop playback and the worker, remove the key files and the include lines.
# Args:    none
# Returns: 0 always
# Globals: reads TTS_CONF, TTS_LUA, MODELS_DIR
cmd_uninstall() {
  # No player and no warm engine may keep running after the tool is unwired.
  cmd_stop 2>/dev/null || true
  worker_stop
  setup_remove_generated "$TTS_CONF"
  # The Lua key file goes the same way.
  setup_remove_generated "$TTS_LUA"
  remove_source_link
  log "Removed tts.conf/tts.lua source links from hyprland.conf and hyprland.lua (if present)."
  # A running Hyprland picks up the removed binds at once.
  hyprland_reload
  log "Downloaded voice models kept at $MODELS_DIR (use 'hyprland-tts purge' to remove them)."
}

# purge_remove_dir — delete a directory tree and report it.
# Args:    $1 <directory>; $2 <label for the message, e.g. "models">
# Returns: 0 always
# Globals: none
purge_remove_dir() {
  # Only existing directories are reported; the path always comes from our own constants.
  if [ -d "$1" ]; then
    rm -rf -- "${1:?}"
    log "Removed $2: $1"
  fi
}

# purge_wants_voices_removed — decide whether the user's own cloned voices are deleted.
# Args:    $1 <--keep-voices | --yes | empty>
# Returns: 0 to delete them; 1 to keep them
# Globals: reads USER_VOICES_DIR
# Notes:   Recordings are irreplaceable: a terminal gets a question, scripts get the flags.
purge_wants_voices_removed() {
  local answer
  [ -d "$USER_VOICES_DIR" ] || return 1
  # An explicit flag always decides.
  [ "$1" != "--keep-voices" ] || return 1
  [ "$1" != "--yes" ] || return 0
  # Interactive use gets a question; without a terminal the purge is the explicit request.
  [ -t 0 ] || return 0
  read -rp "Also delete the voices you added ($USER_VOICES_DIR)? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# purge_engine_data — remove the engines, helper venv, language model and (asked) user voices.
# Args:    $1 <--keep-voices | --yes | empty>
# Returns: 0 always
# Globals: reads HTTS_DATA_DIR, USER_VOICES_DIR
purge_engine_data() {
  local part
  for part in engines venv langid; do
    # Large, re-creatable data first.
    purge_remove_dir "$HTTS_DATA_DIR/$part" "engine data"
  done
  if purge_wants_voices_removed "$1"; then
    purge_remove_dir "$USER_VOICES_DIR" "cloned voices"
  # Tell the user that the recordings survive.
  elif [ -d "$USER_VOICES_DIR" ]; then
    log "Kept your cloned voices in $USER_VOICES_DIR"
  fi
  # The data directory itself goes only when nothing is left in it.
  rmdir "$HTTS_DATA_DIR" 2>/dev/null || true
}

# cmd_purge — uninstall, then delete models, state, config, engine data, caches and runtime files.
# Args:    $1 <optional --yes (no questions) | --keep-voices>
# Returns: 0 always
# Globals: reads MODELS_DIR, STATE_DIR, HTTS_STATE_DIR, CONFIG_DIR, HTTS_CACHE_DIR, RUN_DIR,
#          WORKER_DIR
cmd_purge() {
  # Uninstall also stops the player and the warm worker before their files disappear.
  cmd_uninstall
  purge_remove_dir "$MODELS_DIR" "models"
  purge_remove_dir "$STATE_DIR" "state"
  # The learned loudness gains of streamed sentences are state too.
  purge_remove_dir "$HTTS_STATE_DIR" "learned loudness"
  # The settings go last, after everything that read them.
  purge_remove_dir "$CONFIG_DIR" "config"
  purge_engine_data "${1:-}"
  purge_remove_dir "$HTTS_CACHE_DIR" "cache"
  # Runtime files may hold the last spoken text and audio.
  purge_remove_dir "$RUN_DIR" "runtime files"
  purge_remove_dir "$WORKER_DIR" "worker files"
}
