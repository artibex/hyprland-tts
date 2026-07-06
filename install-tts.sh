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

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX="$HOME/.local"

echo "================================================="
echo "   hyprland-tts — local installer"
echo "================================================="

# --- 1. Runtime dependencies --------------------------------------------------
echo "[1/4] Checking dependencies..."
missing=()
for c in wl-paste piper-tts mpv socat curl awk sed grep; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "  Missing tools: ${missing[*]}"
  echo "  Install the packages providing them, e.g.:"
  echo "    sudo pacman -S --needed wl-clipboard mpv socat curl grep sed gawk gtk4 libadwaita python-gobject"
  echo "    <aur-helper> -S piper-tts-bin"
  echo "  Optional (image reading): sudo pacman -S --needed tesseract tesseract-data-eng perl-image-exiftool"
  echo "  (Re-run this script afterwards.)"
  # piper-tts is the only hard blocker for actually speaking; warn but continue,
  # so the user can still install voices and wire keybinds.
fi

# --- 2. Install program files into ~/.local -----------------------------------
echo "[2/4] Installing program files into $PREFIX ..."
make -C "$REPO_DIR" PREFIX="$PREFIX" install >/dev/null

# --- 3. PATH sanity -----------------------------------------------------------
if ! command -v hyprland-tts >/dev/null 2>&1; then
  case ":$PATH:" in
    *":$PREFIX/bin:"*) : ;;
    *)
      echo "[3/4] Note: $PREFIX/bin is not on your PATH."
      echo "      Add this to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\""
      ;;
  esac
else
  echo "[3/4] hyprland-tts is on PATH."
fi

# --- 4. Wire Hyprland keybinds ------------------------------------------------
echo "[4/4] Wiring Hyprland keybinds..."
"$PREFIX/bin/hyprland-tts" setup || true

echo ""
echo "================================================="
echo " Installed. Next steps:"
echo "   1) Install a voice:   hyprland-tts gui"
echo "                    or:  hyprland-tts model install en-ryan-high"
echo "   2) Highlight text and press SUPER + A to speak."
echo "================================================="
