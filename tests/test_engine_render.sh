#!/usr/bin/env bash
# tests/test_engine_render.sh — qwen3 request building (language, voice, frame cap, escaping),
# error codes, per-chunk Piper fallback with a single notification, worker restart on demand.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# case_request_fields — language name, default voice, frame cap and wav format reach the server.
# Args:    none
# Returns: 0 always
# Globals: none
case_request_fields() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  lib_eval "qwen3_render de 'Hallo Welt.' '$TEST_ROOT/out.wav'"
  assert_rc 0 "$?" "render succeeds"
  assert_eq "ryan German 56" "$(test_speech_log)" "voice ryan, German, cap 11*3/2+40=56"
  assert_eq "RIFF" "$(head -c4 "$TEST_ROOT/out.wav")" "output is a RIFF wav"
  assert_contains "$(cat "$FAKE_TTS_LOG")" '"response_format": "wav"' "wav format requested"
}

# case_language_names — every supported code maps to the title-case name the server expects.
# Args:    none
# Returns: 0 always
# Globals: none
case_language_names() {
  local names
  names="$(lib_eval 'for l in de en fr es it pt ru zh ja ko; do qwen3_language_name $l; printf " "; done')"
  assert_eq "German English French Spanish Italian Portuguese Russian Chinese Japanese Korean " \
    "$names" "language names"
  lib_eval 'qwen3_language_name xx' >/dev/null 2>&1
  assert_rc 1 "$?" "unknown language rejected"
}

# case_frame_cap_scales_with_text — the generation cap grows with the text length.
# Args:    none
# Returns: 0 always
# Globals: none
case_frame_cap_scales_with_text() {
  assert_eq 40 "$(lib_eval "qwen3_max_frames ''")" "empty text -> 40 spare frames"
  assert_eq 49 "$(lib_eval "qwen3_max_frames 'Hallo.'")" "'Hallo.' capped at 49 frames (3.9 s)"
  assert_eq 400 "$(lib_eval "qwen3_max_frames \"\$(printf 'x%.0s' \$(seq 240))\"")" "240 chars -> 400"
}

# wav_peak — print the peak amplitude (0..1) of a 16-bit WAV file.
# Args:    $1 <wav path>
# Returns: 0 always; stdout: peak with two decimals
# Globals: none
wav_peak() {
  python3 -c 'import array,sys,wave
w=wave.open(sys.argv[1]); a=array.array("h"); a.frombytes(w.readframes(w.getnframes()))
print("%.2f" % (max(abs(x) for x in a)/32768))' "$1"
}

# case_silent_render_is_retried_with_new_seed — a silent reply is rejected and retried once.
# Args:    none
# Returns: 0 always
# Globals: none
case_silent_render_is_retried_with_new_seed() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  echo "silent_first=1" > "$FAKE_TTS_CONTROL"
  lib_eval "qwen3_render en 'Hello there.' '$TEST_ROOT/a.wav'"
  assert_rc 0 "$?" "second attempt succeeds"
  assert_eq 2 "$(test_event_count speech)" "exactly one retry"
  assert_contains "$(grep '"speech"' "$FAKE_TTS_LOG" | head -n1)" '"seed": null' "first try unseeded"
  assert_not_contains "$(grep '"speech"' "$FAKE_TTS_LOG" | tail -n1)" '"seed": null' "retry uses a new seed"
  assert_eq "0.13" "$(wav_peak "$TEST_ROOT/a.wav")" "the good audio was kept (and normalised)"
}

# case_two_silent_renders_fall_back_to_piper — no third try; Piper speaks the chunk.
# Args:    none
# Returns: 0 always
# Globals: none
case_two_silent_renders_fall_back_to_piper() {
  test_install_fake_engine
  test_add_piper_voice en
  htts engine start >/dev/null 2>&1
  echo "silent_first=2" > "$FAKE_TTS_CONTROL"
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  lib_eval "engine_render en 'Hello there.' '$TEST_ROOT/a.wav'"
  assert_rc 0 "$?" "chunk still rendered"
  assert_eq 2 "$(test_event_count speech)" "qwen3 tried twice only"
  assert_eq 1 "$(wc -l < "$FAKE_PIPER_LOG")" "piper took over"
}

# case_runaway_render_is_retried — audio far beyond the text length is rejected and retried.
# Args:    none
# Returns: 0 always
# Globals: none
case_runaway_render_is_retried() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  echo "long_first=1" > "$FAKE_TTS_CONTROL"
  lib_eval "qwen3_render en 'Short text.' '$TEST_ROOT/a.wav'"
  assert_rc 0 "$?" "retry after the runaway succeeds"
  assert_eq 2 "$(test_event_count speech)" "one retry"
  assert_contains "$(cat "$HYPRLAND_TTS_WORKER_DIR/worker.log")" "rejected by the audio check (status 4)" "logged"
}

