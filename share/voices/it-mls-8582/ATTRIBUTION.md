# Voice pack: it-mls-8582

Reference clip for zero-shot cloning with Qwen3-TTS Base via qwentts.cpp
(`qwen-tts --ref-spk ref.spk --ref-rvq ref.rvq --ref-text ref.txt`). `ref.spk` / `ref.rvq` here
are encoded with the **0.6B Base** talker; `1.7b/` holds the 1.7B Base encodings (the speaker
embedding width differs per talker size, so the files are NOT interchangeable).
The raw `ref.wav` + `ref.txt` work with any Base talker (`--ref-wav/--ref-text`).

Reference transcript: `Credo che si sia fatta apposta un po' di radura sul cranio, perché una leggera calvizie, in certi casi e per certe professioni, è veramente indispensabile.`

- **Speaker:** Multilingual LibriSpeech speaker id 8582 (male, native Italian LibriVox volunteer), book id 7877 "Novelle per un Anno, vol. 11: La Giara" (Luigi Pirandello, 1918 - public-domain text).
- **Corpus:** Multilingual LibriSpeech (MLS), Italian test partition.
- **Clip id:** `8582_7877_000057` (FLAC from HF `facebook/multilingual_librispeech`, data/mls_italian/test/audio/8582_7877_000.tar.gz).
- **Licence (primary source):** CC BY 4.0 - https://huggingface.co/datasets/facebook/multilingual_librispeech/blob/main/data/mls_italian/LICENSE (same text as the other MLS languages; https://creativecommons.org/licenses/by/4.0/). The recording is a LibriVox audiobook; LibriVox recordings are public domain (https://librivox.org/pages/public-domain/).
- **Attribution:** Pratap, V., Xu, Q., Sriram, A., Synnaeve, G., Collobert, R. (2020). MLS: A Large-Scale Multilingual Dataset for Speech Research. Interspeech 2020 (CC BY 4.0). Audio originates from LibriVox volunteers.
- **Note:** reader's name not verified (the book has several LibriVox readers); transcript = MLS prompt text, punctuation/case restored from Whisper (identical words).
