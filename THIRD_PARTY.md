# Third-party software, models and voices

hyprland-tts itself is Apache-2.0 (see `LICENSE`). It builds on, downloads or ships the following.
"Shipped" means the files are in this repository/package; "downloaded" means they are fetched on
the user's explicit request (`engine install`, `deps install`, `model install`) and are **not**
redistributed by this project.

## Engine and models

| Component | How used | Licence | Source |
|---|---|---|---|
| **qwentts.cpp** (incl. its vendored **ggml**) | Downloaded as a pinned commit and built locally by `engine install qwen3` | MIT | https://github.com/ServeurpersoCom/qwentts.cpp |
| **Qwen3-TTS** weights (talker 0.6B Base / CustomVoice and the 12 Hz speech tokenizer), GGUF conversion by Serveurperso | Downloaded (sha256-pinned) by `engine install qwen3` | Apache-2.0 | https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base, https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF |
| **Vulkan-Headers**, **SPIRV-Headers** (Khronos) | Fetched at pinned commits, only when the system has none | Apache-2.0 / MIT-style (see the repositories) | https://github.com/KhronosGroup |
| **Piper** (`piper-tts`) | Run as an external program (package dependency); not bundled | MIT (`piper-tts-bin` packages rhasspy/piper 2023.11.14, verified via `pacman -Qi`). Note: the successor OHF-Voice/piper1-gpl is GPL-3.0 | https://github.com/rhasspy/piper |
| **Piper voices** | Downloaded by `model install`; not bundled | Per voice, see each voice's model card | https://huggingface.co/rhasspy/piper-voices |

## Language detection and normalisation

| Component | How used | Licence | Source |
|---|---|---|---|
| **fastText `lid.176.ftz`** language-identification model | **Downloaded** by `deps install` (sha256-verified), **not bundled** | **CC BY-SA 3.0** | https://fasttext.cc/docs/en/language-identification.html — Joulin, Grave, Bojanowski, Mikolov: *Bag of Tricks for Efficient Text Classification*; Joulin et al.: *FastText.zip: Compressing text classification models* |
| **fasttext-predict** (prediction-only fastText wheel) | Installed into the private venv from PyPI (hash-pinned) | MIT | https://pypi.org/project/fasttext-predict/ |
| **num2words** | Installed into the private venv from PyPI (hash-pinned, `--no-deps`) | LGPL-2.1 | https://pypi.org/project/num2words/ |
| **docopt** | Dependency of num2words; installed hash-pinned by `deps install` (listed in `lib/py/requirements.txt`) | MIT | https://pypi.org/project/docopt/ |

The model licence (CC BY-SA 3.0) applies to the model file only; it is never merged into this
project's code.

## System components (not bundled)

GTK 4 and libadwaita (LGPL-2.1+), PyGObject (LGPL-2.1+), mpv (GPL-2.0+/LGPL), socat (GPL-2.0),
wl-clipboard (GPL-3.0), curl (curl licence), cmake/gcc/make (build tools, optional).

## Shipped voice packs (`share/voices/<name>/`)

Each pack contains a short reference clip used as the voice-cloning prompt for the Qwen3-TTS Base
model, its transcript, pre-encoded latents and an `ATTRIBUTION.md` with the full provenance. Licences
cover the recordings; personality rights of the speakers are not covered by copyright licences, and
this is not legal advice. Where a licence requires attribution, it is reproduced here and in the
pack; it must travel with any redistribution of the voice files.

### `de-thorsten` — German, CC0 1.0

Thorsten Müller (Thorsten-Voice), male, native German; clip from the Thorsten-Voice Dataset 2022.10,
neutral subset, recorded by Thorsten Müller, audio optimised by Dominik Kreutz. Licence: CC0 1.0
(https://zenodo.org/records/7265581). A Hugging Face mirror card tags it CC-BY-4.0 (stricter), so
attribution is given although CC0 does not require it:

> Thorsten Müller (Thorsten-Voice, https://www.thorsten-voice.de), Dominik Kreutz.
> "Thorsten-Voice Dataset 2022.10", Zenodo, https://doi.org/10.5281/zenodo.7265581

### `en-lj` — English (US), public domain

A reader of the LJ Speech Dataset v1.1 (Keith Ito; LibriVox volunteer), clip `LJ037-0131`. Licence:
public domain (https://keithito.com/LJ-Speech-Dataset/). Courtesy attribution:

> Keith Ito, "The LJ Speech Dataset", https://keithito.com/LJ-Speech-Dataset/ ; recordings from
> LibriVox (public domain).

### `fr-siwis` — French, CC BY 4.0

SIWIS French Speech Synthesis Database, professional voice talent, clip `siwis_neut_book_s03_0140`,
silence-trimmed and encoded as a cloning reference. Licence: CC BY 4.0 (https://doi.org/10.7488/ds/1705).
**The Creative Commons licence does not affect the moral rights of the voice talent; any use
derogatory to the voice talent is prohibited.**

> Yamagishi, J., Honnet, P.-E., Garner, P., Lazaridis, A. (2017). The SIWIS French Speech Synthesis
> Database, 2016 [dataset]. University of Edinburgh, CSTR. https://doi.org/10.7488/ds/1705
> (CC BY 4.0).

### `es-mls-8585` — Spanish, CC BY 4.0

Multilingual LibriSpeech speaker 8585 (anonymous LibriVox volunteer, male), book 7405 "Novelas Cortas
de Asensi", clip `8585_7405_000036`. Licence: CC BY 4.0
(https://huggingface.co/datasets/facebook/multilingual_librispeech); the underlying LibriVox
recordings are public domain.

> Pratap, V., Xu, Q., Sriram, A., Synnaeve, G., Collobert, R. (2020). MLS: A Large-Scale Multilingual
> Dataset for Speech Research. Interspeech 2020 (CC BY 4.0). Audio originates from LibriVox
> volunteers.

### `it-mls-8582` — Italian, CC BY 4.0

Multilingual LibriSpeech speaker 8582 (anonymous LibriVox volunteer, male), book 7877 "Novelle per un
Anno, vol. 11: La Giara" (Luigi Pirandello), clip `8582_7877_000057`. Licence: CC BY 4.0 (same MLS
licence file).

> Pratap, V., Xu, Q., Sriram, A., Synnaeve, G., Collobert, R. (2020). MLS: A Large-Scale Multilingual
> Dataset for Speech Research. Interspeech 2020 (CC BY 4.0). Audio originates from LibriVox
> volunteers.

### Voices you add yourself

`hyprland-tts voice add` stores the licence file you supply (or a note that you confirmed you hold
the rights) in the voice's `LICENSE` file. Responsibility for the recording lies with you.
