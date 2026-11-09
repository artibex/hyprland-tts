#!/usr/bin/env bash
# lib/engine.sh — speech engine abstraction: ENGINE=auto|qwen3|piper picks the backend,
# engine_render turns one "<lang>, <text>" chunk into a WAV, and `hyprland-tts engine`
# manages installation and the warm worker. Piper stays as the light fallback.

# Set to 1 once the Qwen3 worker proved unusable in this run, so later chunks skip it.
ENGINE_QWEN3_DISABLED=0
# The subcommands of `engine`, as shown in the error for an unknown one.
ENGINE_SUBCOMMANDS="status|install|remove|use|config|variant|start|stop"
# Consecutive chunks Qwen3 failed on (any reason); two in a row disable it for the run.
ENGINE_QWEN3_FAILURES=0
# Pid of the background "voice is loading" notifier while the worker starts.
ENGINE_LOADING_NOTICE_PID=""

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

# engine_start_loading_notice — notify after two seconds when the worker is still not ready.
# Args:    none
# Returns: 0 always
# Globals: writes ENGINE_LOADING_NOTICE_PID
engine_start_loading_notice() {
  # A warm worker answers at once, so no notice is needed.
  worker_ready && return 0
  # Without feedback a cold model load (several seconds) looks like a dead shortcut.
  ( sleep 2; engine_notify_once loading "hyprland-tts: loading voice" \
    "The neural voice is starting; speech begins in a few seconds." ) &
  ENGINE_LOADING_NOTICE_PID=$!
}

# engine_stop_loading_notice — cancel the pending "voice is loading" notification.
# Args:    none
# Returns: 0 always
# Globals: reads and clears ENGINE_LOADING_NOTICE_PID
engine_stop_loading_notice() {
  [ -n "$ENGINE_LOADING_NOTICE_PID" ] || return 0
  kill "$ENGINE_LOADING_NOTICE_PID" 2>/dev/null || true
  # Reaping the notifier keeps a "Terminated" job message out of the daemon's output.
  wait "$ENGINE_LOADING_NOTICE_PID" 2>/dev/null || true
  ENGINE_LOADING_NOTICE_PID=""
}

# engine_prepare — make the active engine ready to render (starts the worker for Qwen3).
# Args:    none
# Returns: 0 when ready; 1 when the Qwen3 worker cannot start (Piper then takes over)
# Globals: reads ENGINE; writes ENGINE_QWEN3_DISABLED
engine_prepare() {
  local status=0
  # Piper needs no preparation: every chunk is a one-shot process.
  [ "$(engine_active)" = "qwen3" ] || return 0
  engine_start_loading_notice
  worker_ensure || status=1
  # The notice is cancelled whether the start worked or not.
  engine_stop_loading_notice
  [ "$status" -eq 0 ] && return 0
  # Remember the failure so the per-chunk path does not retry a long start for every sentence.
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
  # RUN_DIR is cleared on every speak, so the marker naturally resets per document.
  [ -d "$RUN_DIR" ] || return 0
  [ ! -e "$RUN_DIR/notified.$1" ] || return 0
  # The marker goes first, so two racing callers still notify only once.
  : > "$RUN_DIR/notified.$1"
  notify "$2" "$3"
}

# wav_python — print an interpreter for the stdlib-only WAV helper.
# Args:    none
# Returns: 0 and the path on stdout; 1 when no python3 exists
# Globals: reads HTTS_PYTHON via pyenv_python
wav_python() {
  # The helper needs no packages, so any python3 will do (the helper venv is preferred).
  pyenv_python || command -v python3
}

