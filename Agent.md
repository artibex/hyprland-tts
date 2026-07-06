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

## 2. Current Architecture (as built)

The project is now a small, packaged toolset — **not** the original two ad-hoc scripts.

| Path | Role |
| --- | --- |
| `bin/hyprland-tts` | **The whole runtime.** One bash entry point with subcommands: `speak`, `ctl`, `stop`, `model`, `gui`, `setup`, `uninstall`, `purge`, and the internal `__daemon`. Single source of truth for all logic. |
| `gui/hyprland-tts-gui` | GTK4 / libadwaita voice manager (Python). A **thin front end** — it only shells out to `hyprland-tts model … --porcelain`. Contains no TTS or download logic. |
| `Makefile` | Installs static assets into `PREFIX` (used by both the PKGBUILD and the local installer). Never touches `$HOME`. |
| `PKGBUILD` / `.SRCINFO` | AUR packaging. |
| `share/applications/hyprland-tts.desktop` | App launcher for the GUI. |
| `share/tts.conf.sample` | Reference copy of the generated Hyprland keybind module. |
| `install-tts.sh` / `uninstall-tts.sh` | Fallback installer for git-checkout users (installs into `~/.local` via the Makefile, then runs `setup`). |
| `README.md` | User-facing docs. |

### Design rule: one brain, thin skins

All behavior lives in `bin/hyprland-tts`. The GUI and the installer scripts are *skins*
over it. **Do not** duplicate logic into them — add a subcommand/flag to the CLI and call it.

### Runtime flow

- **Speak** (`hyprland-tts speak`, bound to `SUPER+A`):
  reads `wl-paste --primary` → `resolve_model()` → records last-used → chunks the text into
  sentences → launches the detached **player daemon** (`__daemon`) and returns immediately.
- **Player daemon** (`__daemon`): plays chunk-by-chunk with `piper-tts … | aplay`; listens
  on a control FIFO. Holds the sentence array, current index, speed, and pause state in
  memory; mirrors them to `$XDG_RUNTIME_DIR/hyprland-tts/` for `ctl status`.
- **Control** (`hyprland-tts ctl <cmd>`, bound to `SUPER+ALT+…`): writes a command
  (`next|prev|restart|faster|slower|pause|resume|toggle|stop|status`) to the FIFO.
- **Model management** (`hyprland-tts model …`): curated catalog + custom-URL install, list
  (human + `--porcelain`), remove, per-language default. The GUI drives exactly these.
- **Setup/uninstall**: idempotently write `~/.config/hypr/tts.conf` and add/remove one
  `source = ~/.config/hypr/tts.conf` line in `hyprland.conf`; `hyprctl reload`.

### Key paths (XDG-compliant; honor `$XDG_*` overrides)

- Models:   `~/.local/share/piper-tts/<lang>/<model>.onnx` (+ `.onnx.json`)
- Last-used: `~/.local/state/piper-tts/last-model`
- Config:   `~/.config/piper-tts/config`  (sourced bash: `VOICE_<lang>=…`, `DEFAULT_SPEED`, `PIPER_BIN`)
- Runtime:  `$XDG_RUNTIME_DIR/hyprland-tts/` (FIFO, pid, index, speed, chunks, status)
- Hyprland: `~/.config/hypr/tts.conf` (sourced from `hyprland.conf`)
- Installed program files: `$PREFIX/bin/{hyprland-tts,hyprland-tts-gui}` + `share/…`

---

## 3. Bugs — status

### Bug 1 — Undetected language must fall back to the *last used* model — ✅ FIXED

`resolve_model()` order is now: **detected language (DE→FR→ES→EN) → last-used model (if its
file still exists) → English → any installed → error.** English is now explicitly detected
(stop-word regex) so plain English text isn't mistaken for "ambiguous". On every successful
resolution the model path is written to `~/.local/state/piper-tts/last-model`; a
missing/corrupt state file is treated as "no last model" and never crashes.
Verified: ambiguous text (`"Firefox 2024"`) reuses the last voice; detected German still
wins over last-used.

