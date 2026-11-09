#!/usr/bin/env bash
# lib/player.sh — smart player built on mpv.
#
# Each sentence chunk is rendered to a WAV once (by the active engine, see engine.sh)
# and one persistent mpv plays the growing playlist. All controls are native mpv IPC
# commands and therefore instant: next/prev = playlist-next/prev, faster/slower = speed
# (pitch preserved), pause/toggle = pause, restart = seek 0. The daemon renders chunks,
# appends them to mpv and quits mpv once the playlist is really exhausted.

# Runtime files inside RUN_DIR (wiped on every speak) and the daemon's child pids.
MPV_SOCK="" ; PIDFILE="" ; CHUNKFILE="" ; DONEFILE="" ; COUNTFILE=""
DAEMON_MPV_PID="" ; DAEMON_RENDER_PID=""

# _player_paths — derive the runtime file paths from RUN_DIR.
# Args:    none
# Returns: 0 always
# Globals: reads RUN_DIR; writes MPV_SOCK, PIDFILE, CHUNKFILE, DONEFILE, COUNTFILE
_player_paths() {
  # All per-speak state lives in one directory so a new speak can wipe it in one go.
  MPV_SOCK="$RUN_DIR/mpv.sock"
  PIDFILE="$RUN_DIR/daemon.pid"
  CHUNKFILE="$RUN_DIR/chunks"
  # The done marker is touched once every chunk has been appended.
  DONEFILE="$RUN_DIR/render.done"
  COUNTFILE="$RUN_DIR/render.count"
}

