#!/usr/bin/env bash
# tests/test_cli.sh — the thin dispatcher: usage text, unknown commands, library discovery, the
# root guard, the GUI launcher's interpreter choice and a few routed subcommands.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# case_usage_forms — help, -h, --help and no argument print the same overview.
# Args:    none
# Returns: 0 always
# Globals: none
case_usage_forms() {
  local reference; reference="$(htts help 2>&1)"
  assert_contains "$reference" "hyprland-tts — accessible, multilingual, offline TTS for Hyprland" "title"
  assert_contains "$reference" "hyprland-tts engine <sub>" "engine documented"
  assert_contains "$reference" "hyprland-tts voice <sub>" "voice documented"
  assert_contains "$reference" "hyprland-tts purge" "purge documented"
  assert_contains "$reference" "hyprland-tts volume [<0-100>]" "volume documented"
  assert_contains "$reference" "hyprland-tts preview <lang>" "preview documented"
  assert_contains "$reference" "[--engine qwen3|piper] [--model <lang>/<name>]" "preview options"
  assert_contains "$reference" "hyprland-tts say [<text>...]" "say documented"
  assert_contains "$reference" "[--lang <code>] [--wait] [--]" "say options"
  assert_eq "$reference" "$(htts 2>&1)" "no argument == help"
  assert_eq "$reference" "$(htts -h 2>&1)" "-h == help"
  assert_eq "$reference" "$(htts --help 2>&1)" "--help == help"
  htts help >/dev/null 2>&1
  assert_rc 0 "$?" "help succeeds"
}

# case_unknown_command — a typo prints the cause and the usage, exit status 1.
# Args:    none
# Returns: 0 always
# Globals: none
case_unknown_command() {
  local out; out="$(htts frobnicate 2>&1)"
  assert_rc 1 "$?" "unknown command fails"
  assert_contains "$out" "unknown command: frobnicate" "cause shown"
  assert_contains "$out" "USAGE" "usage follows"
}

# case_library_discovery — HYPRLAND_TTS_LIB, the checkout layout and a missing library.
# Args:    none
# Returns: 0 always
# Globals: none
case_library_discovery() {
  assert_contains "$(HYPRLAND_TTS_LIB="$TEST_ROOT/nowhere" HOME="$TEST_ROOT/home" htts help 2>&1)" "USAGE" "bad override falls through to the checkout lib"
  local copy="$TEST_ROOT/relocated"
  mkdir -p "$copy/bin"
  cp "$TEST_REPO_DIR/bin/hyprland-tts" "$copy/bin/hyprland-tts"
  local out; out="$(env -u HYPRLAND_TTS_LIB HOME="$TEST_ROOT/home" "$copy/bin/hyprland-tts" help 2>&1)"
  local library_status=$?
  if [ ! -f /usr/lib/hyprland-tts/common.sh ]; then
    assert_rc 1 "$library_status" "no library anywhere"
    assert_eq "hyprland-tts: cannot locate library directory" "$out" "message"
  fi
  cp -r "$TEST_REPO_DIR/lib" "$copy/lib"
  assert_contains "$(env -u HYPRLAND_TTS_LIB "$copy/bin/hyprland-tts" help 2>&1)" "USAGE" "<self>/../lib is found"
  mkdir -p "$copy/lib/hyprland-tts"
  cp -r "$TEST_REPO_DIR/lib/." "$copy/lib/hyprland-tts/"
  rm "$copy/lib/hyprland-tts/common.sh"
  assert_contains "$(env -u HYPRLAND_TTS_LIB "$copy/bin/hyprland-tts" help 2>&1)" "USAGE" "incomplete installed dir is skipped"
}

# case_root_guard — every subcommand refuses root unless the escape hatch is set.
# Args:    none
# Returns: 0 always
# Globals: none
case_root_guard() {
  printf '#!/bin/sh\n[ "$1" = "-u" ] && echo 0 || echo root\n' > "$TEST_ROOT/fakebin/id"
  chmod +x "$TEST_ROOT/fakebin/id"
  local out
  out="$(htts model list 2>&1)"
  assert_rc 1 "$?" "model refused under root"
  assert_contains "$out" "error: Do not run hyprland-tts as root or with sudo." "message headline"
  assert_contains "$out" "hyprland-tts model list" "message repeats the command"
  htts gui >/dev/null 2>&1;  assert_rc 1 "$?" "gui refused under root"
  htts setup >/dev/null 2>&1; assert_rc 1 "$?" "setup refused under root"
  assert_no_file "$XDG_CONFIG_HOME/hypr/tts.conf" "nothing written under root"
  out="$(HYPRLAND_TTS_ALLOW_ROOT=1 htts help 2>&1)"
  assert_rc 0 "$?" "escape hatch allows it"
  assert_contains "$out" "USAGE" "help printed with the escape hatch"
  HYPRLAND_TTS_ALLOW_ROOT=0 htts help >/dev/null 2>&1
  assert_rc 1 "$?" "only the value 1 opens the hatch"
}

