#!/usr/bin/env bash
# ==============================================================================
# hyprland-tts — local installer (no AUR helper required)
# ------------------------------------------------------------------------------
# Prefer the AUR package for a clean, upgradable install:
#     yay -S hyprland-tts && hyprland-tts setup
#
# This script is the fallback for people running straight from the git checkout.
# It installs the SAME files the package installs, but into ~/.local, then wires
# the Hyprland keybinds via `hyprland-tts setup`. It does not duplicate any
# logic — the shipped `bin/hyprland-tts` is the single source of truth.
# ==============================================================================
set -euo pipefail

# The checkout this script lives in (symlinks resolved) and the install prefix.
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX="$HOME/.local"

# print_banner — print the installer's title block.
# Args:    none
# Returns: 0 always
# Globals: none
print_banner() {
  cat <<'TEXT'
=================================================
   hyprland-tts — local installer
=================================================
TEXT
}

# check_dependencies — report missing runtime tools and how to install them.
# Args:    none
# Returns: 0 always (missing tools only produce a hint)
# Globals: none
check_dependencies() {
  local tool
  local -a missing=()
  # Step banner first, so a long dependency probe is never silent.
  echo "[1/4] Checking dependencies..."
  # flock and setsid (util-linux) run the warm engine worker; find/xargs list installed voices.
  for tool in wl-paste piper-tts mpv socat curl awk sed grep flock setsid find xargs; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  # Nothing missing means no output at all.
  [ "${#missing[@]}" -gt 0 ] || return 0
  echo "  Missing tools: ${missing[*]}"
  echo "  Install the packages providing them, e.g.:"
  # Name the packages in one copy-pasteable line.
  echo "    sudo pacman -S --needed wl-clipboard mpv socat curl grep sed gawk gtk4 libadwaita" \
    "python-gobject"
  echo "    <aur-helper> -S piper-tts-bin"
  echo "  Optional (image reading): sudo pacman -S --needed tesseract tesseract-data-eng" \
    "perl-image-exiftool"
  # The tool list is only advice; the installation goes on regardless.
  echo "  (Re-run this script afterwards.)"
}

# install_files — install the program files into the prefix via the Makefile.
# Args:    none
# Returns: 0 on success; non-zero when make fails (set -e then ends the script)
# Globals: reads REPO_DIR, PREFIX
install_files() {
  echo "[2/4] Installing program files into $PREFIX ..."
  # The Makefile is shared with the package build, so both install the same files.
  make -C "$REPO_DIR" PREFIX="$PREFIX" install >/dev/null
}

# check_path — tell the user when the install directory is not on PATH.
# Args:    none
# Returns: 0 always
# Globals: reads PREFIX, PATH
check_path() {
  # An already visible command needs no advice.
  if command -v hyprland-tts >/dev/null 2>&1; then
    echo "[3/4] hyprland-tts is on PATH."
    return 0
  fi
  # Wrapping PATH in colons makes the entry match exact.
  case ":$PATH:" in
    *":$PREFIX/bin:"*) : ;;
    *)
      echo "[3/4] Note: $PREFIX/bin is not on your PATH."
      # Copy-pasteable fix for the missing PATH entry.
      echo "      Add this to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\""
      ;;
  esac
}

# wire_keybinds — let the installed program wire the Hyprland keybinds.
# Args:    none
# Returns: 0 always (a failing setup only shows its own message)
# Globals: reads PREFIX
wire_keybinds() {
  echo "[4/4] Wiring Hyprland keybinds..."
  "$PREFIX/bin/hyprland-tts" setup || true
}

# print_next_steps — print what the user can do now.
# Args:    none
# Returns: 0 always
# Globals: none
print_next_steps() {
  cat <<'TEXT'

=================================================
 Installed. Next steps:
   1) Install a voice:   hyprland-tts gui
                    or:  hyprland-tts model install en-ryan-high
   2) Highlight text and press SUPER + A to speak.
   3) Optional, neural voices:  hyprland-tts engine install qwen3
      (needs cmake git gcc make; shaderc + vulkan-icd-loader for the GPU build)
=================================================
TEXT
}

# main — run the four installation steps in order.
# Args:    none
# Returns: 0 on success
# Globals: none
main() {
  print_banner
  # Missing tools are only reported: piper-tts is the sole hard blocker for speaking, and
  # the user can still install voices and wire keybinds.
  check_dependencies
  install_files
  check_path
  # Wiring last: it needs the installed binary.
  wire_keybinds
  print_next_steps
}

main "$@"
