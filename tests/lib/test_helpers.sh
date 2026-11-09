#!/usr/bin/env bash
# tests/lib/test_helpers.sh — shared helpers for the bash test suite: assertions, an isolated
# HOME/XDG sandbox, a fakebin directory (mpv with --ao=null, fake piper/notify-send/wl-paste/
# build tools), a fake Qwen3 engine install and small log readers. Never touches real dirs.

TEST_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_PASS=0
TEST_FAIL=0
TEST_ROOT=""

# test_pass — record a passing assertion.
# Args:    $1 <description>
# Returns: 0 always
# Globals: writes TEST_PASS
test_pass() { TEST_PASS=$((TEST_PASS + 1)); printf '  PASS: %s\n' "$1"; }

# test_fail — record a failing assertion.
# Args:    $1 <description>; $2 <detail, optional>
# Returns: 0 always
# Globals: writes TEST_FAIL
test_fail() { TEST_FAIL=$((TEST_FAIL + 1)); printf '  FAIL: %s %s\n' "$1" "${2:-}"; }

# assert_eq — compare two strings.
# Args:    $1 <expected>; $2 <actual>; $3 <description>
# Returns: 0 always
# Globals: none
assert_eq() {
  if [ "$1" = "$2" ]; then test_pass "$3"; else test_fail "$3" "(expected '$1', got '$2')"; fi
}

# assert_contains — check that a text contains a substring.
# Args:    $1 <haystack>; $2 <needle>; $3 <description>
# Returns: 0 always
# Globals: none
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then test_pass "$3"; else test_fail "$3" "(missing '$2' in '${1:0:300}')"; fi
}

# assert_not_contains — check that a text lacks a substring.
# Args:    $1 <haystack>; $2 <needle>; $3 <description>
# Returns: 0 always
# Globals: none
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then test_pass "$3"; else test_fail "$3" "(unexpected '$2')"; fi
}

# assert_file — check that a file exists and is non-empty.
# Args:    $1 <path>; $2 <description>
# Returns: 0 always
# Globals: none
assert_file() {
  if [ -s "$1" ]; then test_pass "$2"; else test_fail "$2" "(no non-empty file $1)"; fi
}

# assert_no_file — check that a path does not exist.
# Args:    $1 <path>; $2 <description>
# Returns: 0 always
# Globals: none
assert_no_file() {
  if [ ! -e "$1" ]; then test_pass "$2"; else test_fail "$2" "(unexpected $1)"; fi
}

# assert_rc — check an exit status.
# Args:    $1 <expected status>; $2 <actual status>; $3 <description>
# Returns: 0 always
# Globals: none
assert_rc() { assert_eq "$1" "$2" "$3 (exit status)"; }

