#!/usr/bin/env bash
# lib/stream.sh — play the first sentence while the neural engine is still generating it.
#
# The warm tts-server can stream raw PCM while it synthesizes. For chunk 0 only, the player
# makes a FIFO the playlist entry, mpv plays it as raw audio, and lib/py/htts_stream.py pumps
# the stream into it (and into a copy). When the stream is complete the copy replaces the FIFO
# under the same name, so replay and previous-sentence read an ordinary file. Every failure
# before audible output falls back to the normal render without a double playback.
# Sourced by bin/hyprland-tts; defines functions and constants only.

# mpv per-entry options: the FIFO and the finished copy are raw 24 kHz mono 16-bit PCM.
STREAM_MPV_OPTIONS="demuxer=rawaudio,demuxer-rawaudio-rate=24000,demuxer-rawaudio-channels=1"
STREAM_MPV_OPTIONS+=",demuxer-rawaudio-format=s16le"
# htts_stream.py exit status for "audio was played, but the stream died or ran away".
STREAM_STATUS_PARTIAL=11
# Language and text of a first chunk whose stream ended early; it is rendered again for replay.
STREAM_REPAIR_LANG=""
STREAM_REPAIR_TEXT=""

# stream_helper — print the path of the streaming helper script.
# Args:    none
# Returns: 0 and the path on stdout; 1 when the file is missing (old or partial install)
# Globals: reads HTTS_PY_DIR, LIBDIR via py_helpers_dir
stream_helper() {
  local helper
  helper="$(py_helpers_dir)/htts_stream.py"
  # A missing file means the normal render, never a failed speak.
  [ -f "$helper" ] || return 1
  printf '%s' "$helper"
}

# stream_wanted — tell whether the first chunk of this run should be streamed.
# Args:    none
# Returns: 0 when streaming applies; 1 otherwise
# Globals: reads STREAM_FIRST_CHUNK, ENGINE_QWEN3_DISABLED, ENGINE, QWEN_DEVICE
stream_wanted() {
  # The setting is the master switch; anything but 1 keeps the classic path.
  [ "$STREAM_FIRST_CHUNK" = "1" ] || return 1
  # Piper is fast anyway and has no server; a written-off worker cannot stream either.
  [ "$(engine_active)" = "qwen3" ] && [ "$ENGINE_QWEN3_DISABLED" -eq 0 ] || return 1
  # CPU builds run slower than real time, so a live stream would stall and stutter.
  case "$(qwen3_device)" in CPU*) return 1 ;; esac
  # The helper needs Python and its own file; without either the normal path speaks.
  wav_python >/dev/null && stream_helper >/dev/null
}

# stream_write_body — write the streaming request into a private temporary file.
# Args:    $1 <text>; $2 <voice>; $3 <language code>; $4 <language name>
# Returns: 0 on success; 1 when no private directory exists; stdout: the file path
# Globals: reads QWEN_SEED (optional)
stream_write_body() {
  local body_file
  body_file="$(temp_file)" || return 1
  # Same generation cap as the file path, so a runaway ends at the same length.
  qwen3_request_json "$1" "$2" "$4" "$(qwen3_max_frames "$1" "$3")" "" pcm > "$body_file"
  printf '%s' "$body_file"
}

# stream_attach_entry — create the FIFO and queue it in mpv before any audio exists.
# Args:    $1 <entry path>
# Returns: 0 when mpv accepted the entry; 1 otherwise (no FIFO is left behind)
# Globals: reads STREAM_MPV_OPTIONS, MPV_SOCK
stream_attach_entry() {
  # mpv opens the FIFO at once and waits for the writer, so playback starts with the audio.
  mkfifo -m 600 "$1" || return 1
  if mpv_ipc "{\"command\":[\"loadfile\",\"$1\",\"append-play\",-1,\"$STREAM_MPV_OPTIONS\"]}" \
    >/dev/null; then
    return 0
  fi
  # A dead mpv would leave a FIFO nobody ever reads.
  rm -f "$1"
  return 1
}

# stream_run_helper — run the pump that feeds the FIFO and report its exit status.
# Args:    $1 <port>; $2 <request body file>; $3 <voice>; $4 <entry path>; $5 <max frames>
# Returns: the helper's status (0 ok, 10 no audio, 11 partial); 1 without Python
# Globals: reads NORMALIZE_LOUDNESS, STREAM_*_TIMEOUT, HTTS_STATE_DIR, RUN_DIR, voice gain_db
stream_run_helper() {
  local python helper gain status=0 flags=()
  # Both must exist; otherwise the caller drops the entry and renders the normal way.
  python="$(wav_python)" || return 1
  helper="$(stream_helper)" || return 1
  # Without loudness normalisation the stream is played and measured untouched.
  [ "${NORMALIZE_LOUDNESS:-1}" = "1" ] || flags+=(--no-gain)
  # The voice's calibrated gain_db (if any) replaces the blind default for its first sentence.
  if gain="$(voice_gain_db "$3")"; then flags+=(--default-gain-db "$gain"); fi
  # A direct child (not inside $(...)) so the daemon's cleanup can find and kill it.
  PYTHONPYCACHEPREFIX="$HTTS_CACHE_DIR/pycache" "$python" "$helper" stream "$4" \
    --port "$1" --body "$2" --voice "$3" --gains "$HTTS_STATE_DIR/stream-gain" \
    --runaway-seconds "$(qwen3_runaway_seconds "$5")" \
    --start-timeout "$STREAM_START_TIMEOUT" --idle-timeout "$STREAM_IDLE_TIMEOUT" \
    --request-timeout "$(qwen3_request_timeout)" "${flags[@]}" 2> "$RUN_DIR/stream.log" ||
    status=$?
  # The helper's one-line summary (latency, gain, reason of a failure) belongs in the log.
  worker_log "$(cat "$RUN_DIR/stream.log" 2>/dev/null || true)"
  return "$status"
}

