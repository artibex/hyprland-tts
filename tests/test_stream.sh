#!/usr/bin/env bash
# tests/test_stream.sh — streaming of the first chunk: time to first audio, FIFO lifecycle, replay,
# stop, stall/silence/death/runaway fallbacks, speed, loudness learning and the off switch.
# Real mpv (--ao=null wrapper) and the fake tts-server that streams PCM slowly on demand.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

ONE_SENTENCE='Das ist der erste Satz und er ist nicht lang.'
TWO_PARAGRAPHS='Das ist der erste Satz und er ist nicht lang.

This is the second paragraph and it is in English.'
# Bytes of one fake frame (80 ms of 24 kHz s16le audio).
FRAME_BYTES=3840

# mpv_prop — read one property of the running mpv (empty when unavailable).
# Args:    $1 <property name>
# Returns: 0 always; stdout: the value
# Globals: reads HYPRLAND_TTS_RUN_DIR
mpv_prop() {
  printf '{"command":["get_property","%s"]}\n' "$1" |
    socat -T0.3 - "UNIX-CONNECT:$HYPRLAND_TTS_RUN_DIR/mpv.sock" 2>/dev/null |
    sed -n 's/.*"data":\("[^"]*"\|[^,}]*\).*/\1/p' | head -n1
}

# audio_playing — succeed once mpv's playback position moved (sound is coming out).
# Args:    none
# Returns: 0 when time-pos is above 50 ms; 1 otherwise
# Globals: none
audio_playing() { awk -v t="$(mpv_prop time-pos)" 'BEGIN{exit !(t + 0 > 0.05)}'; }

# queued_in_mpv — succeed once at least one playlist entry exists.
# Args:    none
# Returns: 0 when playlist-count is positive; 1 otherwise
# Globals: none
queued_in_mpv() { awk -v n="$(mpv_prop playlist-count)" 'BEGIN{exit !(n + 0 > 0)}'; }

# seconds_until — poll a command and report how long it took to succeed.
# Args:    $1 <start time from date +%s.%N>; $2 <timeout seconds>; $3.. <command>
# Returns: 0 always; stdout: elapsed seconds, or "never" on timeout
# Globals: none
seconds_until() {
  local start="$1" limit="$2" waited=0
  shift 2
  # 20 ms polling: the figures of interest are fractions of a second.
  while [ "$waited" -lt $(( limit * 50 )) ]; do
    "$@" && { awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b - a}'; return 0; }
    sleep 0.02
    waited=$((waited + 1))
  done
  printf 'never'
}

# below — compare two decimal numbers.
# Args:    $1 <value>; $2 <limit>
# Returns: 0 when value < limit; 1 otherwise (also for non-numbers)
# Globals: none
below() { awk -v v="$1" -v l="$2" 'BEGIN{exit !(v != "never" && v + 0 < l + 0)}'; }

# daemon_gone — succeed once no player daemon is alive.
# Args:    none
# Returns: 0 when the daemon has exited; 1 otherwise
# Globals: reads HYPRLAND_TTS_RUN_DIR
daemon_gone() { ! kill -0 "$(cat "$HYPRLAND_TTS_RUN_DIR/daemon.pid" 2>/dev/null)" 2>/dev/null; }

# stream_helper_alive — succeed while a streaming helper of this sandbox runs.
# Args:    none
# Returns: 0 when one is alive; 1 otherwise
# Globals: reads TEST_ROOT
stream_helper_alive() { pgrep -f -- "$TEST_ROOT/lib/py/htts_stream.py" >/dev/null; }

# speak_text_now — put text on the fake selection and run speak.
# Args:    $1 <text>
# Returns: 0 always
# Globals: reads FAKE_SELECTION
speak_text_now() {
  printf '%s' "$1" > "$FAKE_SELECTION"
  htts speak >/dev/null 2>&1
}

