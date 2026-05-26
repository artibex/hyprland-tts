#!/bin/bash
# ==============================================================================
# PIPER TTS INSTALLER FOR HYPRLAND (WITH AUTOMATIC LANGUAGE ROUTING DETECTION)
# ==============================================================================
set -e

echo "================================================="
echo "   Piper TTS Installer for Hyprland             "
echo "================================================="
echo ""

# 1. Verify and Install System Dependencies
echo "[1/5] Verifying and installing system dependencies..."
if command -v yay &> /dev/null; then
    AUR_HELPER="yay"
elif command -v paru &> /dev/null; then
    AUR_HELPER="paru"
else
    echo "Error: No supported AUR helper (yay or paru) detected!"
    echo "Please install an AUR helper before running this setup script."
    exit 1
fi

sudo pacman -S --needed wl-clipboard alsa-utils curl grep sed --noconfirm
$AUR_HELPER -S piper-tts-bin --noconfirm

# 2. Interactive Language Selection Framework
TTS_DIR="$HOME/.local/share/piper-tts"
mkdir -p "$TTS_DIR"

echo ""
echo "[2/5] Language Configuration Menu"
echo "Select the language models you want to install (Multiple selections allowed)."
echo "Type 'y' for yes, 'n' for no."
echo "-------------------------------------------------"

# Setup activation tracking flags
INST_DE="n"
INST_EN="n"
INST_FR="n"
INST_ES="n"
INST_CUSTOM="n"

read -p "Install German voice (Thorsten-High)? [y/N]: " choice; [[ "$choice" =~ ^[Yy]$ ]] && INST_DE="y"
read -p "Install English voice (Ryan-High)? [y/N]: " choice; [[ "$choice" =~ ^[Yy]$ ]] && INST_EN="y"
read -p "Install French voice (Siwis-Low)? [y/N]: " choice; [[ "$choice" =~ ^[Yy]$ ]] && INST_FR="y"
read -p "Install Spanish voice (Carl-Medium)? [y/N]: " choice; [[ "$choice" =~ ^[Yy]$ ]] && INST_ES="y"
read -p "Do you want to add a custom Hugging Face or direct model URL? [y/N]: " choice; [[ "$choice" =~ ^[Yy]$ ]] && INST_CUSTOM="y"

# Download Engine Block
download_model() {
    local lang_dir="$1"
    local base_url="$2"
    local model_name="$3"
    
    mkdir -p "$TTS_DIR/$lang_dir"
    echo "Downloading $model_name voice model files..."
    curl -L -o "$TTS_DIR/$lang_dir/$model_name.onnx" "$base_url/$model_name.onnx"
    curl -L -o "$TTS_DIR/$lang_dir/$model_name.onnx.json" "$base_url/$model_name.onnx.json"
}

if [ "$INST_DE" = "y" ]; then
    download_model "de" "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/high" "de_DE-thorsten-high"
fi

if [ "$INST_EN" = "y" ]; then
    download_model "en" "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high" "en_US-ryan-high"
fi

if [ "$INST_FR" = "y" ]; then
    download_model "fr" "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/siwis/low" "fr_FR-siwis-low"
fi

if [ "$INST_ES" = "y" ]; then
    download_model "es" "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/carl/medium" "es_ES-carl-medium"
fi

if [ "$INST_CUSTOM" = "y" ]; then
    echo ""
    read -p "Enter the 2-letter ISO language folder name (e.g., 'it', 'pl'): " custom_lang
    read -p "Enter full URL to the .onnx file: " custom_onnx_url
    read -p "Enter full URL to the .onnx.json file: " custom_json_url
    
    custom_model_name=$(basename "$custom_onnx_url" .onnx)
    mkdir -p "$TTS_DIR/$custom_lang"
    echo "Downloading custom voice model ($custom_model_name)..."
    curl -L -o "$TTS_DIR/$custom_lang/$custom_model_name.onnx" "$custom_onnx_url"
    curl -L -o "$TTS_DIR/$custom_lang/$custom_model_name.onnx.json" "$custom_json_url"
fi

# 3. Deploy Intelligent Backend Language Wrapper Router
echo ""
echo "[3/5] Deploying intelligent pattern-matching engine script..."
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
WRAPPER_SCRIPT="$BIN_DIR/hypr-piper-router.sh"

cat << 'EOF' > "$WRAPPER_SCRIPT"
#!/bin/bash
# Automatically routes text to correct localized Piper voice profiles based on character matches

TEXT=$(wl-paste --primary)

# Check if text is empty or contains only whitespace
if [[ -z "${TEXT// }" ]]; then
    exit 0
fi

# Configuration base directory
MODELS_BASE="$HOME/.local/share/piper-tts"

