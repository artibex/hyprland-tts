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
# Longest first chunk (characters) when it is not streamed; a longer one means "streamed".
FIRST_CHUNK_LIMIT=90
# Longest chunk by output position; the last value applies to every later chunk. Mirrors
# CHUNK_RAMP and STREAMED_RAMP in lib/py/htts_split.py, see the model (and gap formula) there.
CHUNK_RAMP=(90 70 78 90 105 120 140 160 185 220)
# The same ramp with the long first chunk of a streamed run (it hides chunk 1's render time).
CHUNK_RAMP_STREAMED=(200 70 78 90 105 120 140 160 185 220)
# The ramp in force for this run; prepare_chunks selects it with use_chunk_ramp.
ACTIVE_RAMP=("${CHUNK_RAMP[@]}")
# Smallest sensible clause-boundary piece when cutting an over-long chunk.
FIRST_CHUNK_MINIMUM=25
# A chunk shorter than this is merged into a neighbour (every request costs about a second).
MIN_FRAGMENT=15
# A sentence at most this long may be merged into the chunk before it.
SHORT_SENTENCE=50
# Longest line chunk_text hands over; the ramp (not this safety net) decides the real cuts.
FALLBACK_LINE_MAX=2000
# The chunks of one fallback run (language and text per position); see fallback_place.
FALLBACK_LANGS=()
FALLBACK_TEXTS=()
# What is left of a sentence after the long first chunk took its opening clauses.
FALLBACK_REST=""
# The merged output list and the fragment waiting for its successor; see absorb_one.
ABSORB_LANGS=()
ABSORB_TEXTS=()
# The waiting fragment's own language and text (empty text = nothing waits).
ABSORB_WAIT_LANG=""
ABSORB_WAIT_TEXT=""
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
# Args:    $1 allowed languages (csv) | $2 default language | $3 raw text | $4 stream flag
# Returns: 0 with chunk lines on stdout; 10 when Python, the venv or the model is missing;
#          otherwise the helper's own exit code (3 = no language model)
# Globals: none
prepare_chunks_python() {
  local allowed="$1" default_lang="$2" text="$3" stream_first="${4:-0}" python model=""
  python="$(pyenv_python)" || return 10
  # Several languages need the classifier model; a single language needs none.
  if [[ "$allowed" == *,* ]]; then
    model="$(langid_model_path)" || return 10
  fi
  printf '%s' "$text" | run_text_helper "$python" "$model" \
    segment --allowed "$allowed" --default "$default_lang" --stream-first "$stream_first"
}

# use_chunk_ramp — select the ramp for this run: long first chunk when it will be streamed.
# Args:    $1 stream flag ("1" = chunk 0 will be streamed; anything else = it will not)
# Returns: 0 always
# Globals: writes ACTIVE_RAMP
use_chunk_ramp() {
  # Only an explicit "1" from the player (stream_wanted) selects the long first chunk.
  if [ "$1" = "1" ]; then
    ACTIVE_RAMP=("${CHUNK_RAMP_STREAMED[@]}")
  else
    ACTIVE_RAMP=("${CHUNK_RAMP[@]}")
  fi
}

# long_first_chunk — tell whether the ramp in force starts with the long streamed first chunk.
# Args:    none
# Returns: 0 for the streamed ramp; 1 for the short first chunk
# Globals: reads ACTIVE_RAMP, FIRST_CHUNK_LIMIT
long_first_chunk() {
  [ "${ACTIVE_RAMP[0]}" -gt "$FIRST_CHUNK_LIMIT" ]
}