# test_wait_until — poll a command until it succeeds or the timeout passes.
# Args:    $1 <timeout seconds>; $2.. <command>
# Returns: 0 when the command succeeded in time; 1 on timeout
# Globals: none
test_wait_until() {
  local limit=$(( $1 * 10 )) waited=0
  shift
  while [ "$waited" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# test_make_fakebin — write the fake executables into $TEST_ROOT/fakebin.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT; writes files only below it
test_make_fakebin() {
  local bin="$TEST_ROOT/fakebin" real_mpv
  real_mpv="$(command -v mpv)"
  mkdir -p "$bin"
  # mpv keeps real IPC/playlist semantics but never opens an audio device.
  printf '#!/bin/sh\nexec "%s" --ao=null "$@"\n' "$real_mpv" > "$bin/mpv"
  # Piper: log the call, then copy a valid WAV unless FAKE_PIPER_FAIL names an existing file.
  cat > "$bin/piper-tts" <<'FAKE'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in --model) model="$2"; shift ;; --output_file) out="$2"; shift ;; esac
  shift
done
text="$(cat)"
printf '%s\t%s\n' "$model" "$text" >> "$FAKE_PIPER_LOG"
[ ! -e "${FAKE_PIPER_FAIL:-/nonexistent}" ] || exit 1
cp "$FAKE_WAV" "$out"
FAKE
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$FAKE_NOTIFY_LOG"\n' > "$bin/notify-send"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\ncat "$FAKE_SELECTION"\n' > "$bin/wl-paste"
  # Build tools only need to exist for the dependency check; cmake and git get real fakes later.
  printf '#!/bin/sh\nexit 0\n' > "$bin/gcc"
  cp "$bin/gcc" "$bin/g++"
  cp "$bin/gcc" "$bin/make"
  chmod +x "$bin"/*
}

# test_make_fake_codec — write a fake qwen-codec that encodes by writing marker latents.
# Args:    $1 <destination path>
# Returns: 0 always
# Globals: none
test_make_fake_codec() {
  cat > "$1" <<'FAKE'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -i) input="$2"; shift ;; --talker) talker="$2"; shift ;; esac
  shift
done
printf 'codec %s talker=%s\n' "$input" "$talker" >> "$FAKE_CODEC_LOG"
grep -q BADWAV "$input" && exit 1
printf 'rvq-latents' > "${input%.wav}.rvq"
printf 'spk-latents' > "${input%.wav}.spk"
FAKE
  chmod +x "$1"
}

# test_setup — create an isolated sandbox and export the environment for one test case.
# Args:    none
# Returns: 0 always
# Globals: writes TEST_ROOT and the exported sandbox variables
test_setup() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/htts-test-XXXXXX")"
  export HOME="$TEST_ROOT/home" XDG_DATA_HOME="$TEST_ROOT/data" XDG_CONFIG_HOME="$TEST_ROOT/config"
  export XDG_STATE_HOME="$TEST_ROOT/state"
  export HYPRLAND_TTS_RUN_DIR="$TEST_ROOT/run" HYPRLAND_TTS_WORKER_DIR="$TEST_ROOT/worker"
  export FAKE_TTS_LOG="$TEST_ROOT/fake-tts.jsonl" FAKE_TTS_CONTROL="$TEST_ROOT/fake-tts.control"
  export FAKE_PIPER_LOG="$TEST_ROOT/piper.log" FAKE_NOTIFY_LOG="$TEST_ROOT/notify.log"
  export FAKE_CODEC_LOG="$TEST_ROOT/codec.log" FAKE_SELECTION="$TEST_ROOT/selection.txt"
  export FAKE_WAV="$TEST_ROOT/fake.wav" QWEN_START_TIMEOUT=20 HTTS_KEEP_AUDIO=1
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
  # Forget any engine settings of the calling environment.
  unset ENGINE QWEN_VARIANT QWEN_DEVICE QWEN_SEED WORKER_IDLE_MINUTES WORKER_IDLE_SECONDS
  unset FAKE_TTS_BAD_DEVICE FAKE_TTS_STARTUP_DELAY HYPRLAND_TTS_SYSTEM_VOICES HTTS_QWEN_ASSET_BASE
  unset HTTS_TEST_ASSET_TABLE
  # The fake server module already knows how to build a valid WAV; reuse it for Piper's output.
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fake_tts_server as f
open(sys.argv[2], "wb").write(f.make_wav())' "$TEST_REPO_DIR/tests/lib" "$FAKE_WAV"
  test_make_fakebin
  test_make_scratch_lib
  export PATH="$TEST_ROOT/fakebin:$PATH"
}

# test_make_scratch_lib — copy lib/ and add the router shim when the router lacks the contract.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT, TEST_REPO_DIR; exports TEST_LIB and HYPRLAND_TTS_LIB
test_make_scratch_lib() {
  export TEST_LIB="$TEST_ROOT/lib" HYPRLAND_TTS_LIB="$TEST_ROOT/lib"
  cp -r "$TEST_REPO_DIR/lib" "$TEST_LIB"
  # Once package 2's router defines prepare_chunks the shim is no longer needed.
  grep -q '^prepare_chunks()' "$TEST_LIB/router.sh" ||
    cat "$TEST_REPO_DIR/tests/lib/router_shim.sh" >> "$TEST_LIB/router.sh"
}

# test_teardown — stop everything the case started and delete the sandbox.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT
test_teardown() {
  [ -n "$TEST_ROOT" ] || return 0
  htts engine stop >/dev/null 2>&1
  htts stop >/dev/null 2>&1
  # Anything still alive that mentions the sandbox path (fake servers, mpv) is ours.
  pkill -KILL -f -- "$TEST_ROOT" 2>/dev/null
  rm -rf -- "$TEST_ROOT"
  TEST_ROOT=""
}

# htts — run the real dispatcher inside the sandbox.
# Args:    $1.. <hyprland-tts arguments>
# Returns: the command's exit status
# Globals: reads TEST_REPO_DIR
htts() { "$TEST_REPO_DIR/bin/hyprland-tts" "$@"; }

# lib_eval — run shell code in a fresh bash that has every module sourced and config loaded.
# Args:    $1 <code to eval>
# Returns: the code's exit status; stdout/stderr pass through
# Globals: reads TEST_LIB, TEST_REPO_DIR
lib_eval() {
  bash -c 'set -euo pipefail; LIBDIR="$1"; HTTS_SELF="$2/bin/hyprland-tts"
    source "$LIBDIR/common.sh"
    for m in text router model image keybind engine qwen3 qwen3_install worker voices pyenv stream \
      player setup hover; do
      source "$LIBDIR/$m.sh"; done
    load_config; eval "$3"' _ "$TEST_LIB" "$TEST_REPO_DIR" "$1"
}

# test_engine_tree — print the fake engine install directory (the pinned-commit path).
# Args:    none
# Returns: 0 always; stdout: directory
# Globals: reads XDG_DATA_HOME
test_engine_tree() {
  lib_eval 'qwen3_engine_dir'
}

# test_install_fake_engine — create a fake installed engine (fake server, codec, dummy models).
# Args:    $1 <variants to create, space separated; default "customvoice">; the first is selected
# Returns: 0 always
# Globals: reads TEST_REPO_DIR
test_install_fake_engine() {
  local tree variant
  tree="$(test_engine_tree)"
  mkdir -p "$tree/bin" "$tree/models"
  cp "$TEST_REPO_DIR/tests/lib/fake_tts_server.py" "$tree/bin/tts-server"
  chmod +x "$tree/bin/tts-server"
  test_make_fake_codec "$tree/bin/qwen-codec"
  printf 'x' > "$tree/models/$(lib_eval 'qwen3_model_file codec')"
  # One dummy talker per requested variant; the fake server only checks the name for "base".
  for variant in ${1:-customvoice}; do
    printf 'x' > "$tree/models/$(lib_eval "qwen3_model_file $variant")"
  done
  printf 'BUILD=vulkan\nDEVICE=Vulkan0\n' > "$tree/engine.conf"
  # The product default is "base"; fixtures select the variant they install (first one wins).
  local installed="${1:-customvoice}"
  test_set_config "QWEN_VARIANT=${installed%% *}"
}

# test_set_config — write a raw line into the sandbox config file.
# Args:    $1 <line, e.g. QWEN_VARIANT=base>
# Returns: 0 always
# Globals: reads XDG_CONFIG_HOME
test_set_config() {
  mkdir -p "$XDG_CONFIG_HOME/piper-tts"
  printf '%s\n' "$1" >> "$XDG_CONFIG_HOME/piper-tts/config"
}

# test_add_piper_voice — create an empty fake Piper voice for a language.
# Args:    $1 <language code>
# Returns: 0 always
# Globals: reads XDG_DATA_HOME
test_add_piper_voice() {
  mkdir -p "$XDG_DATA_HOME/piper-tts/$1"
  : > "$XDG_DATA_HOME/piper-tts/$1/$1-test.onnx"
}

# test_speech_log — print the fake server's speech requests as "<voice> <language> <frames>".
# Args:    none
# Returns: 0 always; stdout: one line per request
# Globals: reads FAKE_TTS_LOG
test_speech_log() {
  [ -f "$FAKE_TTS_LOG" ] || return 0
  python3 - "$FAKE_TTS_LOG" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    event = json.loads(line)
    if event["event"] == "speech":
        print(event["voice"], event["language"], event["max_new_tokens"])
PY
}

# test_event_count — count events of one kind in the fake server log.
# Args:    $1 <event name: start|speech|voice>
# Returns: 0 always; stdout: the count
# Globals: reads FAKE_TTS_LOG
test_event_count() {
  [ -f "$FAKE_TTS_LOG" ] || { echo 0; return 0; }
  grep -c "\"event\": \"$1\"" "$FAKE_TTS_LOG" || true
}

# test_worker_pid — print the worker pid file content (empty when none).
# Args:    none
# Returns: 0 always
# Globals: reads HYPRLAND_TTS_WORKER_DIR
test_worker_pid() {
  cat "$HYPRLAND_TTS_WORKER_DIR/pid" 2>/dev/null || true
}

# test_pid_dead — succeed when a pid no longer exists.
# Args:    $1 <pid>
# Returns: 0 when dead or empty; 1 when alive
# Globals: none
test_pid_dead() { [ -z "$1" ] || ! kill -0 "$1" 2>/dev/null; }

# test_run_cases — run every function named case_* in a fresh sandbox and print the summary.
# Args:    none
# Returns: 0 when everything passed; 1 otherwise
# Globals: reads/writes TEST_PASS, TEST_FAIL
test_run_cases() {
  local case_name
  for case_name in $(declare -F | awk '{print $3}' | grep '^case_' | sort); do
    printf '%s\n' "== $case_name"
    test_setup
    "$case_name"
    test_teardown
  done
  printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$TEST_PASS" "$TEST_FAIL"
  [ "$TEST_FAIL" -eq 0 ]
}
