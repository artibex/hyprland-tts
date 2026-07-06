#!/usr/bin/env bash
# ==============================================================================
# hyprland-tts — local uninstaller (for the git-checkout / ~/.local install)
# ------------------------------------------------------------------------------
# If you installed via the AUR package, remove it with your package manager
# instead:  yay -Rns hyprland-tts   (and run `hyprland-tts purge` first if you
# also want to delete downloaded voices).
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX="$HOME/.local"

echo "================================================="
echo "   hyprland-tts — local uninstaller"
echo "================================================="

# 1. Remove per-user Hyprland wiring (keybinds + hyprland.conf source line).
if command -v hyprland-tts >/dev/null 2>&1; then
  hyprland-tts uninstall || true
elif [ -x "$PREFIX/bin/hyprland-tts" ]; then
  "$PREFIX/bin/hyprland-tts" uninstall || true
fi

# 2. Optionally remove downloaded voices / state / config.
read -rp "Also delete downloaded voice models and settings? [y/N]: " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  if command -v hyprland-tts >/dev/null 2>&1; then
    hyprland-tts purge || true
  elif [ -x "$PREFIX/bin/hyprland-tts" ]; then
    "$PREFIX/bin/hyprland-tts" purge || true
  fi
fi

# 3. Remove the installed program files.
echo "Removing program files from $PREFIX ..."
make -C "$REPO_DIR" PREFIX="$PREFIX" uninstall >/dev/null || true

echo ""
echo "================================================="
echo " Uninstall complete."
echo " System packages (piper-tts-bin, wl-clipboard, alsa-utils) were kept."
echo "================================================="
