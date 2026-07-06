# hyprland-tts

**Accessible, multilingual, offline Text-to-Speech for Hyprland (Wayland) on Arch Linux.**

Highlight text anywhere, press a shortcut, and hear it read aloud in the right language —
powered locally by the neural [`piper-tts`](https://github.com/rhasspy/piper) engine. No
cloud, no telemetry, no background daemons.

---

## ✨ Features

- **Local neural voices** — realistic speech, 100% offline via Piper.
- **Automatic language routing** — detects German / French / Spanish / English from the
  selected text and picks the matching voice. Ambiguous text falls back to a voice you
  choose (see *Fallback voice* below), or the **last voice you actually used** if you
  haven't set one, so short snippets never get read in the wrong language.
- **Smart playback that responds instantly** — while text is read you can jump to the
  next/previous sentence, replay, speed up / slow down, and pause / resume from the
  keyboard. Playback runs through **mpv**, so speed changes are smooth and pitch-preserving
  and skipping is instant (no stutter or re-loading).
- **Voiceover text cleanup** — prose is run through an optimizer that strips markdown,
  decorative symbol rows, and stray markup, and collapses the whitespace that otherwise
  causes long dead-air pauses — without changing the meaning. **Source code gets its own
  cleanup**: it's auto-detected and read in a form meant for listening — operators become
  words (`==` → "equals"), comment markers are stripped but the comment text is kept,
  identifiers like `getUserName` are split into pronounceable words, and structural noise
  (`{ } ( ) [ ] ;`) is turned into pauses or dropped instead of read aloud symbol-by-symbol.
- **Reads copied images** *(optional)* — if you copy an image, it reads the embedded
  description (via exiftool) or the text inside it (via tesseract OCR). *(Web image
  alt-text can't be reached by a global tool — that lives in the browser DOM.)*
- **Speak whatever's under your mouse cursor** *(optional, on-demand)* — press a shortcut
  and it reads the text at the current pointer position, no selecting required. Works in
  apps that expose accessibility info (most GTK/Qt apps, file managers, many browsers) —
  not in terminals, games, or most Electron apps (VS Code, Discord, Slack) unless they've
  had accessibility explicitly turned on. This is a single on-demand query, not continuous
  hover-tracking — see *How it works* for why.
- **Graphical manager** — a GTK4 / libadwaita app to install/remove/default voices **and**
  rebind shortcuts, with conflict checking against your other Hyprland binds. Everything is
  also available on the command line.
- **Clean install / uninstall** — ships as an AUR package. Your `hyprland.conf` gets a
  single `source = ~/.config/hypr/tts.conf` line and nothing else.

---

## 🛠️ Requirements

- Arch Linux with a **Hyprland** (Wayland) session.
- Installed automatically as dependencies: `piper-tts-bin`, `mpv`, `socat`, `wl-clipboard`,
  `gtk4`, `libadwaita`, `python-gobject`.
- Optional: `tesseract` (+ language data) and `perl-image-exiftool` for reading images;
  `at-spi2-core` for the "speak under cursor" shortcut.
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

## ⌨️ Shortcuts

| Shortcut | Action |
| --- | --- |
| `SUPER + A` | Speak the highlighted selection (or a copied image) |
| `SUPER + ALT + H` | Speak the text under the mouse cursor |
| `SUPER + ESCAPE` | Stop speech |
| `SUPER + ALT + →` / `←` | Next / previous sentence |
| `SUPER + ALT + ↑` / `↓` | Speed up / slow down (live, pitch-preserving) |
| `SUPER + ALT + Space` | Pause / resume |
| `SUPER + ALT + R` | Replay current sentence |

**Rebinding is safe and easy.** Use the GUI's *Shortcuts* tab (press a new combo; it warns
if it clashes with another Hyprland bind), or the CLI:

```bash
hyprland-tts keybind list
hyprland-tts keybind set speak "SUPER, B"     # refuses if the combo is taken
hyprland-tts keybind set speak "SUPER, B" --force
hyprland-tts keybind reset                    # back to defaults
```

---

## 🎙️ Managing voices

GUI: `hyprland-tts gui`. Or the command line:

```bash
hyprland-tts model catalog                 # curated voices you can install
hyprland-tts model install en-ryan-high    # install one
hyprland-tts model list                    # installed (marks default / fallback / last used)
hyprland-tts model default de/de_DE-thorsten-high   # per-language default
hyprland-tts model remove fr/fr_FR-siwis-medium     # remove
hyprland-tts model install-url it https://.../it_IT-riccardo-x_low.onnx   # custom URL
```

Voices live in `~/.local/share/piper-tts/<lang>/`.

**Fallback voice.** By default, if the language of a selection can't be detected, the
last voice you spoke with is reused. You can pin this explicitly instead — in the GUI's
*Voices* tab, click **Fallback** next to any installed voice; on the CLI:

```bash
hyprland-tts model fallback fr/fr_FR-siwis-medium   # always use this when undetected
hyprland-tts model fallback                         # show the current fallback voice
hyprland-tts model fallback --clear                 # back to "last voice used"
```

---

## 🗑️ Uninstall

```bash
hyprland-tts purge          # optional: also delete downloaded voices + settings
yay -Rns hyprland-tts       # remove the package
```

From a git checkout instead: `./uninstall-tts.sh`.
`hyprland-tts uninstall` removes only the keybinds (keeps voices); `purge` removes
keybinds **and** voices/state/config.

---

## 🧠 How it works

**Language routing:** the selection is matched against character sets and stop-words for
German, French, Spanish, then English. If a language is detected and you have a voice for
it, that voice is used. If nothing matches (a name, number, URL), it uses your configured
**fallback voice** if you've set one, else the **last voice actually used**
(`~/.local/state/piper-tts/last-model`); otherwise English, then any installed voice.

**Code vs. prose:** selected text is scored against a few signals (symbol density, code
keywords, indentation, camelCase/snake_case identifiers). Text that looks like source code
gets the code-specific cleanup described above instead of the prose one; this is a
heuristic, not a parser, so very short or unusual snippets may be judged either way.

**Playback:** text is cleaned, split into sentences, each rendered once by Piper to audio,
and played by a single mpv instance driven over an IPC socket. That's what makes
next/previous/speed/pause **instant** — the controls are native mpv commands, not
re-synthesis. Because of this, navigation granularity is a *sentence*; word-level seeking
isn't offered (the Piper engine exposes no per-word timing).

**Speak under cursor:** this asks Hyprland for the current pointer position, then asks
AT-SPI (the Linux accessibility framework screen readers use) what text is exposed there.
It's deliberately **one query per keypress, not continuous hover-tracking** — real-time
hover would need a background process constantly watching the mouse, which this project
avoids on principle (no background daemons, ever). Coverage depends entirely on whether the
app under your cursor implements accessibility; most GTK/Qt apps and browsers do, terminals
and games generally don't, and most Electron apps don't unless their accessibility has been
explicitly turned on. It also, necessarily, reads whatever is actually on your screen —
keep that in mind before using it over something you wouldn't want read aloud.

---

## 🛟 Troubleshooting

**`hyprland-tts gui` says GTK4/libadwaita/PyGObject are missing, but they're installed.**
You likely have another `python3` earlier on your `PATH` (pyenv, mise, conda, uv, asdf) —
pacman's `python-gobject` only installs into the *system* Python's site-packages.
`hyprland-tts gui` already checks `/usr/bin/python3` as a fallback; if it still fails,
confirm with `which python3` and `/usr/bin/python3 -c 'import gi'`.

**Never run `hyprland-tts` (or the GUI) with `sudo` / as root.** It needs your desktop's
Wayland session and your own `~/.config`/`~/.local` — as root neither is reachable, and
you'll get errors like `Authorization required` or `Gtk couldn't be initialized`. Every
subcommand refuses to run as root for this reason; just run it as your normal user.

**The desktop menu icon doesn't launch the GUI, but it works from a terminal.** This was a
real bug: the app-launcher environment can resolve `python3` differently than a terminal
shell does, and — unlike `hyprland-tts gui` — a raw `.desktop` launch had no fallback for
that. Both are fixed (the `.desktop` entry now goes through the same CLI wrapper, and the
GUI script self-corrects its interpreter either way); update to the latest package if
you're still seeing this.

**A shortcut (e.g. hover) seems to do nothing at all, even right after installing.** Before
assuming something's broken: check what's *actually* bound, since a keybind can silently
differ from the documented default (yours or an earlier customization):

```bash
hyprland-tts keybind list          # what's really bound right now
hyprland-tts keybind reset hover   # back to the SUPER+ALT+H default, if you want it
```

No reboot or reinstall is needed for keybind changes — `hyprland-tts setup` (or any
`keybind set`/`reset`) already reloads Hyprland for you. If a shortcut still does nothing
and you have `libnotify` installed, hover will now pop a desktop notification when a real
dependency (Hyprland, AT-SPI) is missing, instead of failing in total silence.

---

## 🤖 Contributing

This project is developed largely by AI coding agents. Read **[Agent.md](Agent.md)** first —
it's the architecture and conventions briefing (modular `lib/` layout, one-brain/thin-skins
rule, test commands).

## 📄 License

See [LICENSE](LICENSE).
