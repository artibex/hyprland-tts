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
- **Local & private** — no cloud, no telemetry, no permanent daemon (the neural engine's worker
  starts on demand, listens on 127.0.0.1 only and exits after an idle period).
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

**One brain, thin skins.** All logic lives in the `lib/*.sh` modules (plus the Python text
helpers in `lib/py/`), loaded by the thin dispatcher `bin/hyprland-tts`. The GUI and installers
are *skins* that shell out to the CLI. Never duplicate logic into a skin — add a
subcommand/flag and call it. (The GUI reads the voice attribution/licence files for display
and mirrors the voice-name rule only to enable a button; the CLI stays authoritative.)

### Modules (`lib/`, sourced by the dispatcher in this order)

| Module | Responsibility |
| --- | --- |
| `common.sh` | XDG paths, tunables (`ENGINE`, `QWEN_*`, `WORKER_IDLE_MINUTES`, …), config read/write (`set_config_var`), the **keybind action table** (`ACTION_*`), helpers (`log`/`die`/`have`/`notify`, `is_safe_name`, `json_escape`). |
| `text.sh` | Bash text path: `normalize_text` → `normalize_prose` or `normalize_code` (via `looks_like_code`), + `chunk_text`. Used as the **fallback** when the Python helpers are unavailable. |
| `router.sh` | `prepare_chunks` (raw text → `<lang>\t<sentence>` lines; Python helper first, bash regex fallback), first-chunk cut (≤90 chars), `detect_lang`, `resolve_model` (Piper voice chain: detected → fallback voice → last used → en → any). |
| `model.sh` | Piper voice catalog + install / list / catalog / remove / default / **fallback** (+ all download security). |
| `image.sh` | `read_clipboard_image` — exiftool metadata → tesseract OCR, graceful. |
| `keybind.sh` | Generate `tts.conf` from the action table; `keybind list/set/check/reset`; conflict detection via `hyprctl binds -j`. |
| `engine.sh` | Engine layer: `engine_selected/active/languages`, `engine_render` (Qwen3 first, **Piper safety net per chunk**, one notification per run), `piper_render`, `wav_finish` (calls `htts_wav.py`), `cmd_engine` (`status [--porcelain]`, `install`, `remove`, `use`, `variant`, `config idle`, `start`, `stop`). |
| `qwen3.sh` | Qwen3 backend: pinned constants, install-tree paths, request building (`max_new_tokens` cap ∝ text length, optional seed), `qwen3_render` against the warm server, device selection, usability test. |
| `qwen3_install.sh` | User-space install: pinned `qwentts.cpp` commit (verified after a shallow fetch), sha256-checked GGUF weights, Vulkan/CPU build (BLAS off), fetched Khronos headers when the system has none, flock-guarded. |
| `worker.sh` | On-demand warm worker: flock-guarded start, loopback server on a random port, state in `$XDG_RUNTIME_DIR/hyprland-tts-worker` (0700), idle exit after `WORKER_IDLE_MINUTES`, `worker_ensure/kick/stop/status`. |
| `voices.sh` | Per-language voice choice, cloned voices (`voice list/add/remove/set`), shipped + user voice roots, latent encoding via `qwen-codec`, registration with the running server. |
| `pyenv.sh` | Optional Python helper environment: private venv + hash-pinned `fasttext-predict`/`num2words`, fastText model download (`deps install/status/remove`), interpreter resolution. Optional: older installs lack it. |
| `player.sh` | mpv-based smart player: `cmd_speak`, `speak_text` (shared with `hover`), `run_daemon`, `render_worker`, `cmd_ctl`, `cmd_stop` (playback only). |
| `setup.sh` | Idempotent Hyprland wiring: `setup` / `uninstall` / `purge`. |
| `hover.sh` | `cmd_hover` — on-demand "speak text under the cursor" via `hyprctl cursorpos` + AT-SPI (`hover-read.py`, a non-sourced Python helper installed alongside the `lib/*.sh` modules). |

