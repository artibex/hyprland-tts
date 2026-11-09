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

# daemon_pid_valid — tell whether a pid is a live hyprland-tts player daemon.
# Args:    $1 <pid>
# Returns: 0 when the process exists and its command line names __daemon; 1 otherwise
# Globals: none
daemon_pid_valid() {
  # Digits only: the pid comes from a file and must never reach /proc paths unchecked.
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  # The command line defeats pid reuse: a stale pid file must never get an unrelated process killed.
  [ -r "/proc/$1/cmdline" ] && tr '\0' ' ' < "/proc/$1/cmdline" | grep -q -- '__daemon'
}

# daemon_alive — tell whether the player daemon is running.
# Args:    none
# Returns: 0 when the pid file names a live player daemon; 1 otherwise
# Globals: writes the player paths via _player_paths; reads PIDFILE
daemon_alive() {
  _player_paths
  # No pid file means no daemon was ever started in this run directory.
  [ -f "$PIDFILE" ] || return 1
  daemon_pid_valid "$(cat "$PIDFILE" 2>/dev/null || true)"
}

# daemon_signal — send a signal to the daemon and everything it started.
# Args:    $1 <signal name, e.g. TERM>; $2 <daemon pid>
# Returns: 0 always
# Globals: none
# Notes:   The daemon leads its own session, so its group also holds mpv and in-flight curl/piper.
daemon_signal() {
  local group
  group="$(ps -o pgid= -p "$2" 2>/dev/null | tr -d ' ')"
  # Group-kill only when the pid really leads its group; otherwise signal the process alone.
  if [ "$group" = "$2" ]; then kill "-$1" -- "-$2" 2>/dev/null || true
  else kill "-$1" "$2" 2>/dev/null || true; fi
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
  daemon_signal TERM "$pid"
  # Up to one second for the daemon's trap to quit mpv, then force.
  while daemon_pid_valid "$pid" && [ "$waited" -lt 20 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  # Force the exit if the daemon ignored SIGTERM (the pid is checked again against reuse).
  if daemon_pid_valid "$pid"; then daemon_signal KILL "$pid"; fi
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
  # The Qwen3 engine talks to its server with curl and starts it under a flock.
  if [ "$1" = "qwen3" ]; then
    have curl || speak_fail "curl not found (install curl)"
    have flock || speak_fail "flock not found (install util-linux)"
  fi
  # Without mpv there is no player at all.
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

# speak_limit_text — cut an extremely long selection and tell the user.
# Args:    $1 <text>
# Returns: 0 always; stdout: the text, shortened to SELECTION_MAX_CHARS when longer
# Globals: reads SELECTION_MAX_CHARS
speak_limit_text() {
  local limit="$SELECTION_MAX_CHARS"
  # A junk setting falls back to the default instead of cutting everything.
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=200000
  if [ "${#1}" -gt "$limit" ]; then
    notify "hyprland-tts: selection shortened" "Only the first $limit characters are read."
    # Cutting by characters keeps multi-byte letters intact.
    printf '%s' "${1:0:limit}"
  else
    printf '%s' "$1"
  fi
}

# speak_wait_for_daemon — wait until a freshly started daemon has written its pid file.
# Args:    none
# Returns: 0 when the pid file exists; 1 after about three seconds without one
# Globals: reads PIDFILE
speak_wait_for_daemon() {
  local waited=0
  # Until the pid file exists, a following speak could not find (and stop) this daemon.
  while [ ! -s "$PIDFILE" ] && [ "$waited" -lt 60 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  # The file's existence is the success condition.
  [ -s "$PIDFILE" ]
}

# speak_start_document — under the speak lock: stop the old daemon, prepare chunks, start a new one.
# Args:    $1 <text>; $2 <allowed languages, comma separated>
# Returns: 0 on success or empty text; exits 1 via speak_fail when the run directory is unsafe
# Globals: reads RUN_DIR, HTTS_SELF, DEFAULT_LANG; writes the run directory contents
speak_start_document() {
  # An unsafe (foreign or symlinked) runtime directory would leak chunks and the mpv socket.
  ensure_private_dir "$RUN_DIR" || speak_fail "unsafe runtime directory: $RUN_DIR"
  # One speak at a time: two quick keypresses must not start two daemons.
  (
    flock -w 30 7 || exit 1
    kill_existing_daemon
    # Clear the previous document but keep the lock file this subshell holds.
    find "$RUN_DIR" -mindepth 1 -maxdepth 1 ! -name .speak.lock -exec rm -rf -- {} +
    speak_notice_engine_choice
    # The router yields "<lang><TAB><sentence>" lines; voices are picked per chunk later.
    printf '%s' "$1" | prepare_chunks "$2" "$(speak_default_lang)" > "$CHUNKFILE"
    [ -s "$CHUNKFILE" ] || exit 0
    # setsid detaches the daemon from the keybind's process group; the subshell is the fallback.
    setsid -f "${HTTS_SELF:-$0}" __daemon >/dev/null 2>&1 < /dev/null 7>&- ||
      ( "${HTTS_SELF:-$0}" __daemon >/dev/null 2>&1 < /dev/null 7>&- & )
    speak_wait_for_daemon || true
  # The lock descriptor lives only as long as this subshell.
  ) 7> "$RUN_DIR/.speak.lock"
}

# speak_text — shared by cmd_speak and cmd_hover: chunk the text and start the daemon.
# Args:    $1 <text to speak>
# Returns: 0 on success or empty text; exits 1 via speak_fail without a usable engine
# Globals: reads ENGINE, DEFAULT_LANG, HTTS_SELF, SELECTION_MAX_CHARS; writes RUN_DIR contents
speak_text() {
  local text active_engine allowed
  _player_paths
  # An enormous selection is shortened before any processing.
  text="$(speak_limit_text "$1")"
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
  speak_start_document "$text" "$allowed"
}

# speak_notice_engine_choice — tell the user once when a requested engine is not usable.
# Args:    none
# Returns: 0 always
# Globals: reads ENGINE
speak_notice_engine_choice() {
  local reason
  # Only a requested-but-unusable Qwen3 deserves a notice; auto quietly uses Piper.
  [ "$ENGINE" = "qwen3" ] && [ "$(engine_active)" = "piper" ] || return 0
  reason="$(engine_unusable_reason)"
  if [ "$reason" = "not installed" ]; then
    # Nothing to find: the engine is simply absent.
    engine_notify_once missing "hyprland-tts: Qwen3 not installed" \
      "Using Piper. Install with: hyprland-tts engine install qwen3"
  else
    engine_notify_once missing "hyprland-tts: Qwen3 unavailable" "Using Piper: $reason"
  fi
}

# daemon_cleanup — stop the renderer and mpv, delete the audio files, remove the pid file.
# Args:    none
# Returns: 0 always
# Globals: reads DAEMON_MPV_PID, DAEMON_RENDER_PID, PIDFILE, HTTS_KEEP_AUDIO; deletes WAVs
daemon_cleanup() {
  # Stop the renderer and its in-flight curl/piper first, so nothing appends to a dying mpv.
  if [ -n "$DAEMON_RENDER_PID" ]; then
    pkill -P "$DAEMON_RENDER_PID" 2>/dev/null || true
    kill "$DAEMON_RENDER_PID" 2>/dev/null || true
  fi
  # Ask mpv to quit politely, then make sure the process is gone.
  mpv_ipc '{"command":["quit"]}' >/dev/null 2>&1 || true
  if [ -n "$DAEMON_MPV_PID" ]; then kill "$DAEMON_MPV_PID" 2>/dev/null || true; fi
  # The spoken text and its audio are private; they must not outlive the playback.
  [ "${HTTS_KEEP_AUDIO:-0}" = "1" ] || rm -f "$RUN_DIR"/s[0-9]*.wav "$CHUNKFILE"
  rm -f "$PIDFILE"
}

# daemon_report_failure — log a daemon problem and tell the user (keybind runs have no terminal).
# Args:    $1 <message>
# Returns: 0 always
# Globals: reads RUN_DIR
daemon_report_failure() {
  printf '%s %s\n' "$(date +%H:%M:%S)" "$1" >> "$RUN_DIR/daemon.log" 2>/dev/null || true
  notify "hyprland-tts: playback problem" "$1"
}

# daemon_start_mpv — launch the idle mpv with its IPC socket and wait for the socket.
# Args:    none
# Returns: 0 when the socket exists; 1 when mpv never came up
# Globals: reads MPV_BIN, MPV_SOCK, DEFAULT_SPEED; writes DAEMON_MPV_PID
daemon_start_mpv() {
  local waited=0
  # Unix socket paths are limited to about 107 bytes; a longer one makes mpv ignore the option.
  if [ "${#MPV_SOCK}" -gt 100 ]; then
    daemon_report_failure "runtime path too long: $MPV_SOCK"
    return 1
  fi
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
  # mpv's count rises when it processed an append, so a poll before the last append is rejected;
  # the caller additionally needs two polls in a row, because idle lags the count by milliseconds.
  [ -n "$total" ] && [ "$played" = "$total" ] && [ "$(mpv_get idle-active)" = "true" ]
}

# daemon_render_crashed — handle a renderer that died without finishing (no done marker).
# Args:    none
# Returns: 0 when the renderer vanished and the marker was written; 1 otherwise
# Globals: reads DAEMON_RENDER_PID, DONEFILE, COUNTFILE
daemon_render_crashed() {
  # Dead pid first, marker second: a normal finish touches the marker before the pid exits.
  ! kill -0 "$DAEMON_RENDER_PID" 2>/dev/null || return 1
  [ ! -f "$DONEFILE" ] || return 1
  # Declare what mpv has as the total, so the normal finish logic ends the playback.
  mpv_get playlist-count > "$COUNTFILE"
  : > "$DONEFILE"
  daemon_report_failure "the renderer stopped unexpectedly; playing what was rendered"
}

# daemon_monitor — wait until playback is finished, then quit mpv.
# Args:    none
# Returns: 0 when mpv exited or was told to quit
# Globals: reads DAEMON_MPV_PID
daemon_monitor() {
  local idle_polls=0
  while kill -0 "$DAEMON_MPV_PID" 2>/dev/null; do
    # A vanished renderer is turned into a normal finish.
    daemon_render_crashed || true
    if daemon_playback_finished; then
      idle_polls=$((idle_polls + 1))
    else
      # A busy reading restarts the count.
      idle_polls=0
    fi
    # Two idle polls in a row: one alone can be the stale reading right after an append.
    if [ "$idle_polls" -ge 2 ]; then
      mpv_ipc '{"command":["quit"]}' >/dev/null
      break
    fi
    # Polling interval; the controls themselves are instant (mpv IPC).
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
  # Without a running mpv there is nothing to feed; the user is told why.
  daemon_start_mpv || { daemon_report_failure "mpv did not start"; exit 0; }
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
      # A dead mpv must not kill the renderer under set -e; the monitor ends with mpv anyway.
      mpv_ipc "{\"command\":[\"loadfile\",\"$wav\",\"append-play\"]}" >/dev/null || true
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
