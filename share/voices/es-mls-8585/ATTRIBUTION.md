# Voice pack: es-mls-8585

Reference clip for zero-shot cloning with Qwen3-TTS Base via qwentts.cpp
(`qwen-tts --ref-spk ref.spk --ref-rvq ref.rvq --ref-text ref.txt`). `ref.spk` / `ref.rvq` here
are encoded with the **0.6B Base** talker; `1.7b/` holds the 1.7B Base encodings (the speaker
embedding width differs per talker size, so the files are NOT interchangeable).
The raw `ref.wav` + `ref.txt` work with any Base talker (`--ref-wav/--ref-text`).

Reference transcript: `Y después de mirarla con los ojos llenos de lágrimas, observó que estaba engalanada, cosa que le extrañó muchísimo, pues no era la fiesta del patrón ni estaba siquiera cerca.`

- **Speaker:** Multilingual LibriSpeech speaker id 8585 (male, native Spanish LibriVox volunteer), book id 7405 "Novelas Cortas de Asensi" (Julia de Asensi, 1889 - public-domain text).
- **Corpus:** Multilingual LibriSpeech (MLS), Spanish test partition.
- **Clip id:** `8585_7405_000036` (FLAC from HF `facebook/multilingual_librispeech`, data/mls_spanish/test/audio/8585_7405_000.tar.gz).
- **Licence (primary source):** CC BY 4.0 - https://huggingface.co/datasets/facebook/multilingual_librispeech/blob/main/data/mls_spanish/LICENSE ("Multilingual LibriSpeech (MLS) corpus is licensed under the Creative Commons Attribution 4.0 International License", https://creativecommons.org/licenses/by/4.0/). The recording is a LibriVox audiobook; LibriVox recordings are public domain (https://librivox.org/pages/public-domain/).
- **Attribution:** Pratap, V., Xu, Q., Sriram, A., Synnaeve, G., Collobert, R. (2020). MLS: A Large-Scale Multilingual Dataset for Speech Research. Interspeech 2020 (CC BY 4.0). Audio originates from LibriVox volunteers.
- **Note:** reader's name not verified (MLS speaker ids are anonymous); transcript = MLS prompt text, punctuation/case restored from Whisper (identical words).
