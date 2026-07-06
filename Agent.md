# Agent.md — Briefing for AI Coding Agents

> This project is developed **primarily by AI coding agents**. Read this file in full
> before making any change. It is the source of truth for *what this project is*, *how
> it currently works*, *what it must become*, and *the rules you work under*. When you
> change behavior, update this file in the same change.

---

## 1. Mission

Bring **accessibility to Arch Linux + Hyprland** through a text-to-speech (TTS) system
that is:

- **Easy** — trigger speech on highlighted text with a single keyboard shortcut.
- **Powerful** — multilingual, neural-quality voices, running 100% offline.
- **Local & private** — no cloud, no telemetry, no background daemons.
- **Installable & removable** — a clean AUR package the user can add or drop at will.
- **Smart** — the user can, via keyboard shortcuts, go back/forward through the text,
  replay, and slow down or speed up playback while it is being read.

The target user highlights text anywhere on their desktop, presses a shortcut, and hears
it read aloud in the correct language. That flow must stay fast, obvious, and reliable.

Reference environment: an **Omarchy** install running the newest Hyprland. Do not assume
anything Omarchy-specific is guaranteed on a bare Arch+Hyprland box — keep the design
portable across Hyprland setups.

---

## 2. Architecture (as built)

**One brain, thin skins.** All logic lives in the `lib/*.sh` modules, loaded by the thin
dispatcher `bin/hyprland-tts`. The GUI and installers are *skins* that shell out to the
CLI. Never duplicate logic into a skin — add a subcommand/flag and call it.

### Modules (`lib/`, sourced by the dispatcher in this order)

| Module | Responsibility |
| --- | --- |
| `common.sh` | XDG paths, tunables, config read/write, the **keybind action table** (`ACTION_*`), helpers (`log`/`die`/`have`). |
| `text.sh` | `normalize_text` (voiceover optimizer) + `chunk_text` (sentence splitting). |
| `router.sh` | `detect_lang` + `resolve_model` (last-used fallback) + `remember_model`. |
| `model.sh` | Voice catalog + install / list / catalog / remove / default (+ all download security). |
| `image.sh` | `read_clipboard_image` — exiftool metadata → tesseract OCR, graceful. |
| `keybind.sh` | Generate `tts.conf` from the action table; `keybind list/set/check/reset`; conflict detection via `hyprctl binds -j`. |
| `player.sh` | mpv-based smart player: `cmd_speak`, `run_daemon`, `render_worker`, `cmd_ctl`, `cmd_stop`. |
| `setup.sh` | Idempotent Hyprland wiring: `setup` / `uninstall` / `purge`. |

The dispatcher resolves its lib dir from (in order) `$HYPRLAND_TTS_LIB`,
`<self>/../lib/hyprland-tts` (installed), `<self>/../lib` (git checkout),
`/usr/lib/hyprland-tts`, `~/.local/lib/hyprland-tts`.

### Playback pipeline (the important part)

`speak` → read `wl-paste --primary` (or `read_clipboard_image` if selection empty) →
`normalize_text | chunk_text` → `resolve_model` → remember → launch detached `__daemon`.

`__daemon` starts **one mpv** in idle mode with an IPC socket
(`--input-ipc-server`, `--audio-pitch-correction=yes`), renders each sentence **once** with
Piper to a WAV, and `loadfile … append`s it to mpv's playlist. Controls are **native mpv
IPC commands over the socket via `socat`** and are therefore instant and glitch-free:
`next/prev` = playlist-next/prev, `faster/slower` = set speed (pitch preserved), `pause/
toggle` = set/cycle pause, `restart` = seek 0. The daemon quits mpv once everything is
rendered and the playlist is drained.

> Why this design: the old `aplay` player re-ran Piper on every speed/skip action, and that
> synthesis latency was the "painful stop" users hit. Rendering once + mpv playback removes
> it entirely. **Navigation granularity is a sentence** — Piper exposes no per-word timing,
> so word-level seeking is intentionally not offered.

### Key paths (XDG; honor `$XDG_*`)

- Models `~/.local/share/piper-tts/<lang>/<model>.onnx` (+ `.onnx.json`)
- Last-used `~/.local/state/piper-tts/last-model`
- Config `~/.config/piper-tts/config` (sourced bash: `VOICE_<lang>`, `KEY_<action>`, `DEFAULT_SPEED`, `PIPER_BIN`, `MPV_BIN`)
- Runtime `$XDG_RUNTIME_DIR/hyprland-tts/` (mpv.sock, daemon.pid, chunks, s*.wav, render.done)
- Hyprland `~/.config/hypr/tts.conf` (generated; sourced from `hyprland.conf`)

---

## 3. Feature status

