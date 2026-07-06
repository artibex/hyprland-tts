#!/usr/bin/env bash
# lib/hover.sh — on-demand "speak whatever text is under the mouse pointer".
#
# Scope, read before touching this file:
#
# There is no Wayland-wide API for "what text is under the cursor in any app" —
# Wayland deliberately does not expose global pointer position or arbitrary
# window contents to other clients (unlike X11's XQueryPointer). So this
# feature is built from two Hyprland/accessibility-specific pieces:
#
#   1. Cursor position comes from `hyprctl cursorpos` — a Hyprland-specific
#      command. This action ONLY works under Hyprland (matches the rest of the
#      project's scope).
#   2. The text at that position comes from AT-SPI — the same accessibility
#      framework GNOME's Orca screen reader uses for its "Mouse Review"
#      feature (lib/hover-read.py). AT-SPI only works in apps that implement
#      it: GTK/Qt/Electron apps and most browsers do; terminals, games, and
#      other custom-rendered apps generally don't expose anything. This is a
#      best-effort integration, not a universal one.
#
# Why on-demand, not continuous hover: true "speak on hover" requires a
# process continuously polling pointer position and querying AT-SPI — a
# permanent background daemon, which conflicts with this project's explicit
# "no background daemons" design (see Agent.md Mission). This command instead
# does ONE query per keypress: no standing process, same trigger model as
# every other action in this tool. If real continuous hover is ever wanted,
# it is a deliberate architecture change, not an extension of this file.

# a python3 that actually has the AT-SPI GI binding (same PATH-shadowing
# concern as the GUI's _gui_python in bin/hyprland-tts — see that gotcha)
_hover_python() {
  local cand
  for cand in python3 /usr/bin/python3; do
    have "$cand" || continue
    if "$cand" -c 'import gi; gi.require_version("Atspi","2.0"); from gi.repository import Atspi' \
         >/dev/null 2>&1; then
      printf '%s' "$cand"; return 0
    fi
  done
  return 1
}

cmd_hover() {
  load_config
  if ! have hyprctl; then
    notify "hyprland-tts: hover unavailable" "hyprctl not found — this shortcut needs Hyprland."
    die "'hover' needs Hyprland (hyprctl not found)"
  fi

  local pos x y
  pos="$(hyprctl cursorpos 2>/dev/null)" || die "could not query cursor position"
  x="$(printf '%s' "$pos" | awk -F',' '{gsub(/[[:space:]]/,"",$1); print $1}')"
  y="$(printf '%s' "$pos" | awk -F',' '{gsub(/[[:space:]]/,"",$2); print $2}')"
  [[ "$x" =~ ^-?[0-9]+$ ]] && [[ "$y" =~ ^-?[0-9]+$ ]] || die "unexpected 'hyprctl cursorpos' output: $pos"

  # AT-SPI is optional (at-spi2-core, python-gobject's Atspi typelib). If it's
  # missing, notify once per press rather than staying totally silent — this
  # is a persistent, fixable setup problem, not a "nothing was here" miss, and
  # a keybind-triggered command has no terminal to explain itself otherwise.
  local py
  if ! py="$(_hover_python)"; then
    notify "hyprland-tts: hover unavailable" "Install at-spi2-core (and make sure python-gobject sees it) to use this shortcut."
    exit 0
  fi

  # hint hover-read.py which app is actually focused/on top: AT-SPI has no
  # concept of window stacking order, so without this an occluded background
  # window registered earlier can shadow the real one (confirmed for real:
  # a hidden file manager's sidebar was picked over the visibly focused
  # editor's text). Best-effort only — grep, not jq, to avoid a new dep for
  # one field of Hyprland's own JSON.
  local hint
  hint="$(hyprctl activewindow -j 2>/dev/null | sed -n 's/.*"class": *"\([^"]*\)".*/\1/p' | head -n1)"

  # hard-bounded: never let a stuck/missing AT-SPI registry hang the shortcut
  local text
  text="$(timeout 1.5 "$py" "$LIBDIR/hover-read.py" "$x" "$y" "$hint" 2>/dev/null || true)"
  [ -n "${text//[[:space:]]/}" ] || exit 0

  speak_text "$text"
}
