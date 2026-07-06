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
- **Smart** - The system needs to be go back words or sentenced, skop ahead, slow down or speed up if the users presses keyboard shortcuts to use the system they need


The target user highlights text anywhere on their desktop, presses a shortcut, and hears
it read aloud in the correct language. That flow must stay fast, obvious, and reliable.

Reference environment: an **Omarchy** install running the newest Hyprland. Do not assume
anything Omarchy-specific is guaranteed on a bare Arch+Hyprland box — keep the design
portable across Hyprland setups.

---

## 2. Current State (as of this briefing)

The repo is currently **two shell scripts**, not a package.

| File | Role |
| --- | --- |
| `install-tts.sh` | Installs deps, interactively downloads voice models, writes the router script, wires Hyprland keybinds, hot-reloads. |
| `uninstall-tts.sh` | Removes the router, keybind config, and downloaded models; leaves system packages. |
| `README.md` | End-user facing docs (git-clone + run flow). |
| `LICENSE` | License. |

### How it works today (trace this before editing)

1. **Install** (`install-tts.sh`):
   - Detects an AUR helper (`yay` or `paru`), installs `wl-clipboard alsa-utils curl grep sed` via pacman and `piper-tts-bin` via the AUR helper.
   - Interactive `y/N` prompts to download voice models for DE / EN / FR / ES, plus a custom Hugging Face URL option.
   - Models land in `~/.local/share/piper-tts/<lang>/<model>.onnx` (+ `.onnx.json`).
   - Writes the router to `~/.local/bin/hypr-piper-router.sh`.
   - Writes `~/.config/hypr/tts.conf` with two binds and appends `source = ./tts.conf` to `hyprland.conf`.
   - Runs `hyprctl reload`.

2. **Runtime** (`hypr-piper-router.sh`, generated as a heredoc):
   - Reads the primary selection: `wl-paste --primary`.
   - Empty/whitespace → exit silently.
   - Regex-matches German / French / Spanish character sets and stop-words; else falls to English; else falls to "first `.onnx` found anywhere."
   - Pipes: `piper-tts --model <m> --output_raw | aplay -r 22050 -c 1 -f S16_LE -t raw`.

3. **Keybinds** (in generated `tts.conf`):
   - `SUPER + A` → run router (speak selection).
   - `SUPER + ESCAPE` → `pkill aplay` (stop speech).

### Key runtime paths (do not rename casually — the GUI, router, and packaging all share them)

- Models:  `~/.local/share/piper-tts/<lang>/`
- Router:  `~/.local/bin/hypr-piper-router.sh`
- Hyprland module: `~/.config/hypr/tts.conf` (sourced from `hyprland.conf`)
- **New (to add):** runtime state dir `~/.local/state/piper-tts/` (see Bug 1).
- **New (to add):** user config `~/.config/piper-tts/` for GUI/router settings.

---

## 3. Known Bugs to Fix

### Bug 1 — Language detection can fail; must fall back to the *last used* model

**Problem:** The router only detects a language when the text contains a language-specific
character or stop-word. Short/ambiguous text (e.g. a proper noun, a number, a URL) matches
nothing. Today the "fallback" is English-if-present, otherwise the first `.onnx` found on
disk — which is arbitrary and surprising.

**Required behavior:** When no language is confidently detected, **reuse the last model
that was actually used**. This needs persisted state.

- On every successful synthesis, write the resolved model path to a state file, e.g.
  `~/.local/state/piper-tts/last-model` (create the dir; follow XDG — respect
  `$XDG_STATE_HOME` if set).
- Detection order becomes: **explicit regex match → last-used model (if its file still
  exists) → English → first available model → error.**
- Never crash on a missing/corrupt state file; treat it as "no last model."

### Bug 2 — No GUI or terminal tool to manage / install voice models

**Problem:** Model management is only possible by re-running the interactive installer or
manually curling files. There is no way to see installed models, add new ones, remove
them, or set a default.

**Required behavior:** A **simple, secure, robust, UX-friendly GUI** that is eye friendly to manage speech
models. See §4.3 for the full spec.

---

## 4. Roadmap / Target Design

Three workstreams. Ship them so each is independently testable.

### 4.1 Package as an installable AUR package

Goal: users `yay -S hyprland-tts` to add the feature and `yay -Rns hyprland-tts` (or
pacman) to remove it — no `git clone` + `chmod` dance.

Design guidance:

- Author a `PKGBUILD` (repo name suggests package `hyprland-tts`; confirm name isn't taken
  on the AUR before publishing). Ship a `.SRCINFO`.
- **Split responsibilities the Arch way:**
  - The *package* installs **static, versioned assets** into system paths: the router
    binary/script (e.g. `/usr/bin/hypr-piper-router` or `/usr/lib/hyprland-tts/`), the GUI,
    a sample `tts.conf`, and docs. Package-managed files must be immutable and owned by the
    package — **do not** write into `$HOME` from the PKGBUILD's `package()`.
  - **Per-user state** (keybind wiring into `hyprland.conf`, downloaded models, last-used
    model) stays in the user's home and is set up on **first run / via the GUI or a
    `hyprland-tts setup` command**, not by the package installer. This keeps the package
    idempotent and uninstall clean.
- Declare real dependencies (`piper-tts-bin` from AUR, `wl-clipboard`, `alsa-utils`; the
  GUI toolkit chosen in §4.3). Use `optdepends` where sensible.
- Provide a clean uninstall: package removal drops system files; document how to remove
  user models/config (or offer `hyprland-tts uninstall`).
