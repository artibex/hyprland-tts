# Voice pack: en-lj

Reference clip for zero-shot cloning with Qwen3-TTS Base via qwentts.cpp
(`qwen-tts --ref-spk ref.spk --ref-rvq ref.rvq --ref-text ref.txt`). `ref.spk` / `ref.rvq` here
are encoded with the **0.6B Base** talker; `1.7b/` holds the 1.7B Base encodings (the speaker
embedding width differs per talker size, so the files are NOT interchangeable).
The raw `ref.wav` + `ref.txt` work with any Base talker (`--ref-wav/--ref-text`).

Reference transcript: `When he reached a gasoline service station one block away, he turned north and walked toward a parking area in the rear of the station.`

- **Speaker:** LJ Speech reader (female, US English; LibriVox volunteer "Linda Johnson").
- **Corpus:** The LJ Speech Dataset v1.1 (Keith Ito) - 13,100 clips from 7 non-fiction books.
- **Clip id:** `LJ037-0131` (original 22.05 kHz WAV via HF mirror `flexthink/ljspeech`, upsampled to 24 kHz by the project).
- **Licence (primary source):** Public Domain - https://keithito.com/LJ-Speech-Dataset/ (page: "License: Public Domain"; "This is a public domain speech dataset").
- **Attribution (courtesy):** Keith Ito, "The LJ Speech Dataset", https://keithito.com/LJ-Speech-Dataset/ ; recordings from LibriVox (public domain).
