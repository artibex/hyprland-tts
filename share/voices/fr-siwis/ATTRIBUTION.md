# Voice pack: fr-siwis

Reference clip for zero-shot cloning with Qwen3-TTS Base via qwentts.cpp
(`qwen-tts --ref-spk ref.spk --ref-rvq ref.rvq --ref-text ref.txt`). `ref.spk` / `ref.rvq` here
are encoded with the **0.6B Base** talker; `1.7b/` holds the 1.7B Base encodings (the speaker
embedding width differs per talker size, so the files are NOT interchangeable).
The raw `ref.wav` + `ref.txt` work with any Base talker (`--ref-wav/--ref-text`).

Reference transcript: `De là un équilibre parfait entre la poussée intérieure et la poussée extérieure, qui se neutralisent, ce qui vous permet de les supporter sans peine.`

- **Speaker:** SIWIS professional French female voice talent, studio recording.
- **Corpus:** The SIWIS French Speech Synthesis Database (University of Edinburgh / Idiap), neutral book-text sentences.
- **Clip id:** `siwis_neut_book_s03_0140` (24 kHz FLAC from HF mirror `Rcarvalo/siwis-fr-24k`, shard train-00002).
- **Licence (primary source):** CC BY 4.0 - https://doi.org/10.7488/ds/1705 ; dataset README (https://datashare.ed.ac.uk/server/api/core/bitstreams/ca0b398a-635c-48cd-b85a-beb6f8401e0d/content): "released under the Creative Commons License: Attribution 4.0 International ... The Creative Commons licence does not affect the moral rights of the voice talent with respect to the recordings. Any use derogatory to the voice talent is prohibited."
- **Obligations:** attribution (below); no derogatory use of the voice (moral rights stay with the talent).
- **Attribution:** Yamagishi, J., Honnet, P.-E., Garner, P., Lazaridis, A. (2017). The SIWIS French Speech Synthesis Database, 2016 [dataset]. University of Edinburgh, CSTR. https://doi.org/10.7488/ds/1705 (CC BY 4.0). Clip cut, silence-trimmed and encoded as a voice-cloning reference.
