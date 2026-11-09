# hyprland-tts 2.0 — Neural engine, real language ID, full polish

Status: in progress on `beta`. Research data (measured on the reference box: Ryzen 6000
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

1. Engine layer + Qwen3 backend + on-demand worker + engine install (+ tests with a fake server).
2. Language ID + per-sentence segmentation + neural-TTS text normalisation (+ pytest).
3. Native voice evaluation (Qwen3 Base cloning per language) + CPU-only engine benchmark.
4. Polish: coding standards for every script, test suite, CI (shellcheck, tests, QA gate),
   GUI (engine/voice per language), README + Agent.md, packaging (PKGBUILD deps, install).