# finished — succeed once the daemon of the last speak is done and gone.
# Args:    none
# Returns: 0 when finished; 1 otherwise
# Globals: reads HYPRLAND_TTS_RUN_DIR
finished() { [ -f "$HYPRLAND_TTS_RUN_DIR/render.done" ] && [ ! -f "$HYPRLAND_TTS_RUN_DIR/daemon.pid" ]; }

# request_formats — list the response formats the fake server was asked for, in order.
# Args:    none
# Returns: 0 always; stdout: e.g. "pcm wav"
# Globals: reads FAKE_TTS_LOG
request_formats() {
  [ -f "$FAKE_TTS_LOG" ] || return 0
  python3 -c 'import json, sys
print(" ".join(e["response_format"] for e in map(json.loads, open(sys.argv[1])) if e["event"] == "speech"))' \
    "$FAKE_TTS_LOG"
}

# pcm_rms_db — print the speech loudness (RMS in dBFS) of a raw s16le file.
# Args:    $1 <file>
# Returns: 0 always; stdout: dB with one decimal
# Globals: none
pcm_rms_db() {
  python3 -c 'import array, math, sys
a = array.array("h"); a.frombytes(open(sys.argv[1], "rb").read())
print("%.1f" % (10 * math.log10(sum(v * v for v in a) / len(a) / 32768.0 ** 2)))' "$1"
}

# case_first_audio_precedes_end_of_synthesis — speech starts while the server still generates.
# Args:    none
# Returns: 0 always
# Globals: none
case_first_audio_precedes_end_of_synthesis() {
  test_install_fake_engine
  # 50 frames at 0.1 s: the whole chunk takes 5 s to synthesize.
  echo "dur=4 pcm_first=0.1 pcm_gap=0.1" > "$FAKE_TTS_CONTROL"
  local start appended heard
  start="$(date +%s.%N)"
  speak_text_now "$ONE_SENTENCE"
  appended="$(seconds_until "$start" 8 queued_in_mpv)"
  heard="$(seconds_until "$start" 8 audio_playing)"
  below "$appended" 1.5 && test_pass "first append ${appended}s after speak" ||
    test_fail "first append within 1.5 s" "(took $appended)"
  below "$heard" 3 && test_pass "audio started ${heard}s after speak" ||
    test_fail "audio within 3 s although synthesis takes 5 s" "(took $heard)"
  assert_eq 0 "$(test_event_count stream_end)" "synthesis was still running when speech began"
  assert_eq "pcm" "$(request_formats)" "one streamed request, no file request"
}

# case_classic_path_waits_for_the_whole_chunk — with the switch off the first append is late.
# Args:    none
# Returns: 0 always
# Globals: none
case_classic_path_waits_for_the_whole_chunk() {
  test_install_fake_engine
  test_set_config "STREAM_FIRST_CHUNK=0"
  echo "slow=2" > "$FAKE_TTS_CONTROL"
  local start appended
  start="$(date +%s.%N)"
  speak_text_now "$ONE_SENTENCE"
  appended="$(seconds_until "$start" 10 queued_in_mpv)"
  below "$appended" 2 && test_fail "classic first append waits for the render" "(took $appended)" ||
    test_pass "classic first append after ${appended}s"
  test_wait_until 20 finished
  assert_eq "wav" "$(request_formats)" "only file requests"
  assert_file "$HYPRLAND_TTS_RUN_DIR/s00000.wav" "wav entry as before"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/s00000.pcm" "no streamed entry"
}

# case_fifo_becomes_a_regular_file — the entry is a FIFO while streaming and a file afterwards.
# Args:    none
# Returns: 0 always
# Globals: none
case_fifo_becomes_a_regular_file() {
  test_install_fake_engine
  echo "dur=3 pcm_gap=0.1" > "$FAKE_TTS_CONTROL"
  local entry="$HYPRLAND_TTS_RUN_DIR/s00000.pcm" frames
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 8 audio_playing
  [ -p "$entry" ] && test_pass "entry is a FIFO while streaming" ||
    test_fail "entry is a FIFO while streaming"
  test_wait_until 20 finished
  frames="$(grep -o '"stream_end", "frames": [0-9]*' "$FAKE_TTS_LOG" | grep -o '[0-9]*$')"
  [ -f "$entry" ] && [ ! -p "$entry" ] && test_pass "entry is a regular file afterwards" ||
    test_fail "entry is a regular file afterwards"
  assert_eq "$((frames * FRAME_BYTES))" "$(stat -c %s "$entry")" "copy holds every streamed byte"
  assert_no_file "$entry.part" "no partial file left"
  assert_eq 1 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "completion count is one entry"
}