# stream_drop_entry — remove a stream entry that never produced audio.
# Args:    $1 <entry path>
# Returns: 0 always
# Globals: reads MPV_SOCK
stream_drop_entry() {
  # The dead entry is the only one queued, and a stale one would break the completion count.
  mpv_ipc '{"command":["playlist-remove",0]}' >/dev/null || true
  rm -f "$1" "$1.part"
}

# stream_first_chunk — stream chunk 0 into mpv.
# Args:    $1 <language code>; $2 <text>
# Returns: 0 when an entry for the chunk is queued in mpv (complete or partial audio);
#          1 when nothing was queued and the caller must render the chunk normally
# Globals: reads RUN_DIR; writes the entry s00000.pcm below it
stream_first_chunk() {
  local entry="$RUN_DIR/s00000.pcm" target port voice language_name body_file status=0
  # Any unusable worker state is the normal path's business (it can restart the worker).
  target="$(qwen3_resolve_target "$1")" || return 1
  # The target is "<port>TAB<voice>TAB<language name>".
  IFS=$'\t' read -r port voice language_name <<< "$target"
  body_file="$(stream_write_body "$2" "$voice" "$1" "$language_name")" || return 1
  # From here on mpv waits on the FIFO, so every exit path must settle the entry.
  stream_attach_entry "$entry" || { rm -f "$body_file"; return 1; }
  # The in-flight mark keeps the idle timer from stopping the worker under a long stream.
  worker_request_begin
  worker_touch
  # The helper returns when the stream ended; its status says what mpv has heard.
  stream_run_helper "$port" "$body_file" "$voice" "$entry" "$(qwen3_max_frames "$2" "$1")" ||
    status=$?
  # The idle timer restarts now that the request is over.
  worker_touch
  worker_request_end
  # The request body holds the user's text and must not stay on disk.
  rm -f "$body_file"
  stream_settle "$status" "$entry" "$1" "$2"
}

# stream_settle — decide what the helper's exit status means for the playlist.
# Args:    $1 <helper status>; $2 <entry path>; $3 <language code>; $4 <text>
# Returns: 0 when the entry stays (it played, fully or partly); 1 when it was removed
# Globals: writes STREAM_REPAIR_LANG, STREAM_REPAIR_TEXT
stream_settle() {
  # A complete stream needs nothing more.
  if [ "$1" -eq 0 ]; then return 0; fi
  # Audio was heard but the stream ended early: keep it, and re-render the chunk for replay.
  if [ "$1" -eq "$STREAM_STATUS_PARTIAL" ]; then
    STREAM_REPAIR_LANG="$3"
    STREAM_REPAIR_TEXT="$4"
    # The entry stays in the playlist, so the caller counts it.
    return 0
  fi
  # Nothing was heard: take the dead entry out so the normal render can take its place.
  stream_drop_entry "$2"
  return 1
}

# stream_swap_entry — put a finished WAV in place of the first (partial) entry.
# Args:    $1 <wav path>
# Returns: 0 always (a skipped swap is harmless: the partial copy stays replayable)
# Globals: reads MPV_SOCK
stream_swap_entry() {
  # The entry being heard right now must not be pulled away.
  [ "$(mpv_get playlist-pos)" != "0" ] || return 0
  # Insert the new entry in front, then drop the old one that moved to index 1.
  mpv_ipc "{\"command\":[\"loadfile\",\"$1\",\"insert-at\",0]}" >/dev/null || return 0
  mpv_ipc '{"command":["playlist-remove",1]}' >/dev/null || true
}

# stream_repair_entry — replace a partial first chunk by a normally rendered one for replay.
# Args:    none
# Returns: 0 always
# Globals: reads STREAM_REPAIR_LANG, STREAM_REPAIR_TEXT, RUN_DIR
stream_repair_entry() {
  local wav="$RUN_DIR/s00000.wav"
  # Only a stream that ended early needs repair.
  [ -n "$STREAM_REPAIR_TEXT" ] || return 0
  # The normal render has its own retry and Piper safety net; a failure keeps the partial copy.
  engine_render "$STREAM_REPAIR_LANG" "$STREAM_REPAIR_TEXT" "$wav" || return 0
  stream_swap_entry "$wav"
}
