# Voice pack: de-thorsten

Reference clip for zero-shot cloning with Qwen3-TTS Base via qwentts.cpp
(`qwen-tts --ref-spk ref.spk --ref-rvq ref.rvq --ref-text ref.txt`). `ref.spk` / `ref.rvq` here
are encoded with the **0.6B Base** talker; `1.7b/` holds the 1.7B Base encodings (the speaker
embedding width differs per talker size, so the files are NOT interchangeable).
The raw `ref.wav` + `ref.txt` work with any Base talker (`--ref-wav/--ref-text`).

Reference transcript: `Für meine Freunde und Familie war die Nachricht, dass ich meine Stimme spende nicht überraschend, da sie meine Leidenschaft für Projekte dieser Art kennen.`

- **Speaker:** Thorsten Müller (Thorsten-Voice), male, native German; Rode Podcaster mic ("good" quality subset).
- **Corpus:** Thorsten-Voice Dataset 2022.10, neutral subset. Recorded by Thorsten Müller, audio optimised by Dominik Kreutz.
- **Clip id:** `dd01c488-10f3-a683-00cf-4d215f4d9b19---fb808c4d76a4ab87c1e8be920d11fd64` (from the 24 kHz HF mirror `Thorsten-Voice/TV-24kHz-Neutral`, shard train-00007).
- **Licence (primary source):** CC0 1.0 - https://zenodo.org/records/7265581 (DOI 10.5281/zenodo.7265581; record metadata `license: cc-zero`; description: "licenced under CC0 to provide it for anybody without any financial or licence struggle").
- **Note:** the HF mirror card tags `cc-by-4.0` (stricter than the primary CC0); attribution is given here so both are satisfied.
- **Attribution (requested, not required):** Thorsten Müller (Thorsten-Voice, https://www.thorsten-voice.de), Dominik Kreutz. "Thorsten-Voice Dataset 2022.10", Zenodo, https://doi.org/10.5281/zenodo.7265581