# case_replay_of_first_chunk_after_stream — prev and restart read the finished copy.
# Args:    none
# Returns: 0 always
# Globals: none
case_replay_of_first_chunk_after_stream() {
  test_install_fake_engine
  echo "dur=2 pcm_gap=0.02" > "$FAKE_TTS_CONTROL"
  speak_text_now "$TWO_PARAGRAPHS"
  # Chunk 1 only plays after chunk 0 ended, so its position proves the stream completed.
  test_wait_until 15 test_at_second_chunk
  htts ctl prev; sleep 0.5
  assert_contains "$(htts ctl status)" "pos=0/2" "prev returned to the streamed chunk"
  assert_contains "$(mpv_prop path)" "s00000.pcm" "mpv replays the finished copy"
  below "$(mpv_prop time-pos)" 1.5 && audio_playing && test_pass "replay is playing from the start" ||
    test_fail "replay is playing from the start" "(time-pos $(mpv_prop time-pos))"
  below 1.9 "$(mpv_prop duration)" && test_pass "replay knows its full length" ||
    test_fail "replay knows its full length" "(duration $(mpv_prop duration))"
  sleep 0.8
  htts ctl restart; sleep 0.4
  below "$(mpv_prop time-pos)" 0.9 && test_pass "restart seeks back to the start" ||
    test_fail "restart seeks back to the start" "(time-pos $(mpv_prop time-pos))"
}

# test_at_second_chunk — succeed once mpv plays the second playlist entry.
# Args:    none
# Returns: 0 when pos=1/2 is reported; 1 otherwise
# Globals: none
test_at_second_chunk() { [[ "$(htts ctl status)" == *"pos=1/2"* ]]; }

# case_stop_during_stream_leaves_nothing — no helper, no FIFO, no partial copy; the server is freed.
# Args:    none
# Returns: 0 always
# Globals: none
case_stop_during_stream_leaves_nothing() {
  test_install_fake_engine
  echo "dur=20 pcm_gap=0.1" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 8 audio_playing
  stream_helper_alive && test_pass "helper streaming before stop" || test_fail "helper streaming before stop"
  htts stop >/dev/null 2>&1
  test_wait_until 5 daemon_gone
  assert_rc 0 "$?" "daemon gone"
  ! stream_helper_alive && test_pass "no helper process left" || test_fail "no helper process left"
  assert_eq "" "$(find "$HYPRLAND_TTS_RUN_DIR" -type p)" "no FIFO left"
  assert_eq "" "$(find "$HYPRLAND_TTS_RUN_DIR" -name '*.part')" "no partial copy left"
  test_wait_until 5 grep -q stream_client_gone "$FAKE_TTS_LOG"
  assert_rc 0 "$?" "server saw the disconnect and stopped generating"
}

# case_stalled_stream_falls_back_once — no first byte: the normal render plays, one entry only.
# Args:    none
# Returns: 0 always
# Globals: none
case_stalled_stream_falls_back_once() {
  test_install_fake_engine
  test_set_config "STREAM_START_TIMEOUT=1"
  # The server holds the stream for 30 s before sending anything.
  echo "pcm_first=30 dur=1" > "$FAKE_TTS_CONTROL"
  local max_count=0 count
  speak_text_now "$ONE_SENTENCE"
  # Sample the playlist size until the daemon is done: a double play would need a second entry.
  for _ in $(seq 1 300); do
    finished && break
    count="$(mpv_prop playlist-count)"
    [ "${count:-0}" -le "$max_count" ] || max_count="$count"
    sleep 0.1
  done
  assert_rc 0 "$(finished; echo $?)" "daemon finished"
  assert_eq "pcm wav" "$(request_formats)" "stream attempt, then the normal request"
  assert_eq 1 "$max_count" "the playlist never held more than one entry"
  assert_eq 1 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "one chunk counted"
  assert_file "$HYPRLAND_TTS_RUN_DIR/s00000.wav" "fallback wav exists"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/s00000.pcm" "dead stream entry removed"
  assert_contains "$(cat "$HYPRLAND_TTS_WORKER_DIR/worker.log")" "no audio" "reason logged"
}

