#!/usr/bin/env bash
# lib/player.sh — smart player built on mpv.
#
# Why mpv: Piper synthesis latency was the cause of the "long stop" on speed
# changes and slow skipping. Now each sentence is rendered to a WAV once, and a
# single persistent mpv instance plays the playlist. All controls are native mpv
# IPC commands and therefore INSTANT and glitch-free:
#   next/prev  -> playlist-next / playlist-prev   (already-rendered files)
#   faster/slower -> set speed  (mpv keeps pitch via audio-pitch-correction)
#   pause/toggle  -> set/cycle pause
#   restart    -> seek 0 in the current file
# The daemon's only jobs are: render sentences, feed them to mpv, and quit mpv
# when the playlist is exhausted.

MPV_SOCK="" ; PIDFILE="" ; CHUNKFILE="" ; MODELFILE="" ; DONEFILE=""
_player_paths() {
  MPV_SOCK="$RUN_DIR/mpv.sock"
  PIDFILE="$RUN_DIR/daemon.pid"
  CHUNKFILE="$RUN_DIR/chunks"
  MODELFILE="$RUN_DIR/model"
  DONEFILE="$RUN_DIR/render.done"
}

daemon_alive() {
  _player_paths
  [ -f "$PIDFILE" ] || return 1
  local p; p="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

kill_existing_daemon() {
  _player_paths
  if daemon_alive; then
    local p; p="$(cat "$PIDFILE" 2>/dev/null || true)"
    kill -TERM "$p" 2>/dev/null || true
    local i=0
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.05; i=$((i+1)); done
    kill -KILL "$p" 2>/dev/null || true
  fi
}

# ---- IPC to mpv --------------------------------------------------------------
mpv_ipc() {
  # $1 = JSON command; prints mpv's reply (if any)
  have socat || return 1
  [ -S "$MPV_SOCK" ] || return 1
  printf '%s\n' "$1" | socat -T0.3 - "UNIX-CONNECT:$MPV_SOCK" 2>/dev/null
}
mpv_get() {
  local resp; resp="$(mpv_ipc "{\"command\":[\"get_property\",\"$1\"]}")"
  printf '%s' "$resp" | sed -n 's/.*"data":\([^,}]*\).*/\1/p' | head -n1
}
mpv_set() { mpv_ipc "{\"command\":[\"set_property\",\"$1\",$2]}" >/dev/null; }

# ==============================================================================
# speak — entry point (bound to the speak key). Detached, returns immediately.
# ==============================================================================
cmd_speak() {
  load_config
  _player_paths

  local text=""
  if have wl-paste; then text="$(wl-paste --primary 2>/dev/null || true)"; fi
  # if nothing is selected, try to read an image on the clipboard (OCR/metadata)
  if [ -z "${text//[[:space:]]/}" ]; then
    text="$(read_clipboard_image 2>/dev/null || true)"
  fi
  [ -n "${text//[[:space:]]/}" ] || exit 0

  have "$PIPER_BIN" || die "$PIPER_BIN not found (install piper-tts-bin)"
  have "$MPV_BIN"   || die "$MPV_BIN not found (install mpv)"
  have socat        || die "socat not found (install socat)"

  local model
  model="$(resolve_model "$text")" || \
    die "no voice model installed — run 'hyprland-tts gui' or 'hyprland-tts model install <key>'"
  remember_model "$model"

  kill_existing_daemon
  rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
  printf '%s' "$text" | normalize_text | chunk_text > "$CHUNKFILE"
  [ -s "$CHUNKFILE" ] || exit 0
  printf '%s\n' "$model" > "$MODELFILE"

  setsid -f "$0" __daemon >/dev/null 2>&1 < /dev/null || \
    ( "$0" __daemon >/dev/null 2>&1 < /dev/null & )
}

# ==============================================================================
# __daemon — render sentences, feed mpv, quit when done.
# ==============================================================================
run_daemon() {
  load_config
  _player_paths
  local mpv_pid="" render_pid=""
  cleanup() {
    [ -n "$render_pid" ] && kill "$render_pid" 2>/dev/null || true
    mpv_ipc '{"command":["quit"]}' >/dev/null 2>&1 || true
    [ -n "$mpv_pid" ] && kill "$mpv_pid" 2>/dev/null || true
    rm -f "$PIDFILE"
  }
  trap 'cleanup; exit 0' TERM INT EXIT

  echo $$ > "$PIDFILE"
  local model; model="$(cat "$MODELFILE" 2>/dev/null || true)"
  [ -n "$model" ] || exit 0

  # start mpv idle with an IPC socket; pitch correction keeps voices natural
  "$MPV_BIN" --idle=yes --no-video --force-window=no --no-terminal \
    --input-ipc-server="$MPV_SOCK" \
    --audio-pitch-correction=yes --speed="$DEFAULT_SPEED" \
    >/dev/null 2>&1 &
  mpv_pid=$!

  # wait for the socket (max ~3s)
  local i=0
  while [ ! -S "$MPV_SOCK" ] && kill -0 "$mpv_pid" 2>/dev/null && [ "$i" -lt 60 ]; do
    sleep 0.05; i=$((i+1))
  done
  [ -S "$MPV_SOCK" ] || exit 0

  # background renderer: synthesize each sentence, append to mpv's playlist
  render_worker "$model" &
  render_pid=$!

  # monitor: once everything is rendered and mpv has drained the playlist, quit
  while kill -0 "$mpv_pid" 2>/dev/null; do
    if [ -f "$DONEFILE" ]; then
      [ "$(mpv_get idle-active)" = "true" ] && { mpv_ipc '{"command":["quit"]}' >/dev/null; break; }
    fi
    sleep 0.3
  done
}

render_worker() {
  local model="$1" idx=0 wav mode line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    wav="$RUN_DIR/s$(printf '%05d' "$idx").wav"
    if printf '%s' "$line" | "$PIPER_BIN" --model "$model" --output_file "$wav" >/dev/null 2>&1 \
       && [ -s "$wav" ]; then
      mode="append"; [ "$idx" -eq 0 ] && mode="replace"
      mpv_ipc "{\"command\":[\"loadfile\",\"$wav\",\"$mode\"]}" >/dev/null
      idx=$((idx+1))
    fi
  done < "$CHUNKFILE"
  touch "$DONEFILE"
}

# ==============================================================================
# ctl — control the running player (native mpv IPC = instant)
# ==============================================================================
cmd_ctl() {
  load_config
  _player_paths
  local sub="${1:-status}"
  case "$sub" in
    status)
      if daemon_alive && [ -S "$MPV_SOCK" ]; then
        printf 'pos=%s/%s speed=%s paused=%s\n' \
          "$(mpv_get playlist-pos)" "$(mpv_get playlist-count)" \
          "$(mpv_get speed)" "$(mpv_get pause)"
      else
        echo "idle"
      fi
      return 0 ;;
  esac
  daemon_alive || exit 0
  case "$sub" in
    next)    mpv_ipc '{"command":["playlist-next","force"]}' >/dev/null ;;
    prev)    mpv_ipc '{"command":["playlist-prev","force"]}' >/dev/null ;;
    restart) mpv_ipc '{"command":["seek",0,"absolute"]}' >/dev/null ;;
    pause)   mpv_set pause true ;;
    resume)  mpv_set pause false ;;
    toggle)  mpv_ipc '{"command":["cycle","pause"]}' >/dev/null ;;
    faster|slower)
      local cur new dir
      cur="$(mpv_get speed)"; [ -n "$cur" ] || cur="$DEFAULT_SPEED"
      dir="up"; [ "$sub" = "slower" ] && dir="down"
      new="$(awk -v c="$cur" -v st="$SPEED_STEP" -v lo="$SPEED_MIN" -v hi="$SPEED_MAX" -v d="$dir" \
        'BEGIN{ v = (d=="up") ? c+st : c-st; if(v<lo)v=lo; if(v>hi)v=hi; printf "%.2f", v }')"
      mpv_set speed "$new" ;;
    stop)    mpv_ipc '{"command":["quit"]}' >/dev/null ;;
    *) die "unknown control command: $sub" ;;
  esac
}

cmd_stop() {
  _player_paths
  daemon_alive && mpv_ipc '{"command":["quit"]}' >/dev/null 2>&1 || true
  kill_existing_daemon
}
