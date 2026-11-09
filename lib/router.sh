#!/usr/bin/env bash
# lib/router.sh — language detection, per-sentence chunking and voice-model resolution.
#
# prepare_chunks: raw selected text on stdin -> "<lang><TAB><sentence>" lines. The primary
# path is the Python helper (fastText + normalisation, lib/py/htts_text.py); when Python,
# the venv or the model is missing it falls back to the old regex/bash path (valid output
# either way). Voice resolution order: detected language -> explicit fallback voice
# (see 'model fallback') -> last-used model -> English -> any.
#
# Needs from other modules: common.sh (log, MODELS_DIR, LAST_MODEL_FILE, STATE_DIR),
# text.sh (normalize_text, chunk_text) and pyenv.sh (pyenv_python, langid_model_path).

# Languages the helper can always classify, even without an installed voice.
DEFAULT_LANGS='de,en,fr,es,it'
# Longest first chunk (characters) before it is cut at a clause boundary.
FIRST_CHUNK_LIMIT=90
# Smallest sensible first-chunk piece when cutting at a clause boundary.
FIRST_CHUNK_MINIMUM=25
# Per-language keyword/accent patterns of the regex fallback detector.
REGEX_DE='[ÄäÖöÜüß]|(^|[^[:alpha:]])'
# Common German function words.
REGEX_DE+='(der|die|das|ist|und|nicht|ich|mit|von|dem|den|ein|eine|auch|aber|sind|wird)'
# Right word boundary of the German pattern.
REGEX_DE+='([^[:alpha:]]|$)'
# French accents and function words (single line is short enough).
REGEX_FR='[ÉéÈèÇçÀàÙùÂâÊêÎîÔôÛûËëÏï]|(^|[^[:alpha:]])'
# Common French function words.
REGEX_FR+='(le|la|les|est|une|des|que|dans|pour|avec|vous|nous|cette|être)([^[:alpha:]]|$)'
# Spanish accents/punctuation and function words.
REGEX_ES='[Ññ¿¡áíóúÁÍÓÚ]|(^|[^[:alpha:]])'
# Common Spanish function words.
REGEX_ES+='(el|los|las|una|unos|unas|que|con|para|por|pero|esto|esta|donde)([^[:alpha:]]|$)'
# English function words (no accents to key on).
REGEX_EN='(^|[^[:alpha:]])'
# Common English function words.
REGEX_EN+='(the|and|is|are|you|to|of|in|that|it|for|with|this|have|not|was)([^[:alpha:]]|$)'

# first_model_in — print the alphabetically first Piper model in a directory.
# Args:    $1 directory
# Returns: 0 and the path on stdout (empty when none); 1 when the directory is missing
# Globals: none
first_model_in() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  # Sorted so the pick is deterministic across machines.
  find "$dir" -maxdepth 1 -type f -name '*.onnx' 2>/dev/null | LC_ALL=C sort | head -n1
}

# configured_voice_for — print the user-configured voice file for a language.
# Args:    $1 language code
# Returns: 0 and the path on stdout when VOICE_<lang> names an existing file; 1 otherwise
# Globals: reads VOICE_<lang>
configured_voice_for() {
  local var="VOICE_${1}" val
  val="${!var:-}"
  # Only an existing file counts as a configured voice.
  [ -n "$val" ] && [ -f "$val" ] && printf '%s' "$val"
}

# valid_lang_code — check that a string is a plain ISO 639 language code.
# Args:    $1 candidate
# Returns: 0 for two or three lowercase letters; 1 otherwise
# Globals: none
valid_lang_code() {
  [[ "${1:-}" =~ ^[a-z]{2,3}$ ]]
}

# valid_lang_csv — check a comma-separated list of language codes.
# Args:    $1 candidate list such as "de,en"
# Returns: 0 when every entry is a valid code; 1 otherwise (also when empty)
# Globals: none
valid_lang_csv() {
  [[ "${1:-}" =~ ^[a-z]{2,3}(,[a-z]{2,3})*$ ]]
}

# lang_in_csv — test whether a language is a member of a comma-separated list.
# Args:    $1 language code | $2 comma-separated list
# Returns: 0 when listed; 1 otherwise (also for an empty code)
# Globals: none
lang_in_csv() {
  [ -n "$1" ] && [[ ",$2," == *",$1,"* ]]
}

# model_for_lang — print the Piper model for a language (configured voice, then first model).
# Args:    $1 language code
# Returns: 0 and the path on stdout; 1 when that language has no voice
# Globals: reads MODELS_DIR, VOICE_<lang>
model_for_lang() {
  local lang="$1" model
  # The code becomes part of a variable name and a path, so it must be plain letters.
  valid_lang_code "$lang" || return 1
  # A voice the user chose explicitly beats the first model on disk.
  model="$(configured_voice_for "$lang")" || model=""
  [ -n "$model" ] || model="$(first_model_in "$MODELS_DIR/$lang")" || model=""
  # A language without any model cannot be served here.
  [ -n "$model" ] || return 1
  printf '%s' "$model"
}

