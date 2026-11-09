# hyprland-tts 2.0 — Neural engine, real language ID, full polish

Status: work packages 1–3 and the GUI/documentation part of 4 are done on `beta`; the remaining
open items are listed under *Open items* at the end. Research data (measured on the reference box: Ryzen 6000
"Rembrandt", 12 threads, 30 GB RAM, Radeon 680M iGPU, no ROCm/CUDA) is summarised below.

## 1. Research results

### TTS engines (Whisper-small CER on an 8-item de/en/fr/es/it test set; RTF = synth/audio)

| Engine / runtime | RTF | RAM | First audio | CER | Verdict |
|---|---|---|---|---|---|
| Piper (current), medium/high voices | 0.04–0.23 | 0.2–0.4 GB | ~0.3 s | 0.040 | fast, robotic prosody — keep as light fallback |
| Qwen3-TTS 0.6B, official PyTorch (CPU fp32) | 9.6 | 5.7 GB | 23 s cold | 0.023 | far too slow on CPU |
| **Qwen3-TTS 0.6B, `qwentts.cpp` GGUF Q8_0, Vulkan (iGPU)** | **0.62–0.66 warm** | **1.2 GB** | **0.2 s warm** | 0.035 | **chosen primary engine** |
| Qwen3-TTS 0.6B, `qwentts.cpp` Q8_0, CPU only | 1.1–1.4 (10× worse under load) | 3.2–4.3 GB | ~1 s | 0.07 | CPU fallback, borderline |
| Chatterbox Multilingual V3 (torch CPU) | 5–30 | 6.7 GB | 14–33 s cold, no streaming | 0.039 | too heavy; upstream retired Aug 2026 |
| Chatterbox Turbo / Nano | 1.2–3.0 | 4–6 GB | 12–28 s cold | 0.035 | English only |

Qwen3-TTS: Apache-2.0 weights + code; `qwentts.cpp` MIT; 10 languages (zh en ja ko de fr ru
pt es it); preset speakers (CustomVoice) are zh/en/ja/ko natives only — native German/French/…
voices need the **Base** model's zero-shot cloning from a licence-clean reference clip
(supported by `qwentts.cpp` incl. pre-encoded `.spk/.rvq` latents and a server voice registry).
Known model quirks: reads numbers/abbreviations literally (needs text normalisation) and may
run away on very short inputs (cap `max-new` proportional to text length).

Chatterbox (MIT) was evaluated seriously but loses on every efficiency axis on this class of
hardware and is unmaintained upstream; it is not integrated. CPU-only candidates for a later
engine (Supertonic 3, Kyutai Pocket TTS) are being benchmarked separately.

### Language identification (200 whole-text items, 105 gold-labelled mixed-language sentences)

| Detector | Whole text | Per sentence (held-out) | Cold start | Disk |
|---|---|---|---|---|
| current regex router | 60 % | – | – | – |
| **fastText `lid.176.ftz` restricted to voice languages + smoothing** | **99.5–100 %** | **100 %** | **38 ms** | **2 MB** |
| lingua (high accuracy) | 96.5 % | 91 % | 22 ms | 293 MB |

## 2. Target architecture

```
selection ─► normalize (per language: numbers, dates, currency, abbreviations, code)
          ─► segment (fastText, per sentence, smoothed)  ─►  "<lang>\t<sentence>" chunks
          ─► engine (qwen3 | piper) picks the voice per chunk language
          ─► mpv playlist (unchanged instant controls)
```

- **Engine layer** (`ENGINE=auto|qwen3|piper`): `auto` = qwen3 when installed, else piper.
- **On-demand worker** (user decision): `qwentts.cpp tts-server` is started on the first
  speak, kept warm, and exits after `WORKER_IDLE_MINUTES` (default 10) without requests.
  No permanent daemon, no systemd unit required.
- **Engine install in user space** (`hyprland-tts engine install qwen3`): builds a pinned
  `qwentts.cpp` commit (Vulkan when available, else CPU), downloads pinned GGUF weights with
  sha256 verification. Nothing runs as root.
- **Voices per language**: preset speakers or cloned native voices (licence-clean references
  shipped with attribution), selectable per language; Piper voices remain available.
- **Python helper venv** for fastText + normalisation, created by the tool; graceful fallback
  to the old regex router when it is missing.

## 3. Work packages

1. ✅ **Engine layer + Qwen3 backend + on-demand worker + engine install** (+ tests with a fake
   server). `lib/engine.sh`, `qwen3.sh`, `qwen3_install.sh`, `worker.sh`; bash suites
   `tests/test_engine_*.sh`.
2. ✅ **Language ID + per-sentence segmentation + neural-TTS text normalisation** (+ pytest).
   `lib/py/`, `lib/pyenv.sh`, `tests/py`.
3. ✅ **Native voice evaluation + CPU-only engine benchmark.** Five clone packs shipped
   (`share/voices/`); Supertonic 3 / Pocket TTS measured as CPU-only candidates (not integrated).
4. **Polish**
   - ✅ **4b — GUI and documentation:** GUI pages Engine / Voices / Language / Shortcuts with async
     install + cancel, headless tests (`tests/gui`), README rewrite with troubleshooting,
     Agent.md, CHANGELOG.md, THIRD_PARTY.md.
   - ✅ Packaging: PKGBUILD 2.0.0 (deps, voices, license metadata), Makefile installs voices, helper
     modules and the optional docs.
   - ✅ **4c — first-sentence streaming:** `lib/stream.sh` + `lib/py/htts_stream.py`; real engine
     `speak` → first sound 2.6 s → 1.0 s warm (details, measurements and gotchas in README
     *Latency* and Agent.md).
   - 🔄 **4a — coding standards for every script, bash/pytest suites, CI (shellcheck, tests, QA
     gate):** tracked by the engine/bash polish work (`tools/qa`, `make qa`).

## 4. Open items

- ✅ Streaming left a longer pause after the short first sentence: fixed by a long streamed first
  chunk (≤ 200 characters, sentences merged) and a ramp for the chunks after it; pause 2.2 s →
  0.6 s on the reference box (README *Latency*, Agent.md "Chunk ramp and streaming"). Still open:
  a short chunk followed by a much longer one leaves a gap (limits are caps, not targets), and
  paragraph breaks are not boundaries when merging into chunk 0 — listen to it.
- ✅ `engine variant base|customvoice` (`command_engine_variant`, `lib/engine.sh`), the
  "loading voice…" notification (`engine_start_loading_notice`) and the selection size cap
  (`SELECTION_MAX_CHARS`, `speak_limit_text`) are implemented in the CLI (wave 2).
- zh/ja/ko: decide between dropping and limiting them (CJK sentence splitting); the documented
  support is de/en/fr/es/it, the rest experimental.
- Listen to and approve the five shipped voices (judged by automatic transcription only).
- CPU-only engine for machines without a usable GPU (Supertonic 3: RTF ≈0.23, 650 MB,
  OpenRAIL-M model licence).
- Shipped voices vs. user voices share a directory with `PREFIX=$HOME/.local` installs.
- Click-through test of the GUI on a real Wayland session; clean-chroot `makepkg` + `namcap`.