# case_silent_stream_falls_back — an all-zero stream is never played; the file render takes over.
# Args:    none
# Returns: 0 always
# Globals: none
case_silent_stream_falls_back() {
  test_install_fake_engine
  # Only the first request (the stream) is silent; the fallback request is normal.
  echo "silent_first=1 dur=1.6" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_eq "pcm wav" "$(request_formats)" "silent stream, then the normal request"
  assert_file "$HYPRLAND_TTS_RUN_DIR/s00000.wav" "audible fallback wav"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/s00000.pcm" "silent stream entry removed"
  assert_eq 1 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "one chunk counted"
}

# case_dying_stream_is_repaired_for_replay — a cut stream is heard once; replay gets a full render.
# Args:    none
# Returns: 0 always
# Globals: none
case_dying_stream_is_repaired_for_replay() {
  test_install_fake_engine
  echo "pcm_die=0.4 dur=3" > "$FAKE_TTS_CONTROL"
  speak_text_now "$TWO_PARAGRAPHS"
  test_wait_until 8 audio_playing
  # Slow file renders keep mpv on chunk 1 while the repair of chunk 0 finishes.
  echo "slow=1.5 dur=3" > "$FAKE_TTS_CONTROL"
  test_wait_until 15 test_first_entry_is_wav
  assert_rc 0 "$?" "entry 0 was swapped for a normally rendered wav"
  assert_eq 2 "$(mpv_prop playlist-count)" "the swap kept the playlist size"
  test_wait_until 20 finished
  assert_eq "pcm wav wav" "$(request_formats)" "chunk 0 streamed once, chunk 1 and the repair as files"
  assert_eq 2 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "both chunks counted"
  assert_eq "$((5 * FRAME_BYTES))" "$(stat -c %s "$HYPRLAND_TTS_RUN_DIR/s00000.pcm")" \
    "the partial copy holds the 0.4 s that were played"
  assert_contains "$(cat "$HYPRLAND_TTS_WORKER_DIR/worker.log")" "partial" "partial stream logged"
}

# test_first_entry_is_wav — succeed once the first playlist entry is a rendered wav.
# Args:    none
# Returns: 0 when playlist entry 0 ends in .wav; 1 otherwise
# Globals: none
test_first_entry_is_wav() { [[ "$(mpv_prop playlist/0/filename)" == *s00000.wav* ]]; }

# case_runaway_stream_is_cut — a never-ending stream stops at the runaway limit.
# Args:    none
# Returns: 0 always
# Globals: none
case_runaway_stream_is_cut() {
  test_install_fake_engine
  # The server would stream 40 s; the cap for this text allows about 6.9 s.
  echo "long_first=1 pcm_gap=0.01" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 30 finished
  local size; size="$(stat -c %s "$HYPRLAND_TTS_RUN_DIR/s00000.pcm")"
  below "$size" 400000 && test_pass "stream cut at the limit ($size bytes)" ||
    test_fail "stream cut at the limit" "($size bytes)"
  below 300000 "$size" && test_pass "most of the allowed length was kept" ||
    test_fail "most of the allowed length was kept" "($size bytes)"
  test_wait_until 5 grep -q stream_client_gone "$FAKE_TTS_LOG"
  assert_rc 0 "$?" "server told to stop generating"
  assert_contains "$(cat "$HYPRLAND_TTS_WORKER_DIR/worker.log")" "runaway" "runaway logged"
  assert_eq "pcm wav" "$(request_formats)" "a normal render was made for replay"
}

