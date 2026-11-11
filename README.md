# hyprland-tts

**Accessible, multilingual, offline Text-to-Speech for Hyprland (Wayland) on Arch Linux.**

Highlight text anywhere, press a shortcut, and hear it read aloud in the right language. Since
**2.0** the default voice is a neural **Qwen3-TTS** engine running on your GPU (Vulkan), with
one native-sounding voice per language, per-sentence language detection and proper reading of
numbers, dates and abbreviations. The light [`piper-tts`](https://github.com/rhasspy/piper)
engine stays as a fast fallback. 100% offline: no cloud, no telemetry, no permanent daemon.

---

## ✨ Features

- **Neural voices (new in 2.0)** — Qwen3-TTS 0.6B via [`qwentts.cpp`](https://github.com/ServeurpersoCom/qwentts.cpp)
  on the integrated GPU (Vulkan) or the CPU. Built and installed in your user directory with
  one command; the first sentence is **played while it is still being generated**, so speech
  starts about a second after the shortcut (see *Latency*).
- **One native voice per language** — German, English, French, Spanish and Italian voices are
  cloned from licence-clean reference clips that ship with the package. You can add your own
  (WAV + transcript) and choose a voice per language.
- **Real language detection, per sentence** — a 1 MB offline fastText model. A text that
  switches between German and English switches voice sentence by sentence.
- **Per-language text normalisation** — numbers, dates, times, currency, units, abbreviations
  and shell commands are written out in words before synthesis, because neural voices
  otherwise read them literally.
- **On-demand engine worker** — the neural engine starts on the first speak, stays warm
  (about 1.2 GB RAM) and exits on its own after `WORKER_IDLE_MINUTES` without requests. While
  the model loads you get a short **"loading voice…"** notification, so a slow first sentence
  does not look like a dead shortcut.
- **Selection size cap** — a very long selection (for example an accidental select-all) is
  limited to a maximum size so the engine cannot be kept busy for minutes.
- **Piper as light fallback** — fast and small. Used when Qwen3 is not installed, selected
  explicitly, or when a chunk fails (you get one notification, speech continues).
- **Smart playback that responds instantly** — next/previous sentence, replay, speed up/down
  and pause/resume while text is read. Playback runs through **mpv**, so speed changes are
  pitch-preserving and skipping is instant.
- **Own volume, own mixer entry** — the reader appears as `hyprland-tts` in the system mixer
  (not as a generic `mpv`), and `hyprland-tts volume <0-100>` or the GUI slider sets its volume
  on top of the system volume, live while it speaks.
- **Voice preview** — `hyprland-tts preview <lang>` (or the ▶ buttons in the GUI) speaks a
  sample sentence with the voice a language would get, or with one installed Piper voice.
- **Speak text from scripts** — `hyprland-tts say` reads words or stdin aloud through the same
  player (optionally in a fixed language, optionally waiting until it has finished), without
  touching your selection.
- **Voiceover text cleanup** — markdown, decorative symbols and stray markup are removed;
  **source code gets its own cleanup** (operators become words, identifiers are split,
  braces become pauses). Classified per paragraph.
- **Reliable on long documents** — playback never cuts off mid-document, even when one chunk
  renders slowly.
- **Quality gate on every chunk** — silent or runaway renders are detected and retried;
  loudness is normalised so voices switch without volume jumps.
- **Reads copied images** *(optional)* — embedded description (exiftool) or text in the image
  (tesseract OCR).
- **Speak whatever is under your mouse cursor** *(optional, on-demand, CLI-only)* —
  `hyprland-tts hover`, via AT-SPI.
- **Graphical manager** — GTK4 / libadwaita app with four pages: **Engine** (status, choose
  engine, install with live log and cancel, worker control), **Voices** (volume and stop, voice
  per language, cloned voices with licence confirmation, Piper voices, ▶ preview buttons),
  **Language** (language-detection
  helpers) and **Shortcuts**. Everything is also available on the command line.
- **Clean install / uninstall** — AUR package; your `hyprland.conf` gets a single
  `source = ~/.config/hypr/tts.conf` line and nothing else.

---

## 🛠️ Requirements

- Arch Linux with a **Hyprland** (Wayland) session.
- Installed automatically as dependencies: `piper-tts-bin`, `mpv`, `socat`, `wl-clipboard`,
  `curl`, `python`, `gtk4`, `libadwaita`, `python-gobject`.
- **For the neural engine** (`hyprland-tts engine install qwen3`): `cmake git gcc make`; for
  the GPU build also `shaderc` and `vulkan-icd-loader` (plus a Vulkan driver such as
  `vulkan-radeon`). `vulkan-headers` and `spirv-headers` are optional: pinned copies are
  fetched into your user directory when the system has none.
- **For language detection and normalisation** (`hyprland-tts deps install`): Python 3.9–3.13
  or `g++` (see Troubleshooting for Python 3.14). Alternatively install the AUR packages
  `python-fasttext-predict` and `python-num2words` and skip the private environment.
- Optional: `tesseract` (+ language data) and `perl-image-exiftool` for reading images;
  `at-spi2-core` for the "speak under cursor" command; `libnotify` for failure notifications.
- Network is needed only for explicit downloads: voices, the engine build (GitHub, Hugging
  Face) and the helper packages (PyPI, fastText model).

---

## 🚀 Quick start

```bash
# 1. Install
yay -S hyprland-tts                      # or: paru -S hyprland-tts
#    from a git checkout instead: makepkg -si   (package, preferred)
#                              or ./install-tts.sh (~/.local) — never both, see Troubleshooting

# 2. Wire the shortcuts into Hyprland (idempotent)
hyprland-tts setup

# 3. Language detection + number reading (small venv + 1 MB model)
hyprland-tts deps install

# 4. Neural engine: builds qwentts.cpp (Vulkan if possible, else CPU) and downloads
#    about 2.2 GB of verified models. Takes roughly 7 minutes. Nothing runs as root.
hyprland-tts engine install qwen3 --variant base

# Check it
hyprland-tts engine status
```

Then highlight some text and press **SUPER + ALT + A**. Steps 3 and 4 can also be done from the GUI
(`hyprland-tts gui`, tabs *Language* and *Engine*) with a live log and a Cancel button.

Without steps 3 and 4 everything still works with Piper voices
(`hyprland-tts model install de-thorsten-high` or the GUI *Voices* tab).

---

## 🔊 Engines

`ENGINE=auto` (default) uses Qwen3-TTS when it is installed and usable and Piper otherwise.
Force one with `hyprland-tts engine use auto|qwen3|piper`.

Measured on the reference machine (Ryzen 6000 "Rembrandt", 12 threads, 30 GB RAM, Radeon 680M
iGPU, **no** ROCm/CUDA). RTF = synthesis time / audio time (below 1 is faster than real time).
The machine was shared with other jobs while measuring, so expect roughly ±20 % noise.

| Engine / runtime | RTF | RAM | First audio | Cold start | CER* | Verdict |
|---|---|---|---|---|---|---|
| **Piper** (medium/high voices, CPU) | 0.04–0.23 | 0.2–0.4 GB | ~0.3 s | 0.24–0.4 s | 0.040 | fast, more robotic prosody; **fallback** |
| **Qwen3-TTS 0.6B, `qwentts.cpp` Q8_0, Vulkan (iGPU)** | **0.62–0.77 warm** | **1.2 GB** | **0.2 s warm** | worker ready in ~1 s | 0.035 | **primary engine** |
| Qwen3-TTS 0.6B, `qwentts.cpp` Q8_0, CPU only | 1.1–1.4 (up to 10× worse under CPU load) | 3.2–4.3 GB | ~1 s | ~1 s | 0.07 | borderline real time; CPU fallback |
| Qwen3-TTS 0.6B, official PyTorch (CPU, fp32) | 9.6 | 5.7 GB | none (no streaming) | 23 s | 0.023 | far too slow; not used |
| Qwen3-TTS 1.7B, Vulkan | 0.8–1.0 | 2.3 GB | 0.35 s | 1.5 s | 0.06 | no measurable gain; not the default |
| Chatterbox Multilingual V3 (torch, CPU) | 5.4–30 | 6.7 GB (4.9 GB disk) | none (no streaming) | 14–33 s | 0.039 | too heavy; **not integrated** |
| Chatterbox Turbo / Nano (English only) | 1.2–3.0 | 4–6 GB | none | 12–28 s | 0.035 | English only; not integrated |

\* CER = character error rate of an automatic transcription (Whisper-small) of the synthesized
speech on an 8-sentence de/en/fr/es/it test set. It measures intelligibility, **not**
naturalness: single seed, so differences below about 0.02 are noise. Final voice choice is by
ear.

**Why Qwen3-TTS.** Apache-2.0 weights, ten model languages (zh, en, ja, ko, de, fr, ru, pt, es, it),
real streaming in `qwentts.cpp` (MIT), and it runs in real time on an integrated GPU with
1.2 GB RAM. **Supported languages: de, en, fr, es, it (native cloned voices); further Qwen3 languages
(pt, ru, zh, ja, ko) are experimental** — sentence splitting for CJK text is limited, so
they may be reduced or dropped in a later release. The built-in preset speakers are native
only in zh/en/ja/ko, so the **Base** model is used with zero-shot cloning from a licence-clean
reference clip per language (see *Voices*). Known model quirks, all handled by the pipeline: it reads numbers and
abbreviations literally (→ normaliser), and may run away on very short inputs (→ generation
cap proportional to text length, retry, Piper fallback).

**Why not Chatterbox.** It was evaluated seriously (MIT, 23 languages) and loses on every
efficiency axis on this class of hardware: RTF 5–30 on CPU, 6.7 GB resident, 15–35 s cold
start, no streaming; its intelligibility (CER 0.039) is no better than Piper's (0.040). The
upstream project declared itself retired in August 2026, there is no per-language default
voice, and its only fast variants are English-only. It is not integrated; revisit if a GPU
backend for it matures.

### Latency (shortcut → first sound)

Measured with the real Vulkan engine on the reference machine (Radeon 680M), a 34-character
first sentence (2 s of audio), mpv with a null audio output; "first sound" = mpv's playback
position passed 0.1 s. Medians of the runs listed; the text is the six-chunk smoke test.

| | Before (whole chunk first) | After (`STREAM_FIRST_CHUNK=1`) |
|---|---|---|
| Warm worker | 2.6 s (2.5–2.9 s, 6 runs) | **1.0 s** (0.9–1.1 s, 6 runs) |
| Cold worker (model load + first-request warm-up) | 4.0–4.5 s (2 runs) | 3.2–3.7 s (2 runs) |
| All six chunks played, total | 26.9 s (all 6 chunks play) | 26.5–28 s (all 6 chunks play; render-bound, unchanged) |

Where the remaining ~1 s goes (warm): about 0.3–0.4 s between the key press and the request
(`speak`'s text preparation 0.15 s, then player and mpv start), 0.05 s starting the helper,
0.1–0.25 s until the engine's first audio, 0.3 s until mpv has the 12000 bytes (0.25 s of audio)
its raw-audio reader insists on, and the 0.1 s the measurement itself counts as played. Streaming applies to the **first chunk
only**; later chunks are rendered while it plays. CPU builds and Piper keep the old behaviour
(a CPU build is slower than real time, so a live stream would stutter) including the short
90-character first chunk.

**The pause after the first chunk.** The engine renders one chunk at a time, so chunk 2 only
starts when chunk 1 has been generated (≈ 0.6 s per second of audio, while it plays for 1 s).
With a short streamed first sentence nothing could hide that: the pause was about 1.9 s. Since
a streamed first chunk starts playing after its first 0.25 s of audio whatever its length, it is
now built long (up to 200 characters, 8–12 s of audio) and the second chunk is kept at 70
characters. Same text, warm worker, real engine (medians of the runs; `speak` → mpv with a null
audio output):

| | Before (short first chunk) | After (long first chunk) |
|---|---|---|
| First sound, warm | 0.9 s (0.82–1.20 s, 4 runs) | 0.9 s (0.85–1.37 s, 6 runs) |
| Pause after the first chunk | **2.2 s** (1.3–2.3 s) | **0.6 s** (0.53–0.64 s) |
| Other pauses | 0.45–1.4 s | 0.45–0.65 s |
| Whole two-paragraph text played | 24.6–25.5 s | 22.1–24.3 s |
| One 122-character sentence | 2 chunks, 0.87 s pause | 1 chunk, no pause |

The remaining 0.5–0.6 s between chunks is mpv opening the next file.

### Choosing an engine

| You have | Do this |
|---|---|
| A Vulkan-capable GPU or iGPU (most AMD/Intel/NVIDIA desktops and laptops) | `engine install qwen3` (auto-detects Vulkan) |
| No usable GPU, a fast CPU | `engine install qwen3 --cpu` (works, but expect RTF ~1.4; may stutter under load) |
| Old hardware / little RAM | stay on Piper: `engine use piper` |

`hyprland-tts engine install qwen3 [--cpu|--vulkan] [--variant base|customvoice]`:

- `base` (default): native cloned voice per language, requires at least one cloned voice
  (five are shipped).
- `customvoice`: nine built-in preset speakers (ryan, aiden, vivian, serena, uncle_fu, dylan,
  eric, ono_anna, sohee); native only in zh/en/ja/ko, they speak every language with an accent.

Switch the active model without reinstalling the engine with
`hyprland-tts engine variant base|customvoice` (the GUI's *Switch model* button; the other
model's weights must be installed, which `engine install qwen3 --variant …` does).
`engine remove qwen3` deletes the engine and models but keeps your cloned voices and settings.

---

## 🎙️ Voices

### Neural voices (Qwen3-TTS)

One voice per language. Shipped voice packs (`share/hyprland-tts/shipped-voices/<name>/`, each with its
own `ATTRIBUTION.md`):

| Voice | Language | Speaker / corpus | Licence | Obligation |
|---|---|---|---|---|
| `de-thorsten` | German | Thorsten Müller, Thorsten-Voice 2022.10 | **CC0 1.0** | none (citation requested) |
| `en-lj` | English (US) | LJ Speech reader (LibriVox), Keith Ito | **Public domain** | none |
| `fr-siwis` | French | SIWIS professional voice talent, Univ. of Edinburgh | **CC BY 4.0** | attribution; **no derogatory use** of the voice |
| `es-mls-8585` | Spanish | Multilingual LibriSpeech speaker 8585 (LibriVox) | **CC BY 4.0** | attribution (Pratap et al. 2020) |
| `it-mls-8582` | Italian | Multilingual LibriSpeech speaker 8582 (LibriVox) | **CC BY 4.0** | attribution (Pratap et al. 2020) |

The full attribution text of every pack is in its `ATTRIBUTION.md` and in
[THIRD_PARTY.md](THIRD_PARTY.md). The GUI shows it behind the ⓘ button of each voice. Voice
licences cover the recordings; personality rights of the speakers are not covered by
copyright licences, and this is not legal advice.

```bash
hyprland-tts voice list                          # per-language assignment, presets, cloned voices
hyprland-tts voice set de de-thorsten            # choose the voice for a language
hyprland-tts voice set de --clear                # back to the default
hyprland-tts voice add anna ref.wav transcript.txt --license LICENSE.txt
hyprland-tts voice remove anna                   # user voices only; shipped ones are read-only
```

**Adding your own voice** needs the `base` variant. Use a clean 6–12 s recording of **one**
speaker in the target language (WAV) and a text file with exactly the words spoken. Only use
recordings you may use for this: your own voice, a licence that allows it, or the speaker's
consent. The GUI (*Voices → Add voice…*) makes you confirm that, and stores the confirmation
(or the licence file you give it) next to the voice. Voices are created locally; the voice name
may contain `a-z 0-9 _ -`. Languages without a shipped voice (pt, ru and the experimental zh, ja, ko) use the Base
model's built-in default voice until you add one.

Cost of cloning (0.6B Vulkan, measured): preset RTF 0.65, cloned voice with transcript 0.77,
same RAM; first audio 120 ms → 176 ms.

### Piper voices

Unchanged from 1.x; they live in `~/.local/share/piper-tts/<lang>/` and are used by the Piper
engine and as the safety net.

```bash
hyprland-tts model catalog                 # curated voices you can install
hyprland-tts model install en-ryan-high    # install one
hyprland-tts model list                    # installed (marks default / fallback / last used)
hyprland-tts model default de/de_DE-thorsten-high   # per-language default
hyprland-tts model remove fr/fr_FR-siwis-medium     # remove
hyprland-tts model install-url it https://.../it_IT-riccardo-x_low.onnx   # custom URL
hyprland-tts model fallback fr/fr_FR-siwis-medium   # voice for undetected language (--clear to unset)
```

### Previewing a voice

`hyprland-tts preview <lang>` speaks a built-in sample sentence (de, en, fr, es, it, pt, ru, zh,
ja, ko) through the normal player, so volume, speed and the stop shortcut apply. The language is
fixed, no detection runs.

```bash
hyprland-tts preview de                    # active engine: what the speak shortcut would use
hyprland-tts preview fr --engine piper     # force an engine (qwen3 or piper)
hyprland-tts preview de --model de/de_DE-thorsten-high   # one installed Piper voice
```

`--model` must name a voice of the same language. A preview does not change the "last used"
voice. It fails with a message for a language without a sample sentence, a language without a
voice for the engine, `--engine qwen3` when Qwen3 is not usable, and a model of another language.
In the GUI every neural *voice per language* row and every installed Piper voice has a ▶ button
(the neural one is disabled when Qwen3 is not installed or the language has no voice).

### Speak text from scripts

`hyprland-tts say` reads text given to it instead of the selection, so a script or an assistant
can speak without touching what you highlighted. The words are joined with single spaces; with no
words (or a single `-`) it reads all of stdin. It uses the normal player: volume, speed, the stop
shortcut, the length limit (`SELECTION_MAX_CHARS`) and the Piper fallback apply, and a new `say` or
`speak` replaces a reading in progress.

```bash
hyprland-tts say "Der Build ist fertig."                    # detected language, returns at once
printf '%s' "$text" | hyprland-tts say --lang de --wait     # German, returns after playback
hyprland-tts say -- "-5 Grad draußen"                       # -- : text may start with a dash
```

`--lang <code>` fixes the language (no detection); it must have a voice for the active engine,
otherwise `say` fails with a message. `--wait` returns only when this reading has ended — played
to the end, stopped (`hyprland-tts stop` or the shortcut) or replaced by another reading — so
calls can be chained; Ctrl+C ends the wait, not the reading. `say` prints nothing on success;
errors go to stderr with exit status 1 (unknown option, a language without a voice,
`nothing to say` for empty or whitespace-only text).

---

## 🌍 Language detection and text preparation

`hyprland-tts deps install` creates a private Python environment in
`~/.local/share/hyprland-tts/venv` with two pinned, hash-checked packages
([`fasttext-predict`](https://pypi.org/project/fasttext-predict/) and
[`num2words`](https://pypi.org/project/num2words/)) and downloads the 938 KB fastText model
`lid.176.ftz` (sha256-verified). Nothing runs as root. `deps status` shows what is in place,
`deps remove` deletes it.

What it does for every selection:

1. **Clean up** markdown and code (as before).
2. **Normalise per language** (de, en, fr, es, it): cardinal/ordinal numbers, decimals,
   dates and times, currency, percent, units, common abbreviations, acronyms and command
   lines — `1.250,75 Euro` becomes words, `sudo pacman -Syu` is spelled out sensibly.
3. **Detect the language per sentence** with fastText, restricted to the languages that have a
   voice and smoothed over neighbouring sentences. Measured: 99.5–100 % on whole texts
   (the old regex router: 60 %), 100 % per sentence on a held-out mixed-language set, 38 ms
   cold start, 2 MB model.
4. **Chunk** into sentences. When the first sentence will be streamed (see *Latency*) the first
   chunk is **long**, up to 200 characters with whole sentences merged into it, because its
   length no longer delays the first sound and the audio it holds gives the engine time to
   render the second chunk; then the chunks grow step by step (70, 78, 90 … 220 characters).
   Without streaming (Piper, CPU builds, `STREAM_FIRST_CHUNK=0`) the first chunk is at most
   90 characters so speech starts fast.

**Fallback without the helpers:** if the venv or the model is missing the old bash/regex path
takes over (German/French/Spanish/English detection from stop-words for the whole text, no
per-sentence switching, no language-specific normalisation). Nothing breaks; mixed-language
text just stays in one voice and numbers may sound wrong.

**Known limitation:** language detection works per sentence with smoothing over neighbours, so
a very short sentence in another language is absorbed by the surrounding language. For
example, in `Hello world. Das ist ein Test.` the short English opener is read with the German
voice. Longer sentences switch correctly.

---

## ⌨️ Shortcuts

| Shortcut | Action |
| --- | --- |
| `SUPER + ALT + A` | Speak the highlighted selection (or a copied image) |
| `SUPER + ALT + ESCAPE` | Stop speech (the warm engine worker keeps running; `engine stop` frees its RAM) |
| `SUPER + CTRL + ALT + →` / `←` | Next / previous sentence |
| `SUPER + CTRL + ALT + ↑` / `↓` | Speed up / slow down (live, pitch-preserving) |
| `SUPER + CTRL + ALT + Space` | Pause / resume |
| `SUPER + ALT + R` | Replay current sentence |

**hyprland-tts is an add-on, so its defaults never take a key the desktop already uses.** Start,
stop and replay sit on `SUPER + ALT`, the live playback controls on `SUPER + CTRL + ALT`; none
of them is bound by Omarchy 4 (checked against its default bindings by the test suite). The old
1.x defaults (`SUPER + A`, `SUPER + ESCAPE`, `SUPER + ALT + arrows/Space`) clash with Omarchy's
*Select all*, *System menu*, group moves and *Apps* — see Troubleshooting. `hyprland-tts setup`
warns about every shortcut another bind also uses.

`hover` is CLI-only (`hyprland-tts hover`) and intentionally hidden from the Shortcuts UI and
the default bindings while that feature is stabilised.

**Rebinding is safe and easy.** Use the GUI's *Shortcuts* tab (press a new combo; it warns if
it clashes with another Hyprland bind), or the CLI:

```bash
hyprland-tts keybind list
hyprland-tts keybind set speak "SUPER ALT, B"     # refuses if the combo is taken
hyprland-tts keybind set speak "SUPER ALT, B" --force
hyprland-tts keybind reset                    # back to defaults
```

---

## 🖥️ Graphical manager

`hyprland-tts gui` (or the *hyprland-tts* launcher entry). It is a thin skin: it only
runs the CLI, so everything it does can be done in a terminal.

| Page | What you can do |
|---|---|
| **Engine** | See the active engine, why Qwen3 is inactive, compute device and worker state; choose Automatic / Qwen3 / Piper; install Qwen3 (backend and model choice, live log, Cancel); remove it; start/stop the worker; set the idle timeout (1–240 min). |
| **Voices** | *Playback* group on top: volume slider (applied after a short pause while dragging) and a Stop button. Preview (▶) the neural voice of a language or an installed Piper voice. Pick the neural voice per language; add a cloned voice from a WAV and transcript (with mandatory licence/consent confirmation); remove your own voices; read the attribution of shipped voices; manage Piper voices (install, default, fallback, remove, custom URL). |
| **Language** | See whether per-sentence detection is ready; install/remove the helpers with a live log; short explanation of the fallback. |
| **Shortcuts** | Rebind or reset shortcuts with conflict checking. |

Closing the window during an install asks first, because it cancels the install.

---

## 📟 Command reference

```text
hyprland-tts speak | hover | stop | ctl <next|prev|restart|faster|slower|pause|resume|toggle|status>
hyprland-tts volume [<0-100>]                        # show / set the reader volume (live)
hyprland-tts preview <lang> [--engine qwen3|piper] [--model <lang>/<name>]
hyprland-tts say [--lang <code>] [--wait] [--] [<text>...]   # speak text (none or -: stdin)
hyprland-tts engine status [--porcelain]
hyprland-tts engine install qwen3 [--cpu|--vulkan] [--variant base|customvoice]
hyprland-tts engine remove qwen3
hyprland-tts engine use auto|qwen3|piper
hyprland-tts engine variant base|customvoice        # switch the active model, no reinstall
hyprland-tts engine start | stop                     # warm the worker / free its RAM
hyprland-tts engine config idle <minutes 1-240>
hyprland-tts voice list [--porcelain] | add <name> <wav> <transcript> [--license F] | remove <name>
hyprland-tts voice set <lang> <voice|--clear>
hyprland-tts deps install | status [--porcelain] | remove
hyprland-tts model list|catalog|install|install-url|remove|default|fallback
hyprland-tts keybind list|set|check|reset
hyprland-tts gui | setup | uninstall | purge | help
```

`stop` stops playback only; `engine stop` stops the worker. `ctl status` prints
`pos=<n>/<count> speed=<x> paused=<bool> volume=<v>` (or `idle`).

`volume` without a value prints the stored volume; with a value it stores it and changes a
reader that is speaking right now. It is mpv's own volume (a cubic curve like system mixers),
applied on top of the system volume. It stops at 100 on purpose: speech is loudness-normalised
to about −21 dBFS RMS with peaks near full scale, so amplification above 100 would clip.

---

## ⚙️ Configuration

The config file is `~/.config/piper-tts/config` (sourced bash, `KEY=value`). Prefer the CLI
or GUI; every key below can also be set by hand.

| Key | Default | Meaning |
|---|---|---|
| `ENGINE` | `auto` | `auto` (Qwen3 when usable), `qwen3` or `piper`. |
| `QWEN_VARIANT` | `base` | Loaded model: `base` (cloned voices) or `customvoice` (preset speakers). Set by `engine install`. |
| `QWEN_VOICE_<lang>` | – | Voice for a language, e.g. `QWEN_VOICE_de=de-thorsten`. Set by `voice set`. |
| `WORKER_IDLE_MINUTES` | `10` | Idle minutes before the warm worker exits. Set by `engine config idle` (1–240). |
| `DEFAULT_LANG` | `en` | Language assumed when detection finds nothing usable. |
| `QWEN_DEVICE` | from install | Override the compute device, e.g. `CPU` or `Vulkan0`. |
| `QWEN_SEED` | – (random) | Fixed sampling seed for reproducible speech. |
| `QWEN_START_TIMEOUT` | `90` | Seconds the worker may take to load the model. |
| `QWEN_REQUEST_TIMEOUT` | `120` | Seconds one chunk may take before it falls back to Piper. |
| `QWEN_CODEC_DEVICE` | `CPU` | Device used to encode a cloned voice's reference clip. |
| `NORMALIZE_LOUDNESS` | `1` | `1` = bring every chunk to one loudness; `0` = leave audio untouched. |
| `STREAM_FIRST_CHUNK` | `1` | `1` = play the first chunk while Qwen3 is still generating it (GPU builds only) and build it long (≤ 200 characters); `0` = render a short first chunk (≤ 90 characters) whole first. |
| `STREAM_START_TIMEOUT` | `5` | Seconds the streamed first sentence may take to produce its first audio before it is rendered the normal way. |
| `STREAM_IDLE_TIMEOUT` | `5` | Seconds without new audio mid-stream before the stream is given up (what was heard is kept). |
| `VOICE_<lang>` | – | Default Piper voice per language (`model default`). |
| `FALLBACK_VOICE` | – | Piper voice for undetected languages (`model fallback`). |
| `KEY_<action>` | built-in | Shortcut override (`keybind set`). |
| `DEFAULT_SPEED` | `1.0` | Initial playback speed. |
| `VOLUME` | `100` | Reader volume 0–100 (mpv's own mixer, on top of the system volume; no boost above 100). Set by `volume`; an invalid value counts as `100`. |
| `PIPER_BIN`, `MPV_BIN` | `piper-tts`, `mpv` | Executables to use. |

Paths: engines `~/.local/share/hyprland-tts/engines/`, your voices
`~/.local/share/hyprland-tts/voices/<name>/`, helper venv and model
`~/.local/share/hyprland-tts/{venv,langid}/`, Piper voices `~/.local/share/piper-tts/`,
worker state `$XDG_RUNTIME_DIR/hyprland-tts-worker/` (mode 0700).

---

## 🔒 Privacy

- **Offline.** No telemetry, no cloud TTS. Text never leaves your machine.
- The neural engine runs in a local worker that binds **127.0.0.1 only**, on a random port;
  its state directory is private (0700) and `curl` ignores proxy variables for it.
- **The worker's HTTP port is unauthenticated.** Any local process — and in principle a web
  page open in your browser that guesses the random port — can send it a speech request and
  make the machine **speak**. It cannot read your data: the server only turns text into audio
  and returns that audio to the caller. Stop the worker (`hyprland-tts engine stop`) when you
  do not want it, and keep the idle timeout short if this matters to you.
- Network is used only when *you* start a download: voices, the engine build and models,
  the helper packages and the language model. Every download is pinned and checked (git
  commit, sha256, pip hashes).
- Nothing runs as root; the tool refuses to.
- Hover reads whatever text is on screen under the pointer (like any screen reader) — keep
  that in mind before using it over private content.

---

## 📈 Resource usage

| | Disk | RAM | Notes |
|---|---|---|---|
| Piper voice | 60–120 MB each | 0.2–0.4 GB per synthesis process | released after each sentence |
| Qwen3 engine + Base model | about 2.2 GB (engine, codec, model; one model variant ≈ 1 GB) | **1.2 GB while the worker is warm** (Vulkan), 3.2–4.3 GB on CPU | exits after `WORKER_IDLE_MINUTES`; `engine stop` frees it now |
| Language helpers | few MB venv + 1 MB model | ~20 MB per call | started per keypress, 38 ms |
| Shipped voice packs | ~2 MB total | – | read-only, in `/usr/share` |

No process runs permanently. After an idle period nothing of hyprland-tts is resident.

---

## 🧠 How it works

```
selection ─► clean up (markdown, code per paragraph)
          ─► normalise per language (numbers, dates, currency, abbreviations)
          ─► segment (fastText, per sentence) ─► "<lang>\t<sentence>" chunks
          ─► engine picks the voice per chunk language
               qwen3 worker (127.0.0.1, warm) ─► quality gate (silence / runaway / loudness)
                 first sentence: PCM stream  ─► straight into mpv while it is generated
               piper (one-shot)               ─►           ┘  (fallback for any failed chunk)
          ─► mpv playlist (instant next / prev / speed / pause over an IPC socket)
```

Text is cleaned, split into sentences, each rendered once to a WAV (the first one with the neural
engine is streamed into mpv instead, see *Latency*) and played by one mpv
instance driven over an IPC socket; that is what makes next/previous/speed/pause instant. The
granularity is a sentence (neither engine exposes per-word timing). The neural worker is
started on demand when you speak, and the text preparation runs while the model loads.

**Speak under cursor** asks Hyprland for the pointer position and AT-SPI (the accessibility
framework screen readers use) for the text there — one query per keypress, never continuous
tracking, because that would need a permanent background process. Coverage depends on the
app: most GTK/Qt apps and browsers work; terminals, games and most Electron apps (VS Code,
Discord, Slack) do not unless their accessibility is switched on.

---

## 🛟 Troubleshooting

Every problem below was hit for real while building the project.

### Playback

**Reading stops after a few seconds and the player just sits there (paused).** Found on the
real Omarchy desktop, never in the `--ao=null` test runs: Arch's `mpv-mpris` package installs a
system-wide `mpris.so` script, so every mpv registers as a desktop media player, and the
Omarchy shell (quickshell) sent an MPRIS `Pause` to the reader's mpv about three seconds after
it started (seen with `dbus-monitor "interface='org.mpris.MediaPlayer2.Player'"`). The player
now starts mpv with `--load-scripts=no` (and `--keep-open=no`, so a user `mpv.conf` cannot break
end-of-document detection). Media keys therefore do not control the reader; use the
hyprland-tts shortcuts (`ctl pause|resume|toggle`).

**The reader is silent or very quiet, although other audio works.** Found on the real desktop,
right after installing language detection, which looked like the cause but was not (German was
detected as `de`, the rendered audio was ≈ −21 dBFS RMS, the mpv stream was neither corked nor
muted). The reader's mpv registered with PipeWire as plain `mpv` (`application.id = mpv`), and
WirePlumber remembers stream volume per application
(`~/.local/state/wireplumber/stream-properties`, key `Output/Audio:application.id:mpv`). So the
reader shared one stored volume with every other mpv on the system: a video turned down in the
mixer turned the reader down too, to near silence. Fixed: mpv starts with
`--audio-client-name=hyprland-tts`, so the reader has its own mixer entry `hyprland-tts`
(application id, name and node name) that starts at 100 % and does not follow other mpv players;
an old `mpv` entry in the mixer no longer affects it. Check while it speaks:

```bash
pactl list sink-inputs    # the reader: application.name = "hyprland-tts", Corked: no, Mute: no
hyprland-tts volume       # the reader's own volume (0-100), on top of the mixer entry
```

The volume shown for that sink input must be sane (not near 0 %). With an older version, raise
the `mpv` entry in the mixer while the reader speaks.

### GUI and shortcuts

**`hyprland-tts gui` says GTK4/libadwaita/PyGObject are missing, but they're installed.**
You likely have another `python3` earlier on your `PATH` (pyenv, mise, conda, uv, asdf) —
pacman's `python-gobject` only installs into the *system* Python. `hyprland-tts gui` already
falls back to `/usr/bin/python3`; if it still fails, check `which python3` and
`/usr/bin/python3 -c 'import gi'`.

**Never run `hyprland-tts` (or the GUI) with `sudo` / as root.** It needs your Wayland
session and your own `~/.config`/`~/.local`; as root you get `Authorization required` or
`Gtk couldn't be initialized`. Every subcommand refuses to run as root.

**The desktop-menu entry doesn't launch the GUI, but it works from a terminal.** The
launcher environment can resolve `python3` differently; the `.desktop` entry now goes through
`hyprland-tts gui` and the GUI script re-executes itself under the system interpreter. Update
to the latest package.

**A shortcut seems to do nothing at all, even right after installing.**

```bash
hyprland-tts keybind list          # what is really bound (also repairs drift from Hyprland's live state)
hyprland-tts keybind reset speak   # back to the SUPER+ALT+A default
```

`keybind list` repairs the generated `tts.conf` if you edited the config by hand (that used to
leave a shortcut silently stuck on an old key). No reboot is ever needed. If a keybind action
fails because of a missing dependency (Hyprland, AT-SPI, mpv, Piper, socat, a voice model)
you get a desktop notification instead of silence; "no text found there" for hover means the
shortcut fired but the app exposes no text through AT-SPI.

**After `./install-tts.sh` the GUI still shows the old shortcuts and the new keys do nothing.**
Found on the real desktop: the 1.1 pacman package (`/usr/bin`) was still installed next to the
fresh `~/.local` copy. `/usr/bin` comes before `~/.local/bin` on Hyprland's PATH, so the menu entry
(`Exec=hyprland-tts gui`) started the **old** GUI, and its `keybind list` regenerated `tts.lua`
with the old defaults one second after opening (`journalctl --user` shows the `gtk-launch`,
`tts.lua` the same timestamp). Keybinds then ran the old program on the old keys. Diagnose with
`type -a hyprland-tts` and `pacman -Q hyprland-tts`. Keep exactly one install: upgrade the
package from the checkout (`makepkg -si`) and remove the local copy
(`make PREFIX=$HOME/.local uninstall` in the checkout), then `hyprland-tts setup`. The installer
now refuses to install next to another one, and `setup` warns when PATH holds several.

**Uninstalling the `~/.local` copy deleted the neural engine and my own voices.** Found while
cleaning up the case above: for a local install `share/hyprland-tts` *is* the data directory
(`$XDG_DATA_HOME/hyprland-tts` with `engines/` and `voices/`), and `make uninstall` (also run by
`./uninstall-tts.sh`) removed it with `rm -rf`, even without purge. Fixed: uninstall removes only
`shipped-voices/` and leaves the directory when anything else is in it; only `hyprland-tts purge`
deletes user data.

**`SUPER + A` selects all text (or jumps to the line start) instead of reading aloud.** Seen
after the upgrade to Omarchy 4: Omarchy now binds `SUPER + A` to *Select all* (it sends
`Ctrl + A` to the window, `default/hypr/bindings/clipboard.lua`), and the old hyprland-tts
default sat on the same key: two binds on one combo, and Omarchy's *Select all* replaces or
drops the selection that was meant to be read. The same
happened to `SUPER + ESCAPE` (*System menu*), `SUPER + ALT + arrows` (*Move window to group*) and
`SUPER + ALT + Space` (*Apps*). Diagnose with `hyprland-tts keybind check "SUPER, A"` — it lists
the other bind with its description, e.g. `64 A -> __lua 70 (Select all)`. Fixed by new
defaults that Omarchy does not use (table above). After upgrading from 1.x run once:

```bash
hyprland-tts setup                 # regenerates tts.conf/tts.lua with the new defaults
```

Shortcuts you set yourself (`keybind set`) are kept; `setup` warns if one of them is shared.

### Engine install (`hyprland-tts engine install qwen3`)

**`cblas_sgemm` undefined reference / BLAS link failure.** Upstream's own build script
enables `-DGGML_BLAS=ON`, which fails to link. The installer builds with `-DGGML_BLAS=OFF`;
if you build `qwentts.cpp` by hand, do the same.

**Missing Vulkan headers (`vulkan/vulkan.h`, `spirv.hpp`, `SPIRV-HeadersConfig.cmake`).**
Either `sudo pacman -S vulkan-headers spirv-headers`, or do nothing: the installer fetches
pinned Khronos headers (verified by commit) into its own work directory. SPIRV-Headers must
be installed through cmake (`find_package(SPIRV-Headers CONFIG)` does not accept a plain
checkout), which the installer does.

**"Vulkan requested but no usable Vulkan setup".** The GPU build needs the loader's
development symlink (`vulkan-icd-loader`), a Vulkan driver (`vulkan-radeon`, `vulkan-intel`,
`nvidia-utils`) and `glslc` (`shaderc`). Check `vulkaninfo --summary`. Otherwise use
`engine install qwen3 --cpu`.

**`sha256 mismatch` or `download failed`.** The file is discarded, never installed. Run the
install again; it resumes partial downloads and skips verified files.

**`another engine install is already running`.** Installs are serialised with a lock; wait
for the other one (or cancel it) — the GUI shows the same message.

**The install was cancelled or the window closed.** Cancelling kills the whole build tree;
re-running resumes from the verified downloads.

### Language detection helpers (`hyprland-tts deps install`)

**`pip` fails building `fasttext-predict` (no wheel, compiler error) on Python 3.14.** The
package has no wheel for Python 3.14 yet, so pip compiles the source distribution, which needs
`g++`: `sudo pacman -S gcc`. Or use an older interpreter for the private venv:
`uv python install 3.13` and `HTTS_DEPS_PYTHON=$(uv python find 3.13) hyprland-tts deps install`.

**`deps status` says ready but mixed text is read in one voice.** Detection is restricted to
languages that have a voice, and very short openers such as `Hello world.` before a German
text are smoothed into the surrounding language (known limitation). Check `hyprland-tts engine status` for the language list.

### Speech problems

**Numbers, dates or commands are read wrongly or garbled** (`1.250,75 Euro`, `Kfz`,
`sudo pacman -Syu`). The Qwen3 model reads text literally; the per-language normaliser fixes
this, but it only runs when the helpers are installed: `hyprland-tts deps status`, then
`hyprland-tts deps install`.

**Qwen3 is selected but Piper speaks.** Run `hyprland-tts engine status`. Common reasons:
not installed for the chosen variant, the Base model has no cloned voice, or the worker
failed (you get one "Qwen3 unavailable" notification per speak, then Piper takes over). Look
at `$XDG_RUNTIME_DIR/hyprland-tts-worker/worker.log` and `server.log`.

**There is a pause after the first sentence.** The engine renders one chunk at a time and can
only start the second chunk once it has finished generating the first, so the first chunk has to
last long enough to cover that (see *Latency*). hyprland-tts therefore merges the first sentences
(up to 200 characters) into the streamed first chunk and keeps the second chunk small. A pause of
about 0.6 s remains (mpv opening the next file); a longer one means the first chunk could not be
filled: a very short first sentence followed by one over 200 characters without a comma, or a
machine that is slower than usual (check `htts_stream: ok … wall=` in the worker log: wall should
stay below the audio length). If the worker cannot stream at all, the long first chunk is cut into
short pieces and rendered the classic way, so speech still starts after about 2–3 s. Set
`STREAM_FIRST_CHUNK=0` to return to the short first chunk.

**How do I see whether the first sentence was streamed?** Look at the worker log
(`$XDG_RUNTIME_DIR/hyprland-tts-worker/worker.log`):
`htts_stream: ok first_audio=154ms audio=2.00s wall=1.32s gain=+12.6dB` means it streamed.
`htts_stream: no audio (<reason>)` means nothing was played and the sentence was rendered the
normal way (reasons: `no stream: ConnectionRefusedError` = the worker was gone, `HTTP 500 …` =
the engine refused the request, `no stream: TimeoutError` = no audio within
`STREAM_START_TIMEOUT`, `silent render` = the engine returned a second of zeros).
`partial … (stream broke …)`, `(request timeout)` or `(runaway length)` means the sentence was
heard but ended early; it is re-rendered once so that "previous sentence" replays the complete
version. No `htts_stream` line at all: streaming is off (`STREAM_FIRST_CHUNK=0`), the engine
device is `CPU`, or Piper speaks.

**The first sentence is quieter or louder than the rest.** A streamed sentence cannot be
normalised after the fact, so it is played with a gain learned per voice from your earlier
speaks (`~/.local/state/hyprland-tts/stream-gain`; delete it to start over). A voice's very first
use plays with +6 dB, which is up to ~6 dB too quiet for a quiet clone (measured: the German
clone needs +11…13 dB); afterwards it lands within about 1–2 dB of the other sentences
(measured −20.0, −21.8, −22.8 dB against −21…−22 dB for the others; the engine's own level
varies from run to run).

**The first sentence is slow again.** `htts_stream: ok first_audio=…` in the worker log tells
the engine's share: seconds there mean a busy iGPU or a cold model after a long idle, not the
player. After a cold start the first request of a session is slower (≈ 1.7 s, Vulkan pipeline
set-up). `STREAM_FIRST_CHUNK=0` restores the old path.

**The first sentence is slow after a pause.** The worker had idled out and has to load the
model (about 1 s on Vulkan, longer on CPU or a cold disk cache); a "loading voice…"
notification shows while that happens. Warm it up in advance with
`hyprland-tts engine start`, or raise the idle timeout in the Engine page.

**A short text produced a long burst of noise or silence (runaway generation).** The model
occasionally fails to stop on very short inputs (a one-word input produced 16 s of audio
once). The pipeline caps the generation length proportionally to the text, treats a render
that hits the cap as a runaway, retries once and then falls back to Piper for that chunk.

**A chunk was silent.** On one of 124 measured runs the GPU returned exactly zero samples
while another job used the iGPU. The quality gate detects silent output and retries once with a
new seed; set `QWEN_SEED` only if you want reproducibility, since it also repeats bad draws.

**GPU contention or a shared iGPU stalls speech.** Heavy GPU use by other programs (games,
other inference) slows the Vulkan worker. Set `QWEN_DEVICE=CPU` in the config, or close the
other program; slow chunks fall back to Piper after `QWEN_REQUEST_TIMEOUT` seconds.

**CPU mode becomes 10× slower when the machine is busy.** The CPU build's threads spin-wait: on
a saturated CPU the real-time factor jumped from 1.4 to 12–14. This is inherent to the CPU
runtime; prefer the Vulkan build (RTF 0.65–1.1 even at load average 7–10) or Piper.

**Only the first part of a very long text is read.** The selection size cap shortens huge
selections (an accidental select-all) on purpose. Select less, or read the document in parts.

**Volume jumps between voices.** Left enabled by default, loudness normalisation prevents it;
check `NORMALIZE_LOUDNESS=1` (clone voices are naturally quieter than the presets).

**`it_IT-serena-high` crashes the Piper binary** (`"aɪ" is not a single codepoint`). The
installed `piper-tts` build does not handle that voice's newer multi-character phoneme map;
use `it_IT-paola-medium` or another Italian voice.

**A date like "am 3. Oktober" lost the "3."** Fixed: markdown list markers are only stripped
at the start of a line.

### Experimenting with the official Python package yourself

Not used by hyprland-tts (RTF 9.6 on this CPU), but if you try it: PyPI's `torchaudio` is the
CUDA build and fails with `OSError ... _torchaudio.so` — reinstall the CPU wheel
(`--index-url https://download.pytorch.org/whl/cpu`); `HF_HUB_OFFLINE=1` with a repo id still
calls the API, pass the local snapshot directory; bf16 on a CPU without AVX512-BF16 is about
4× slower than fp32.

### For contributors (shell pitfalls that caused random failures)

- `awk` with an early `exit`, `grep -m1`, or `head` in a pipeline plus `set -o pipefail`
  produces random `SIGPIPE` failures (the producer is killed). Read the whole stream.
- A spawned worker must not inherit the lock file descriptor: start it with `9>&-`, otherwise
  the flock is held for the worker's whole life and the next start waits forever.
- `fn &` in bash gives the PID of a subshell, not of the server it starts; record the real
  server PID from inside.

---

## 🗑️ Uninstall / purge

```bash
hyprland-tts engine stop           # stop the warm worker (it also exits on its own when idle)
hyprland-tts engine remove qwen3   # delete the neural engine and models (keeps voices + settings)
hyprland-tts deps remove           # delete the helper venv and the language model
hyprland-tts purge                 # remove keybind wiring AND all user data (voices, state, config)
yay -Rns hyprland-tts              # remove the package
```

From a git checkout instead: `./uninstall-tts.sh`. `hyprland-tts uninstall` removes only the
keybinds (keeps voices and data); `purge` removes keybinds **and** voices, engines, helper
environment, state and config. The package files in `/usr` are only touched by pacman.

---

## 🤖 Contributing

This project is developed largely by AI coding agents. Read **[Agent.md](Agent.md)** first — it
is the architecture and conventions briefing (modular `lib/` layout, one-brain/thin-skins
rule, test commands, gotchas). Changes are listed in **[CHANGELOG.md](CHANGELOG.md)**;
third-party licences and voice attributions in **[THIRD_PARTY.md](THIRD_PARTY.md)**; the 2.0
plan and research notes in `docs/PLAN-2.0.md`.

## 📄 License

hyprland-tts is licensed under the Apache License 2.0 — see [LICENSE](LICENSE). The shipped
voice clips carry their own licences (CC0, public domain, CC BY 4.0) and downloaded models
have theirs; see [THIRD_PARTY.md](THIRD_PARTY.md).
