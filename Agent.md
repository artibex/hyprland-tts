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
| `text.sh` | `normalize_text` dispatches to `normalize_prose` or `normalize_code` (via `looks_like_code`), + `chunk_text` (sentence splitting). |
| `router.sh` | `detect_lang` + `resolve_model` (fallback-voice + last-used) + `remember_model`. |
| `model.sh` | Voice catalog + install / list / catalog / remove / default / **fallback** (+ all download security). |
| `image.sh` | `read_clipboard_image` — exiftool metadata → tesseract OCR, graceful. |
| `keybind.sh` | Generate `tts.conf` from the action table; `keybind list/set/check/reset`; conflict detection via `hyprctl binds -j`. |
| `player.sh` | mpv-based smart player: `cmd_speak`, `speak_text` (shared with `hover`), `run_daemon`, `render_worker`, `cmd_ctl`, `cmd_stop`. |
| `setup.sh` | Idempotent Hyprland wiring: `setup` / `uninstall` / `purge`. |
| `hover.sh` | `cmd_hover` — on-demand "speak text under the cursor" via `hyprctl cursorpos` + AT-SPI (`hover-read.py`, a non-sourced Python helper installed alongside the `lib/*.sh` modules). |

The dispatcher resolves its lib dir from (in order) `$HYPRLAND_TTS_LIB`,
`<self>/../lib/hyprland-tts` (installed), `<self>/../lib` (git checkout),
`/usr/lib/hyprland-tts`, `~/.local/lib/hyprland-tts`.

### Playback pipeline (the important part)

`speak` → read `wl-paste --primary` (or `read_clipboard_image` if selection empty) →
`normalize_text | chunk_text` → `resolve_model` → remember → launch detached `__daemon`.

`__daemon` starts **one mpv** in idle mode with an IPC socket
(`--input-ipc-server`, `--audio-pitch-correction=yes`), renders each sentence **once** with
Piper to a WAV, and `loadfile … append-play`s it to mpv's playlist. Controls are **native
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
- Config `~/.config/piper-tts/config` (sourced bash: `VOICE_<lang>`, `FALLBACK_VOICE`,
  `KEY_<action>`, `DEFAULT_SPEED`, `PIPER_BIN`, `MPV_BIN`)
- Runtime `$XDG_RUNTIME_DIR/hyprland-tts/` (mpv.sock, daemon.pid, chunks, s*.wav, render.done,
  render.count)
- Hyprland `~/.config/hypr/tts.conf` (generated; sourced from `hyprland.conf`)

---

## 3. Feature status

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
  bound to `SUPER ALT, H` by default. **Deliberately on-demand, one AT-SPI query per
  keypress — not continuous hover polling**, because true continuous hover needs a
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
- `depends`: `bash piper-tts-bin wl-clipboard mpv socat procps-ng curl gawk sed grep gtk4
  libadwaita python-gobject`. `optdepends`: `hyprland`, `tesseract`(+`-data-eng`),
  `perl-image-exiftool`, `at-spi2-core` (for `hover`). (GTK stack is a hard dep so
  `hyprland-tts gui` always works; `alsa-utils` was dropped when playback moved to mpv.)
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
- **XDG compliance**; **idempotent** setup (2× setup → 1 source line; uninstall → 0 refs).
- **Keep core shortcuts as defaults** (`SUPER+A`, `SUPER+ESCAPE`); playback controls default
  to `SUPER+ALT+…`. All are user-rebindable via `keybind`.
- **Update docs with code:** README (users) + this Agent.md (agents).

---

## 6. Testing / Verification

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
- **GUI** — `py_compile` + graceful no-GTK message. Not interactively clicked-through this
  session (the dev box turned out to have a live Hyprland desktop — see below — but
  popping a window on someone's live session mid-debugging wasn't the moment for it).
  Still needs a real interactive smoke-test: Voices (install/remove/default/fallback),
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

Not yet run: clean-chroot `makepkg` + `namcap`; an actual interactive GUI click-through.

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
│   ├── common.sh  text.sh   router.sh  model.sh
│   ├── image.sh   keybind.sh player.sh  setup.sh
│   └── hover.sh   hover-read.py     # on-demand cursor read (AT-SPI; not sourced, exec'd)
├── gui/hyprland-tts-gui             # GTK4/libadwaita: Voices + Shortcuts (thin CLI front end)
├── share/
│   ├── applications/hyprland-tts.desktop
│   └── tts.conf.sample              # reference copy (real file is generated)
├── install-tts.sh / uninstall-tts.sh  # local (~/.local) installer for git-checkout users
```