# case_speed_change_during_stream — faster/slower act on the streamed entry; the stream completes.
# Args:    none
# Returns: 0 always
# Globals: none
case_speed_change_during_stream() {
  test_install_fake_engine
  echo "dur=6 pcm_gap=0.1" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 8 audio_playing
  htts ctl faster; sleep 0.3
  assert_contains "$(htts ctl status)" "speed=1.2" "faster while streaming"
  audio_playing && test_pass "still playing after the speed change" ||
    test_fail "still playing after the speed change"
  htts ctl slower; sleep 0.3
  assert_contains "$(htts ctl status)" "speed=1" "slower while streaming"
  test_wait_until 30 finished
  assert_eq "$((75 * FRAME_BYTES))" "$(stat -c %s "$HYPRLAND_TTS_RUN_DIR/s00000.pcm")" \
    "the stream was not disturbed by the speed changes"
}

# case_loudness_is_learned_per_voice — the second speak lands on the target loudness.
# Args:    none
# Returns: 0 always
# Globals: none
case_loudness_is_learned_per_voice() {
  test_install_fake_engine
  # A quiet voice: the raw speech sits near -29 dBFS, so 8 dB bring it to the -21 dB target.
  echo "amp=0.05 dur=1.5 pcm_gap=0.01" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  local first second gains="$XDG_STATE_HOME/hyprland-tts/stream-gain"
  first="$(pcm_rms_db "$HYPRLAND_TTS_RUN_DIR/s00000.pcm")"
  assert_contains "$(cat "$gains")" "ryan	8.0" "measured gain stored for the voice"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  second="$(pcm_rms_db "$HYPRLAND_TTS_RUN_DIR/s00000.pcm")"
  below "$first" -22 && test_pass "first use plays with the default gain ($first dB)" ||
    test_fail "first use plays with the default gain" "($first dB)"
  awk -v v="$second" 'BEGIN{exit !(v > -21.6 && v < -20.4)}' &&
    test_pass "second use reaches the target ($second dB)" ||
    test_fail "second use reaches the target" "($second dB)"
}

# make_calibrated_voice — install a shipped German clone, optionally with a gain_db file.
# Args:    $1 <voice name>; $2 <gain_db content, empty for none>
# Returns: 0 always
# Globals: reads TEST_ROOT; exports HYPRLAND_TTS_SYSTEM_VOICES
make_calibrated_voice() {
  export HYPRLAND_TTS_SYSTEM_VOICES="$TEST_ROOT/shipped"
  mkdir -p "$TEST_ROOT/shipped/$1"
  printf 's' > "$TEST_ROOT/shipped/$1/ref.spk"
  printf 'r' > "$TEST_ROOT/shipped/$1/ref.rvq"
  [ -z "$2" ] || printf '%s\n' "$2" > "$TEST_ROOT/shipped/$1/gain_db"
}

# stream_log_gain — print the gain (e.g. +8.0dB) the last streaming helper reported.
# Args:    none
# Returns: 0 always; stdout: the gain figure, empty when none was logged
# Globals: reads HYPRLAND_TTS_RUN_DIR
stream_log_gain() {
  sed -n 's/.*gain=\([-+][0-9.]*dB\).*/\1/p' "$HYPRLAND_TTS_RUN_DIR/stream.log" 2>/dev/null | head -n1
}

# case_calibrated_gain_makes_the_first_sentence_loud_enough — gain_db replaces the +6 dB guess.
# Args:    none
# Returns: 0 always
# Globals: none
case_calibrated_gain_makes_the_first_sentence_loud_enough() {
  test_install_fake_engine "base"
  make_calibrated_voice de-quiet "8.0"
  # Raw speech near -29 dBFS: 8 dB reach the -21 dB target at once, +6 dB would leave -23 dB.
  echo "amp=0.05 dur=1.5 pcm_gap=0.01" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  local first
  first="$(pcm_rms_db "$HYPRLAND_TTS_RUN_DIR/s00000.pcm")"
  awk -v v="$first" 'BEGIN{exit !(v > -21.6 && v < -20.4)}' &&
    test_pass "first use of a calibrated voice is on target ($first dB)" ||
    test_fail "first use of a calibrated voice is on target" "($first dB)"
  assert_eq "+8.0dB" "$(stream_log_gain)" "the helper applied the voice's gain_db"
}