# make_fake_gui — install a fake GUI script that prints the interpreter that launched it.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT
make_fake_gui() {
  printf 'import sys\nprint("GUI via", sys.executable, sys.argv[1:])\n' > "$TEST_ROOT/fakebin/hyprland-tts-gui"
  chmod +x "$TEST_ROOT/fakebin/hyprland-tts-gui"
}

# case_gui_uses_a_python_with_gtk — the interpreter that passes the GTK probe launches the GUI.
# Args:    none
# Returns: 0 always
# Globals: none
case_gui_uses_a_python_with_gtk() {
  make_fake_gui
  # A python3 on PATH that claims to have GTK and runs scripts with the real interpreter.
  printf '#!/bin/sh\nif [ "$1" = "-c" ]; then exit 0; fi\nexec /usr/bin/python3 "$@"\n' > "$TEST_ROOT/fakebin/python3"
  chmod +x "$TEST_ROOT/fakebin/python3"
  local out; out="$(htts gui --flag 2>&1)"
  assert_rc 0 "$?" "gui launched"
  assert_contains "$out" "GUI via" "fake GUI ran"
  assert_contains "$out" "['--flag']" "arguments forwarded"
}

# case_gui_falls_back_to_system_python — a PATH python3 without GTK is skipped for /usr/bin/python3.
# Args:    none
# Returns: 0 always
# Globals: none
case_gui_falls_back_to_system_python() {
  if ! /usr/bin/python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")' 2>/dev/null; then
    test_pass "skipped: this system python has no GTK4 (fallback not observable)"
    return 0
  fi
  make_fake_gui
  printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/fakebin/python3"
  chmod +x "$TEST_ROOT/fakebin/python3"
  assert_contains "$(htts gui 2>&1)" "GUI via /usr/bin/python3" "launched with the system interpreter"
}

# case_gui_explains_missing_gtk — without any GTK python the message names packages and the PATH issue.
# Args:    none
# Returns: 0 always
# Globals: none
case_gui_explains_missing_gtk() {
  if /usr/bin/python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")' 2>/dev/null; then
    test_pass "skipped: this system python has GTK4 (failure not observable)"
    return 0
  fi
  make_fake_gui
  printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/fakebin/python3"
  chmod +x "$TEST_ROOT/fakebin/python3"
  local out; out="$(htts gui 2>&1)"
  assert_rc 1 "$?" "gui fails without GTK"
  assert_contains "$out" "GUI needs GTK4 + libadwaita + PyGObject for python3." "headline"
  assert_contains "$out" "pacman -S --needed gtk4 libadwaita python-gobject" "package hint"
  assert_contains "$out" "shadowing the system interpreter" "PATH hint"
}

# case_gui_component_missing — no GUI script anywhere gives a clear error.
# Args:    none
# Returns: 0 always
# Globals: none
case_gui_component_missing() {
  local copy="$TEST_ROOT/nogui" out tool_dir="$TEST_ROOT/toolbin" tool
  mkdir -p "$copy/bin" "$tool_dir"
  cp "$TEST_REPO_DIR/bin/hyprland-tts" "$copy/bin/hyprland-tts"
  cp -r "$TEST_REPO_DIR/lib" "$copy/lib"
  # A system-wide GUI must stay invisible: link every tool of /usr/bin except the GUI itself.
  for tool in /usr/bin/*; do
    [ "${tool##*/}" = "hyprland-tts-gui" ] || ln -s "$tool" "$tool_dir/${tool##*/}"
  done
  out="$(PATH="$tool_dir" env -u HYPRLAND_TTS_LIB "$copy/bin/hyprland-tts" gui 2>&1)"
  assert_rc 1 "$?" "gui without component fails"
  assert_eq "error: GUI component not found." "$out" "message"
}

# case_routed_subcommands — ctl, stop, deps and the error paths reach their modules.
# Args:    none
# Returns: 0 always
# Globals: none
case_routed_subcommands() {
  assert_eq "idle" "$(htts ctl status)" "ctl status without a player"
  htts stop >/dev/null 2>&1;  assert_rc 0 "$?" "stop without a player is harmless"
  htts ctl next >/dev/null 2>&1; assert_rc 0 "$?" "ctl next without a player is harmless"
  assert_contains "$(htts engine status)" "selected: auto" "engine routed"
  assert_contains "$(htts voice list)" "language voices:" "voice routed"
  assert_contains "$(htts keybind list)" "Speak selection" "keybind routed"
  assert_contains "$(htts model list)" "No models installed." "model routed"
  htts deps status >/dev/null 2>&1
  assert_contains "$(htts deps bogus 2>&1)" "usage: hyprland-tts deps" "deps usage"
  htts ctl bogus >/dev/null 2>&1; assert_rc 0 "$?" "ctl with no daemon exits quietly before validating"
}

test_run_cases