# ramp_limit — longest chunk allowed at an output position.
# Args:    $1 position (0 = first chunk)
# Returns: 0 always; stdout: the limit in characters
# Globals: reads ACTIVE_RAMP
ramp_limit() {
  local position="$1" last=$((${#ACTIVE_RAMP[@]} - 1))
  # Positions beyond the ramp keep its largest value.
  [ "$position" -le "$last" ] || position="$last"
  printf '%s' "${ACTIVE_RAMP[$position]}"
}

# ramp_clause_cut — position of the last clause boundary (comma, semicolon, colon + space).
# Args:    $1 window (the text that may hold the cut) | $2 smallest acceptable head length
# Returns: 0 always; stdout: head length including the punctuation mark; 0 when none qualifies
# Globals: none
ramp_clause_cut() {
  local head="${1%[,;:] *}"
  # The head must be a real piece, and the window must hold a boundary at all.
  if [ "$head" != "$1" ] && [ "$((${#head} + 1))" -ge "$2" ]; then
    printf '%s' "$((${#head} + 1))"
  else
    printf '0'
  fi
}

# ramp_cut — find where to cut a chunk that is over its limit (clause, else word boundary).
# Args:    $1 chunk text (longer than the limit) | $2 limit
# Returns: 0 always; stdout: number of characters in the head piece
# Globals: reads MIN_FRAGMENT, FIRST_CHUNK_MINIMUM
ramp_cut() {
  local text="$1" reach="$2" window head minimum cut
  # The remainder must not become a fragment, so the cut moves left when it would.
  [ $((${#text} - reach)) -ge "$MIN_FRAGMENT" ] || reach=$((${#text} - MIN_FRAGMENT))
  minimum=$((reach / 3 < FIRST_CHUNK_MINIMUM ? reach / 3 : FIRST_CHUNK_MINIMUM))
  window="${text:0:reach + 1}"
  # Prefer the last clause boundary that leaves a real head (the mark stays in the clause).
  cut="$(ramp_clause_cut "$window" "$minimum")"
  [ "$cut" -eq 0 ] || { printf '%s' "$cut"; return 0; }
  # Otherwise cut at the last space; a window without one is cut hard.
  head="${window% *}"
  [ "$head" != "$window" ] && [ "${#head}" -gt 0 ] || head="${window:0:reach}"
  printf '%s' "${#head}"
}

# fallback_wrap — print a sentence as pieces that each fit the ramp limit of their position.
# Args:    $1 sentence | $2 position the first piece will have in the output
# Returns: 0 always; stdout: one piece per line (no empty pieces)
# Globals: reads ACTIVE_RAMP via ramp_limit
fallback_wrap() {
  local text="$1" position="$2" limit cut
  limit="$(ramp_limit "$position")"
  # Every piece has its own limit, so a long sentence starts small and ends large.
  while [ "${#text}" -gt "$limit" ]; do
    cut="$(ramp_cut "$text" "$limit")"
    printf '%s\n' "${text:0:cut}"
    # The rest loses the space it was cut at.
    text="${text:cut}"
    text="${text#"${text%%[![:space:]]*}"}"
    # The next piece is one step further up the ramp.
    position=$((position + 1))
    limit="$(ramp_limit "$position")"
  done
  [ -z "$text" ] || printf '%s\n' "$text"
}

# fallback_can_join — tell whether a sentence may be appended to the last chunk.
# Args:    $1 language | $2 sentence
# Returns: 0 for a same-language sentence that fits the chunk's ramp limit (any sentence for the
#          long streamed first chunk, only short ones for later chunks); 1 otherwise
# Globals: reads FALLBACK_LANGS, FALLBACK_TEXTS, SHORT_SENTENCE, ACTIVE_RAMP
fallback_can_join() {
  local lang="$1" sentence="$2" last=$((${#FALLBACK_TEXTS[@]} - 1)) joined
  # Nothing to join, or a language change.
  [ "$last" -ge 0 ] && [ "${FALLBACK_LANGS[$last]}" = "$lang" ] || return 1
  # A short first chunk stays alone; the long one takes any sentence; later ones short ones.
  if [ "$last" -eq 0 ]; then
    long_first_chunk || return 1
  else
    [ "${#sentence}" -le "$SHORT_SENTENCE" ] || return 1
  fi
  # The result must still fit the limit of the chunk it extends.
  joined=$((${#FALLBACK_TEXTS[$last]} + 1 + ${#sentence}))
  [ "$joined" -le "$(ramp_limit "$last")" ]
}

# fallback_fill_first — move the opening clauses of a too-long sentence into the long first chunk.
# Args:    $1 language | $2 sentence
# Returns: 0 always; sets FALLBACK_REST to what is left of the sentence (all of it if untouched)
# Globals: reads ACTIVE_RAMP, MIN_FRAGMENT, FIRST_CHUNK_MINIMUM; writes FALLBACK_TEXTS,
#          FALLBACK_REST
fallback_fill_first() {
  local lang="$1" sentence="$2" reach cut=0 rest
  FALLBACK_REST="$sentence"
  # Only a long first chunk of the same language is topped up.
  [ "${#FALLBACK_TEXTS[@]}" -eq 1 ] && [ "${FALLBACK_LANGS[0]}" = "$lang" ] && long_first_chunk ||
    return 0
  # The cut stays inside the free room and leaves a remainder that is no fragment.
  reach=$((ACTIVE_RAMP[0] - ${#FALLBACK_TEXTS[0]} - 1))
  [ "$reach" -le $((${#sentence} - MIN_FRAGMENT)) ] || reach=$((${#sentence} - MIN_FRAGMENT))
  # A window below the minimum piece size has no useful clause boundary.
  if [ "$reach" -ge "$FIRST_CHUNK_MINIMUM" ]; then
    cut="$(ramp_clause_cut "${sentence:0:reach + 1}" "$FIRST_CHUNK_MINIMUM")"
  fi
  [ "$cut" -gt 0 ] || return 0
  # The clauses move up; the rest loses the space it was cut at.
  FALLBACK_TEXTS[0]+=" ${sentence:0:cut}"
  rest="${sentence:cut}"
  FALLBACK_REST="${rest#"${rest%%[![:space:]]*}"}"
}

# fallback_place — add one sentence to the chunk list, merged or wrapped along the ramp.
# Args:    $1 language | $2 sentence
# Returns: 0 always
# Globals: writes FALLBACK_LANGS, FALLBACK_TEXTS, FALLBACK_REST
fallback_place() {
  local lang="$1" sentence="$2" piece last
  # A neighbour that fits joins its predecessor instead of costing a request of its own.
  if fallback_can_join "$lang" "$sentence"; then
    last=$((${#FALLBACK_TEXTS[@]} - 1))
    # The sentence is glued to the end of the last chunk.
    FALLBACK_TEXTS[last]+=" $sentence"
    return 0
  fi
  # Otherwise the long first chunk is topped up and the rest starts new chunks on the ramp.
  fallback_fill_first "$lang" "$sentence"
  while IFS= read -r piece; do
    # Pieces of quotes or punctuation only are noise.
    [[ "$piece" =~ [[:alnum:]] ]] || continue
    FALLBACK_LANGS+=("$lang")
    FALLBACK_TEXTS+=("$piece")
  done < <(fallback_wrap "$FALLBACK_REST" "${#FALLBACK_TEXTS[@]}")
}

# absorb_push — append one chunk to the merged output list.
# Args:    $1 language | $2 text
# Returns: 0 always
# Globals: writes ABSORB_LANGS, ABSORB_TEXTS
absorb_push() {
  ABSORB_LANGS+=("$1")
  ABSORB_TEXTS+=("$2")
}

# absorb_one — place one chunk: merge a fragment back or forward, else keep it.
# Args:    $1 language | $2 text
# Returns: 0 always
# Globals: reads MIN_FRAGMENT; writes ABSORB_LANGS, ABSORB_TEXTS, ABSORB_WAIT_LANG, ABSORB_WAIT_TEXT
absorb_one() {
  local lang="$1" text="$2" last
  # A waiting fragment goes in front of this chunk when the language matches, else it stays alone.
  if [ -n "$ABSORB_WAIT_TEXT" ] && [ "$ABSORB_WAIT_LANG" = "$lang" ]; then
    text="$ABSORB_WAIT_TEXT $text"
  elif [ -n "$ABSORB_WAIT_TEXT" ]; then
    # Another language: the fragment is kept on its own.
    absorb_push "$ABSORB_WAIT_LANG" "$ABSORB_WAIT_TEXT"
  fi
  ABSORB_WAIT_TEXT=""
  last=$((${#ABSORB_TEXTS[@]} - 1))
  # The first chunk is never extended, so only a later fragment is merged away.
  if [ "${#text}" -ge "$MIN_FRAGMENT" ] || [ "$last" -lt 0 ]; then
    absorb_push "$lang" "$text"
  elif [ "$last" -ge 1 ] && [ "${ABSORB_LANGS[$last]}" = "$lang" ]; then
    # Back into the previous chunk of the same language.
    ABSORB_TEXTS[last]+=" $text"
  else
    # Otherwise it waits to be put in front of the next chunk.
    ABSORB_WAIT_LANG="$lang"
    ABSORB_WAIT_TEXT="$text"
  fi
}

# fallback_absorb_fragments — merge chunks that are too short into a same-language neighbour.
# Args:    none
# Returns: 0 always; stdout: "lang<TAB>text" lines
# Globals: reads FALLBACK_LANGS, FALLBACK_TEXTS; resets and writes the ABSORB_* lists
fallback_absorb_fragments() {
  local index
  # A fresh run starts with empty lists and nothing waiting.
  ABSORB_LANGS=()
  ABSORB_TEXTS=()
  # Nothing waits for a successor yet.
  ABSORB_WAIT_LANG=""
  ABSORB_WAIT_TEXT=""
  # Every chunk is placed in turn.
  for index in "${!FALLBACK_TEXTS[@]}"; do
    absorb_one "${FALLBACK_LANGS[$index]}" "${FALLBACK_TEXTS[$index]}"
  done
  # A fragment at the very end without a partner stays as it is.
  [ -z "$ABSORB_WAIT_TEXT" ] || absorb_push "$ABSORB_WAIT_LANG" "$ABSORB_WAIT_TEXT"
  # The contract is one tab-separated line per chunk.
  for index in "${!ABSORB_TEXTS[@]}"; do
    printf '%s\t%s\n' "${ABSORB_LANGS[$index]}" "${ABSORB_TEXTS[$index]}"
  done
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
# Args:    $1 allowed languages (csv) | $2 default language | $3 stream flag ("1" = long first
#          chunk); text on stdin
# Returns: 0 always; stdout: "lang<TAB>chunk" lines (no empty or punctuation-only chunks)
# Globals: writes FALLBACK_LANGS, FALLBACK_TEXTS (reset first), ACTIVE_RAMP
prepare_chunks_fallback() {
  local allowed="$1" default_lang="$2" chunk lang previous=""
  use_chunk_ramp "${3:-0}"
  # A fresh run starts with an empty chunk list.
  FALLBACK_LANGS=()
  FALLBACK_TEXTS=()
  while IFS= read -r chunk; do
    # Tabs would break the output format; chunks without a letter or digit are noise.
    chunk="${chunk//$'\t'/ }"
    [[ "$chunk" =~ [[:alnum:]] ]] || continue
    lang="$(fallback_lang_for_chunk "$chunk" "$allowed" "$default_lang" "$previous")"
    # Sentences are placed one after the other so that each knows its ramp position.
    fallback_place "$lang" "$chunk"
    previous="$lang"
  done < <(normalize_text | CHUNK_MAX="$FALLBACK_LINE_MAX" chunk_text)
  fallback_absorb_fragments
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
# Args:    $1 allowed languages | $2 default language | $3 raw text | $4 stream flag
# Returns: 0 with chunk lines on stdout; 1 when the fallback must run
# Globals: reads STATE_DIR, RUN_DIR
prepare_chunks_try_python() {
  local status=0 log_path
  log_path="$(helper_log_file)"
  # Helper errors go to the log instead of being hidden.
  prepare_chunks_python "$1" "$2" "$3" "${4:-0}" 2>> "$log_path" || status=$?
  [ "$status" -ne 0 ] || return 0
  # 10 means "no Python or model here" and 3 "no language model" (both normal); the rest crashed.
  if [ "$status" -ne 10 ] && [ "$status" -ne 3 ]; then
    engine_notify_once helper "hyprland-tts: text helper failed" \
      "Using the simple text pipeline. Details: $log_path"
  fi
  return 1
}

# prepare_chunks — raw text on stdin -> "lang<TAB>sentence" lines, one chunk per line.
# Args:    $1 allowed languages, comma-separated (e.g. de,en) | $2 default language (optional) |
#          $3 stream flag (optional): "1" when the player will stream chunk 0, else it is short
# Returns: 0 on success (also for empty input); 1 on an invalid language list
# Globals: reads DEFAULT_LANGS via helpers; never loads a model for a single language
# Notes:   First chunk <= 90 chars (<= 200 and merged into when streamed), then a growing ramp
#          (CHUNK_RAMP); never merges across languages; falls back to regex.
prepare_chunks() {
  local allowed="${1:-}" default_lang="${2:-}" stream_first="${3:-0}" text chunks
  valid_lang_csv "$allowed" || { log "prepare_chunks: invalid language list '$allowed'"; return 1; }
  # A default outside the list would break the contract, so use the first allowed language.
  lang_in_csv "$default_lang" "$allowed" || default_lang="${allowed%%,*}"
  text="$(cat)"
  # Python path first; any failure (exit code 3 = no model, or a crash) uses the fallback.
  if chunks="$(prepare_chunks_try_python "$allowed" "$default_lang" "$text" "$stream_first")"; then
    [ -z "$chunks" ] || printf '%s\n' "$chunks"
    return 0
  fi
  # The Python path failed or is missing, so the regex/bash path runs.
  prepare_chunks_fallback "$allowed" "$default_lang" "$stream_first" <<< "$text"
}