# case_voice_without_gain_db_keeps_the_builtin_default — user and old voices still work.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_without_gain_db_keeps_the_builtin_default() {
  test_install_fake_engine "base"
  make_calibrated_voice de-plain ""
  echo "amp=0.05 dur=1.5 pcm_gap=0.01" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_eq "+6.0dB" "$(stream_log_gain)" "no gain_db: the +6 dB default"
  assert_eq "pcm" "$(request_formats)" "and the chunk was still streamed"
  # A malformed gain_db is ignored in the same way.
  printf 'loud\n' > "$TEST_ROOT/shipped/de-plain/gain_db"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_contains "$(cat "$XDG_STATE_HOME/hyprland-tts/stream-gain")" "de-plain" "gain learned as usual"
}

# case_learned_gain_beats_the_calibrated_one — the machine's own measurement wins.
# Args:    none
# Returns: 0 always
# Globals: none
case_learned_gain_beats_the_calibrated_one() {
  test_install_fake_engine "base"
  make_calibrated_voice de-quiet "12.0"
  mkdir -p "$XDG_STATE_HOME/hyprland-tts"
  printf 'de-quiet\t3.0\n' > "$XDG_STATE_HOME/hyprland-tts/stream-gain"
  echo "amp=0.05 dur=1.5 pcm_gap=0.01" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_eq "+3.0dB" "$(stream_log_gain)" "learned +3 dB used instead of the calibrated +12 dB"
}

# case_cpu_engine_does_not_stream — a CPU build (slower than real time) keeps the file path.
# Args:    none
# Returns: 0 always
# Globals: none
case_cpu_engine_does_not_stream() {
  test_install_fake_engine
  printf 'BUILD=cpu\nDEVICE=CPU\n' > "$(test_engine_tree)/engine.conf"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_eq "wav" "$(request_formats)" "no streamed request on CPU"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/s00000.pcm" "no streamed entry"
}

# case_piper_never_streams — Piper is one-shot and fast; no FIFO and no helper are involved.
# Args:    none
# Returns: 0 always
# Globals: none
case_piper_never_streams() {
  test_add_piper_voice de
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_file "$HYPRLAND_TTS_RUN_DIR/s00000.wav" "piper wav as before"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/s00000.pcm" "no streamed entry"
  assert_no_file "$HYPRLAND_TTS_RUN_DIR/stream.log" "helper never ran"
}

# case_off_switch_and_missing_helper_keep_the_classic_path — both fall back silently.
# Args:    none
# Returns: 0 always
# Globals: none
case_off_switch_and_missing_helper_keep_the_classic_path() {
  test_install_fake_engine
  rm -f "$TEST_LIB/py/htts_stream.py"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_eq "wav" "$(request_formats)" "no stream without the helper file"
  assert_file "$HYPRLAND_TTS_RUN_DIR/s00000.wav" "normal entry"
}

# case_second_speak_replaces_a_running_stream — a new speak ends the old stream cleanly.
# Args:    none
# Returns: 0 always
# Globals: none
case_second_speak_replaces_a_running_stream() {
  test_install_fake_engine
  echo "dur=20 pcm_gap=0.1" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 8 audio_playing
  echo "dur=1 pcm_gap=0.01" > "$FAKE_TTS_CONTROL"
  speak_text_now "$ONE_SENTENCE"
  test_wait_until 20 finished
  assert_eq 1 "$(cat "$HYPRLAND_TTS_RUN_DIR/render.count")" "new document counted"
  ! stream_helper_alive && test_pass "old helper is gone" || test_fail "old helper is gone"
  assert_eq "" "$(find "$HYPRLAND_TTS_RUN_DIR" -type p)" "no FIFO left"
}

test_run_cases
