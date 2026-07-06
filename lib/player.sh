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

MPV_SOCK="" ; PIDFILE="" ; CHUNKFILE="" ; MODELFILE="" ; DONEFILE="" ; COUNTFILE=""
_player_paths() {
  MPV_SOCK="$RUN_DIR/mpv.sock"
  PIDFILE="$RUN_DIR/daemon.pid"
  CHUNKFILE="$RUN_DIR/chunks"
  MODELFILE="$RUN_DIR/model"
  DONEFILE="$RUN_DIR/render.done"
  COUNTFILE="$RUN_DIR/render.count"
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
  speak_text "$text"
}

# shared by cmd_speak and cmd_hover (lib/hover.sh) — everything from "got some
# text" onward: resolve a voice, remember it, chunk it, hand off to the daemon.
speak_text() {
  local text="$1"
  _player_paths

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

  # Monitor: quit mpv once everything is rendered AND actually finished playing.
  #
  # Deliberately NOT just "DONEFILE exists and idle-active is true right now":
  # render_worker touches DONEFILE the instant it has ISSUED its last
  # append-play IPC call, which is not the same moment mpv has PROCESSED it.
  # A poll landing in that gap could see a stale idle-active=true (from the
  # tail end of the previous chunk) and quit mpv before the last chunk(s)
  # actually play — cutting playback short. Confirmed real via a fake-Piper
  # test with one deliberately slow chunk: the daemon reported fully idle
  # only ~0.3s after two chunks were appended in a burst, far too fast for
  # both to have actually played.
  #
  # Fix: track the number of chunks render_worker actually appended
  # (COUNTFILE, written alongside DONEFILE) and require mpv's OWN reported
  # playlist-count to match it, in addition to idle-active. playlist-count
  # only advances once mpv has genuinely processed an append, so this can't
  # be fooled by IPC delivery lag the way a bare idle-active check can — a
  # premature poll just sees a lower count and correctly keeps waiting.
  while kill -0 "$mpv_pid" 2>/dev/null; do
    if [ -f "$DONEFILE" ]; then
      local total have
      total="$(cat "$COUNTFILE" 2>/dev/null || true)"
      have="$(mpv_get playlist-count)"
      if [ -n "$total" ] && [ "$have" = "$total" ] && [ "$(mpv_get idle-active)" = "true" ]; then
        mpv_ipc '{"command":["quit"]}' >/dev/null
        break
      fi
    fi
    sleep 0.3
  done
}

render_worker() {
  # Rendering (this loop) and playback (mpv) run concurrently: mpv starts
  # playing chunk 0 as soon as it's appended, while we're still synthesizing
  # chunk 1, 2, ... Whenever synthesis of one chunk takes longer than
  # playback of everything queued so far — a plausible slowdown for a long
  # document, a slow disk, or a longer chunk from code normalization — mpv
  # DRAINS ITS PLAYLIST AND GOES IDLE before the next chunk is appended.
  #
  # Plain `append` (the mode this used to use for every chunk after the
  # first) only adds to the playlist — it does NOT resume playback if mpv is
  # already idle. Confirmed empirically against a live mpv instance: once
  # idle, `loadfile x append` leaves idle-active=true and playlist-pos=-1
  # forever, i.e. the file is queued but never played. That is the exact
  # mechanism behind two real user reports: "audio just stops" (more likely
  # whenever a chunk is unusually slow to synthesize, e.g. a code-derived
  # chunk) and "sometimes cut short" (the same race, triggered by ordinary
  # timing variance on any long document) — not something that shows up on
  # short test inputs where synthesis always outpaces playback.
  #
  # `append-play` fixes this unconditionally: it starts playback if mpv is
  # idle, and behaves exactly like `replace` on an empty playlist (verified),
  # so there's no need for a separate first-chunk case anymore either.
  local model="$1" idx=0 wav line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    wav="$RUN_DIR/s$(printf '%05d' "$idx").wav"
    if printf '%s' "$line" | "$PIPER_BIN" --model "$model" --output_file "$wav" >/dev/null 2>&1 \
       && [ -s "$wav" ]; then
      mpv_ipc "{\"command\":[\"loadfile\",\"$wav\",\"append-play\"]}" >/dev/null
      idx=$((idx+1))
    fi
  done < "$CHUNKFILE"
  # record how many chunks actually got appended (a chunk whose synthesis
  # failed is skipped, so this can be less than the line count) — the
  # monitor loop waits for mpv's own playlist-count to reach this number
  # before it's allowed to quit; see the comment there for why.
  printf '%s\n' "$idx" > "$COUNTFILE"
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