- **Bug 1 (undetected language → last-used model)** — ✅ `router.sh::resolve_model`.
  Order: detected (DE→FR→ES→EN) → last-used (if file exists) → English → any → error.
- **Bug 2 (model manager, GUI + terminal)** — ✅ `model.sh` + GUI *Voices* tab.
- **Smart playback (skip/replay/speed/pause)** — ✅ mpv IPC in `player.sh`. Instant.
- **Voiceover text optimizer** — ✅ `text.sh::normalize_text`: strips markdown (headings,
  emphasis `*`/`~~`, code fences, list/quote markers), turns links/emails/images into short
  spoken stand-ins (`(link)`, `(email)`, alt-text), drops decorative symbol rows, converts
  table pipes to pauses, and collapses whitespace/blank-line runs into single sentence
  breaks — **meaning preserved** (leaves `snake_case` and accents intact).
- **Rebind + conflict detection** — ✅ `keybind.sh` + GUI *Shortcuts* tab (press-to-capture,
  warns on clash via `hyprctl binds -j`).
- **Image reading** — ✅ `image.sh` (exiftool description → tesseract OCR), optional deps,
  silent if absent. **Web alt-text is out of scope** (browser DOM only) — `image.sh` is the
  documented extension point if a browser bridge is ever added.
- **GUI dependency detection (real-world fix)** — ✅ `_gui_python()` in `bin/hyprland-tts`
  no longer trusts a bare `python3`; see the gotcha in §5 for the exact failure it fixes.
- **Root/sudo guard (real-world fix)** — ✅ `refuse_root()` blocks every subcommand under
  root, in both the dispatcher and the GUI; see the gotcha in §5.

---

## 4. Packaging

- `Makefile` installs static assets into `PREFIX` (`bin/`, `lib/hyprland-tts/*.sh`, desktop,
  docs). Used by both the PKGBUILD (`DESTDIR`, `PREFIX=/usr`) and the local installer
  (`PREFIX=$HOME/.local`). **Never writes to `$HOME`.**
- `PKGBUILD` currently builds from the **local working tree** (`source=()`, `package()` cds
  to `$startdir`) so `makepkg` works while iterating on `main`. The AUR release recipe
  (tag tarball + real `sha256sums` + release `package()`) is a commented block to swap in
  at publish time; then regenerate `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`.
- `depends`: `bash piper-tts-bin wl-clipboard mpv socat procps-ng curl gawk sed grep gtk4
  libadwaita python-gobject`. `optdepends`: `hyprland`, `tesseract`(+`-data-eng`),
  `perl-image-exiftool`. (GTK stack is a hard dep so `hyprland-tts gui` always works;
  `alsa-utils` was dropped when playback moved to mpv.)
- Per-user wiring is `hyprland-tts setup`, never the package. `purge` removes user data.

---

## 5. Conventions & Constraints for Agents

- **One brain, thin skins.** New behavior → a `lib/` function + CLI subcommand, not code in
  the GUI/installers.
- **Platform:** Arch Linux, Hyprland (Wayland). Audio via mpv (PipeWire/Pulse/ALSA behind it).
- **Offline-first:** no runtime network except explicit, user-initiated downloads. No telemetry.
- **Shell:** `bash` with `set -euo pipefail` in the dispatcher; modules define functions
  only (no top-level side effects). Quote variables; guard destructive `rm`.
- **Gotchas that bit us (don't reintroduce):** `tr` does **not** understand `\xNN` — use
  `LC_ALL=C sed` for byte-level UTF-8 stripping. When deleting config/marker lines with
  `sed`, pick a delimiter absent from the pattern (`|` alternation vs `|` address; `#` vs a
  `#`-containing marker) — prefer `grep -vF` for fixed strings. `die` uses `printf %b` so
  messages may contain `\n`.
- **Never trust a bare `python3` for GTK checks.** A user hit this for real:
  `hyprland-tts gui` reported GTK4/libadwaita/PyGObject missing while
  `pacman -S gtk4 libadwaita python-gobject` said "up to date". Root cause: their `PATH`
  had a user-managed interpreter (pyenv/mise/conda/uv/asdf) ahead of `/usr/bin/python3`,
  and pacman-installed PyGObject only lives in the *system* interpreter's site-packages.
  Fix (`bin/hyprland-tts::_gui_python`): probe `python3` from `PATH`, then fall back to
  `/usr/bin/python3` explicitly, and launch the GUI with that resolved interpreter
  (`"$py" "$gui"`, not `exec "$gui"`) so the check and the actual run always agree — never
  rely on the GUI script's own `#!/usr/bin/env python3` shebang for this.
- **Never run any part of this tool as root/via `sudo`.** Confirmed for real: after hitting
  the bug above, the user tried `sudo hyprland-tts gui`, which crashed with
  `Authorization required` / `Gtk couldn't be initialized` — root has no access to the
  caller's Wayland session, and `~/.config`/`~/.local` would resolve under `/root` instead
  of the real user's home. `refuse_root()` in `bin/hyprland-tts::main()` (plus a duplicate
  `os.geteuid()` guard at the top of `gui/hyprland-tts-gui`, for anyone invoking the GUI
  binary directly) blocks every subcommand under root with a message pointing at the real
  fix, before touching GTK/Wayland at all. Escape hatch: `HYPRLAND_TTS_ALLOW_ROOT=1` (not
  documented for normal use — packaging/CI only).
