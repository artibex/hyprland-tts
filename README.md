# hyprland-tts

**Accessible, multilingual, offline Text-to-Speech for Hyprland (Wayland) on Arch Linux.**

Highlight text anywhere, press a shortcut, and hear it read aloud in the right language —
powered locally by the neural [`piper-tts`](https://github.com/rhasspy/piper) engine. No
cloud, no telemetry, no background daemons.

---

## ✨ Features

- **Local neural voices** — realistic speech, 100% offline via Piper.
- **Automatic language routing** — detects German / French / Spanish / English from the
  selected text and picks the matching voice. Ambiguous text falls back to the **last voice
  you actually used**, so short snippets never get read in the wrong language.
- **Smart playback controls** — while text is being read you can jump to the next/previous
  sentence, replay the current one, speed up / slow down, and pause / resume — all from
  keyboard shortcuts.
- **Graphical voice manager** — a small GTK4 / libadwaita app to install, remove, and set
  default voices, including from a custom Hugging Face URL. Everything is also available on
  the command line.
- **Clean install / uninstall** — ships as an AUR package. Your `hyprland.conf` stays
  untouched except for a single `source = ~/.config/hypr/tts.conf` line.

---

## 🛠️ Requirements

- Arch Linux with a **Hyprland** (Wayland) session.
- PipeWire or PulseAudio (`aplay` from `alsa-utils`).
- For the AUR install: an AUR helper (`yay` or `paru`).
- Voices are downloaded on first use (needs a network connection once).

---

## 🚀 Install

### Option A — AUR package (recommended)

```bash
yay -S hyprland-tts        # or: paru -S hyprland-tts
hyprland-tts setup         # wires the keybinds into your Hyprland config
hyprland-tts gui           # install a voice (or: hyprland-tts model install en-ryan-high)
```

### Option B — from the git checkout

```bash
git clone https://github.com/artibex/hyprland-tts.git
cd hyprland-tts
./install-tts.sh           # installs into ~/.local and runs setup for you
```

Then highlight some text and press **SUPER + A**.

---

## ⌨️ Default keybinds

| Shortcut | Action |
| --- | --- |
| `SUPER + A` | Speak the highlighted (primary) selection |
| `SUPER + ESCAPE` | Stop speech |
| `SUPER + ALT + →` / `←` | Next / previous sentence |
| `SUPER + ALT + ↑` / `↓` | Speed up / slow down |
| `SUPER + ALT + Space` | Pause / resume |
| `SUPER + ALT + R` | Replay current sentence |

Edit `~/.config/hypr/tts.conf` to change them — it's a normal Hyprland config file.

---

## 🎙️ Managing voices

Use the GUI:

```bash
hyprland-tts gui
```

…or the command line:

```bash
hyprland-tts model catalog                 # curated voices you can install
hyprland-tts model install en-ryan-high    # install one
hyprland-tts model list                    # what's installed (marks default / last used)
hyprland-tts model default de/de_DE-thorsten-high   # per-language default voice
hyprland-tts model remove fr/fr_FR-siwis-medium     # remove a voice
# custom voice from a direct/HF URL:
hyprland-tts model install-url it https://.../it_IT-riccardo-x_low.onnx
```

Voices live in `~/.local/share/piper-tts/<lang>/`.

---

## 🗑️ Uninstall

```bash
hyprland-tts purge          # optional: also delete downloaded voices + settings
yay -Rns hyprland-tts       # remove the package
```

From a git checkout instead: `./uninstall-tts.sh`.

`hyprland-tts uninstall` removes only the keybinds (keeps your downloaded voices);
`hyprland-tts purge` removes the keybinds **and** the voices/state/config.

---

## 🧠 How language routing works

1. The selected text is matched against character sets and stop-words for German, French,
   Spanish, and English (in that order).
2. If a language is detected and you have a voice for it, that voice is used.
3. If **nothing** matches (a name, a number, a URL, a single word), it reuses the **last
   voice actually used**.
4. Otherwise it falls back to English, then to any installed voice.

The chosen voice is remembered in `~/.local/state/piper-tts/last-model`.

Speech is spoken sentence by sentence, which is what makes the next/previous/replay
controls possible. (Word-level seeking isn't offered because the `piper-tts-bin` engine
doesn't expose per-word timing — the sentence is the reliable navigation unit.)

---

## 🤖 Contributing

This project is developed largely by AI coding agents. If you're an agent (or a human doing
deep work), read **[Agent.md](Agent.md)** first — it's the architecture and conventions
briefing.

## 📄 License

See [LICENSE](LICENSE).
