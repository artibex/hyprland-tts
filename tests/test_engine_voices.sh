#!/usr/bin/env bash
# tests/test_engine_voices.sh — voice add/list/set/remove, defaults per variant, shipped voices,
# registration of cloned voices with the running (Base) server.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# make_reference — create a reference wav and transcript in the sandbox.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT
make_reference() {
  printf 'RIFFfake-reference-audio' > "$TEST_ROOT/ref.wav"
  printf 'Dies ist der Referenztext.\n' > "$TEST_ROOT/ref.txt"
}

# make_shipped_voice — create a shipped (read-only package) voice directory.
# Args:    $1 <name>
# Returns: 0 always
# Globals: reads TEST_ROOT; exports HYPRLAND_TTS_SYSTEM_VOICES
make_shipped_voice() {
  export HYPRLAND_TTS_SYSTEM_VOICES="$TEST_ROOT/shipped"
  mkdir -p "$TEST_ROOT/shipped/$1"
  printf 's' > "$TEST_ROOT/shipped/$1/ref.spk"
  printf 'r' > "$TEST_ROOT/shipped/$1/ref.rvq"
  printf 'CC0' > "$TEST_ROOT/shipped/$1/LICENSE"
}

# case_voice_add_creates_layout — add encodes via qwen-codec and writes the documented files.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_add_creates_layout() {
  test_install_fake_engine "customvoice base"
  make_reference
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_rc 0 "$?" "voice add"
  local dir="$XDG_DATA_HOME/hyprland-tts/voices/anna"
  assert_file "$dir/ref.wav" "ref.wav stored"
  assert_file "$dir/ref.txt" "ref.txt stored"
  assert_file "$dir/ref.spk" "ref.spk encoded"
  assert_file "$dir/ref.rvq" "ref.rvq encoded"
  assert_file "$dir/LICENSE" "LICENSE written"
  assert_contains "$(cat "$FAKE_CODEC_LOG")" "talker=" "qwen-codec got --talker"
  assert_contains "$(cat "$FAKE_CODEC_LOG")" "qwen-talker-0.6b-base" "base talker used for encoding"
  assert_eq "" "$(ls -A "$XDG_DATA_HOME/hyprland-tts/voices" | grep '^\.new' || true)" "no scratch dir left"
}

# case_voice_add_with_license — a supplied licence file is kept verbatim.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_add_with_license() {
  test_install_fake_engine "customvoice base"
  make_reference
  printf 'CC-BY 4.0 by Someone\n' > "$TEST_ROOT/lic.txt"
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" --license "$TEST_ROOT/lic.txt" >/dev/null 2>&1
  assert_eq "CC-BY 4.0 by Someone" "$(cat "$XDG_DATA_HOME/hyprland-tts/voices/anna/LICENSE")" "licence copied"
}

# case_voice_add_validation — bad names, missing files, duplicates and encode errors are refused.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_add_validation() {
  test_install_fake_engine "customvoice base"
  make_reference
  htts voice add '../evil' "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "path traversal name refused"
  htts voice add 'Upper' "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "uppercase name refused"
  htts voice add anna "$TEST_ROOT/nope.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "missing wav refused"
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/nope.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "missing transcript refused"
  printf 'BADWAV' > "$TEST_ROOT/bad.wav"
  htts voice add broken "$TEST_ROOT/bad.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "failed encode refused"
  assert_no_file "$XDG_DATA_HOME/hyprland-tts/voices/broken" "no half-created voice"
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "duplicate refused"
}

# case_voice_add_needs_base_model — without the Base talker add explains how to install it.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_add_needs_base_model() {
  test_install_fake_engine customvoice
  make_reference
  local out; out="$(htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" 2>&1)"
  assert_rc 1 "$?" "refused without base model"
  assert_contains "$out" "--variant base" "hint names the fix"
}

# case_voice_list_shows_presets_clones_and_assignments — list output covers all three kinds.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_list_shows_presets_clones_and_assignments() {
  test_install_fake_engine "customvoice base"
  make_reference
  make_shipped_voice de-shipped
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  local out; out="$(htts voice list)"
  assert_contains "$out" "variant: customvoice" "variant shown"
  assert_contains "$out" "  de   ryan" "default ryan for de"
  assert_contains "$out" "uncle_fu" "presets listed"
  assert_contains "$out" "anna" "user clone listed"
  assert_contains "$out" "de-shipped" "shipped clone listed"
  assert_contains "$(htts voice list --porcelain)" "cloned	anna	user" "porcelain user clone"
  assert_contains "$(htts voice list --porcelain)" "cloned	de-shipped	shipped" "porcelain shipped clone"
}

# case_voice_set_validates_and_persists — set checks language and voice, --clear resets.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_set_validates_and_persists() {
  test_install_fake_engine
  htts voice set de aiden >/dev/null 2>&1
  assert_rc 0 "$?" "set de aiden"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VOICE_de=aiden" "stored"
  assert_contains "$(htts voice list)" "  de   aiden" "list reflects it"
  htts voice set xx aiden >/dev/null 2>&1
  assert_rc 1 "$?" "unknown language refused"
  htts voice set de nobody >/dev/null 2>&1
  assert_rc 1 "$?" "unknown voice refused"
  htts voice set de 'a b' >/dev/null 2>&1
  assert_rc 1 "$?" "unsafe voice name refused"
  htts voice set de --clear >/dev/null 2>&1
  assert_rc 0 "$?" "clear accepted"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VOICE_de" "assignment removed"
}

