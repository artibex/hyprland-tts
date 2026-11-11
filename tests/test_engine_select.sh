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

# case_base_variant_without_cloned_voice_still_speaks — Base falls back to its built-in voice.
# Args:    none
# Returns: 0 always
# Globals: none
case_base_variant_without_cloned_voice_still_speaks() {
  test_install_fake_engine "customvoice base"
  test_set_config "QWEN_VARIANT=base"
  assert_contains "$(htts engine status)" "active:   qwen3" "base without clones is usable"
}

# case_default_variant_is_base — a fresh configuration selects the native-voice talker.
# Args:    none
# Returns: 0 always
# Globals: none
case_default_variant_is_base() {
  assert_eq "base" "$(lib_eval 'printf %s "$QWEN_VARIANT"')" "default variant"
  assert_eq "base" "$(lib_eval 'qwen3_parse_install_args qwen3 | cut -d" " -f2')" "install default"
}

# case_status_porcelain_without_install — every contract key is present, qwen3 explained.
# Args:    none
# Returns: 0 always
# Globals: none
case_status_porcelain_without_install() {
  test_add_piper_voice de
  local out; out="$(htts engine status --porcelain)"
  assert_eq "selected=auto
active=piper
qwen3_installed=0
qwen3_variant=base
qwen3_device=
qwen3_reason=not installed
worker=stopped
worker_port=
idle_minutes=10
piper_languages=de
languages=de" "$out" "porcelain contract"
}

# case_status_porcelain_with_running_worker — installed engine, live worker, port reported.
# Args:    none
# Returns: 0 always
# Globals: none
case_status_porcelain_with_running_worker() {
  test_install_fake_engine base
  htts engine start >/dev/null 2>&1
  local out; out="$(htts engine status --porcelain)"
  assert_contains "$out" "active=qwen3" "active"
  assert_contains "$out" "qwen3_installed=1" "installed"
  assert_contains "$out" "qwen3_device=Vulkan0" "device"
  assert_contains "$out" "qwen3_reason=
" "no reason when active"
  assert_contains "$out" "worker=running" "worker running"
  assert_eq "$(cat "$HYPRLAND_TTS_WORKER_DIR/port")" "$(printf '%s\n' "$out" | sed -n 's/^worker_port=//p')" "port"
  assert_contains "$out" "languages=de,en,fr,es,it,pt,ru,zh,ja,ko" "ten languages"
}

# case_status_porcelain_reasons — variant missing and forced piper are explained.
# Args:    none
# Returns: 0 always
# Globals: none
case_status_porcelain_reasons() {
  test_install_fake_engine customvoice
  test_set_config "QWEN_VARIANT=base"
  assert_contains "$(htts engine status --porcelain)" "qwen3_reason=variant base is not installed" "variant"
  test_install_fake_engine base
  test_set_config "ENGINE=piper"
  assert_contains "$(htts engine status --porcelain)" "qwen3_reason=engine set to piper" "piper chosen"
}

# case_engine_config_idle — idle minutes are validated, persisted and reported.
# Args:    none
# Returns: 0 always
# Globals: none
case_engine_config_idle() {
  htts engine config idle 25 >/dev/null 2>&1
  assert_rc 0 "$?" "25 accepted"
  assert_contains "$(htts engine status --porcelain)" "idle_minutes=25" "reported"
  local bad
  for bad in 0 241 abc 05 -3 ""; do
    htts engine config idle "$bad" >/dev/null 2>&1
    assert_rc 1 "$?" "'$bad' refused"
  done
  htts engine config speed 5 >/dev/null 2>&1
  assert_rc 1 "$?" "unknown key refused"
  assert_contains "$(htts engine status --porcelain)" "idle_minutes=25" "unchanged by bad input"
}

# case_idle_change_reaches_running_worker — the live worker uses the new limit at once.
# Args:    none
# Returns: 0 always
# Globals: none
case_idle_change_reaches_running_worker() {
  test_install_fake_engine base
  htts engine start >/dev/null 2>&1
  htts engine config idle 3 >/dev/null 2>&1
  assert_contains "$(htts engine status)" "idle limit 180s" "status shows the new limit"
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
