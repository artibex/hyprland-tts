#!/bin/bash
# ==============================================================================
# PIPER TTS UNINSTALLER FOR HYPRLAND Environment Configuration Modules
# ==============================================================================
set -e

echo "================================================="
echo "   Piper TTS Uninstaller for Hyprland           "
echo "================================================="
echo ""

HYPR_DIR="$HOME/.config/hypr"
MAIN_CONF="$HYPR_DIR/hyprland.conf"
TTS_DIR="$HOME/.local/share/piper-tts"
WRAPPER_SCRIPT="$HOME/.local/bin/hypr-piper-router.sh"

# 1. Delete modular dynamic target configurations
if [ -f "$HYPR_DIR/tts.conf" ]; then
    echo "[1/4] Purging targeted runtime subsystem file links (tts.conf)..."
    rm "$HYPR_DIR/tts.conf"
fi

# 2. Strip initialization code injection footprints from main configuration profile
if [ -f "$MAIN_CONF" ]; then
    echo "[2/4] Detaching engine references from your primary hyprland.conf structure..."
    sed -i '/# TTS (Text-to-Speech) Configuration Module Integration Link/d' "$MAIN_CONF"
    sed -i '/source = .\/tts.conf/d' "$MAIN_CONF"
fi

# 3. Clean routing logic binary elements
if [ -f "$WRAPPER_SCRIPT" ]; then
    echo "[3/4] Wiping logical backend matching routing script components..."
    rm "$WRAPPER_SCRIPT"
fi

# 4. Tear down model local data space directory
if [ -d "$TTS_DIR" ]; then
    echo "[4/4] Removing user-space Piper engine voice models (~/.local/share/piper-tts)..."
    rm -rf "$TTS_DIR"
fi

echo ""
echo "System core binaries (piper-tts-bin, wl-clipboard, alsa-utils) have been preserved."
echo "If you intend to drop dependencies completely, please execute this command manually:"
echo "sudo pacman -Rns alsa-utils wl-clipboard && $AUR_HELPER -Rns piper-tts-bin"
echo ""

# Live environment refresh execution core hook
echo "Broadcasting configuration adjustments to live system state..."
hyprctl reload || true

echo "================================================="
echo " Uninstallation Successfully Processed!"
echo "================================================="