### Bug 2 — No GUI/terminal tool to manage models — ✅ FIXED

Both exist: `hyprland-tts model …` (terminal) and `hyprland-tts gui` (GTK4/libadwaita).
Security is enforced in the CLI (see §4.3), so the GUI inherits it for free.

---

## 4. Component notes

### 4.1 AUR package

- `package()` runs `make PREFIX=/usr DESTDIR="$pkgdir" install` — installs **only** static
  files owned by the package. **Never write into `$HOME` from the PKGBUILD.**
- Per-user wiring is `hyprland-tts setup` (run by the user after install). Package removal
  drops system files; `hyprland-tts purge` removes user voices/state/config.
- `depends`: `bash piper-tts-bin wl-clipboard alsa-utils procps-ng curl gawk sed grep`.
  GUI toolkit is `optdepends` (`gtk4`, `libadwaita`, `python-gobject`) so headless users can
  skip it; `hyprland-tts gui` fails gracefully if missing.
- `sha256sums` is currently `SKIP` — **replace with the real checksum when you publish a
  tag**, and bump `pkgver` in both `PKGBUILD` and `.SRCINFO` together.

### 4.2 Router / player

- Sentence-chunking (`chunk_text`) splits on `.!?…;:` and hard-wraps long runs at ~240
  chars on word boundaries. Newlines are collapsed so one chunk = one line (trivially
  indexable via `mapfile`).
- Playback granularity is a **sentence**. `next/prev/restart` move by sentence; `faster/
  slower` re-synthesize the current sentence for instant effect (piper `--length_scale`,
  clamped 0.5–2.0). Pause/resume `SIGSTOP`/`SIGCONT` the playback children.
- **Word-level seeking is intentionally not implemented**: `piper-tts-bin` exposes no
  per-word timing, so seeking inside rendered audio isn't reliable. Sentence is the unit.
  If a future engine provides word timestamps, add a finer chunk mode here.
- Sample rate is read from the model's `.onnx.json` (`sample_rate`), default 22050.
- Concurrency: the daemon backgrounds each `piper|aplay` pipeline in a subshell and kills
  it via `pkill -P <subshell>` + kill of the subshell. Avoid `setsid`-based PGID tricks —
  they were rejected as unreliable for tracking pipeline completion.

### 4.3 GUI & security

- Toolkit **decision: GTK4 + libadwaita via PyGObject.** Rationale: first-class on Arch
  (official repos), small footprint, native Wayland, automatic light/dark, and no bundled
  runtime. Recorded here so it isn't re-litigated.
- The GUI never downloads or deletes directly — it calls the CLI, which enforces:
  - language codes must match `^[a-z]{2,3}$` (blocks `../` path traversal);
  - model names must match `^[A-Za-z0-9._-]+$`;
  - URLs must be `https://`, `.onnx` / `.onnx.json` only;
  - downloads go to a temp file and are atomically moved on success, cleaned up on failure;
  - empty/zero-byte downloads are rejected.
- The GUI runs every action in a worker thread (UI never freezes) and reports the CLI's
  stderr in a toast on failure. Destructive actions confirm first.

---

## 5. Conventions & Constraints for Agents

- **One brain, thin skins** (see §2). New behavior → a CLI subcommand/flag, not duplicated
  logic in the GUI or installers.
- **Platform:** Arch Linux, Hyprland (Wayland), PipeWire/PulseAudio via `aplay`.
- **Offline-first:** no runtime network calls except explicit, user-initiated downloads.
  No telemetry, ever.
- **Shell:** `bash` with `set -euo pipefail`. Quote variables. Guard destructive `rm`.
- **XDG compliance:** honor `$XDG_DATA_HOME`, `$XDG_STATE_HOME`, `$XDG_CONFIG_HOME`,
  `$XDG_RUNTIME_DIR`; fall back to the standard locations.
