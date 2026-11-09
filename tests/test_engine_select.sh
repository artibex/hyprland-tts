#!/usr/bin/env bash
# tests/test_engine_select.sh — engine selection (auto|qwen3|piper), languages, `engine use`.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# case_auto_without_install_uses_piper — a fresh box has only Piper.
# Args:    none
# Returns: 0 always
# Globals: none
case_auto_without_install_uses_piper() {
  assert_contains "$(htts engine status)" "active:   piper" "auto + no install -> piper"
}

# case_auto_with_install_uses_qwen3 — an installed engine wins under auto.
# Args:    none
# Returns: 0 always
# Globals: none
case_auto_with_install_uses_qwen3() {
  test_install_fake_engine
  assert_contains "$(htts engine status)" "active:   qwen3" "auto + install -> qwen3"
}

# case_forced_piper_ignores_install — ENGINE=piper beats an installed qwen3.
# Args:    none
# Returns: 0 always
# Globals: none
case_forced_piper_ignores_install() {
  test_install_fake_engine
  test_set_config "ENGINE=piper"
  assert_contains "$(htts engine status)" "active:   piper" "piper forced"
  assert_contains "$(htts engine status)" "selected: piper" "selection shown"
}

# case_forced_qwen3_without_install_falls_back — a missing install never breaks speaking.
# Args:    none
# Returns: 0 always
# Globals: none
case_forced_qwen3_without_install_falls_back() {
  test_set_config "ENGINE=qwen3"
  local out
  out="$(htts engine status)"
  assert_contains "$out" "selected: qwen3" "qwen3 selected"
  assert_contains "$out" "active:   piper" "falls back to piper"
  assert_contains "$out" "not installed" "status explains why"
}

# case_missing_variant_counts_as_not_installed — customvoice files do not serve variant base.
# Args:    none
# Returns: 0 always
# Globals: none
case_missing_variant_counts_as_not_installed() {
  test_install_fake_engine customvoice
  test_set_config "QWEN_VARIANT=base"
  assert_contains "$(htts engine status)" "active:   piper" "base variant missing -> piper"
}

# case_base_variant_without_cloned_voice_is_unusable — Base needs a voice, else Piper speaks.
# Args:    none
# Returns: 0 always
# Globals: none
case_base_variant_without_cloned_voice_is_unusable() {
  test_install_fake_engine "customvoice base"
  test_set_config "QWEN_VARIANT=base"
  local out; out="$(htts engine status)"
  assert_contains "$out" "active:   piper" "base without voices -> piper"
  assert_contains "$out" "no cloned voice" "status explains it"
  mkdir -p "$XDG_DATA_HOME/hyprland-tts/voices/anna"
  printf 's' > "$XDG_DATA_HOME/hyprland-tts/voices/anna/ref.spk"
  printf 'r' > "$XDG_DATA_HOME/hyprland-tts/voices/anna/ref.rvq"
  assert_contains "$(htts engine status)" "active:   qwen3" "a cloned voice makes it usable"
}

# case_languages_follow_active_engine — qwen3 speaks ten languages, piper only installed ones.
# Args:    none
# Returns: 0 always
# Globals: none
case_languages_follow_active_engine() {
  test_add_piper_voice de
  test_add_piper_voice en
  assert_eq "de,en" "$(lib_eval 'engine_languages')" "piper languages = installed voices"
  test_install_fake_engine
  assert_eq "de,en,fr,es,it,pt,ru,zh,ja,ko" "$(lib_eval 'engine_languages')" "qwen3 languages"
}

# case_engine_use_validates_and_persists — only the three names are accepted and stored.
# Args:    none
# Returns: 0 always
# Globals: none
case_engine_use_validates_and_persists() {
  htts engine use bogus >/dev/null 2>&1
  assert_rc 1 "$?" "engine use bogus rejected"
  htts engine use piper >/dev/null 2>&1
  assert_rc 0 "$?" "engine use piper accepted"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "ENGINE=piper" "stored in config"
  assert_contains "$(htts engine status)" "selected: piper" "status reflects the change"
}

# case_invalid_engine_value_behaves_like_auto — a hand-edited garbage value is harmless.
# Args:    none
# Returns: 0 always
# Globals: none
case_invalid_engine_value_behaves_like_auto() {
  test_set_config "ENGINE=banana"
  assert_contains "$(htts engine status)" "selected: auto" "garbage -> auto"
}

test_run_cases
