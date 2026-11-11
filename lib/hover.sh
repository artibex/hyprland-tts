#!/usr/bin/env bash
# lib/hover.sh — on-demand "speak whatever text is under the mouse pointer".
#
# Scope: Wayland has no global "text under the cursor" API. The cursor position comes from the
# Hyprland-specific `hyprctl cursorpos`; the text comes from AT-SPI (the framework behind Orca's
# Mouse Review, lib/hover-read.py), which only apps that implement it expose (GTK/Qt, most
# browsers; not terminals or games). The feature is deliberately on-demand — one AT-SPI query
# per keypress, no polling daemon — because continuous hover would need a permanent background
# process, which conflicts with the project's "no background daemons" rule (Agent.md §1, §3).

# _hover_python — find a python3 that has the AT-SPI GI binding.
# Args:    none
# Returns: 0 when one exists; 1 otherwise; stdout: the interpreter command
# Globals: none
# Notes:   Same PATH-shadowing concern as _gui_python in bin/hyprland-tts (Agent.md §5).
_hover_python() {
  local candidate probe
  probe='import gi; gi.require_version("Atspi","2.0"); from gi.repository import Atspi'
  # PATH python3 first, then the system one.
  for candidate in python3 /usr/bin/python3; do
    have "$candidate" || continue
    # The import probe decides, not the mere existence of an interpreter.
    if "$candidate" -c "$probe" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  # No interpreter can import AT-SPI.
  return 1
}

# hover_cursor_position — print the pointer position as "x y".
# Args:    none
# Returns: 0 on success; exits 1 via die when hyprctl fails or prints something unexpected
# Globals: none
hover_cursor_position() {
  local position x y
  position="$(hyprctl cursorpos 2>/dev/null)" || die "could not query cursor position"
  # hyprctl prints "x, y"; blanks are stripped from each coordinate.
  x="$(printf '%s' "$position" | awk -F',' '{gsub(/[[:space:]]/,"",$1); print $1}')"
  y="$(printf '%s' "$position" | awk -F',' '{gsub(/[[:space:]]/,"",$2); print $2}')"
  # Coordinates can be negative on multi-monitor layouts, but must be integers.
  if ! [[ "$x" =~ ^-?[0-9]+$ ]] || ! [[ "$y" =~ ^-?[0-9]+$ ]]; then
    die "unexpected 'hyprctl cursorpos' output: $position"
  fi
  printf '%s %s' "$x" "$y"
}

# hover_focus_hint — print the class of the focused window (empty when unknown).
# Args:    none
# Returns: 0 always; stdout: the window class
# Globals: none
# Notes:   AT-SPI has no stacking order, so the hint keeps a hidden app from shadowing the real one.
hover_focus_hint() {
  # sed instead of jq avoids a new dependency for one field of Hyprland's own JSON.
  hyprctl activewindow -j 2>/dev/null | sed -n 's/.*"class": *"\([^"]*\)".*/\1/p' | head -n1 || true
}

# hover_require_hyprland — notify and die when hyprctl is missing.
# Args:    none
# Returns: 0 when hyprctl exists; exits 1 via die otherwise
# Globals: none
hover_require_hyprland() {
  have hyprctl && return 0
  # A keybind has no terminal, so the notification is the only visible explanation.
  notify "hyprland-tts: hover unavailable" "hyprctl not found — this shortcut needs Hyprland."
  die "'hover' needs Hyprland (hyprctl not found)"
}

# hover_read_text — query AT-SPI for the text at a point, bounded in time.
# Args:    $1 <python interpreter>; $2 <x>; $3 <y>; $4 <focused window class, may be empty>
# Returns: 0 always; stdout: the text (empty when nothing was found)
# Globals: reads LIBDIR
hover_read_text() {
  # The hard timeout keeps a stuck AT-SPI registry from ever hanging the shortcut.
  timeout 1.5 "$1" "$LIBDIR/hover-read.py" "$2" "$3" "$4" 2>/dev/null || true
}

# cmd_hover — speak the text under the mouse pointer.
# Args:    none
# Returns: 0 always (silently when nothing is found); exits 1 via die without Hyprland
# Globals: reads LIBDIR
cmd_hover() {
  local python position x y hint text
  load_config
  # Cursor position and focus hints exist only under Hyprland.
  hover_require_hyprland
  # A failure inside the substitution must end the command (the die only ends the subshell).
  position="$(hover_cursor_position)" || exit 1
  read -r x y <<< "$position"
  # AT-SPI is optional; a persistent setup problem deserves a visible hint, unlike "no text here".
  if ! python="$(_hover_python)"; then
    notify "hyprland-tts: hover unavailable" \
      "Install at-spi2-core (and make sure python-gobject sees it) to use this shortcut."
    exit 0
  fi
  # The focused window's class decides which app's tree is searched first.
  hint="$(hover_focus_hint)"
  text="$(hover_read_text "$python" "$x" "$y" "$hint")"
  # Moving the mouse over unsupported areas is normal, so this exit is only a short notice.
  if [ -z "${text//[[:space:]]/}" ]; then
    notify "hyprland-tts: no text found" \
      "No accessible text was found under the cursor in this app."
    exit 0
  fi
  # From here on the text is spoken like any other selection.
  speak_text "$text"
}