# case_voice_remove_user_only — user voices can be removed (and unassigned), shipped ones not.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_remove_user_only() {
  test_install_fake_engine "customvoice base"
  make_reference
  make_shipped_voice de-shipped
  htts voice add anna "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  htts voice set de anna >/dev/null 2>&1
  htts voice remove anna >/dev/null 2>&1
  assert_rc 0 "$?" "remove user voice"
  assert_no_file "$XDG_DATA_HOME/hyprland-tts/voices/anna" "directory gone"
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VOICE_de" "assignment dropped"
  htts voice remove de-shipped >/dev/null 2>&1
  assert_rc 1 "$?" "shipped voice cannot be removed"
  htts voice remove '../x' >/dev/null 2>&1
  assert_rc 1 "$?" "unsafe name refused"
}

# case_base_variant_defaults — Base picks <lang>-* clones, then 'default', then its built-in voice.
# Args:    none
# Returns: 0 always
# Globals: none
case_base_variant_defaults() {
  test_install_fake_engine "base"
  make_shipped_voice de-anna
  mkdir -p "$TEST_ROOT/shipped/en-bob" "$TEST_ROOT/shipped/default"
  for v in en-bob default; do printf 's' > "$TEST_ROOT/shipped/$v/ref.spk"; printf 'r' > "$TEST_ROOT/shipped/$v/ref.rvq"; done
  assert_eq "de-anna" "$(lib_eval 'voice_for_lang de')" "de -> de-anna"
  assert_eq "en-bob" "$(lib_eval 'voice_for_lang en')" "en -> en-bob"
  assert_eq "default" "$(lib_eval 'voice_for_lang fr')" "fr -> default"
  rm -rf "$TEST_ROOT/shipped/default"
  assert_eq "base-default" "$(lib_eval 'voice_for_lang fr')" "fr without clone -> built-in voice"
  assert_eq "base-default" "$(lib_eval 'voice_for_lang ja')" "ja -> built-in voice"
}

# case_shipped_native_voices_are_the_defaults — the packaged clones cover de en fr es it.
# Args:    none
# Returns: 0 always
# Globals: none
case_shipped_native_voices_are_the_defaults() {
  test_install_fake_engine "base"
  export HYPRLAND_TTS_SYSTEM_VOICES="$TEST_REPO_DIR/share/voices"
  assert_eq "de-thorsten en-lj es-mls-8585 fr-siwis it-mls-8582" \
    "$(lib_eval 'for l in de en es fr it; do voice_for_lang $l; printf " "; done' | xargs -n1 | sort | xargs)" \
    "five native defaults"
  assert_eq "base-default" "$(lib_eval 'voice_for_lang pt')" "pt uses the built-in voice"
  assert_contains "$(htts voice list --porcelain)" "assign	de	de-thorsten" "porcelain assignment"
  assert_contains "$(htts voice list --porcelain)" "assign	ko	base-default" "porcelain built-in"
}

# case_voice_info_reports_attribution — info finds ATTRIBUTION.md as well as LICENSE.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_info_reports_attribution() {
  test_install_fake_engine "base"
  export HYPRLAND_TTS_SYSTEM_VOICES="$TEST_REPO_DIR/share/voices"
  local out; out="$(htts voice info de-thorsten)"
  assert_contains "$out" "source=shipped" "shipped source"
  assert_contains "$out" "license=$TEST_REPO_DIR/share/voices/de-thorsten/ATTRIBUTION.md" "attribution file"
  htts voice info nobody >/dev/null 2>&1
  assert_rc 1 "$?" "unknown voice refused"
}

# case_builtin_voice_is_assignable_and_reserved — base-default can be set, never created.
# Args:    none
# Returns: 0 always
# Globals: none
case_builtin_voice_is_assignable_and_reserved() {
  test_install_fake_engine "base"
  make_reference
  htts voice set pt base-default >/dev/null 2>&1
  assert_rc 0 "$?" "set pt base-default"
  htts voice add base-default "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_rc 1 "$?" "reserved name refused"
}

# case_base_worker_registers_clones — the worker uploads every cloned voice at start.
# Args:    none
# Returns: 0 always
# Globals: none
case_base_worker_registers_clones() {
  test_install_fake_engine "customvoice base"
  test_set_config "QWEN_VARIANT=base"
  make_reference
  make_shipped_voice de-anna
  htts voice add mine "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  htts engine start >/dev/null 2>&1
  assert_eq 2 "$(test_event_count voice)" "two voices registered at start"
  assert_contains "$(grep '"voice"' "$FAKE_TTS_LOG")" '"name": "de-anna"' "shipped voice registered"
  assert_contains "$(grep '"voice"' "$FAKE_TTS_LOG")" 'Referenztext' "ref_text forwarded"
  assert_contains "$(grep '"voice"' "$FAKE_TTS_LOG")" '"has_spk": true, "has_rvq": true' "latents sent"
}

# case_voice_add_registers_with_running_server — no restart is needed for a new clone.
# Args:    none
# Returns: 0 always
# Globals: none
case_voice_add_registers_with_running_server() {
  test_install_fake_engine "customvoice base"
  test_set_config "QWEN_VARIANT=base"
  make_reference
  htts engine start >/dev/null 2>&1
  htts voice add late "$TEST_ROOT/ref.wav" "$TEST_ROOT/ref.txt" >/dev/null 2>&1
  assert_contains "$(grep '"voice"' "$FAKE_TTS_LOG")" '"name": "late"' "registered live"
}

# case_customvoice_worker_registers_nothing — CustomVoice servers have no registry.
# Args:    none
# Returns: 0 always
# Globals: none
case_customvoice_worker_registers_nothing() {
  test_install_fake_engine "customvoice base"
  make_shipped_voice de-anna
  htts engine start >/dev/null 2>&1
  assert_eq 0 "$(test_event_count voice)" "no registration attempts"
}

test_run_cases
