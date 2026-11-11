#!/usr/bin/env bash
# tests/test_installer.sh — the local installer (install-tts.sh) refuses to install next to
# another hyprland-tts install, because the other one would keep running from keybinds and the
# menu and rewrite tts.lua with its own defaults.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# fake_pacman — install a fake pacman that reports hyprland-tts as an installed package.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT
fake_pacman() {
  # -Qq succeeds silently, -Q prints name and version like the real one.
  printf '#!/bin/sh\n[ "$1" = "-Qq" ] && exit 0\necho "hyprland-tts 1.1.0-3"\n' \
    > "$TEST_ROOT/fakebin/pacman"
  chmod +x "$TEST_ROOT/fakebin/pacman"
}

# case_refuses_next_to_a_package — a pacman package stops the install before any file is written.
# Args:    none
# Returns: 0 always
# Globals: reads HOME (sandboxed)
case_refuses_next_to_a_package() {
  fake_pacman
  local out
  out="$(bash "$TEST_REPO_DIR/install-tts.sh" 2>&1)"
  assert_rc 1 "$?" "installer stops"
  assert_contains "$out" "Another hyprland-tts install is present:" "headline"
  assert_contains "$out" "    pacman package hyprland-tts 1.1.0-3" "package named"
  assert_contains "$out" "Upgrade the package from this checkout instead:  makepkg -si" "upgrade hint"
  assert_contains "$out" "sudo pacman -R hyprland-tts" "remove hint"
  assert_no_file "$HOME/.local/bin/hyprland-tts" "nothing installed"
  assert_no_file "$XDG_CONFIG_HOME/hypr/tts.lua" "no keybinds written"
}

# case_refuses_next_to_another_binary — another hyprland-tts on PATH also stops the install.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT, HOME
case_refuses_next_to_another_binary() {
  # A pacman without the package, so only the PATH lookup can find the competitor.
  printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/fakebin/pacman"
  mkdir -p "$TEST_ROOT/otherbin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/otherbin/hyprland-tts"
  chmod +x "$TEST_ROOT/fakebin/pacman" "$TEST_ROOT/otherbin/hyprland-tts"
  local out
  out="$(PATH="$TEST_ROOT/otherbin:$PATH" bash "$TEST_REPO_DIR/install-tts.sh" 2>&1)"
  assert_rc 1 "$?" "installer stops"
  assert_contains "$out" "    $TEST_ROOT/otherbin/hyprland-tts" "other binary named"
  assert_no_file "$HOME/.local/bin/hyprland-tts" "nothing installed"
}

test_run_cases