# case_loudness_is_normalised — quiet and loud renders end up at about the same level.
# Args:    none
# Returns: 0 always
# Globals: none
case_loudness_is_normalised() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  echo "amp=0.10" > "$FAKE_TTS_CONTROL"
  lib_eval "qwen3_render en 'Quiet voice.' '$TEST_ROOT/quiet.wav'"
  echo "amp=0.30" > "$FAKE_TTS_CONTROL"
  lib_eval "qwen3_render en 'Loud voice.' '$TEST_ROOT/loud.wav'"
  assert_eq "$(wav_peak "$TEST_ROOT/loud.wav")" "$(wav_peak "$TEST_ROOT/quiet.wav")" "same peak after gain"
}

# case_normalisation_can_be_switched_off — NORMALIZE_LOUDNESS=0 leaves the audio untouched.
# Args:    none
# Returns: 0 always
# Globals: none
case_normalisation_can_be_switched_off() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  echo "amp=0.10" > "$FAKE_TTS_CONTROL"
  NORMALIZE_LOUDNESS=0 lib_eval "qwen3_render en 'Quiet voice.' '$TEST_ROOT/quiet.wav'"
  assert_eq "0.10" "$(wav_peak "$TEST_ROOT/quiet.wav")" "untouched when disabled"
}

# case_base_default_voice_sends_no_voice — a language without clone asks for the built-in voice.
# Args:    none
# Returns: 0 always
# Globals: none
case_base_default_voice_sends_no_voice() {
  test_install_fake_engine base
  htts engine start >/dev/null 2>&1
  lib_eval "qwen3_render pt 'Ola mundo.' '$TEST_ROOT/a.wav'"
  assert_rc 0 "$?" "render without a voice"
  assert_eq "None Portuguese 55" "$(test_speech_log)" "no voice member in the request"
}

# case_frame_cap_for_logographic_text — Chinese and Japanese get a larger cap per character.
# Args:    none
# Returns: 0 always
# Globals: none
case_frame_cap_for_logographic_text() {
  assert_eq 48 "$(lib_eval "qwen3_max_frames '你好' zh")" "zh: 4 frames per character"
  assert_eq 46 "$(lib_eval "qwen3_max_frames '你好' ko")" "ko: 3 frames per character"
  assert_eq "6.848" "$(lib_eval 'qwen3_runaway_seconds 107')" "80% of the cap's audio length"
}

# case_configured_voice_per_language — QWEN_VOICE_<lang> selects the preset per language.
# Args:    none
# Returns: 0 always
# Globals: none
case_configured_voice_per_language() {
  test_install_fake_engine
  test_set_config "QWEN_VOICE_de=aiden"
  htts engine start >/dev/null 2>&1
  lib_eval "qwen3_render de 'Hallo Welt.' '$TEST_ROOT/a.wav'; qwen3_render en 'Hello.' '$TEST_ROOT/b.wav'"
  assert_eq "aiden German 56
ryan English 49" "$(test_speech_log)" "de -> aiden, en -> default ryan"
}

# case_json_escaping — quotes, backslashes and newlines arrive exactly as typed.
# Args:    none
# Returns: 0 always
# Globals: none
case_json_escaping() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  lib_eval "qwen3_render en \$'say \"hi\" \\\\ now\nnext\ttab' '$TEST_ROOT/a.wav'"
  local received
  received="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    if e["event"]=="speech": print(repr(e["input"]))' "$FAKE_TTS_LOG")"
  assert_eq "'say \"hi\" \\\\ now\\nnext\\ttab'" "$received" "text round-trips through JSON"
}

# case_seed_only_when_configured — QWEN_SEED is forwarded when numeric.
# Args:    none
# Returns: 0 always
# Globals: none
case_seed_only_when_configured() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  lib_eval "qwen3_render en 'No seed.' '$TEST_ROOT/a.wav'"
  assert_contains "$(tail -n1 "$FAKE_TTS_LOG")" '"seed": null' "no seed by default"
  QWEN_SEED=42 lib_eval "qwen3_render en 'Seeded.' '$TEST_ROOT/b.wav'"
  assert_contains "$(tail -n1 "$FAKE_TTS_LOG")" '"seed": 42' "seed forwarded"
}

