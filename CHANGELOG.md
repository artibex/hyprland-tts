# Changelog

All notable changes to hyprland-tts. Format follows [Keep a Changelog](https://keepachangelog.com/);
versions follow [Semantic Versioning](https://semver.org/).

## [2.0.0] — unreleased (branch `beta`)

Neural engine, native voices per language, real language detection, full polish.

### Added

- **Qwen3-TTS neural engine** (`ENGINE=auto|qwen3|piper`) running through
  [`qwentts.cpp`](https://github.com/ServeurpersoCom/qwentts.cpp) on the GPU (Vulkan) or CPU.
  Measured on a Ryzen 6000 + Radeon 680M iGPU: ready in 1 s, ≈1.2 GB RAM, real-time factor
  0.65–0.77, first audio 0.2 s. `hyprland-tts engine status|install qwen3|remove qwen3|use|start|stop`,
  `engine config idle <minutes>`.
- **User-space engine install** (`engine install qwen3 [--cpu|--vulkan] [--variant base|customvoice]`):
  pinned `qwentts.cpp` commit, sha256-verified GGUF weights, Vulkan headers fetched locally when the
  system has none, flock-guarded, no root. About 7 minutes and 2.2 GB.
- **On-demand worker**: the engine server starts on the first speak, binds 127.0.0.1 on a random
  port (state in a 0700 runtime directory) and exits after `WORKER_IDLE_MINUTES` (default 10).
- **Native cloned voices per language** shipped in `share/voices/`: `de-thorsten` (CC0),
  `en-lj` (public domain), `fr-siwis`, `es-mls-8585`, `it-mls-8582` (CC BY 4.0), each with an
  `ATTRIBUTION.md`. `hyprland-tts voice list|add|remove|set`; add your own from a WAV and transcript.
- **Per-sentence language detection** with fastText (`lid.176.ftz`, 99.5–100 % on whole texts vs 60 %
  for the old router) and **per-language text normalisation** (numbers, dates, times, currency,
  units, abbreviations, acronyms, command lines) for de/en/fr/es/it. Installed by
  `hyprland-tts deps install|status|remove` into a private, hash-pinned venv.
- **Audio quality gate**: silent and runaway renders are detected and retried; loudness
  normalisation (`NORMALIZE_LOUDNESS`).
- **First-sentence streaming** (`STREAM_FIRST_CHUNK=1`, default; Qwen3 on a GPU device): the first
  chunk is played while the engine still generates it (`response_format: pcm` into a FIFO that
  mpv reads as raw audio) instead of after the whole chunk was rendered. Real engine on the
  reference box: `speak` → first audible audio ≈ 1.0 s warm (was ≈ 2.6 s) and ≈ 3.2–3.7 s cold (was 4.0–4.5 s). Replay and previous-sentence read
  the finished copy (it replaces the FIFO under the same name); loudness comes from a gain
  learned per voice (`~/.local/state/hyprland-tts/stream-gain`, +6 dB until learned); a stream
  that never produces audio, stays silent for a second or stalls falls back to the normal
  render without playing twice; a stream that dies after audio was heard is re-rendered for
  replay; a runaway is cut at the generation cap. New keys `STREAM_FIRST_CHUNK`,
  `STREAM_START_TIMEOUT`, `STREAM_IDLE_TIMEOUT`. CPU builds, Piper and chunks ≥ 1 are unchanged.
  Implementation: `lib/stream.sh`, `lib/py/htts_stream.py`; tests `tests/test_stream.sh`,
  `tests/py/test_stream.py`.
- **Per-chunk Piper fallback** with a single notification when a Qwen3 chunk fails.
- **Reader volume**: `hyprland-tts volume` prints it, `hyprland-tts volume <0-100>` stores it
  (`VOLUME`, default 100, an invalid value counts as 100) and changes a speaking reader at once
  over mpv IPC. It is mpv's own mixer (cubic curve), on top of the system volume, and capped at
  100: speech is normalised to about −21 dBFS RMS with peaks near full scale, so more would
  clip (an mpv lavfi limiter could not be driven live through `af-command` in mpv 0.41, so there
  is no boost). `ctl status` also prints `volume=`.
- **Voice preview**: `hyprland-tts preview <lang> [--engine qwen3|piper] [--model <lang>/<name>]`
  speaks a built-in sample sentence (de en fr es it pt ru zh ja ko) through the normal player
  (volume, speed and the stop shortcut apply), with the language fixed instead of detected.
  Without `--engine` it uses the active engine; `--model` implies Piper and plays that installed
  voice (same language only) without changing the "last used" voice. Implementation:
  `lib/preview.sh`.
- **Speak text from scripts**: `hyprland-tts say [--lang <code>] [--wait] [--] [<text>...]` reads
  the given words (or stdin) through the normal player instead of the selection, so a script or an
  assistant does not have to overwrite it. `--lang` fixes the language (checked against the
  engine's voices), `--wait` returns once this reading has ended (finished, stopped or replaced);
  quiet on success, errors on stderr. Implementation: `lib/say.sh`; tests `tests/test_say.sh`.
- GUI, *Voices* page: a *Playback* group on top with a volume slider (applied after a short pause
  while dragging) and a Stop button; a ▶ preview button on every neural *voice per language* row
  (disabled when Qwen3 is not installed or the language has no voice) and on every installed Piper
  voice.
- **GUI redesign**: pages *Engine* (status, engine choice, install with live log and Cancel,
  remove, worker start/stop, idle timeout, switch model), *Voices* (voice per language, cloned
  voices with mandatory licence/consent confirmation, attribution viewer, Piper management),
  *Language* (helper install with log, explanation of the fallback) and *Shortcuts*. Closing the
  window during an install asks first.
- Headless GUI test suite (`tests/gui`, GTK4 Broadway, fake CLI), bash and pytest suites for the
  engine layer and text helpers.
- Documentation: README rewrite (engine comparison with measured numbers, voices and licences,
  configuration, privacy, resource usage, troubleshooting), `THIRD_PARTY.md`, this changelog.

### Changed

- **New default shortcuts — hyprland-tts no longer takes Omarchy's keys.** Omarchy 4 binds
  `SUPER + A` (*Select all*), `SUPER + ESCAPE` (*System menu*), `SUPER + ALT + arrows` (*Move
  window to group*) and `SUPER + ALT + Space` (*Apps*); the old defaults shared those combos, so
  speaking a selection first replaced it. New: speak `SUPER + ALT + A`, stop `SUPER + ALT +
  ESCAPE`, replay `SUPER + ALT + R` (unchanged), next/previous/faster/slower `SUPER + CTRL + ALT +
  arrows`, pause/resume `SUPER + CTRL + ALT + Space`. **Upgrading from 1.x: run
  `hyprland-tts setup` once**; your own `keybind set` choices are kept.
- `setup` warns about every shortcut another live bind also uses, with the fix command;
  `keybind check` (and the GUI's conflict dialog) names the other bind by its description, since
  Lua binds only report a numeric id (`64 A -> __lua 70 (Select all)`).
- `make uninstall` (and `./uninstall-tts.sh`) with `PREFIX=~/.local` no longer deletes
  `~/.local/share/hyprland-tts` wholesale — that is also the data directory holding the Qwen3
  engine and the user's cloned voices. Only `shipped-voices/` is removed.
- `install-tts.sh` refuses to install into `~/.local` while another hyprland-tts install exists
  (pacman package or another binary on PATH): the older `/usr/bin` copy shadowed the new one, and
  its GUI rewrote `tts.lua` with the old defaults. `setup` warns when PATH holds several installs.
- The test suite checks every default against a snapshot of Omarchy's default bindings
  (`tests/data/omarchy-default-binds.txt`, refreshed with `make omarchy-snapshot`), and tests use
  a quiet fake `hyprctl` so a run never reloads or reads the live desktop.
- The reader's mpv starts with `--load-scripts=no --keep-open=no`: a system `mpris.so`
  (`mpv-mpris`) let the Omarchy shell pause the reader over MPRIS a few seconds into a document
  (found on the live desktop; README troubleshooting *Playback*).
- The reader's mpv starts with `--audio-client-name=hyprland-tts` and has its own mixer entry
  `hyprland-tts`. As plain `mpv` it shared WirePlumber's stored per-application volume
  (`Output/Audio:application.id:mpv`) with every other mpv, so a video turned down in the mixer
  left the reader silent or very quiet (found on the live desktop; README troubleshooting
  *Playback*).
- The player polls for the mpv socket and the daemon's pid file every 20 ms (was 50 ms): they sit
  on the path to the first sentence.
- First chunk of a speak is at most 90 characters when it is rendered whole, so speech starts
  faster; when it will be streamed it is **long** (≤ 200 characters, whole sentences merged into
  it, opening clauses of a longer sentence added) and followed by a growing ramp (70, 78, 90 …
  220). The player decides before chunking (`prepare_chunks <allowed> <default> <1|0>`,
  `htts_text.py segment --stream-first 1`) and a stream that fails on a long first chunk is
  rendered as short pieces instead. Real engine, same text, warm: the pause after the first
  chunk drops from ≈ 2.2 s to ≈ 0.6 s, first sound unchanged (≈ 0.9 s), total play time
  −1 to −3 s (see README "Latency").
- `stop` stops playback only; `engine stop` stops the warm worker.
- Markdown list markers are stripped only at the start of a line (fixes "am 3. Oktober" losing
  the "3.").
- The package now depends on `python`; license metadata is Apache-2.0 (code) plus CC-BY-4.0
  (attributed voice clips).

### Known limitations

- A very short sentence in another language (`Hello world. Das ist ein Test.`) is smoothed into the
  surrounding language.
- Supported languages are de, en, fr, es, it (native cloned voices); further Qwen3 languages are
  experimental and may be limited or dropped because CJK sentence splitting is not solved.
- The worker's local HTTP port is unauthenticated (127.0.0.1, random port): another local process
  or a web page could make the machine speak, but cannot read data.
- Voice quality was judged by automatic transcription only; the final voice choice is by ear.
- Streaming moves the first sound earlier but not the moment chunk 1 is ready: after a short
  first sentence there can be a pause (measured ≈ 3 s) while the longer second chunk renders.
- The first streamed sentence is loudness-matched with a learned per-voice gain, so it can differ
  from the exactly normalised later sentences by a decibel or two. A voice's very first
  streamed sentence uses the +6 dB default: measured on the reference box the German clone needs
  +12.5 dB, the built-in voice +5…6 dB, so that one sentence can be up to ~6 dB quieter.

### Evaluated, not integrated

- **Chatterbox** (Multilingual V3 / Turbo / Nano): CPU real-time factor 5–30 (English-only
  variants 1.2–3), 4–7 GB RAM, 12–33 s cold start, no streaming, intelligibility on par with
  Piper, upstream retired in August 2026.
- Qwen3-TTS through the official PyTorch package (RTF 9.6, 5.7 GB) and the 1.7B model (no
  measurable gain for 1 GB more RAM).

## [1.1.0]

Piper-based reader with mpv playback, voice manager and shortcut editor GUI, text cleanup for prose
and code, fallback voice, hover reading, Lua config support for Hyprland 0.55+ (Omarchy 4), and the
fixes documented in the README troubleshooting section.