# wav_finish — check a rendered WAV (silence, runaway) and normalise its loudness in place.
# Args:    $1 <wav path>; $2 <runaway seconds, optional; 0 = no limit>
# Returns: 0 when usable or not checkable; 3 silent; 4 runaway; 5 unreadable
# Globals: reads NORMALIZE_LOUDNESS
wav_finish() {
  local python helper flags=()
  # Without Python the audio is trusted as it is: no check is better than no speech.
  python="$(wav_python)" || return 0
  declare -F py_helpers_dir >/dev/null || return 0
  helper="$(py_helpers_dir)/htts_wav.py"
  # A missing helper file (old install) means no check, not no speech.
  [ -f "$helper" ] || return 0
  [ "${NORMALIZE_LOUDNESS:-1}" = "1" ] || flags+=(--no-normalise)
  # The cache prefix keeps .pyc files out of read-only install directories.
  PYTHONPYCACHEPREFIX="${XDG_CACHE_HOME:-$HOME/.cache}/hyprland-tts/pycache" \
    "$python" "$helper" finish "$1" --runaway-seconds "${2:-0}" "${flags[@]}"
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
  # Same loudness as the neural voices; a failed check must not silence the fallback.
  wav_finish "$3" 0 || true
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

# engine_count_failure — count a failed Qwen3 chunk; two in a row switch it off for this run.
# Args:    none
# Returns: 0 always
# Globals: writes ENGINE_QWEN3_FAILURES, ENGINE_QWEN3_DISABLED
engine_count_failure() {
  ENGINE_QWEN3_FAILURES=$((ENGINE_QWEN3_FAILURES + 1))
  # A timeout (120 s per chunk) must not repeat for every remaining sentence of the document.
  [ "$ENGINE_QWEN3_FAILURES" -lt 2 ] || ENGINE_QWEN3_DISABLED=1
}

# engine_render — render one chunk into a WAV with the active engine, Piper as safety net.
# Args:    $1 <language code>; $2 <text>; $3 <output wav path>
# Returns: 0 when a WAV was written; 1 when no engine could render it
# Globals: reads and writes ENGINE_QWEN3_DISABLED and ENGINE_QWEN3_FAILURES; reads RUN_DIR
engine_render() {
  # Try Qwen3 first when it is active and has not been written off in this run.
  if [ "$(engine_active)" = "qwen3" ] && [ "$ENGINE_QWEN3_DISABLED" -eq 0 ]; then
    if qwen3_render_retrying "$1" "$2" "$3"; then ENGINE_QWEN3_FAILURES=0; return 0; fi
    engine_count_failure
  fi
  # Reaching here with qwen3 active means a failure: tell the user once, then use Piper.
  if [ "$(engine_active)" = "qwen3" ]; then
    engine_notify_once qwen3 "hyprland-tts: Qwen3 unavailable" "Falling back to Piper voices."
  fi
  piper_render "$1" "$2" "$3"
}

# engine_unusable_reason — explain in a few words why Qwen3 is not the active engine.
# Args:    none
# Returns: 0 always; stdout: reason text, empty when Qwen3 is active
# Globals: reads ENGINE, QWEN_VARIANT, ENGINES_DIR
engine_unusable_reason() {
  # Active means nothing to explain.
  [ "$(engine_active)" != "qwen3" ] || return 0
  # An explicit user choice beats everything else.
  [ "$(engine_selected)" != "piper" ] || { printf 'engine set to piper'; return 0; }
  # The server binary exists, so only the selected talker's model file is missing.
  if [ -x "$(qwen3_bin_dir)/tts-server" ]; then
    printf 'variant %s is not installed' "$QWEN_VARIANT"
  else
    printf 'not installed'
  fi
}

# command_engine_status_porcelain — print the engine state as key=value lines for the GUI.
# Args:    none
# Returns: 0 always
# Globals: reads ENGINE, QWEN_VARIANT, WORKER_DIR, MODELS_DIR, WORKER_IDLE_MINUTES
command_engine_status_porcelain() {
  local installed=0 device="" port=""
  # The device is only meaningful for a usable install.
  if qwen3_installed; then installed=1; device="$(qwen3_device)"; fi
  port="$(worker_port || true)"
  # A stale port file of a dead worker must not leak into the answer.
  [ "$(worker_state)" != "stopped" ] || port=""
  printf 'selected=%s\nactive=%s\n' "$(engine_selected)" "$(engine_active)"
  printf 'qwen3_installed=%s\nqwen3_variant=%s\n' "$installed" "$QWEN_VARIANT"
  # Device and reason complete the Qwen3 block of the contract.
  printf 'qwen3_device=%s\nqwen3_reason=%s\n' "$device" "$(engine_unusable_reason)"
  printf 'worker=%s\nworker_port=%s\n' "$(worker_state)" "$port"
  printf 'idle_minutes=%s\npiper_languages=%s\n' "$(worker_idle_minutes)" "$(piper_languages)"
  # The languages the active engine can speak close the status contract.
  printf 'languages=%s\n' "$(engine_languages)"
}

# command_engine_status — implement `engine status [--porcelain]`.
# Args:    $1 <optional --porcelain>
# Returns: 0 always
# Globals: reads ENGINE, QWEN_VARIANT, WORKER_DIR, MODELS_DIR
command_engine_status() {
  # The machine-readable form has its own function so the human text stays unchanged.
  [ "${1:-}" != "--porcelain" ] || { command_engine_status_porcelain; return 0; }
  printf 'selected: %s\nactive:   %s\n' "$(engine_selected)" "$(engine_active)"
  # Installed means usable for the current variant; show the path when present.
  if qwen3_usable; then
    printf 'qwen3:    installed (%s, device %s) at %s\n' "$QWEN_VARIANT" "$(qwen3_device)" \
      "$(qwen3_engine_dir)"
  else
    printf 'qwen3:    not installed for variant %s (hyprland-tts engine install qwen3)\n' \
      "$QWEN_VARIANT"
  fi
  # Worker state is always shown, since it explains where the 1 GB of RAM went.
  printf 'worker:   %s\n' "$(worker_status_line)"
  # An empty language list is spelled out so the line is never blank.
  printf 'piper:    %s\n' "$(piper_languages | grep . || printf 'no voices installed')"
}

# command_engine_variant — implement `engine variant <base|customvoice>`: switch the active talker.
# Args:    $1 <variant>
# Returns: 0 on success; exits 1 via die for an unknown or not installed variant
# Globals: writes QWEN_VARIANT in the config file
command_engine_variant() {
  qwen3_variant_valid "${1:-}" || die "usage: hyprland-tts engine variant base|customvoice"
  # Switching to a model that is not on disk would only make Piper speak.
  [ -s "$(qwen3_model_path "$1")" ] ||
    die "variant $1 is not installed: hyprland-tts engine install qwen3 --variant $1"
  set_config_var QWEN_VARIANT "$1"
  # The running shell follows the file, so later steps see the new variant.
  QWEN_VARIANT="$1"
  # A running worker notices the change at the next request and restarts with the new talker.
  log "Active variant set to $1"
}

# command_engine_config — implement `engine config idle <minutes>`.
# Args:    $1 <key, only "idle">; $2 <minutes 1-240>
# Returns: 0 on success; exits 1 via die on a bad key or value
# Globals: writes WORKER_IDLE_MINUTES in the config file
command_engine_config() {
  [ "${1:-}" = "idle" ] || die "usage: hyprland-tts engine config idle <minutes 1-240>"
  # Digits only (no leading zero) within the range keeps the sourced config file safe.
  if ! [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || [ "$2" -gt 240 ]; then
    die "idle minutes must be a whole number from 1 to 240"
  fi
  set_config_var WORKER_IDLE_MINUTES "$2"
  # The running worker re-reads the value on its next idle check.
  log "Worker idle limit set to $2 minutes"
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
# Args:    $1 <status|install|remove|use|config|variant|start|stop>; $2.. <subcommand arguments>
# Returns: 0 on success; exits 1 via die on an unknown subcommand
# Globals: reads the config file via load_config
cmd_engine() {
  local sub="${1:-status}"
  load_config
  # Drop the subcommand name so only its own arguments remain in "$@".
  shift || true
  # Each arm calls its command_engine_<name> function (stop is two plain calls).
  case "$sub" in
    status)  command_engine_status "$@" ;;
    install) command_engine_install "$@" ;;
    # Removal also stops the worker before deleting files.
    remove)  command_engine_remove "$@" ;;
    use)     command_engine_use "$@" ;;
    config)  command_engine_config "$@" ;;
    # Switch the active talker.
    variant) command_engine_variant "$@" ;;
    start)   command_engine_start ;;
    # Stopping needs no engine files, so it also works after a remove.
    stop)    worker_stop; log "Worker stopped" ;;
    *) die "unknown engine subcommand: $sub ($ENGINE_SUBCOMMANDS)" ;;
  esac
}
