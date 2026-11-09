#!/usr/bin/env bash
# lib/engine.sh — speech engine abstraction: ENGINE=auto|qwen3|piper picks the backend,
# engine_render turns one "<lang>, <text>" chunk into a WAV, and `hyprland-tts engine`
# manages installation and the warm worker. Piper stays as the light fallback.

# Set to 1 once the Qwen3 worker proved unusable in this run, so later chunks skip it.
ENGINE_QWEN3_DISABLED=0

# engine_selected — print the engine the user asked for.
# Args:    none
# Returns: 0 always; stdout: auto | qwen3 | piper
# Globals: reads ENGINE
engine_selected() {
  # Anything unrecognised in a hand-edited config behaves like the default.
  case "$ENGINE" in
    qwen3|piper) printf '%s' "$ENGINE" ;;
    *) printf 'auto' ;;
  esac
}

# engine_active — print the engine that will actually speak.
# Args:    none
# Returns: 0 always; stdout: qwen3 | piper
# Globals: reads ENGINE, QWEN_VARIANT, ENGINES_DIR
engine_active() {
  # Piper is always selectable; Qwen3 only when usable, whatever was requested.
  if [ "$(engine_selected)" != "piper" ] && qwen3_usable; then
    printf 'qwen3'
  else
    printf 'piper'
  fi
}

# piper_languages — list the languages with at least one installed Piper voice.
# Args:    none
# Returns: 0 always; stdout: comma-separated language codes (empty when none)
# Globals: reads MODELS_DIR
piper_languages() {
  local languages
  # Models live in <lang>/<name>.onnx, so the parent directory name is the language.
  languages="$(find "$MODELS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.onnx' \
    -printf '%h\n' 2>/dev/null | xargs -r -n1 basename | LC_ALL=C sort -u | paste -sd, - || true)"
  printf '%s' "$languages"
}

# engine_languages — list the languages the active engine can speak.
# Args:    none
# Returns: 0 always; stdout: comma-separated language codes
# Globals: reads ENGINE, MODELS_DIR
engine_languages() {
  # The router restricts language detection to this set.
  if [ "$(engine_active)" = "qwen3" ]; then qwen3_languages; else piper_languages; fi
}

# engine_prepare — make the active engine ready to render (starts the worker for Qwen3).
# Args:    none
# Returns: 0 when ready; 1 when the Qwen3 worker cannot start (Piper then takes over)
# Globals: reads ENGINE; writes ENGINE_QWEN3_DISABLED
engine_prepare() {
  # Piper needs no preparation: every chunk is a one-shot process.
  [ "$(engine_active)" = "qwen3" ] || return 0
  worker_ensure && return 0
  # Remember the failure so the per-chunk path does not retry a 30 s start every sentence.
  ENGINE_QWEN3_DISABLED=1
  return 1
}

# engine_warm — start the Qwen3 worker in the background so loading overlaps text preparation.
# Args:    none
# Returns: 0 always
# Globals: reads ENGINE
engine_warm() {
  # No wait here: engine_prepare blocks later, when the first chunk is actually needed.
  [ "$(engine_active)" = "qwen3" ] && worker_kick
  return 0
}

# engine_notify_once — show a desktop notification at most once per player run.
# Args:    $1 <marker name>; $2 <title>; $3 <message>
# Returns: 0 always
# Globals: reads RUN_DIR
engine_notify_once() {
  # RUN_DIR is recreated on every speak, so the marker naturally resets per document.
  [ -d "$RUN_DIR" ] || return 0
  [ ! -e "$RUN_DIR/notified.$1" ] || return 0
  : > "$RUN_DIR/notified.$1"
  # The user sees a desktop notification only after the marker is in place.
  notify "$2" "$3"
}

# piper_render — synthesize a chunk with Piper using the voice for its language.
# Args:    $1 <language code>; $2 <text>; $3 <output wav>
# Returns: 0 when a non-empty WAV was written; 1 otherwise
# Globals: reads PIPER_BIN
piper_render() {
  local model
  # The router knows the voice fallback chain (language, fallback voice, last-used, any).
  model="$(piper_model_for_lang "$1")" || return 1
  have "$PIPER_BIN" || return 1
  # Piper reads the text on stdin; the output file must be non-empty to count.
  printf '%s' "$2" | "$PIPER_BIN" --model "$model" --output_file "$3" >/dev/null 2>&1 &&
    [ -s "$3" ] || return 1
  # Keep the router's "last used voice" fallback working now that voices are chosen per chunk.
  ! declare -F remember_model >/dev/null || remember_model "$model"
}