# daemon_alive — tell whether the player daemon is running.
# Args:    none
# Returns: 0 when the pid file names a live process; 1 otherwise
# Globals: reads PIDFILE via _player_paths
daemon_alive() {
  local pid
  _player_paths
  # No pid file means no daemon was ever started in this run directory.
  [ -f "$PIDFILE" ] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  # An empty or stale pid means the daemon is gone.
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# kill_existing_daemon — terminate a running daemon so a new speak starts clean.
# Args:    none
# Returns: 0 always
# Globals: reads PIDFILE via _player_paths
kill_existing_daemon() {
  local pid waited=0
  _player_paths
  # Nothing to kill when no daemon runs.
  daemon_alive || return 0
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  kill -TERM "$pid" 2>/dev/null || true
  # Up to one second for the daemon's trap to quit mpv, then force.
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  # Force the exit if the daemon ignored SIGTERM.
  kill -KILL "$pid" 2>/dev/null || true
}

# mpv_ipc — send one JSON command to mpv's IPC socket.
# Args:    $1 <JSON command>
# Returns: 0 when sent; 1 when socat or the socket is missing; stdout: mpv's reply
# Globals: reads MPV_SOCK
mpv_ipc() {
  have socat || return 1
  [ -S "$MPV_SOCK" ] || return 1
  # -T0.3 bounds the wait so a stuck mpv cannot freeze a keybind.
  printf '%s\n' "$1" | socat -T0.3 - "UNIX-CONNECT:$MPV_SOCK" 2>/dev/null
}

# mpv_get — read one mpv property.
# Args:    $1 <property name>
# Returns: 0 always; stdout: the property value (empty when unavailable)
# Globals: reads MPV_SOCK
mpv_get() {
  local reply
  reply="$(mpv_ipc "{\"command\":[\"get_property\",\"$1\"]}")"
  # The reply is {"data":<value>,...}; only the value is wanted.
  printf '%s' "$reply" | sed -n 's/.*"data":\([^,}]*\).*/\1/p' | head -n1
}

# mpv_set — set one mpv property.
# Args:    $1 <property name>; $2 <JSON value>
# Returns: 0 always
# Globals: reads MPV_SOCK
mpv_set() {
  # The reply carries nothing the callers need.
  mpv_ipc "{\"command\":[\"set_property\",\"$1\",$2]}" >/dev/null
}

# cmd_speak — entry point of the speak key: read the selection and hand it to the player.
# Args:    none
# Returns: 0 always (silently when there is nothing to read)
# Globals: reads the primary selection and the clipboard
cmd_speak() {
  local text=""
  load_config
  # Cheap and idempotent; keeps this function usable on its own.
  _player_paths
  # The primary selection is what the user just highlighted.
  if have wl-paste; then text="$(wl-paste --primary 2>/dev/null || true)"; fi
  # With nothing selected, a copied image may still yield text (OCR/metadata).
  if [ -z "${text//[[:space:]]/}" ]; then
    text="$(read_clipboard_image 2>/dev/null || true)"
  fi
  [ -n "${text//[[:space:]]/}" ] || exit 0
  # From here on the text is handled like any other selection.
  speak_text "$text"
}

# speak_fail — notify and die for a missing prerequisite (keybind runs have no terminal).
# Args:    $1 <message>
# Returns: exits 1 via die
# Globals: none
speak_fail() {
  # A notification is the only way a keybind-launched failure becomes visible.
  notify "hyprland-tts: speech unavailable" "$1"
  die "$1"
}

# speak_check_tools — verify the programs the chosen engine needs.
# Args:    $1 <engine: qwen3|piper>
# Returns: 0 when all exist; exits 1 via speak_fail otherwise
# Globals: reads PIPER_BIN, MPV_BIN
speak_check_tools() {
  # Piper is only mandatory when it is the engine (it is the fallback otherwise).
  if [ "$1" = "piper" ]; then
    have "$PIPER_BIN" || speak_fail "$PIPER_BIN not found (install piper-tts-bin)"
  fi
  have "$MPV_BIN" || speak_fail "$MPV_BIN not found (install mpv)"
  # Playback controls are impossible without socat, so fail early and visibly.
  have socat || speak_fail "socat not found (install socat)"
}

# speak_default_lang — print the language assumed when detection finds nothing.
# Args:    none
# Returns: 0 always; stdout: a language code
# Globals: reads DEFAULT_LANG
speak_default_lang() {
  local first="${DEFAULT_LANG%%[ ,]*}"
  # Only a well-formed code is trusted; anything else means English.
  [[ "$first" =~ ^[a-z]{2,3}$ ]] || first="en"
  printf '%s' "$first"
}

# speak_text — shared by cmd_speak and cmd_hover: chunk the text and start the daemon.
# Args:    $1 <text to speak>
# Returns: 0 on success or empty text; exits 1 via speak_fail without a usable engine
# Globals: reads ENGINE, DEFAULT_LANG, HTTS_SELF; writes RUN_DIR contents
speak_text() {
  local text="$1" active_engine allowed
  _player_paths
  # The engine decides which tools and which language list apply.
  active_engine="$(engine_active)"
  speak_check_tools "$active_engine"
  allowed="$(engine_languages)"
  # No usable voice for the active engine: nothing could be spoken.
  [ -n "$allowed" ] ||
    speak_fail "No voice installed: run 'hyprland-tts gui' or 'hyprland-tts model install <key>'"
  declare -F prepare_chunks >/dev/null || speak_fail "router too old: prepare_chunks missing"
  # Start loading the Qwen3 model now so it overlaps with text preparation.
  engine_warm
  kill_existing_daemon
  rm -rf "$RUN_DIR"
  # Fresh, empty runtime directory for this document.
  mkdir -p "$RUN_DIR"
  speak_notice_engine_choice
  # The router yields "<lang><TAB><sentence>" lines; voices are picked per chunk later.
  printf '%s' "$text" | prepare_chunks "$allowed" "$(speak_default_lang)" > "$CHUNKFILE"
  [ -s "$CHUNKFILE" ] || exit 0
  # setsid detaches the daemon from the keybind's process group; the subshell is the fallback.
  setsid -f "${HTTS_SELF:-$0}" __daemon >/dev/null 2>&1 < /dev/null ||
    ( "${HTTS_SELF:-$0}" __daemon >/dev/null 2>&1 < /dev/null & )
}

# speak_notice_engine_choice — tell the user once when a requested engine is not usable.
# Args:    none
# Returns: 0 always
# Globals: reads ENGINE
speak_notice_engine_choice() {
  # ENGINE=qwen3 with no install would otherwise silently sound like Piper.
  [ "$ENGINE" = "qwen3" ] && [ "$(engine_active)" = "piper" ] &&
    engine_notify_once missing "hyprland-tts: Qwen3 not installed" \
      "Using Piper. Install with: hyprland-tts engine install qwen3"
  return 0
}

# daemon_cleanup — stop the renderer and mpv, remove the pid file.
# Args:    none
# Returns: 0 always
# Globals: reads DAEMON_MPV_PID, DAEMON_RENDER_PID, PIDFILE
daemon_cleanup() {
  # Stop the renderer first so it cannot append to a dying mpv.
  if [ -n "$DAEMON_RENDER_PID" ]; then kill "$DAEMON_RENDER_PID" 2>/dev/null || true; fi
  # Ask mpv to quit politely, then make sure the process is gone.
  mpv_ipc '{"command":["quit"]}' >/dev/null 2>&1 || true
  if [ -n "$DAEMON_MPV_PID" ]; then kill "$DAEMON_MPV_PID" 2>/dev/null || true; fi
  rm -f "$PIDFILE"
}

# daemon_start_mpv — launch the idle mpv with its IPC socket and wait for the socket.
# Args:    none
# Returns: 0 when the socket exists; 1 when mpv never came up
# Globals: reads MPV_BIN, MPV_SOCK, DEFAULT_SPEED; writes DAEMON_MPV_PID
daemon_start_mpv() {
  local waited=0
  # Idle mode keeps one process alive across chunks; pitch correction keeps voices natural.
  "$MPV_BIN" --idle=yes --no-video --force-window=no --no-terminal \
    --input-ipc-server="$MPV_SOCK" \
    --audio-pitch-correction=yes --speed="$DEFAULT_SPEED" >/dev/null 2>&1 &
  DAEMON_MPV_PID=$!
  # Wait up to about 3 s for the socket; a dead mpv ends the wait early.
  while [ ! -S "$MPV_SOCK" ] && kill -0 "$DAEMON_MPV_PID" 2>/dev/null && [ "$waited" -lt 60 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  # The socket's existence is the success condition.
  [ -S "$MPV_SOCK" ]
}

# daemon_playback_finished — tell whether every rendered chunk has been played.
# Args:    none
# Returns: 0 when rendering is done and mpv is idle at the final count; 1 otherwise
# Globals: reads DONEFILE, COUNTFILE
daemon_playback_finished() {
  local total played
  [ -f "$DONEFILE" ] || return 1
  # The rendered total is written by render_worker when it finishes.
  total="$(cat "$COUNTFILE" 2>/dev/null || true)"
  played="$(mpv_get playlist-count)"
  # mpv's own count only rises once it processed an append, so a stale idle read
  # right after the last append cannot cut the final chunks off.
  [ -n "$total" ] && [ "$played" = "$total" ] && [ "$(mpv_get idle-active)" = "true" ]
}

# daemon_monitor — wait until playback is finished, then quit mpv.
# Args:    none
# Returns: 0 when mpv exited or was told to quit
# Globals: reads DAEMON_MPV_PID
daemon_monitor() {
  while kill -0 "$DAEMON_MPV_PID" 2>/dev/null; do
    if daemon_playback_finished; then
      # Playback is complete: let mpv exit so the daemon can end.
      mpv_ipc '{"command":["quit"]}' >/dev/null
      break
    fi
    sleep 0.3
  done
}

# run_daemon — the detached `__daemon`: start mpv, render chunks, quit when done.
# Args:    none
# Returns: 0 always
# Globals: reads RUN_DIR files; writes PIDFILE
run_daemon() {
  load_config
  _player_paths
  # Whatever ends the daemon, mpv and the renderer must not be left behind.
  trap 'daemon_cleanup; exit 0' TERM INT EXIT
  echo $$ > "$PIDFILE"
  [ -s "$CHUNKFILE" ] || exit 0
  # Without a running mpv there is nothing to feed, so end quietly.
  daemon_start_mpv || exit 0
  # Rendering and playback run concurrently: mpv plays chunk 0 while chunk 1 renders.
  render_worker &
  DAEMON_RENDER_PID=$!
  daemon_monitor
}

# render_worker — render each chunk and append it to mpv's playlist.
# Args:    none
# Returns: 0 always
# Globals: reads CHUNKFILE, RUN_DIR; writes COUNTFILE, DONEFILE
render_worker() {
  local index=0 lang text wav
  # A failed engine start is not fatal: engine_render falls back to Piper per chunk.
  engine_prepare || true
  while IFS=$'\t' read -r lang text; do
    [ -n "$text" ] || continue
    # Zero-padded names keep the playlist order readable in a directory listing.
    wav="$RUN_DIR/s$(printf '%05d' "$index").wav"
    # append-play (not append) resumes playback if mpv already drained and went idle.
    if engine_render "$lang" "$text" "$wav"; then
      mpv_ipc "{\"command\":[\"loadfile\",\"$wav\",\"append-play\"]}" >/dev/null
      index=$((index + 1))
    fi
  done < "$CHUNKFILE"
  # Chunks whose rendering failed are skipped, so the count can be below the line count.
  printf '%s\n' "$index" > "$COUNTFILE"
  touch "$DONEFILE"
}

# ctl_status — print the player state for `ctl status`.
# Args:    none
# Returns: 0 always; stdout: "pos=<n>/<count> speed=<x> paused=<bool>" or "idle"
# Globals: reads MPV_SOCK
ctl_status() {
  if daemon_alive && [ -S "$MPV_SOCK" ]; then
    printf 'pos=%s/%s speed=%s paused=%s\n' "$(mpv_get playlist-pos)" \
      "$(mpv_get playlist-count)" "$(mpv_get speed)" "$(mpv_get pause)"
  else
    # Scripts and the GUI test for this exact word.
    echo "idle"
  fi
}

# ctl_change_speed — step the playback speed up or down within the allowed range.
# Args:    $1 <faster|slower>
# Returns: 0 always
# Globals: reads DEFAULT_SPEED, SPEED_STEP, SPEED_MIN, SPEED_MAX
ctl_change_speed() {
  local current direction="up" new_speed
  current="$(mpv_get speed)"
  # Before mpv answers, fall back to the configured start speed.
  [ -n "$current" ] || current="$DEFAULT_SPEED"
  [ "$1" = "slower" ] && direction="down"
  # awk does the float math and clamps the result to the configured limits.
  new_speed="$(awk -v c="$current" -v st="$SPEED_STEP" -v lo="$SPEED_MIN" -v hi="$SPEED_MAX" \
    -v d="$direction" 'BEGIN{ v = (d=="up") ? c+st : c-st; if(v<lo)v=lo; if(v>hi)v=hi;
    printf "%.2f", v }')"
  mpv_set speed "$new_speed"
}

# cmd_ctl — control the running player through mpv IPC.
# Args:    $1 <status|next|prev|restart|pause|resume|toggle|faster|slower|stop>
# Returns: 0 on success or when idle; exits 1 via die on an unknown command
# Globals: reads RUN_DIR files
cmd_ctl() {
  local sub="${1:-status}"
  load_config
  # Needed before any mpv_ipc call below.
  _player_paths
  # Status works without a daemon; every other command needs one.
  [ "$sub" != "status" ] || { ctl_status; return 0; }
  daemon_alive || exit 0
  case "$sub" in
    next)    mpv_ipc '{"command":["playlist-next","force"]}' >/dev/null ;; # next sentence
    prev)    mpv_ipc '{"command":["playlist-prev","force"]}' >/dev/null ;; # previous sentence
    restart) mpv_ipc '{"command":["seek",0,"absolute"]}' >/dev/null ;; # replay this sentence
    pause)   mpv_set pause true ;; # freeze without losing the position
    resume)  mpv_set pause false ;; # continue where paused
    toggle)  mpv_ipc '{"command":["cycle","pause"]}' >/dev/null ;; # one key for both
    faster|slower) ctl_change_speed "$sub" ;; # step within the allowed speed range
    stop)    mpv_ipc '{"command":["quit"]}' >/dev/null ;; # end this document's playback
    *) die "unknown control command: $sub" ;;
  esac
}

# cmd_stop — stop playback (the warm worker keeps running; use `engine stop` for that).
# Args:    none
# Returns: 0 always
# Globals: reads RUN_DIR files
cmd_stop() {
  _player_paths
  # Quitting mpv politely first avoids an audible click from a killed stream.
  if daemon_alive; then mpv_ipc '{"command":["quit"]}' >/dev/null 2>&1 || true; fi
  kill_existing_daemon
}