# any_installed_model — print the alphabetically first Piper model of any language.
# Args:    none
# Returns: 0 and the path on stdout; 1 when no model is installed
# Globals: reads MODELS_DIR
any_installed_model() {
  local model
  model="$(find "$MODELS_DIR" -type f -name '*.onnx' 2> /dev/null | LC_ALL=C sort | head -n1)"
  # An empty find result means nothing is installed.
  [ -n "$model" ] && printf '%s' "$model"
}

# installed_langs — print the languages that have a Piper voice, comma-separated.
# Args:    none
# Returns: 0 always; stdout: for example "de,en" (empty when no voice is installed)
# Globals: reads MODELS_DIR, VOICE_<lang>
installed_langs() {
  local dir name
  # Language directories that contain at least one model.
  for dir in "$MODELS_DIR"/*/; do
    name="$(basename "$dir")"
    # Keep valid codes whose directory holds a model, one per line.
    valid_lang_code "$name" && [ -n "$(first_model_in "$dir")" ] && printf '%s\n' "$name"
  done 2> /dev/null | sort -u | paste -sd, -
}

# supported_langs_csv — languages the detector may answer: the defaults plus installed voices.
# Args:    none
# Returns: 0 always; stdout: for example "de,en,fr,es,it,nl"
# Globals: reads DEFAULT_LANGS
supported_langs_csv() {
  # Defaults first (stable order), then extra installed languages, deduplicated.
  { tr ',' '\n' <<< "$DEFAULT_LANGS"; installed_langs | tr ',' '\n'; } \
    | awk 'NF && !seen[$0]++' | paste -sd, -
}

# detect_lang_regex — guess the language of a text from accents and function words.
# Args:    $1 text
# Returns: 0 always; stdout: de, fr, es, en, or empty when undecided
# Globals: reads REGEX_DE, REGEX_FR, REGEX_ES, REGEX_EN
detect_lang_regex() {
  local text="$1" LC_ALL=C.UTF-8
  # The UTF-8 locale makes the accent classes match characters, not bytes ("naïve" is not German).
  # First matching pattern wins (the historic order: German before the rest).
  if [[ "$text" =~ $REGEX_DE ]]; then echo de; return; fi
  if [[ "$text" =~ $REGEX_FR ]]; then echo fr; return; fi
  if [[ "$text" =~ $REGEX_ES ]]; then echo es; return; fi
  # English has no accents, so it is checked last.
  if [[ "$text" =~ $REGEX_EN ]]; then echo en; return; fi
  echo ""
}

# detect_lang — dominant language of a text: fastText when available, else regex.
# Args:    $1 text
# Returns: 0 always; stdout: ISO 639-1 code, or empty when undecided
# Globals: reads DEFAULT_LANGS; runs the Python helper when present
detect_lang() {
  local text="$1" python model lang
  # The helper needs the interpreter and the model; otherwise use the regex path.
  if python="$(pyenv_python)" && model="$(langid_model_path)"; then
    lang="$(printf '%s' "$text" | run_text_helper "$python" "$model" \
      detect --allowed "$(supported_langs_csv)" --default '')" || lang=""
    [ -z "$lang" ] || { printf '%s' "$lang"; return 0; }
  fi
  # No usable helper or model: the regex detector answers.
  detect_lang_regex "$text"
}

# piper_model_for_lang — Piper model for a language with the full fallback chain.
# Args:    $1 language code (may be empty for "undetected")
# Returns: 0 and the path on stdout; 1 when no model exists at all
# Globals: reads FALLBACK_VOICE, LAST_MODEL_FILE, MODELS_DIR
# Notes:   Chain: language voice -> FALLBACK_VOICE -> last-used -> English -> any model.
piper_model_for_lang() {
  local lang="${1:-}" model
  # The voice of the language itself comes first.
  if [ -n "$lang" ]; then
    model="$(model_for_lang "$lang")" && [ -n "$model" ] && { printf '%s' "$model"; return 0; }
  fi
  # A deliberately set fallback voice beats the automatic last-used heuristic.
  if [ -n "${FALLBACK_VOICE:-}" ] && [ -f "$FALLBACK_VOICE" ]; then
    printf '%s' "$FALLBACK_VOICE"
    return 0
  fi
  # Reuse the model that was actually used last.
  if [ -f "$LAST_MODEL_FILE" ]; then
    model="$(cat "$LAST_MODEL_FILE" 2> /dev/null || true)"
    [ -n "$model" ] && [ -f "$model" ] && { printf '%s' "$model"; return 0; }
  fi
  # English, then any installed model.
  model="$(model_for_lang en)" && [ -n "$model" ] && { printf '%s' "$model"; return 0; }
  any_installed_model
}

# resolve_model — pick the Piper model for a whole text (detect, then fall back).
# Args:    $1 text
# Returns: 0 and the path on stdout; 1 when no model exists
# Globals: see detect_lang and piper_model_for_lang
resolve_model() {
  local lang
  lang="$(detect_lang "$1")"
  # The voice follows the same chain as for an explicit language.
  piper_model_for_lang "$lang"
}

# remember_model — store the model that was used so the next undetected text reuses it.
# Args:    $1 model path
# Returns: 0 always
# Globals: reads STATE_DIR, LAST_MODEL_FILE
remember_model() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$LAST_MODEL_FILE" 2> /dev/null || true
}

# run_text_helper — run lib/py/htts_text.py with the model path and a writable bytecode cache.
# Args:    $1 python interpreter | $2 model path (may be empty) | $3.. helper arguments
# Returns: the helper's exit code (3 = language model unavailable); stdout: helper output
# Globals: reads XDG_CACHE_HOME, HOME
run_text_helper() {
  local python="$1" model="$2"
  shift 2
  # The cache prefix keeps .pyc files out of read-only install directories.
  PYTHONPYCACHEPREFIX="${XDG_CACHE_HOME:-$HOME/.cache}/hyprland-tts/pycache" \
    HTTS_LID_MODEL="$model" "$python" "$(py_helpers_dir)/htts_text.py" "$@"
}

# prepare_chunks_python — segment text with the Python helper.
# Args:    $1 allowed languages (csv) | $2 default language | $3 raw text
# Returns: 0 with chunk lines on stdout; 10 when Python, the venv or the model is missing;
#          otherwise the helper's own exit code (3 = no language model)
# Globals: none
prepare_chunks_python() {
  local allowed="$1" default_lang="$2" text="$3" python model=""
  python="$(pyenv_python)" || return 10
  # Several languages need the classifier model; a single language needs none.
  if [[ "$allowed" == *,* ]]; then
    model="$(langid_model_path)" || return 10
  fi
  printf '%s' "$text" | run_text_helper "$python" "$model" \
    segment --allowed "$allowed" --default "$default_lang"
}

# first_chunk_cut — find where to cut an over-long first chunk (clause, else word boundary).
# Args:    $1 chunk text
# Returns: 0 always; stdout: number of characters in the first piece (the whole length if short)
# Globals: reads FIRST_CHUNK_LIMIT, FIRST_CHUNK_MINIMUM
first_chunk_cut() {
  local text="$1" window head
  # Short chunks stay whole.
  [ "${#text}" -gt "$FIRST_CHUNK_LIMIT" ] || { printf '%s' "${#text}"; return 0; }
  window="${text:0:FIRST_CHUNK_LIMIT}"
  # Prefer the last clause boundary (comma, semicolon, colon + space) in the window.
  head="${window%[,;:] *}"
  if [ "$head" != "$window" ] && [ "${#head}" -ge "$FIRST_CHUNK_MINIMUM" ]; then
    # The cut includes the punctuation mark so the clause stays intact.
    printf '%s' "$((${#head} + 1))"
    return 0
  fi
  # Otherwise cut at the last space; a window without one is cut hard.
  head="${window% *}"
  [ "$head" != "$window" ] && [ "${#head}" -gt 0 ] || head="$window"
  printf '%s' "${#head}"
}

# emit_fallback_chunk — print one chunk line; the very first chunk is split when too long.
# Args:    $1 language | $2 chunk text | $3 1 when this is the first chunk, else 0
# Returns: 0 always; stdout: one or two "lang<TAB>text" lines
# Globals: none
emit_fallback_chunk() {
  local lang="$1" chunk="$2" is_first="$3" cut rest
  cut="$(first_chunk_cut "$chunk")"
  # Only the first chunk is shortened, to start playback quickly.
  if [ "$is_first" -eq 1 ] && [ "$cut" -lt "${#chunk}" ]; then
    rest="${chunk:cut}"
    rest="${rest# }"
    # The head goes out first, the remainder follows as its own chunk.
    printf '%s\t%s\n' "$lang" "${chunk:0:cut}"
    [ -z "$rest" ] || printf '%s\t%s\n' "$lang" "$rest"
    return 0
  fi
  # Later chunks and short first chunks go out unchanged.
  printf '%s\t%s\n' "$lang" "$chunk"
}

# fallback_lang_for_chunk — language of one chunk in the regex path, restricted to allowed.
# Args:    $1 chunk | $2 allowed csv | $3 default language | $4 previous chunk's language
# Returns: 0 always; stdout: a language from the allowed list
# Globals: none
fallback_lang_for_chunk() {
  local chunk="$1" allowed="$2" default_lang="$3" previous="$4" lang
  # A single allowed language needs no detection.
  [[ "$allowed" == *,* ]] || { printf '%s' "$allowed"; return 0; }
  lang="$(detect_lang_regex "$chunk")"
  # Undecided or unavailable chunks inherit the neighbour's language.
  if lang_in_csv "$lang" "$allowed"; then
    printf '%s' "$lang"
  elif [ -n "$previous" ]; then
    # The neighbour's language is the best guess for undecided text.
    printf '%s' "$previous"
  else
    printf '%s' "$default_lang"
  fi
}

# prepare_chunks_fallback — the old bash path: normalize_text | chunk_text + regex language.
# Args:    $1 allowed languages (csv) | $2 default language; text on stdin
# Returns: 0 always; stdout: "lang<TAB>chunk" lines (no empty or punctuation-only chunks)
# Globals: none
prepare_chunks_fallback() {
  local allowed="$1" default_lang="$2" chunk lang previous="" is_first=1
  while IFS= read -r chunk; do
    # Tabs would break the output format; chunks without a letter or digit are noise.
    chunk="${chunk//$'\t'/ }"
    [[ "$chunk" =~ [[:alnum:]] ]] || continue
    lang="$(fallback_lang_for_chunk "$chunk" "$allowed" "$default_lang" "$previous")"
    # The first chunk may be split here for a fast start of playback.
    emit_fallback_chunk "$lang" "$chunk" "$is_first"
    previous="$lang"
    is_first=0
  done < <(normalize_text | chunk_text)
}

# helper_log_file — print the path of the text helper's error log (and keep it small).
# Args:    none
# Returns: 0 always; stdout: the log path
# Globals: reads STATE_DIR
helper_log_file() {
  local path="$STATE_DIR/helper.log"
  mkdir -p "$STATE_DIR" 2> /dev/null || true
  # A log that grew past 100 KB is cut to its newest quarter.
  if [ "$(stat -c %s "$path" 2> /dev/null || echo 0)" -gt 102400 ]; then
    tail -c 25600 "$path" > "$path.new" && mv -f "$path.new" "$path"
  fi
  printf '%s' "$path"
}

# prepare_chunks_try_python — run the Python path, keep its errors in a log, tell the user once.
# Args:    $1 allowed languages | $2 default language | $3 raw text
# Returns: 0 with chunk lines on stdout; 1 when the fallback must run
# Globals: reads STATE_DIR, RUN_DIR
prepare_chunks_try_python() {
  local status=0 log_path
  log_path="$(helper_log_file)"
  # Helper errors go to the log instead of being hidden.
  prepare_chunks_python "$1" "$2" "$3" 2>> "$log_path" || status=$?
  [ "$status" -ne 0 ] || return 0
  # 10 means "no Python or model here" and 3 "no language model" (both normal); the rest crashed.
  if [ "$status" -ne 10 ] && [ "$status" -ne 3 ]; then
    engine_notify_once helper "hyprland-tts: text helper failed" \
      "Using the simple text pipeline. Details: $log_path"
  fi
  return 1
}

# prepare_chunks — raw text on stdin -> "lang<TAB>sentence" lines, one chunk per line.
# Args:    $1 allowed languages, comma-separated (e.g. de,en) | $2 default language (optional)
# Returns: 0 on success (also for empty input); 1 on an invalid language list
# Globals: reads DEFAULT_LANGS via helpers; never loads a model for a single language
# Notes:   First chunk <= ~90 chars; never merges across languages; falls back to regex.
prepare_chunks() {
  local allowed="${1:-}" default_lang="${2:-}" text chunks
  valid_lang_csv "$allowed" || { log "prepare_chunks: invalid language list '$allowed'"; return 1; }
  # A default outside the list would break the contract, so use the first allowed language.
  lang_in_csv "$default_lang" "$allowed" || default_lang="${allowed%%,*}"
  text="$(cat)"
  # Python path first; any failure (exit code 3 = no model, or a crash) uses the fallback.
  if chunks="$(prepare_chunks_try_python "$allowed" "$default_lang" "$text")"; then
    [ -z "$chunks" ] || printf '%s\n' "$chunks"
    return 0
  fi
  # The Python path failed or is missing, so the regex/bash path runs.
  prepare_chunks_fallback "$allowed" "$default_lang" <<< "$text"
}