- **Hyprland config:** keep all binds in the sourced `tts.conf` module; append/remove must
  be idempotent (verified: 2× setup → 1 source line; uninstall → 0 refs).
- **Keep the two core shortcuts stable** (`SUPER+A` speak, `SUPER+ESCAPE` stop). Playback
  controls default to `SUPER+ALT+…` to avoid conflicts.
- **Update docs with code:** README (users) and this Agent.md (agents) stay in sync.

---

## 6. Testing / Verification

No unit-test framework yet; verify by exercising the real flow. `make check` runs
`bash -n` + `py_compile`. Useful manual checks (all runnable with a scratch `$HOME` and
fake `piper-tts`/`aplay`/`wl-paste` on `PATH` — see below):

- **Router logic** — source `bin/hyprland-tts` and call `detect_lang` / `resolve_model`
  against a fake models dir. Confirm: DE/FR/ES/EN detection; ambiguous text → last-used;
  detected language beats last-used. *(Verified.)*
- **Chunking** — `chunk_text` splits sentences and wraps >240-char runs. *(Verified.)*
- **Daemon** — with fake `aplay` (`sleep`) and `piper-tts` (drain stdin), run `speak` then
  `ctl next|prev|faster|prev|pause|resume|stop` and watch `ctl status`; confirm no orphan
  processes after `stop`. *(Verified.)*
- **Model commands** — `catalog`, `list`/`--porcelain`, `default` (writes config), `remove`
  (clears default/last refs), and that `install-url` rejects non-https / traversal / wrong
  extension. *(Verified.)*
- **Setup/uninstall** — on a scratch `hyprland.conf`: 2× setup = one source line; uninstall
  restores it cleanly. *(Verified.)*
- **Packaging** — `make PREFIX=/usr DESTDIR=/tmp/stage install` lands the expected layout;
  `uninstall` removes it. *(Verified.)* For the real package: build in a clean chroot
  (`makepkg`) and run `namcap` on the `.pkg.tar.zst` and `.SRCINFO`. *(Not yet run — needs
  a published tag + real checksum.)*
- **GUI** — `py_compile` passes. **Not launched on the dev box** (no PyGObject there); must
  be smoke-tested on an Arch+GTK4 machine: install / list / remove / set-default and the
  failure paths (no network, bad URL, traversal) all surface a toast, none crash.

---

## 7. Definition of Done — status

- [x] Router falls back to the **last used model** when language is undetected (Bug 1),
      XDG state file, crash-safe.
- [x] A **model manager** (GUI *and* terminal) covering list / install / remove /
      set-default with the security + robustness requirements in §4.3.
- [x] **Smart playback**: next/prev sentence, replay, faster/slower, pause/resume via
      shortcuts (sentence granularity; word-level noted as an engine limitation).
- [x] **PKGBUILD + .SRCINFO + Makefile** producing an installable package with the
      package-vs-per-user split; local installer kept working.
- [x] README + Agent.md updated to the as-built architecture.

**Open follow-ups:** publish a tagged release and set the real `sha256sums`; run
`namcap`/clean-chroot build; smoke-test the GUI on a real GTK4 desktop; consider adding
`shellcheck` to CI.

---

## 8. File Map

```
hyprland-tts/
├── Agent.md                         # THIS FILE — read first
├── README.md                        # user-facing docs
├── LICENSE
├── PKGBUILD / .SRCINFO              # AUR packaging
├── Makefile                         # install/uninstall static assets (PREFIX/DESTDIR)
├── bin/
│   └── hyprland-tts                 # the whole runtime (router+player+ctl+model+setup)
├── gui/
│   └── hyprland-tts-gui             # GTK4/libadwaita voice manager (thin CLI front end)
├── share/
│   ├── applications/hyprland-tts.desktop
│   └── tts.conf.sample              # reference copy of generated keybinds
├── install-tts.sh                   # local (~/.local) installer for git-checkout users
└── uninstall-tts.sh
```