# qwen3_render_retrying — render via Qwen3, restarting a vanished worker once.
# Args:    $1 <language code>; $2 <text>; $3 <output wav>
# Returns: 0 on success; 1 when this chunk must fall back to Piper
# Globals: writes ENGINE_QWEN3_DISABLED
qwen3_render_retrying() {
  local status=0
  qwen3_render "$@" || status=$?
  # A zero status is the normal case and needs no recovery.
  [ "$status" -eq 0 ] && return 0
  # Status 1 is a per-chunk problem (bad text, no voice); only 2 means the worker is gone.
  [ "$status" -eq 2 ] || return 1
  # One restart attempt; if that fails too, stop trying Qwen3 for the rest of this run.
  if worker_ensure; then qwen3_render "$@"; return; fi
  ENGINE_QWEN3_DISABLED=1
  return 1
}

# engine_render — render one chunk into a WAV with the active engine, Piper as safety net.
# Args:    $1 <language code>; $2 <text>; $3 <output wav path>
# Returns: 0 when a WAV was written; 1 when no engine could render it
# Globals: reads ENGINE_QWEN3_DISABLED, RUN_DIR
engine_render() {
  # Try Qwen3 first when it is active and has not been written off in this run.
  if [ "$(engine_active)" = "qwen3" ] && [ "$ENGINE_QWEN3_DISABLED" -eq 0 ]; then
    qwen3_render_retrying "$1" "$2" "$3" && return 0
  fi
  # Reaching here with qwen3 active means a failure: tell the user once, then use Piper.
  if [ "$(engine_active)" = "qwen3" ]; then
    engine_notify_once qwen3 "hyprland-tts: Qwen3 unavailable" "Falling back to Piper voices."
  fi
  piper_render "$1" "$2" "$3"
}

# command_engine_status — implement `engine status`.
# Args:    none
# Returns: 0 always
# Globals: reads ENGINE, QWEN_VARIANT, WORKER_DIR, MODELS_DIR
command_engine_status() {
  printf 'selected: %s\nactive:   %s\n' "$(engine_selected)" "$(engine_active)"
  # Installed means usable for the current variant; show the path when present.
  if qwen3_usable; then
    printf 'qwen3:    installed (%s, device %s) at %s\n' "$QWEN_VARIANT" "$(qwen3_device)" \
      "$(qwen3_engine_dir)"
  # Installed but silent: only the Base variant without any cloned voice gets here.
  elif qwen3_installed; then
    printf 'qwen3:    installed but unusable: variant base has no cloned voice (voice add ...)\n'
  else
    printf 'qwen3:    not installed for variant %s (hyprland-tts engine install qwen3)\n' \
      "$QWEN_VARIANT"
  fi
  # Worker state is always shown, since it explains where the 1 GB of RAM went.
  printf 'worker:   %s\n' "$(worker_status_line)"
  # An empty language list is spelled out so the line is never blank.
  printf 'piper:    %s\n' "$(piper_languages | grep . || printf 'no voices installed')"
}

# command_engine_use — implement `engine use auto|qwen3|piper`.
# Args:    $1 <engine name>
# Returns: 0 on success; exits 1 via die on an invalid name
# Globals: writes ENGINE in the config file
command_engine_use() {
  # Only the three documented values may land in the sourced config file.
  case "${1:-}" in
    auto|qwen3|piper) ;;
    *) die "usage: hyprland-tts engine use auto|qwen3|piper" ;;
  esac
  # Persist the choice so every later speak and the GUI see it.
  set_config_var ENGINE "$1"
  log "Engine set to $1"
  # Selecting qwen3 without the install would silently use Piper, so say so now.
  if [ "$1" = "qwen3" ] && ! qwen3_installed; then
    log "note: qwen3 is not installed yet; Piper is used until: hyprland-tts engine install qwen3"
  fi
  return 0
}

# command_engine_start — implement `engine start`: warm the worker now.
# Args:    none
# Returns: 0 when serving; exits 1 via die when the engine is missing or fails
# Globals: reads ENGINES_DIR
command_engine_start() {
  qwen3_installed || die "qwen3 is not installed: hyprland-tts engine install qwen3"
  worker_ensure || die "worker failed to start; see $(worker_file server.log)"
  # Report the live worker so the user sees the port and idle limit.
  log "Worker running: $(worker_status_line)"
}

# cmd_engine — dispatch the `engine` subcommands.
# Args:    $1 <status|install|remove|use|start|stop>; $2.. <subcommand arguments>
# Returns: 0 on success; exits 1 via die on an unknown subcommand
# Globals: reads the config file via load_config
cmd_engine() {
  local sub="${1:-status}"
  load_config
  # Drop the subcommand name so only its own arguments remain in "$@".
  shift || true
  # Each arm only forwards; the work lives in command_engine_<name>.
  case "$sub" in
    status)  command_engine_status ;;
    install) command_engine_install "$@" ;;
    # Removal also stops the worker before deleting files.
    remove)  command_engine_remove "$@" ;;
    use)     command_engine_use "$@" ;;
    start)   command_engine_start ;;
    # Stopping needs no engine files, so it also works after a remove.
    stop)    worker_stop; log "Worker stopped" ;;
    *) die "unknown engine subcommand: $sub (status|install|remove|use|start|stop)" ;;
  esac
}