Python helpers (`lib/py/`, run by the helper venv's interpreter; **not** sourced):

| File | Responsibility |
| --- | --- |
| `htts_text.py` | CLI front end: `segment`, `detect`, `normalize`, `markup` (stdin → stdout; exit 3 = model/fastText unavailable → bash falls back). |
| `htts_pipeline.py` | markup clean-up → sentences → language labels → normalisation → chunks. |
| `htts_langid.py` | fastText `lid.176.ftz` restricted to the allowed languages + sentence smoothing. |
| `htts_split.py`, `htts_markup.py` | Sentence splitting/chunk assembly; markdown and code clean-up. |
| `htts_norm.py`, `htts_norm_numbers.py`, `htts_norm_tokens.py`, `htts_numbers.py`, `htts_lang_{de,en,fr,es,it}.py` | Per-language normalisation (numbers via `num2words`, dates, times, currency, units, abbreviations, acronyms, command lines). |
| `htts_wav.py` | Standard-library WAV gate: silent / runaway detection and loudness normalisation (exit 0 ok, 3 silent, 4 runaway, 5 unreadable). |
| `requirements.txt` | Pinned, hash-checked packages for `deps install`. |

The GUI (`gui/hyprland-tts-gui`, GTK4/libadwaita, one file) has four pages — Engine, Voices,
Language, Shortcuts — and only runs CLI commands (`engine …`, `voice …`, `deps …`, `model …`,
`keybind …`). Short commands run on a worker thread (toast on completion); `engine install` and
`deps install` run through `CliJob` (own process group, merged output streamed line by line into
a log view, Cancel = SIGTERM to the group then SIGKILL after 3 s).

The dispatcher resolves its lib dir from (in order) `$HYPRLAND_TTS_LIB`,
`<self>/../lib/hyprland-tts` (installed), `<self>/../lib` (git checkout),
`/usr/lib/hyprland-tts`, `~/.local/lib/hyprland-tts`.

### Playback pipeline (the important part)

```
selection ─► clean up (markdown; code per paragraph)
          ─► normalise per language (numbers, dates, currency, abbreviations, CLI)   [Python helper]
          ─► segment per sentence (fastText, smoothed) ─► "<lang>\t<sentence>" chunks
          ─► engine_render picks the voice per chunk language
               qwen3: warm worker on 127.0.0.1 ─► htts_wav.py gate (silent/runaway → retry, loudness)
               piper: one-shot                  (also the per-chunk fallback; one notification)
          ─► mpv playlist (append-play; instant next/prev/speed/pause over IPC)
```

`speak` → read `wl-paste --primary` (or `read_clipboard_image` if selection empty) →
`engine_warm` (kicks the Qwen3 worker so loading overlaps text preparation) →
`prepare_chunks` (Python helper; falls back to `normalize_text | chunk_text` + regex router when
the venv/model are missing) → launch detached `__daemon`. The first chunk is ≤90 characters so
speech starts early.

`__daemon` starts **one mpv** in idle mode with an IPC socket
(`--input-ipc-server`, `--audio-pitch-correction=yes`), renders each chunk **once** through
`engine_render` to a WAV, and `loadfile … append-play`s it to mpv's playlist. Controls are **native
mpv IPC commands over the socket via `socat`** and are therefore instant and glitch-free:
`next/prev` = playlist-next/prev, `faster/slower` = set speed (pitch preserved), `pause/
toggle` = set/cycle pause, `restart` = seek 0. The daemon quits mpv once everything is
rendered AND mpv's own reported playlist-count confirms it has actually finished playing
(see the `append-play`/`COUNTFILE` gotchas in §5 — both were real, confirmed-live bugs, not
theoretical).

> Why this design: the old `aplay` player re-ran Piper on every speed/skip action, and that
> synthesis latency was the "painful stop" users hit. Rendering once + mpv playback removes
> it entirely. **Navigation granularity is a sentence** — Piper exposes no per-word timing,
> so word-level seeking is intentionally not offered.

### Key paths (XDG; honor `$XDG_*`)

- Models `~/.local/share/piper-tts/<lang>/<model>.onnx` (+ `.onnx.json`)
- Last-used `~/.local/state/piper-tts/last-model`
- Config `~/.config/piper-tts/config` (sourced bash, see the table below)
- Runtime `$XDG_RUNTIME_DIR/hyprland-tts/` (mpv.sock, daemon.pid, chunks, s*.wav, render.done,
  render.count) — wiped on every speak
- Worker state `$XDG_RUNTIME_DIR/hyprland-tts-worker/` (mode 0700: pid, port, ready, last-use,
  lock, worker.log, server.log) — separate so a new speak cannot wipe it
- Engines `~/.local/share/hyprland-tts/engines/qwentts/<commit>/` (`bin/`, models, `engine.conf`)
- User voices `~/.local/share/hyprland-tts/voices/<name>/` (`ref.wav`, `ref.txt`, `ref.spk`,
  `ref.rvq`, `LICENSE`); shipped voices `<prefix>/share/hyprland-tts/shipped-voices/<name>/` (read-only,
  each with `ATTRIBUTION.md`)
- Helper venv `~/.local/share/hyprland-tts/venv/`, model `~/.local/share/hyprland-tts/langid/lid.176.ftz`
- Hyprland `~/.config/hypr/tts.conf` (generated; sourced from `hyprland.conf`)

### Configuration keys (config file) and environment

| Key | Default | Notes |
| --- | --- | --- |
| `ENGINE` | `auto` | `auto` / `qwen3` / `piper`. |
| `QWEN_VARIANT` | `base` | `base` (cloned voices) / `customvoice` (presets); written by `engine install` / `engine variant`. |
| `QWEN_VOICE_<lang>` | – | Voice per language (`voice set`); only 2–3 letter codes (shell variable names). |
| `WORKER_IDLE_MINUTES` | `10` | `engine config idle <1-240>`. |
| `DEFAULT_LANG` | `en` | Router default when detection finds nothing. |
| `QWEN_DEVICE` | install's `engine.conf` | Override, e.g. `CPU`, `Vulkan0`. |
| `QWEN_SEED` | random | Numeric sampling seed. |
| `QWEN_START_TIMEOUT` / `QWEN_REQUEST_TIMEOUT` | 90 / 120 | Worker load / one-chunk limits (seconds). |
| `QWEN_CODEC_DEVICE` | `CPU` | Device of the reference-clip encoder (`voice add`). |
| `NORMALIZE_LOUDNESS` | `1` | `0` disables the `htts_wav.py` loudness step. |
| `VOICE_<lang>`, `FALLBACK_VOICE`, `KEY_<action>`, `DEFAULT_SPEED`, `PIPER_BIN`, `MPV_BIN` | – | 1.x keys (Piper voices, shortcuts, tools). |

Test seams and overrides (environment variables, none needed in normal use):

| Variable | Purpose |
| --- | --- |
| `HYPRLAND_TTS_RUN_DIR` | Replace the player runtime directory (tests). |
| `HYPRLAND_TTS_WORKER_DIR` | Replace the worker state directory (tests). |
| `HYPRLAND_TTS_SYSTEM_VOICES` | Extra read-only voice root searched first (tests, custom installs). |
| `WORKER_IDLE_SECONDS` | Idle limit in seconds, overrides `WORKER_IDLE_MINUTES` (tests). |
| `HTTS_QWEN_ASSET_BASE` | Alternative weight download base URL (tests; `file://` and loopback http allowed only with it; hashes still enforced). |
| `HTTS_TEST_ASSET_TABLE` | Alternative weight table `<role>|<file>|<sha256>` (tests with tiny fixture files). |
| `HTTS_PYTHON` | Explicit interpreter for the text helpers (tests). |
| `HTTS_LID_MODEL` | Explicit fastText model path (tests, packaging). |
| `HTTS_DEPS_PYTHON` | Interpreter used to create the helper venv (e.g. a `python3.13`). |
| `HTTS_PY_DIR` | Directory with the `htts_*.py` helpers (tests, odd layouts). |
| `HYPRLAND_TTS_LIB`, `HYPRLAND_TTS_CLI`, `HYPRLAND_TTS_ALLOW_ROOT` | Library dir (dispatcher), CLI path (GUI), root-guard escape hatch (CI only). |

---

## 3. Feature status

### 2.0 (branch `beta`; plan and research in `docs/PLAN-2.0.md`)

- **Qwen3-TTS engine** — ✅ `engine.sh`/`qwen3.sh`/`qwen3_install.sh`/`worker.sh`. `ENGINE=auto`
  uses Qwen3 when installed *and usable* (Base variant needs ≥1 cloned voice). Failed chunks fall
  back to Piper with one notification per run; a dead worker is restarted once, then written off
  for the run. Measured warm Vulkan (Radeon 680M): ready 1 s, RSS ≈1.2 GB, RTF 0.65–0.77, first
  PCM 0.2 s; CPU Q8_0 RTF 1.1–1.4 (×10 worse under load), RSS 3.2–4.3 GB.
- **On-demand worker** — ✅ binds 127.0.0.1 on a random port (**unauthenticated**: any local
  process or a web page guessing the port can make it speak, never read data — documented in the
  README privacy section), flock-guarded start (the spawned worker must not inherit the lock fd),
  exits after `WORKER_IDLE_MINUTES`. `stop` = playback only; `engine stop` = worker.
- **Engine install in user space** — ✅ ≈7 min, 2.2 GB; Vulkan or CPU auto-detected; pinned
  commit + sha256 weights; Vulkan headers fetched locally when the system has none.
- **Native cloned voices** — ✅ `voices.sh` + `share/voices/` (de-thorsten CC0, en-lj public
  domain, fr-siwis CC-BY-4.0, es-mls-8585 + it-mls-8582 CC-BY-4.0, each with `ATTRIBUTION.md`);
  user voices via `voice add`; per-language choice via `voice set`. Supported languages:
  de/en/fr/es/it native; pt/ru/zh/ja/ko experimental (CJK sentence splitting is limited and the
  list may shrink).
- **Language ID + normalisation** — ✅ `lib/py/` via the helper venv (`deps install`): fastText
  per sentence (smoothed), per-language normalisation, markdown/code clean-up. Falls back to the
  bash/regex path when venv or model are missing. Known limitation: a very short sentence in
  another language ("Hello world. Das ist ein Test.") is smoothed into its neighbours.
- **Audio quality gate** — ✅ `htts_wav.py`: silence and runaway detection (retry), loudness
  normalisation (`NORMALIZE_LOUDNESS`).
- **GUI 2.0** — ✅ Engine / Voices / Language / Shortcuts pages; async install with log + cancel;
  licence-consent gate for cloned voices; headless tests in `tests/gui/`.
- **Pending / coming from the engine side** — `engine variant base|customvoice` (GUI "Switch
  model" already calls it), a "loading voice…" notification while the worker loads, a selection
  size cap. The README mentions all three; verify wording against the final CLI.

### 1.x features (unchanged)

- **Bug 1 (undetected language → last-used model)** — ✅ `router.sh::resolve_model`.
  Order: detected (DE→FR→ES→EN) → **explicit fallback voice** → last-used (if file exists)
  → English → any → error.
- **Bug 2 (model manager, GUI + terminal)** — ✅ `model.sh` + GUI *Voices* tab.
- **Smart playback (skip/replay/speed/pause)** — ✅ mpv IPC in `player.sh`. Instant.
- **Playback stopping/cutting short mid-document (real-world fix)** — ✅ Two distinct real
  bugs, both confirmed live against a real mpv instance, see the gotchas in §5:
  `render_worker` now uses `append-play` instead of `append` (a plain append never resumes
  playback if mpv already went idle, which happens whenever one chunk's synthesis takes
  longer than playing everything queued so far — more likely for a slow/code-derived
  chunk, but a risk on any sufficiently long document); and the daemon's "are we actually
  done" check now waits for mpv's own `playlist-count` to match the true rendered total,
  not just a single `idle-active` reading (which can be transiently stale right as the
  last chunks are appended, cutting them off).
- **Code-in-prose (real-world fix)** — ✅ `text.sh::normalize_text` now classifies and
  normalizes **per paragraph** (blank-line-separated block; markdown fences count as
  boundaries too) instead of the whole selection at once. Previously a big prose blob with
  one embedded code snippet was classified as a whole, so the snippet's raw
  `{ } ( ) ;` reached Piper completely unstripped — bad to listen to, and a likely
  contributor to the slow/erratic synthesis timing behind the playback-stopping bug above.
- **Voiceover text optimizer (prose)** — ✅ `text.sh::normalize_prose`: strips markdown
  (headings, emphasis `*`/`~~`, code fences, list/quote markers), turns links/emails/images
  into short spoken stand-ins (`(link)`, `(email)`, alt-text), drops decorative symbol rows,
  converts table pipes to pauses, and collapses whitespace/blank-line runs into single
  sentence breaks — **meaning preserved** (leaves `snake_case` and accents intact).
- **Voiceover text optimizer (code)** — ✅ `text.sh::looks_like_code` + `normalize_code`.
  `normalize_text` scores 4 independent signals (symbol density, keywords, indented-line
  count, camelCase/snake_case identifiers) and routes to `normalize_code` when ≥2 agree.
  `normalize_code` translates meaningful operators to words (`==`→"equals", `&&`→"and",
  `=>`/`->`→"arrow", etc.), strips comment *markers* while keeping comment *text* (`//`,
  `#`, `/* */`), splits camelCase/snake_case identifiers into pronounceable words, turns
  `{ } ;` into silent sentence breaks instead of reading them aloud, and drops `() [ ]`
  by replacing with a space (not nothing — a straight delete glues adjacent tokens
  together, e.g. `getName(user)` → `Nameuser`; this bit us during testing, see §5 gotcha).
  A final pass drops lines that are only periods/whitespace (e.g. a lone `}` that became
  `.`) so playback doesn't speak empty sentences. Best-effort heuristic, not a parser —
  documented as such in the code; doesn't understand strings-that-look-like-comments or
  describe control flow.
- **Fallback voice (GUI + CLI)** — ✅ `model.sh::cmd_model fallback` (`set` / `--clear` /
  show-current) + GUI *Voices* tab "Fallback voice" group and a "Fallback" button per
  installed voice. Stored as `FALLBACK_VOICE` in the config file; takes priority over the
  automatic last-used heuristic in `resolve_model` since it's a deliberate user choice;
  cleared automatically if that model is removed (same as `default`).
- **Rebind + conflict detection** — ✅ `keybind.sh` + GUI *Shortcuts* tab (press-to-capture,
  warns on clash via `hyprctl binds -j`).
- **Image reading** — ✅ `image.sh` (exiftool description → tesseract OCR), optional deps,
  silent if absent. **Web alt-text is out of scope** (browser DOM only) — `image.sh` is the
  documented extension point if a browser bridge is ever added.
- **GUI dependency detection (real-world fix)** — ✅ `_gui_python()` in `bin/hyprland-tts`
  no longer trusts a bare `python3`; see the gotcha in §5 for the exact failure it fixes.
- **Root/sudo guard (real-world fix)** — ✅ `refuse_root()` blocks every subcommand under
  root, in both the dispatcher and the GUI; see the gotcha in §5.
- **Hover: speak text under the cursor** — ✅ `hover.sh::cmd_hover` + `hover-read.py`,
  intentionally **not exposed via default keybinds or the Shortcuts UI right now**
  (CLI-only via `hyprland-tts hover`) while stability work continues. Deliberately
  on-demand, one AT-SPI query per keypress — not continuous hover polling, because true
  continuous hover needs a
  permanent background daemon watching pointer position, which conflicts with this
  project's "no background daemons" principle (see §1 Mission). This was an explicit
  scope decision asked of the user, not assumed — see the options in the PR/session that
  added this feature if you need the reasoning restated.
  - Cursor position comes from `hyprctl cursorpos` — Hyprland-specific; this action only
    works under Hyprland (matches the rest of the project's scope).
  - Text comes from AT-SPI (the same accessibility framework Orca's "Mouse Review" uses):
    only works in apps that implement it. Confirmed working live against GTK apps
    (Mousepad, Nautilus). **Electron apps (VS Code, Discord, Slack, etc.) commonly don't
    register with AT-SPI at all** unless the app has had accessibility explicitly enabled
    — confirmed live: the actual focused window (`code`) was simply absent from AT-SPI's
    application list. Terminals and games are similarly invisible to it. This is a hard
    ceiling on coverage, not a bug to chase.
  - AT-SPI has no concept of window stacking order, and occluded/background windows keep
    reporting their old geometry — without help, a hidden app's node can shadow the really
    visible one at the same screen point (confirmed live: a background file manager's
    sidebar was returned instead of the focused editor's text). Fixed by passing the
    *actually focused* window's class (`hyprctl activewindow -j`, grep'd for `"class"`) as
    a hint that `hover-read.py` checks first, falling back to a full scan if that app isn't
    AT-SPI-registered.
  - Hard-bounded by a shell `timeout` around the whole Python call (currently 1.5s) so a
    stuck/missing AT-SPI registry degrades to silence, never a hang.
  - **Privacy note:** this command reads whatever text is actually on screen at the cursor,
    including in other people's open documents/messages if the pointer happens to be there.
    That's inherent to what the feature does (same as it would be for any screen reader),
    not a bug — but worth being upfront about in the README, which it now is.
  - **No-text feedback:** when AT-SPI is working but the pointed-at app does not expose
    text there, `cmd_hover` now sends a short notification instead of exiting silently.
    That keeps the shortcut from looking dead on unsupported areas and makes the
    distinction between "shortcut fired" and "app exposed nothing" visible to the user.
  - **Missing-dependency notifications (`common.sh::notify`).** A keybind-triggered action
    has no terminal to show a `die` message to — a silent failure and "the shortcut isn't
    even bound" look identical to the user. Confirmed for real: a user reported hover
    "not working" after install; the real cause turned out to be a stale/custom keybind
    (see next bullet), but while diagnosing it we realized a genuinely missing dependency
    (no AT-SPI, no `hyprctl`) would have been just as silent and just as confusing. Fixed
    by adding `notify()` and using `notify-send` for desktop-visible failures, then calling
    it from `cmd_hover`'s two dependency-missing paths as well as the shared speech path
    when Piper/mpv/socat or any voice model is missing — but deliberately **not** from the
    "no text found at this point" exit, since that's an expected, frequent outcome while
    moving the mouse around and would just be spam.
  - **`tts.conf` (the generated, LIVE file) can drift from the config file `keybind list`
    reads — and `keybind list` used to just lie when that happened (real bug, fixed).**
    First diagnosed as "the user must have deliberately rebound hover to `SUPER ALT, a`,
    pairing it with Speak's `A`" — `keybind list` reported the correct `SUPER ALT, H`
    default (the config file had no `KEY_hover` override) and that looked like the whole
    story. It wasn't: `hyprctl binds -j` and the on-disk `~/.config/hypr/tts.conf` still
    showed the OLD `SUPER ALT, a` binding live, even though the config said default. Root
    cause: only `keybind set`/`reset`/`setup` regenerate `tts.conf` — if a `KEY_*` line is
    ever removed by hand (editing the config file directly, which looks like the obvious
    thing to do and is not forbidden) instead of via `keybind reset`, the config file
    correctly reverts to reporting the default, but the generated `tts.conf` — and
    therefore the actual live Hyprland bind — silently keeps the stale value forever.
    `keybind list` was reporting the config's belief, not the truth of what Hyprland
    actually had bound, and there was no way to tell the two apart from its output. Fixed:
    `cmd_keybind`'s `list` subcommand now regenerates `tts.conf` (and reloads Hyprland,
    only if the content actually changed) *before* reporting anything, so what it prints
    always matches what's actually live — self-healing on the exact command a confused
    user would naturally run to check. **Lesson: don't stop at the first plausible
    explanation that fits the evidence you happened to check first — `keybind list`
    matching config was consistent with "deliberate rebind" but the live bind said
    otherwise, and only checking `hyprctl binds -j` directly caught it.**

---

## 4. Packaging

- `Makefile` installs static assets into `PREFIX` (`bin/`, `lib/hyprland-tts/*.sh`, desktop,
  docs). Used by both the PKGBUILD (`DESTDIR`, `PREFIX=/usr`) and the local installer
  (`PREFIX=$HOME/.local`). **Never writes to `$HOME`.**
- `PKGBUILD` currently builds from the **local working tree** (`source=()`, `package()` cds
  to `$startdir`) so `makepkg` works while iterating on `main`. The AUR release recipe
  (tag tarball + real `sha256sums` + release `package()`) is a commented block to swap in
  at publish time; then regenerate `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`.
- `depends`: `bash python piper-tts-bin wl-clipboard mpv socat procps-ng curl gawk sed grep
  util-linux findutils gtk4 libadwaita python-gobject`. `optdepends`: `hyprland`,
  `tesseract`(+`-data-eng`), `perl-image-exiftool`, `at-spi2-core` (for `hover`), `libnotify`,
  `python-fasttext-predict` + `python-num2words` (AUR; else `deps install`), and the engine build
  tools `cmake git gcc make shaderc vulkan-icd-loader` (+ optional `vulkan-headers`,
  `spirv-headers`). (GTK stack is a hard dep so `hyprland-tts gui` always works; `alsa-utils` was
  dropped when playback moved to mpv.)
- Shipped voice packs install to `$PREFIX/share/hyprland-tts/shipped-voices/` (a separate name, so a
  `PREFIX=$HOME/.local` install never mixes them into the user voice directory); `THIRD_PARTY.md` and
  `CHANGELOG.md` install as optional docs. **Caveat:** with `PREFIX=$HOME/.local` (local
  installer) that directory equals the user voice directory, so shipped voices are reported as
  `user` voices (removable); the GUI therefore falls back to `ATTRIBUTION.md` for user voices.
- `hover-read.py` installs alongside the `lib/*.sh` modules (`$LIBDIR/hover-read.py`,
  mode 755 — it's executed directly by `hover.sh`, not sourced like the `.sh` files).
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
  **This fix only covers launches that go through `bin/hyprland-tts gui`.** A `.desktop`
  file's `Exec=` (or anything else invoking `hyprland-tts-gui` directly) bypasses the
  wrapper entirely and hits the same PATH-shadowing bug again via the script's own
  shebang — confirmed for real: the user's desktop-menu launch silently did nothing (no
  terminal to show the resulting `ModuleNotFoundError`), while `hyprland-tts gui` from a
  terminal worked fine. Two fixes, both shipped: the `.desktop` file's `Exec=` now reads
  `hyprland-tts gui` (routes through the wrapper like everything else — "one brain, thin
  skins" applies to desktop entries too), **and** `gui/hyprland-tts-gui` itself now probes
  and self-`exec`s into `/usr/bin/python3` at the top of the script (`_reexec_with_gtk_python`)
  as defense-in-depth for any launch path that still invokes the raw binary. Verified live:
  running the script directly under this box's PATH-shadowed `python3` now correctly
  re-execs into the system one and GTK initializes, instead of a silent `ModuleNotFoundError`.
- **Never run any part of this tool as root/via `sudo`.** Confirmed for real: after hitting
  the bug above, the user tried `sudo hyprland-tts gui`, which crashed with
  `Authorization required` / `Gtk couldn't be initialized` — root has no access to the
  caller's Wayland session, and `~/.config`/`~/.local` would resolve under `/root` instead
  of the real user's home. `refuse_root()` in `bin/hyprland-tts::main()` (plus a duplicate
  `os.geteuid()` guard at the top of `gui/hyprland-tts-gui`, for anyone invoking the GUI
  binary directly) blocks every subcommand under root with a message pointing at the real
  fix, before touching GTK/Wayland at all. Escape hatch: `HYPRLAND_TTS_ALLOW_ROOT=1` (not
  documented for normal use — packaging/CI only).
- **AT-SPI's tree structure follows widget hierarchy, not visual containment — do not
  prune a search by "does this node's bounds contain the point."** A GTK notebook's
  "page tab" accessible reports only the tiny tab-*label* rectangle; its actual page
  content is a child with much larger, geometrically unrelated screen bounds. Pruning a
  point-search when a parent's bounds don't contain the point silently skips real,
  correctly-nested content — caught by testing `hover-read.py` against a live GTK app.
  Walk the whole (bounded) subtree instead and pick the best match by its own bounds.
- **This GI/Atspi binding's `Text.get_text()` is not what it looks like.** Calling it as
  a bound method — `iface.get_text(start, end)` — raises `takes exactly 1 argument (3
  given)` and gets silently swallowed by any `except Exception`, so every real text node
  quietly contributes nothing. The working form is the static/free function:
  `Atspi.Text.get_text(iface, 0, -1)`. This one cost real debugging time against a live
  desktop — confirm empirically before trusting a GI method's signature from memory,
  it can differ from the C API docs.
- **When stripping structural characters from spoken text, replace with a space, not
  nothing.** A bare `s/[()]//g` glues adjacent tokens together (`getName(user)` →
  `Nameuser`, unpronounceable and confusing) — always `s/[()]/ /g` and let the whitespace
  tidy-up pass collapse runs. Caught in `normalize_code`; applies to any future text
  transform in `text.sh`.
- **mpv's `loadfile … append` does not resume playback once mpv has gone idle — you need
  `append-play`.** Confirmed empirically against a live mpv instance: after mpv drains its
  playlist and reports `idle-active: true`, appending another file with plain `append`
  raises `playlist-count` but `idle-active` and `playlist-pos` never change — the file
  sits queued and is never played, silently, forever. `append-play` fixes this
  unconditionally (and behaves exactly like `replace` on an empty/fresh playlist, so it's
  safe to use for every chunk, no first-chunk special case needed). This was the real
  mechanism behind two user reports — "audio just stops" (more likely when one chunk is
  unusually slow to synthesize, giving mpv time to drain and go idle before the next
  append) and "sometimes cut short" (the same race from ordinary timing variance on a long
  document) — and it does **not** reproduce on short test inputs where synthesis always
  outpaces playback, so a quick manual smoke test alone won't catch it; you need a
  deliberately slow-to-render chunk to force the race (see `render_worker`'s comment for
  a reproducible harness sketch).
- **A `DONEFILE`-exists-plus-one-`idle-active`-reading "are we done" check is racy — verify
  against mpv's own count, not a single timing-sensitive read.** `render_worker` touches
  its done-marker the instant it has *issued* its last `append-play` IPC call, which is
  not the same moment mpv has *processed* it; a monitor-loop poll landing in that gap can
  see a stale `idle-active: true` left over from the previous chunk and quit mpv before
  the last chunk(s) actually play. Fixed by having `render_worker` also record how many
  chunks it appended (`COUNTFILE`) and having the monitor loop require mpv's own
  `playlist-count` to reach that number, in addition to `idle-active` — a premature poll
  just sees a lower count and correctly keeps waiting, instead of trusting a snapshot that
  might be stale. General principle: when two processes coordinate via "the other one
  finished," prefer a condition the OTHER side reports about its own real state over one
  your side merely infers from a single timing-dependent read.
- **Verify `set -e` suspicions empirically, don't just flag them.** While investigating
  the above, `mode="append"; [ "$idx" -eq 0 ] && mode="replace"` looked like a classic
  `set -e`-plus-`&&`-list footgun (a standalone `A && B` where `A` fails would seem to
  exit the whole function under `set -e`). Tested it in isolation before "fixing" it:
  bash exempts every command in an `&&`/`||` list except the last one from triggering
  `-e`, so this specific pattern was never actually broken — the real bugs were the two
  mpv issues above. Don't spend a fix on a plausible-looking gotcha without confirming it
  reproduces; a wrong diagnosis here would have masked the real bug.
- **Testing `run_daemon`/`speak_text` for real spawns real mpv, which opens a real audio
  device by default — `run_daemon` never passes `--ao=null`.** Even fake, silent WAV
  content still opens a genuine PipeWire/ALSA stream. Confirmed while debugging: running
  the actual daemon repeatedly without muting it caused mpv to become unresponsive to its
  own IPC socket, most likely from multiple leftover test instances contending for the
  audio device — a test-environment artifact that looked exactly like a logic bug until
  isolated. When testing this path, wrap `mpv` in a fakebin script that injects `--ao=null`
  before invoking the real binary — keeps real mpv IPC/playlist semantics (unlike a fully
  fake `mpv`) while never touching audio hardware or a live user's speakers.
- **2.0 gotchas (don't reintroduce):**
  - **`awk` early `exit`, `grep -m1`, `head` + `set -o pipefail` = random SIGPIPE failures.**
    The producer is killed when the reader quits early; a function then fails "sometimes".
    Read the whole stream (see `qwen3_asset_field`).
  - **The spawned worker must not inherit the flock fd** (`9>&-` in `worker_kick`/spawn), or the
    lock is held for the worker's whole life and every later start blocks.
  - **`fn &` gives a subshell pid, not the server pid.** Record the real `tts-server` pid from
    inside; `worker_pid_alive` also matches `/proc/<pid>/cmdline` against `__worker` to defeat
    pid reuse.
  - **`find_package(SPIRV-Headers CONFIG)` needs a cmake-installed prefix**, not a plain
    checkout — the installer runs `cmake --install` for the fetched headers.
  - **Upstream's `-DGGML_BLAS=ON` fails to link** (`cblas_sgemm`); the installer uses OFF.
  - **GGML CPU threads spin-wait:** on a saturated CPU RTF went 1.4 → 12–14. Prefer Vulkan;
    upstream has no thread flag (it uses cores/2).
  - **Runaway generation:** a one-word input once produced 16 s of audio (no EOS). Always cap
    `max_new_tokens` proportional to the text (`qwen3_max_frames`) and treat a render ≥80 % of the
    cap as runaway (retry, then Piper).
  - **Silent output:** 1 of 124 Vulkan runs returned all-zero samples under iGPU contention —
    `htts_wav.py` gates peak < 0.01 and the render is retried with a new seed.
  - **Qwen reads literally:** `1.250,75 Euro`, `Kfz`, `sudo pacman -Syu` come out garbled unless
    normalised first. Never feed raw text to the neural engine when the helpers exist.
  - **Speaker embeddings are talker-size specific** (0.6B: 4096 B, 1.7B: 8192 B); `.rvq` codec
    tokens are shared. Packs hold the 0.6B encodings in `ref.*`.
  - **`fasttext-predict` has no Python 3.14 wheel:** pip builds the sdist (needs g++). Use
    `HTTS_DEPS_PYTHON=python3.13` or `gcc`.
  - **PyPI `torchaudio` (pulled by `qwen-tts`) is the CUDA build** and fails to load; official
    PyTorch path is RTF 9.6 anyway and is not used. `HF_HUB_OFFLINE=1` + repo id still calls the
    API. bf16 on CPUs without AVX512-BF16 is ~4× slower than fp32.
  - **Piper `it_IT-serena-high` crashes the installed `piper-tts`** (multi-character phoneme
    "aɪ"); use `it_IT-paola-medium`.
  - **Markdown list markers are stripped only at line start** (otherwise "am 3. Oktober" lost
    its "3.").
  - **The worker's HTTP port is unauthenticated** (127.0.0.1, random port). Never add an
    endpoint that returns user data; keep it text → audio only.
  - **Keep fixtures out of the user's data:** tests set `HOME`, `XDG_*`,
    `HYPRLAND_TTS_WORKER_DIR`, `HYPRLAND_TTS_RUN_DIR` to temp dirs. Never test against the real
    config, and never play audio (`--ao=null` wrapper for mpv, see above).
  - **GUI tests must not claim the real application id.** A running `hyprland-tts-gui` (same
    D-Bus id) turns a second `Adw.Application` in the test process into a *remote* instance and
    the first `Adw.ApplicationWindow(...)` **segfaults**. `tests/gui` creates `TtsApp` with
    `flags=Gio.ApplicationFlags.NON_UNIQUE` and its own id.
  - **GUI widget traps:** `Adw.ActionRow` titles/subtitles parse Pango markup — set
    `use_markup=False` for CLI text (`&`, `<`); `Adw.Toast` too. Programmatic `set_selected`
    emits `notify::selected`: guard it (`_populating`) or connect after selecting. After an async
    job ends, update button sensitivity immediately — do not wait for the status refresh.
    `Adw.AlertDialog` (≥1.5) replaces the deprecated `Adw.MessageDialog`; `create_dialog` /
    `present_dialog` cover both. The GUI cancels an install with `os.killpg` on the child's own
    session (`start_new_session=True`), so build children die with it.
- **XDG compliance**; **idempotent** setup (2× setup → 1 source line; uninstall → 0 refs).
- **Keep core shortcuts as defaults** (`SUPER+A`, `SUPER+ESCAPE`); playback controls default
  to `SUPER+ALT+…`. Hover is intentionally not bound/shown in UI for now. Exposed
  shortcuts are user-rebindable via `keybind`.
- **Update docs with code:** README (users, incl. the troubleshooting section — every fix or
  debug session documents its errors there), this Agent.md (agents), `CHANGELOG.md`,
  `THIRD_PARTY.md` (licences/attribution) and `docs/PLAN-2.0.md` (status).
- **Code standard (all code, enforced by the QA gate):** module docstring and a docstring (summary,
  Args, Returns) on every def/class; an intent comment above every small group of statements (never
  more than 3 uncommented statements in a row; no echo comments); meaningful names; lines ≤100;
  small functions. Gates: `python3 tools/qa/qa-precheck.py . <files>`,
  `python3 tools/qa/comment-runs.py <files>` (extension-based: the extensionless GUI script must
  be checked through a `.py` copy/symlink), `uvx ruff check --line-length 100`.

---

## 6. Testing / Verification

Exact commands:

```bash
make check                      # bash -n on every script, py_compile on every Python file
make test                       # bash tests/run.sh: every tests/test_*.sh + pytest tests/py (if pytest exists)
bash tests/test_engine_worker.sh   # a single bash suite
python -m pytest tests/py -q    # text helpers (langid, normalisation, markup, split)
python -m pytest tests/gui -q   # GUI, headless (see below)
make qa                         # coding-standard gate
```

**GUI tests (`tests/gui/test_gui.py`, 70 tests).** The module is skipped when PyGObject, GTK4,
libadwaita or `gtk4-broadwayd` are missing. It starts a private **Broadway** daemon
(`gtk4-broadwayd :N`, `GDK_BACKEND=broadway`, `WAYLAND_DISPLAY`/`DISPLAY` removed) so no window can
ever appear on the live desktop, imports `gui/hyprland-tts-gui` as a module and drives widgets
programmatically on the GLib main loop. A **fake `hyprland-tts`** (written to a temp dir, selected
via `HYPRLAND_TTS_CLI`) records every argv and file argument and replays canned porcelain/stderr
(incl. hanging jobs for cancel and a SIGTERM-ignoring one for the SIGKILL escalation). Covered:
porcelain parsing, page construction, button → argv mapping, async install log streaming, cancel
(process group dead), close-during-install, error toasts, consent gating of `voice add`, temp-file
cleanup, and a contract check against the real CLI in an isolated `HOME`. System Python with `gi`
is `/usr/bin/python3`; if pytest is missing there:
`uv venv --system-site-packages -p /usr/bin/python3 /tmp/v && uv pip install --python /tmp/v/bin/python pytest`.

`make check` runs `bash -n` on the dispatcher + `py_compile` on the GUI. Manual checks use a
scratch `$HOME` and fakes on `PATH`. Status of what's been exercised:

- **Text optimizer (prose)** — markdown/URL/email/table/symbol-row/blank-line cases; accents
  and `snake_case` preserved; no double periods / leading commas. *(Verified.)*
- **Text optimizer (code)** — `looks_like_code` correctly classifies a JS-style snippet as
  code and plain prose as prose; `normalize_code` on a JS function and a Python function
  (braces vs. `#`/indentation) both produce clean, chunk-able sentences with no glued
  tokens and no stray empty-period lines; `**kwargs` isn't mistaken for markdown emphasis
  (that stripping only happens in `normalize_prose`). *(Verified.)*
- **Router** — DE/FR/ES/EN detection; ambiguous → fallback voice (if set) → last-used;
  detected beats fallback beats last-used; fallback cleared on model removal. *(Verified.)*
- **Keybind** — modmask math, combo split, `tts.conf` generation, and conflict detection
  against a fake `hyprctl binds -j` (blocks; `--force` overrides). *(Verified.)*
- **mpv player** — **real mpv (via a `--ao=null`-injecting fakebin wrapper — see the audio
  gotcha in §5) + socat + fake Piper WAVs**: speak → next/prev (instant), faster/slower
  (live speed 1.2/0.8, no restart), pause/resume, stop → clean, no orphans. *(Verified.)*
- **`append-play` fix + `COUNTFILE` completion check** — reproduced the actual bug with a
  fake Piper that deliberately sleeps 2.5s on one chunk out of three, and an authoritative
  timestamped log of real synthesis start/end times cross-referenced against `ctl status`
  polls every 0.3s: confirmed mpv correctly stays idle (not stuck) through the slow
  chunk's synthesis, then resumes and plays the remaining chunks once they're appended,
  and the daemon only reports done once mpv's real `playlist-count` reaches the true
  total. Also confirmed the normal fast-path (no artificial delay) and all `ctl` commands
  are unaffected. *(Verified — this is the actual fix for two user-reported bugs, not
  speculative; see §5 for the two gotchas this uncovered.)*
- **Model commands** — catalog/list/porcelain (now 7 fields incl. fallback)/default/
  fallback (set/clear/show)/remove + URL security (rejects non-https/traversal/wrong-
  extension). *(Verified.)*
- **Setup/uninstall** — idempotent wiring round-trip. *(Verified.)*
- **Packaging** — `make install` layout (incl. `lib/`), and a real `makepkg` build. *(Verified.)*
- **GUI** — ✅ headless Broadway test suite (`tests/gui`, 70 tests, mutation-checked) plus a
  smoke run of all four pages against the real CLI in an isolated `HOME`. **Not** click-through
  tested on a real Wayland session (never pop windows on the live desktop): visual layout,
  Wayland focus behaviour and the file chooser portal are unverified.
- **Image reading** — logic only; needs a live Wayland clipboard to exercise end-to-end.
- **GUI python3 resolution** — reproduced the exact failure on the dev box itself (its
  `PATH` python3 is mise-managed and lacks `gi`; `/usr/bin/python3` has it): confirmed the
  old bare-`python3` check falsely reports the stack missing, confirmed `_gui_python()`
  correctly falls back and resolves `/usr/bin/python3`. *(Verified — this is a real,
  reproduced regression fix, not speculative.)*
- **Root guard** — faked `id -u` → `0` on `PATH`; confirmed `gui`/`model`/`setup` all refuse
  cleanly before touching GTK/Wayland, real (non-root) invocations are unaffected, and
  `HYPRLAND_TTS_ALLOW_ROOT=1` bypasses it. *(Verified.)*
- **Hover** — **tested against a real, live Hyprland + AT-SPI desktop**, not just fakes:
  `hyprctl cursorpos`/`activewindow` parsing; real query against Mousepad and Nautilus
  (found real file content, not just widget names); the two real bugs this surfaced (child
  bounds not nested in parent bounds; `Text.get_text()`'s actual calling convention) — both
  documented as gotchas in §5 and fixed; graceful silent fallback confirmed for an
  AT-SPI-unregistered focused app (VS Code) and for `hyprctl`/AT-SPI entirely absent.
  Did **not** exercise the final `speak_text` handoff live (would have synthesized and
  played the real (and in one case personal/sensitive) on-screen text through the user's
  speakers mid-debugging) — that leg of the pipeline is the same `speak_text` already
  covered by the mpv player tests above, just fed a different text source.

Correction to an earlier assumption in this file: the dev box used for prior sessions turned
out to have a **live Hyprland/Wayland session** reachable the whole time (`hyprctl` worked,
AT-SPI was running) — the earlier GTK launch failures were most likely from this agent
overriding `$XDG_RUNTIME_DIR` for an unrelated test, which hides the real Wayland socket from
GTK, not from the environment being genuinely headless. Don't assume "no display" without
checking `hyprctl monitors` / `$WAYLAND_DISPLAY` first — and don't override `$XDG_RUNTIME_DIR`
in a test without restoring it, since that variable is also how GTK finds the compositor.

- **Keybind self-heal** — simulated the exact drift bug live: generated `tts.conf` via
  `setup`, hand-edited it to reintroduce a stale binding (bypassing `keybind set/reset`,
  exactly how the real bug occurred), then confirmed `keybind list` detects the
  difference, regenerates `tts.conf` correctly, and reports the true (now-fixed) value.
  *(Verified — also applied directly against the real reporting user's live system to fix
  their actual stuck `hover` binding, confirmed via `hyprctl binds -j` before and after.)*
- **Mixed prose+code normalization** — pure prose, pure code (JS-brace and Python-`#`
  styles), a prose paragraph with an embedded code snippet (no blank lines needed —
  markdown fences count as boundaries too) all produce clean output with the code portion
  properly normalized regardless of the surrounding text's classification, and no
  double-punctuation at paragraph joins. *(Verified.)*

Not yet run: clean-chroot `makepkg` + `namcap`; an interactive GUI click-through on a real
Wayland session; a full Qwen3 install + speak on a second machine (verified on the reference box:
install ≈7 min / 2.2 GB, warm Vulkan ready 1 s, RSS ≈1.2 GB, RTF 0.65–0.77, first PCM 0.2 s).

---

## 7. Open follow-ups

- Publish a tagged release; swap PKGBUILD to the release recipe + real `sha256sums`;
  regenerate `.SRCINFO`; run `namcap`.
- Smoke-test the GUI and real audio playback on a Hyprland desktop (listen to the five shipped
  voices: quality was judged by ASR error rate only, never by ear).
- Land `engine variant`, the "loading voice…" notification and the selection size cap, then
  verify README wording. Decide the fate of the experimental zh/ja/ko languages.
- A CPU-only engine for machines without a usable GPU (Supertonic 3 measured RTF ≈0.23, 650 MB,
  OpenRAIL-M model licence; Kyutai Pocket TTS slower and misreads digits).
- Local-install voice root collision (see §4 caveat); `make qa` does not yet cover the GUI script
  (extensionless) or `tests/gui`.
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
├── CHANGELOG.md / THIRD_PARTY.md    # release notes / licences and voice attribution
├── bin/hyprland-tts                 # thin dispatcher (resolves lib/, dispatches subcommands)
├── lib/                             # THE LOGIC
│   ├── common.sh  text.sh   router.sh  model.sh   image.sh   keybind.sh
│   ├── engine.sh  qwen3.sh  qwen3_install.sh  worker.sh  voices.sh  pyenv.sh   # 2.0 engine layer
│   ├── player.sh  setup.sh  hover.sh  hover-read.py   # hover: AT-SPI, not sourced, exec'd
│   └── py/                          # htts_*.py text helpers + requirements.txt (helper venv)
├── gui/hyprland-tts-gui             # GTK4/libadwaita: Engine, Voices, Language, Shortcuts (thin CLI front end)
├── share/
│   ├── applications/hyprland-tts.desktop
│   ├── voices/<name>/               # shipped voice packs (ref.wav/.txt/.spk/.rvq, ATTRIBUTION.md)
│   └── tts.conf.sample              # reference copy (real file is generated)
├── tests/                           # test_*.sh bash suites, lib/ helpers, py/ (pytest), gui/ (Broadway)
├── tools/qa/                        # vendored coding-standard gate (qa-precheck.py, comment-runs.py)
├── docs/PLAN-2.0.md                 # 2.0 plan, research numbers, work-package status
├── install-tts.sh / uninstall-tts.sh  # local (~/.local) installer for git-checkout users
```
