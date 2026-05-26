# hyprland-tts
 a simple TTS installation for Hyprland

# Hyprland Multilingual Text-to-Speech (TTS) Engine
An intelligent, lightweight, and system-wide Text-to-Speech solution tailored specifically for **Hyprland (Wayland)** on Arch Linux. Powered locally by the modern `piper-tts` neural engine, this tool drops heavy background daemons (like Speech Dispatcher) and replaces them with a sleek, automated routing script that automatically detects the language of your highlighted text.

---

## ✨ Features

- **Local Neural Voices:** Uses Piper TTS for realistic, clear, human-like voice synthesis running 100% offline.
- **Dynamic Language Routing (Pattern Matching):** Automatically detects the language of the selected text using regex pattern-matching (German, English, French, Spanish) and uses the appropriate voice profile instantly.
- **Interactive Multi-Voice Setup:** Choose precisely which language models to install, download multiple voices, or input a custom Hugging Face URL.
- **Zero Configuration Friction:** Keeps your `hyprland.conf` untouched by placing all binds into a separate `tts.conf` module, dynamically sourced.
- **Instant Activation:** Automatically reloads your Hyprland configuration live via `hyprctl` upon installation or uninstallation.

---

## 🛠️ System Requirements

Before running the script, make sure you fulfill these basic prerequisites:
- **OS:** Arch Linux running a **Hyprland** desktop session.
- **AUR Helper:** An active AUR helper installed (`yay` or `paru`) to fetch the Piper binaries.
- **Audio Server:** PipeWire or PulseAudio (with standard `aplay` capabilities).

---

## 🚀 Super Simple Installation

To set up your multilingual system-wide TTS engine, simply run these commands in your terminal:

```bash
# 1. Clone this repository
git clone https://github.com/artibex/hyprland-tts.git
cd hyprland-tts

# 2. Make the installer executable
chmod +x install-tts.sh

# 3. Run the installer
./install-tts.sh


# 4. Uninstall TTS by running
chmod +x uninstall-tts.sh
./uninstall-tts.sh