- **XDG compliance**; **idempotent** setup (2× setup → 1 source line; uninstall → 0 refs).
- **Keep core shortcuts as defaults** (`SUPER+A`, `SUPER+ESCAPE`); playback controls default
  to `SUPER+ALT+…`. All are user-rebindable via `keybind`.
- **Update docs with code:** README (users) + this Agent.md (agents).

---

## 6. Testing / Verification

`make check` runs `bash -n` on the dispatcher + `py_compile` on the GUI. Manual checks use a
scratch `$HOME` and fakes on `PATH`. Status of what's been exercised:

- **Text optimizer** — markdown/URL/email/table/symbol-row/blank-line cases; accents and
  `snake_case` preserved; no double periods / leading commas. *(Verified.)*
- **Router** — DE/FR/ES/EN detection; ambiguous → last-used; detected beats last-used. *(Verified.)*
- **Keybind** — modmask math, combo split, `tts.conf` generation, and conflict detection
  against a fake `hyprctl binds -j` (blocks; `--force` overrides). *(Verified.)*
- **mpv player** — **real mpv + socat + fake Piper WAVs**: speak → next/prev (instant),
  faster/slower (live speed 1.2/0.8, no restart), pause/resume, stop → clean, no orphans. *(Verified.)*
- **Model commands** — catalog/list/porcelain/default/remove + URL security (rejects
  non-https/traversal/wrong-extension). *(Verified.)*
- **Setup/uninstall** — idempotent wiring round-trip. *(Verified.)*
- **Packaging** — `make install` layout (incl. `lib/`), and a real `makepkg` build. *(Verified.)*
- **GUI** — `py_compile` + graceful no-GTK message. **Not launched on the dev box** (no
  PyGObject there); smoke-test on a real GTK4 desktop: Voices (install/remove/default),
  Shortcuts (press-to-rebind, conflict dialog), custom-URL, failure paths → toast, no crash.
- **Image reading** — logic only; needs a live Wayland clipboard to exercise end-to-end.
- **GUI python3 resolution** — reproduced the exact failure on the dev box itself (its
  `PATH` python3 is mise-managed and lacks `gi`; `/usr/bin/python3` has it): confirmed the
  old bare-`python3` check falsely reports the stack missing, confirmed `_gui_python()`
  correctly falls back and resolves `/usr/bin/python3`. *(Verified — this is a real,
  reproduced regression fix, not speculative.)*
- **Root guard** — faked `id -u` → `0` on `PATH`; confirmed `gui`/`model`/`setup` all refuse
  cleanly before touching GTK/Wayland, real (non-root) invocations are unaffected, and
  `HYPRLAND_TTS_ALLOW_ROOT=1` bypasses it. *(Verified.)*

Not yet run: clean-chroot `makepkg` + `namcap`; real audio on a Hyprland session; the GUI
has still never been shown on an actual display (this dev box is headless).

---

## 7. Open follow-ups

- Publish a tagged release; swap PKGBUILD to the release recipe + real `sha256sums`;
  regenerate `.SRCINFO`; run `namcap`.
- Smoke-test the GUI and real audio playback on a Hyprland desktop.
- Consider: per-voice/per-language speed presets; a spoken "reading…" indicator;
  `shellcheck` in CI; a browser-extension bridge for true web alt-text.

---

## 8. File Map

```
hyprland-tts/
├── Agent.md                         # THIS FILE — read first
├── README.md                        # user-facing docs
├── LICENSE
├── PKGBUILD / .SRCINFO              # AUR packaging (local-build by default)
├── Makefile                         # install static assets (PREFIX/DESTDIR)
├── bin/hyprland-tts                 # thin dispatcher (resolves lib/, dispatches subcommands)
├── lib/                             # THE LOGIC
│   ├── common.sh  text.sh  router.sh  model.sh
│   └── image.sh   keybind.sh player.sh  setup.sh
├── gui/hyprland-tts-gui             # GTK4/libadwaita: Voices + Shortcuts (thin CLI front end)
├── share/
│   ├── applications/hyprland-tts.desktop
│   └── tts.conf.sample              # reference copy (real file is generated)
├── install-tts.sh / uninstall-tts.sh  # local (~/.local) installer for git-checkout users
```