# case_server_error_is_status_1 — an HTTP 500 gives status 1 and no output file.
# Args:    none
# Returns: 0 always
# Globals: none
case_server_error_is_status_1() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  echo fail500 > "$FAKE_TTS_CONTROL"
  lib_eval "qwen3_render en 'Hello.' '$TEST_ROOT/a.wav'"
  assert_rc 1 "$?" "500 -> status 1"
  assert_no_file "$TEST_ROOT/a.wav" "no wav left behind"
  assert_no_file "$TEST_ROOT/a.wav.part" "no part file left behind"
}

# case_unreachable_worker_is_status_2 — without a worker the status tells the caller to restart.
# Args:    none
# Returns: 0 always
# Globals: none
case_unreachable_worker_is_status_2() {
  test_install_fake_engine
  lib_eval "qwen3_render en 'Hello.' '$TEST_ROOT/a.wav'"
  assert_rc 2 "$?" "no worker -> status 2"
}

# case_fallback_to_piper_notifies_once — failed chunks use Piper; one notification per run.
# Args:    none
# Returns: 0 always
# Globals: none
case_fallback_to_piper_notifies_once() {
  test_install_fake_engine
  test_add_piper_voice en
  htts engine start >/dev/null 2>&1
  echo fail500 > "$FAKE_TTS_CONTROL"
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  lib_eval "engine_render en 'First.' '$TEST_ROOT/a.wav'; engine_render en 'Second.' '$TEST_ROOT/b.wav'"
  assert_rc 0 "$?" "engine_render still succeeds"
  assert_file "$TEST_ROOT/a.wav" "first chunk rendered by piper"
  assert_eq 2 "$(wc -l < "$FAKE_PIPER_LOG")" "piper rendered both chunks"
  assert_eq 1 "$(wc -l < "$FAKE_NOTIFY_LOG")" "notified exactly once"
  assert_contains "$(cat "$FAKE_NOTIFY_LOG")" "Falling back to Piper" "notification text"
}

# case_fallback_per_chunk_recovers — qwen3 serves again as soon as the server does.
# Args:    none
# Returns: 0 always
# Globals: none
case_fallback_per_chunk_recovers() {
  test_install_fake_engine
  test_add_piper_voice en
  htts engine start >/dev/null 2>&1
  echo fail500 > "$FAKE_TTS_CONTROL"
  lib_eval "engine_render en 'Bad one.' '$TEST_ROOT/a.wav'"
  echo ok > "$FAKE_TTS_CONTROL"
  : > "$FAKE_PIPER_LOG"
  lib_eval "engine_render en 'Good one.' '$TEST_ROOT/b.wav'"
  assert_eq 0 "$(wc -l < "$FAKE_PIPER_LOG")" "later chunk went to qwen3 again"
}

# case_dead_worker_is_restarted_on_demand — a vanished worker is restarted for the next chunk.
# Args:    none
# Returns: 0 always
# Globals: none
case_dead_worker_is_restarted_on_demand() {
  test_install_fake_engine
  htts engine start >/dev/null 2>&1
  kill -KILL "$(test_worker_pid)" "$(cat "$HYPRLAND_TTS_WORKER_DIR/server.pid")"
  sleep 0.3
  lib_eval "engine_render en 'After the crash.' '$TEST_ROOT/a.wav'"
  assert_rc 0 "$?" "chunk rendered after restart"
  assert_eq 2 "$(test_event_count start)" "a second server was started"
  assert_eq 1 "$(test_event_count speech)" "the chunk was served by qwen3, not piper"
}

# case_unstartable_worker_disables_qwen3_for_the_run — no restart storm; piper takes over.
# Args:    none
# Returns: 0 always
# Globals: none
case_unstartable_worker_disables_qwen3_for_the_run() {
  test_install_fake_engine
  test_add_piper_voice en
  export FAKE_TTS_BAD_DEVICE=any
  mkdir -p "$HYPRLAND_TTS_RUN_DIR"
  lib_eval "engine_prepare || true; engine_render en 'One.' '$TEST_ROOT/a.wav'
    engine_render en 'Two.' '$TEST_ROOT/b.wav'"
  assert_rc 0 "$?" "both chunks rendered by the fallback"
  assert_eq 2 "$(wc -l < "$FAKE_PIPER_LOG")" "piper rendered both"
  local starts; starts="$(test_event_count start)"
  # Vulkan0 + CPU, three attempts each, once: six at most, never a second round.
  [ "$starts" -le 6 ] && test_pass "no restart storm ($starts server starts)" ||
    test_fail "no restart storm" "($starts server starts)"
}

test_run_cases
