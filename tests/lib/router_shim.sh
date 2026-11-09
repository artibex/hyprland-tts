#!/usr/bin/env bash
# tests/lib/router_shim.sh — stand-in for the 2.0 router contract (prepare_chunks and
# piper_model_for_lang), appended to a scratch copy of router.sh only when the real
# router does not define them yet. Detection is the old regex router: de/fr/es/en.

# prepare_chunks — split stdin into "<lang><TAB><sentence>" lines, as the real router does.
# Args:    $1 <allowed languages, comma separated>; $2 <default language>
# Returns: 0 always; stdout: one chunk per line
# Globals: none
prepare_chunks() {
  local allowed="$1" default_lang="$2" line lang
  # Old normaliser and chunker give sentence-sized lines; the language comes per line.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lang="$(detect_lang "$line")"
    # A language the engine cannot speak (or none) becomes the default language.
    [[ ",$allowed," == *",$lang,"* ]] || lang="$default_lang"
    printf '%s\t%s\n' "$lang" "$line"
  done < <(normalize_text | chunk_text)
}

# piper_model_for_lang — voice file for a language with the old fallback chain.
# Args:    $1 <language code>
# Returns: 0 when a model exists; 1 otherwise; stdout: model path
# Globals: reads MODELS_DIR
piper_model_for_lang() {
  local model
  # Language voice first, then English, then whatever exists.
  model="$(model_for_lang "$1")" && { printf '%s' "$model"; return 0; }
  model="$(model_for_lang en)" && { printf '%s' "$model"; return 0; }
  model="$(find "$MODELS_DIR" -type f -name '*.onnx' 2>/dev/null | LC_ALL=C sort | head -n1)"
  # An empty result means no model exists at all.
  [ -n "$model" ] && printf '%s' "$model"
}