- Keep the current shell-script install path working (or clearly deprecate it) until the
  AUR package is proven, so users aren't stranded.

### 4.2 Harden the router

- Implement Bug 1 (last-used-model fallback + state file).
- Prefer sourcing the Hyprland module via an **absolute-ish** path
  (`source = ~/.config/hypr/tts.conf`) rather than the current relative `source = ./tts.conf`,
  which breaks when Hyprland's CWD isn't the config dir. Handle both when detecting an
  existing link during install/uninstall.
- Make the router configurable (voice per language, playback params) via
  `~/.config/piper-tts/`, without editing the script itself.
- Keep it dependency-light and fast; the speak-on-shortcut latency is the core UX.

### 4.3 Model-manager GUI

A **simple, secure, robust, UX-friendly** GUI to manage and install voice models.

Must-have capabilities:

- **List** installed models (language, voice, quality, size, which is default/last-used).
- **Install** a model: from a curated list of known Piper voices **and** via a custom
  Hugging Face / direct URL.
- **Remove** a model.
- **Set default** language→voice mapping.
- Show download **progress** and clear success/failure states.

Non-functional requirements (these are why the user asked for "secure and robust"):

- **Security:** Validate URLs before download. Only fetch `.onnx` / `.onnx.json`. Write
  only under the models dir — never allow path traversal (`../`) from a user-supplied
  language folder or filename. Verify downloads (size/hash where a manifest provides it)
  and clean up partial files on failure. Do not execute downloaded content.
- **Robustness:** Handle no-network, partial downloads, disk-full, missing deps, and
  corrupt model dirs without crashing. Every failure gets a human-readable message.
- **UX:** Minimal clicks for the common path (install a recommended voice). Sensible
  defaults. Reversible actions with confirmation on destructive ones.

Toolkit is **not yet decided** — pick one appropriate for a lightweight Hyprland/Wayland
desktop app and record the choice (and rationale) here when you make it. Bias toward
something with a small dependency footprint that packages cleanly on Arch.

---

## 5. Conventions & Constraints for Agents

- **Platform:** Arch Linux, Hyprland (Wayland), PipeWire/PulseAudio via `aplay`. Test
  assumptions against this only.
- **Offline-first:** No network calls at runtime except explicit, user-initiated model
  downloads. No telemetry, ever.
- **Shell scripts:** `bash`, keep `set -e` (and prefer `set -euo pipefail` in new
  scripts). Quote variables. Avoid destructive `rm -rf` without a guarded, absolute path.
- **XDG compliance:** Respect `$XDG_DATA_HOME`, `$XDG_STATE_HOME`, `$XDG_CONFIG_HOME`;
  fall back to the standard `~/.local/share`, `~/.local/state`, `~/.config`.
- **Don't touch `hyprland.conf` more than necessary.** Keep all binds in the sourced
  `tts.conf` module. Make append/remove idempotent (never double-append; clean removal).
- **Idempotency:** Install/setup steps must be safe to run repeatedly.
- **Keep the two shortcuts stable** (`SUPER+A` speak, `SUPER+ESCAPE` stop) unless the user
  asks otherwise — they are the product's muscle memory. If made configurable, keep these
  as defaults.
- **Update docs with code:** README (user-facing) and this Agent.md (agent-facing) must
  stay in sync with actual behavior.

---

## 6. Testing / Verification Expectations

There is no automated test suite yet. Until one exists, verify changes by exercising the
real flow — do not claim success without observing behavior:

- **Router:** feed it sample text per language and confirm the correct model is chosen;
  specifically test the ambiguous-text case to prove the last-used-model fallback works;
  test empty selection (silent exit) and missing-model (clean error).
- **Install/uninstall:** run on a scratch `$HOME` or container; confirm files land in and
  are removed from the expected paths, `hyprland.conf` is appended once and cleaned fully,
  and `hyprctl reload` is invoked.
- **PKGBUILD:** build in a clean chroot (`makepkg`/`extra-x86_64-build`); run
  `namcap` on the resulting package and `.SRCINFO`.
- **GUI:** exercise install / list / remove / set-default and the failure paths
  (no network, bad URL, path-traversal attempt) — confirm each fails safely.

When adding real tests, prefer shellcheck for scripts and a smoke-test harness for the
router's decision logic; record how to run them here.

---

## 7. Definition of Done for the Current Roadmap

- [ ] Router falls back to the **last used model** when language is undetected (Bug 1),
      backed by an XDG state file, crash-safe.
- [ ] A working **model-manager GUI** covering list / install / remove / set-default with
      the security + robustness requirements in §4.3.
- [ ] A **PKGBUILD + .SRCINFO** producing an installable AUR package that adds the feature
      and removes cleanly, following the package-vs-per-user split in §4.1.
- [ ] README updated for the AUR install/uninstall flow; this Agent.md updated to match
      final architecture (toolkit choice, final paths, test commands).

---

## 8. Quick File Map

```
hyprland-tts/
├── Agent.md            # THIS FILE — read first
├── README.md           # user-facing docs (keep in sync)
├── LICENSE
├── install-tts.sh      # current installer (to be superseded/adapted by PKGBUILD)
├── uninstall-tts.sh    # current uninstaller
└── (planned)
    ├── PKGBUILD        # AUR packaging
    ├── .SRCINFO
    ├── src/router      # hardened router (last-used fallback, config-driven)
    └── src/gui         # model-manager GUI
```
