#!/usr/bin/env bash
# tests/test_packaging.sh — `make install` into a staging directory: every module, the helper
# requirements, the shipped voices and the licence land in place, and the INSTALLED copy runs.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# stage_install — install the repository into a staging directory below the sandbox.
# Args:    none
# Returns: 0 on success; prints the staging root on stdout
# Globals: reads TEST_ROOT, TEST_REPO_DIR
stage_install() {
  # The fake `make` of the sandbox (a no-op for the engine dependency check) must not run here.
  PATH="${PATH#"$TEST_ROOT/fakebin:"}" make -C "$TEST_REPO_DIR" install \
    DESTDIR="$TEST_ROOT/stage" PREFIX=/usr >/dev/null 2>&1
  printf '%s' "$TEST_ROOT/stage"
}

# check_shipped_gains — every shipped voice carries a plausible calibrated gain_db.
# Args:    $1 <directory with the voice folders (installed or in the checkout)>
# Returns: 0 always
# Globals: none
check_shipped_gains() {
  local dir voice gain count=0
  for dir in "$1"/*/; do
    voice="$(basename "$dir")"
    gain="$(head -n 1 "$dir/gain_db" 2>/dev/null)"
    count=$((count + 1))
    # A plain number inside the normaliser's range (-12 .. +14 dB).
    [[ "$gain" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] &&
      awk -v g="$gain" 'BEGIN{exit !(g >= -12 && g <= 14)}' &&
      test_pass "shipped voice $voice has gain_db $gain" ||
      test_fail "shipped voice $voice has a valid gain_db" "(got '$gain')"
  done
  assert_eq "5" "$count" "five shipped voices checked"
}

# case_install_layout — all runtime files are installed (the helper requirements were once missing).
# Args:    none
# Returns: 0 always
# Globals: none
case_install_layout() {
  local stage lib module
  stage="$(stage_install)"
  lib="$stage/usr/lib/hyprland-tts"
  assert_file "$stage/usr/bin/hyprland-tts" "dispatcher installed"
  for module in common text router model image keybind engine qwen3 qwen3_install worker voices \
    pyenv stream player setup hover; do
    assert_file "$lib/$module.sh" "module $module installed"
  done
  assert_file "$lib/py/requirements.txt" "pinned helper requirements installed (deps install needs it)"
  assert_file "$lib/py/htts_wav.py" "WAV helper installed"
  assert_file "$lib/py/htts_stream.py" "stream helper installed"
  assert_file "$lib/hover-read.py" "hover helper installed"
  assert_file "$stage/usr/share/hyprland-tts/shipped-voices/de-thorsten/ref.spk" "shipped voice latents"
  assert_file "$stage/usr/share/hyprland-tts/shipped-voices/de-thorsten/ATTRIBUTION.md" "attribution shipped"
  assert_file "$stage/usr/share/licenses/hyprland-tts/LICENSE" "licence installed"
  check_shipped_gains "$stage/usr/share/hyprland-tts/shipped-voices"
  [ -x "$stage/usr/bin/hyprland-tts" ] && test_pass "dispatcher is executable" || test_fail "dispatcher is executable"
}

# case_installed_copy_runs — the staged dispatcher finds its library and reports dependency status.
# Args:    none
# Returns: 0 always
# Globals: none
case_installed_copy_runs() {
  local stage out
  stage="$(stage_install)"
  out="$(env -u HYPRLAND_TTS_LIB -u HTTS_PYTHON -u HTTS_LID_MODEL \
    "$stage/usr/bin/hyprland-tts" deps status --porcelain 2>&1)"
  assert_rc 0 "$?" "deps status runs from the installed copy"
  assert_contains "$out" "ready=" "porcelain contract present"
  out="$(env -u HYPRLAND_TTS_LIB HYPRLAND_TTS_SYSTEM_VOICES= "$stage/usr/bin/hyprland-tts" voice list --porcelain 2>&1)"
  assert_contains "$out" "assign	de	de-thorsten" "shipped clones found next to the installed library"
}

# case_makefile_uninstall_is_complete — uninstall removes everything install created.
# Args:    none
# Returns: 0 always
# Globals: none
case_makefile_uninstall_is_complete() {
  stage_install >/dev/null
  PATH="${PATH#"$TEST_ROOT/fakebin:"}" make -C "$TEST_REPO_DIR" uninstall \
    DESTDIR="$TEST_ROOT/stage" PREFIX=/usr >/dev/null 2>&1
  assert_eq "" "$(find "$TEST_ROOT/stage" -type f 2>/dev/null)" "no file left after uninstall"
}

test_run_cases