# Fallback profile settings scanning
DEFAULT_MODEL=""
if [ -d "$MODELS_BASE" ]; then
    # Look for any available model to use as a generic backup fallback
    FIRST_MODEL=$(find "$MODELS_BASE" -type f -name "*.onnx" | head -n 1)
    if [ ! -z "$FIRST_MODEL" ]; then
        DEFAULT_MODEL="$FIRST_MODEL"
    fi
fi

# Explicit Regular Expression Character Maps
REGEX_DE="[ÄäÖöÜüß]|\b(der|die|das|ist|und|nicht|es|ich|zu|mit|von|im|dem|den|ein|eine|einen)\b"
REGEX_FR="[ÉéÈèÇçÀàÙùÂâÊêÎîÔôÛûËëÏïÜü]|\b(le|la|les|et|est|un|une|des|que|dans|en|du|pour|par)\b"
REGEX_ES="[ÑñÁáÉéÍíÓóÚú¿¡]|\b(el|la|los|las|y|es|un|una|en|que|de|por|para|con|del)\b"

# Execution function handler
say_text() {
    local model_path="$1"
    echo "$TEXT" | piper-tts --model "$model_path" --output_raw | aplay -r 22050 -c 1 -f S16_LE -t raw
    exit 0
}

# 1. Language Pattern Match Execution Path
if [[ "$TEXT" =~ $REGEX_DE ]] && [ -d "$MODELS_BASE/de" ]; then
    MODEL=$(find "$MODELS_BASE/de" -type f -name "*.onnx" | head -n 1)
    [ ! -z "$MODEL" ] && say_text "$MODEL"

elif [[ "$TEXT" =~ $REGEX_FR ]] && [ -d "$MODELS_BASE/fr" ]; then
    MODEL=$(find "$MODELS_BASE/fr" -type f -name "*.onnx" | head -n 1)
    [ ! -z "$MODEL" ] && say_text "$MODEL"

elif [[ "$TEXT" =~ $REGEX_ES ]] && [ -d "$MODELS_BASE/es" ]; then
    MODEL=$(find "$MODELS_BASE/es" -type f -name "*.onnx" | head -n 1)
    [ ! -z "$MODEL" ] && say_text "$MODEL"

# 2. Default English Check or Fallback Route Execution Path
elif [ -d "$MODELS_BASE/en" ]; then
    MODEL=$(find "$MODELS_BASE/en" -type f -name "*.onnx" | head -n 1)
    [ ! -z "$MODEL" ] && say_text "$MODEL"
fi

# 3. Ultimate Fallback Array if no criteria or explicit English is found
if [ ! -z "$DEFAULT_MODEL" ]; then
    say_text "$DEFAULT_MODEL"
else
    echo "Error: No executable Piper language model found!" >&2
    exit 1
fi
EOF

chmod +x "$WRAPPER_SCRIPT"

# Ensure ~/.local/bin is part of the user path configuration context
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo "Warning: ~/.local/bin is not in your system PATH variable."
    echo "The script will use absolute execution links to bypass this."
fi

# 4. Synthesize Hyprland tts.conf configuration binding file
echo "[4/5] Generating contextual tts.conf configuration file..."
HYPR_DIR="$HOME/.config/hypr"
mkdir -p "$HYPR_DIR"

cat << EOF > "$HYPR_DIR/tts.conf"
# ==============================================================================
# System-Wide Multilingual Text-To-Speech Setup Config Module
# ==============================================================================

# TTS Initialization Triggers (SUPER + A) -> Invokes the smart regex detection router
bind = SUPER, A, exec, $WRAPPER_SCRIPT

# Interrupt Signal System Target (SUPER + ESCAPE) -> Immediately kills active audio streams
bind = SUPER, ESCAPE, exec, pkill aplay
EOF

# Link sub-config module inside main runtime instance profile
MAIN_CONF="$HYPR_DIR/hyprland.conf"
if [ -f "$MAIN_CONF" ]; then
    if grep -q "source = ./tts.conf" "$MAIN_CONF" || grep -q "source = ~/.config/hypr/tts.conf" "$MAIN_CONF"; then
        echo "tts.conf link directives are already active inside your main configuration profile."
    else
        echo "" >> "$MAIN_CONF"
        echo "# TTS (Text-to-Speech) Configuration Module Integration Link" >> "$MAIN_CONF"
        echo "source = ./tts.conf" >> "$MAIN_CONF"
        echo "Successfully appended source hooks directly inside your primary hyprland.conf profile."
    fi
else
    echo "Warning: No running hyprland.conf found. Modular configuration file saved stand-alone."
fi

# 5. Hot Environment Live Reload Execution Core
echo "[5/5] Broadcasting runtime refresh updates via hyprctl communications..."
hyprctl reload || true

echo ""
echo "================================================="
echo " Installation Complete and Environment Reloaded!"
echo " Highlight any text snippet and tap: SUPER + A"
echo " Interrupt active speech playbacks with: SUPER + ESCAPE"
echo "================================================="
