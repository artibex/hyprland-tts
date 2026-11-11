#!/usr/bin/env bash
# lib/qwen3.sh — Qwen3-TTS backend: install-tree paths, voice-independent request
# building and the render call against the warm tts-server (see lib/worker.sh).
# Sourced by bin/hyprland-tts; defines functions and pinned constants only.

# Pinned qwentts.cpp commit; it also names the install directory so upgrades coexist.
QWEN_CPP_COMMIT="de2ad833e9bd5c06082231d1da637789f7562816"
# Languages the Qwen3-TTS model can speak, as two-letter codes.
QWEN3_LANGUAGES="de,en,fr,es,it,pt,ru,zh,ja,ko"
# The nine built-in CustomVoice speakers (zh/en/ja/ko natives; all speak every language).
QWEN3_PRESETS="ryan aiden vivian serena uncle_fu dylan eric ono_anna sohee"

# qwen3_languages — print the languages the Qwen3 engine can speak.
# Args:    none
# Returns: 0 always; stdout: comma-separated language codes
# Globals: reads QWEN3_LANGUAGES
qwen3_languages() {
  # One constant keeps the engine layer and the CLI validation in sync.
  printf '%s' "$QWEN3_LANGUAGES"
}

# English title-case language names as the server expects them, keyed by language code.
declare -gA QWEN3_LANGUAGE_NAMES=(
  [de]="German" [en]="English" [fr]="French" [es]="Spanish" [it]="Italian"
  [pt]="Portuguese" [ru]="Russian" [zh]="Chinese" [ja]="Japanese" [ko]="Korean"
)
# GGUF file names of the pinned Hugging Face revision, keyed by model role.
declare -gA QWEN3_MODEL_FILES=(
  [customvoice]="qwen-talker-0.6b-customvoice-Q8_0.gguf"
  [base]="qwen-talker-0.6b-base-Q8_0.gguf"
  # The codec is shared by both talker variants.
  [codec]="qwen-tokenizer-12hz-Q8_0.gguf"
)

# qwen3_language_name — map a two-letter code to the title-case name the server expects.
# Args:    $1 <language code, e.g. de>
# Returns: 0 when known; 1 when unsupported; stdout: e.g. German
# Globals: reads QWEN3_LANGUAGE_NAMES
qwen3_language_name() {
  # An unset key means the model cannot speak that language.
  [ -n "${QWEN3_LANGUAGE_NAMES[${1:-}]:-}" ] || return 1
  printf '%s' "${QWEN3_LANGUAGE_NAMES[$1]}"
}

# qwen3_engine_dir — print the install directory of the pinned engine build.
# Args:    none
# Returns: 0 always; stdout: absolute directory (may not exist yet)
# Globals: reads ENGINES_DIR, QWEN_CPP_COMMIT
qwen3_engine_dir() {
  # The commit in the path lets a future pin bump install side by side.
  printf '%s/qwentts/%s' "$ENGINES_DIR" "$QWEN_CPP_COMMIT"
}

# qwen3_bin_dir — print the directory holding tts-server, qwen-codec and the ggml libraries.
# Args:    none
# Returns: 0 always; stdout: absolute directory
# Globals: reads ENGINES_DIR, QWEN_CPP_COMMIT
qwen3_bin_dir() {
  # Binaries and shared libraries live together so the $ORIGIN rpath finds them.
  printf '%s/bin' "$(qwen3_engine_dir)"
}

# qwen3_model_file — print the GGUF file name of a model role.
# Args:    $1 <role: customvoice|base|codec>
# Returns: 0 when known; 1 for an unknown role; stdout: file name
# Globals: reads QWEN3_MODEL_FILES
qwen3_model_file() {
  # Unknown roles (for example a mistyped variant) must fail instead of building a bad path.
  [ -n "${QWEN3_MODEL_FILES[${1:-}]:-}" ] || return 1
  printf '%s' "${QWEN3_MODEL_FILES[$1]}"
}

# qwen3_model_path — print the installed path of a model role.
# Args:    $1 <role: customvoice|base|codec>
# Returns: 0 when the role is known (file may be absent); 1 otherwise; stdout: path
# Globals: reads ENGINES_DIR, QWEN_CPP_COMMIT
qwen3_model_path() {
  local file_name
  # Resolve the role first so an unknown role fails before any path is built.
  file_name="$(qwen3_model_file "$1")" || return 1
  # Models sit next to bin/ inside the versioned engine directory.
  printf '%s/models/%s' "$(qwen3_engine_dir)" "$file_name"
}

# qwen3_variant_valid — tell whether a name is one of the two talker variants.
# Args:    $1 <variant name>
# Returns: 0 for base or customvoice; 1 otherwise
# Globals: none
qwen3_variant_valid() {
  [ "$1" = "base" ] || [ "$1" = "customvoice" ]
}

# qwen3_installed — tell whether the engine can serve the currently selected variant.
# Args:    none
# Returns: 0 when binaries, codec and the variant's talker exist; 1 otherwise
# Globals: reads QWEN_VARIANT, ENGINES_DIR
qwen3_installed() {
  local bin_dir
  bin_dir="$(qwen3_bin_dir)"
  # Only the two real talkers count; "codec" would name an installed file but cannot talk.
  qwen3_variant_valid "$QWEN_VARIANT" || return 1
  # The server binary is the one hard requirement of every variant.
  [ -x "$bin_dir/tts-server" ] || return 1
  # The codec model is shared by both variants.
  [ -s "$(qwen3_model_path codec)" ] || return 1
  # An unknown variant name must not count as installed.
  [ -s "$(qwen3_model_path "$QWEN_VARIANT" 2>/dev/null)" ]
}

# qwen3_usable — tell whether Qwen3 can actually speak.
# Args:    none
# Returns: 0 when usable; 1 otherwise
# Globals: reads QWEN_VARIANT, ENGINES_DIR
# Notes:   Base without a cloned voice still speaks (built-in voice), so usable == installed.
qwen3_usable() {
  qwen3_installed
}

# qwen3_device — print the compute device the server should use first.
# Args:    none
# Returns: 0 always; stdout: Vulkan0 or CPU (or a user override)
# Globals: reads QWEN_DEVICE; the install's engine.conf
qwen3_device() {
  local DEVICE=""
  # An explicit user override beats whatever the install decided.
  [ -z "${QWEN_DEVICE:-}" ] || { printf '%s' "$QWEN_DEVICE"; return 0; }
  # engine.conf is written by the installer and only assigns DEVICE.
  # shellcheck disable=SC1091
  [ ! -f "$(qwen3_engine_dir)/engine.conf" ] || source "$(qwen3_engine_dir)/engine.conf"
  # The CPU build always works, so it is the safe default when nothing says otherwise.
  printf '%s' "${DEVICE:-CPU}"
}

# qwen3_run_tool — run an engine binary with its own shared libraries first on the path.
# Args:    $1 <binary name inside bin/>; $2.. <arguments>
# Returns: the binary's exit status; stdout/stderr: the binary's output
# Globals: reads ENGINES_DIR, QWEN_CPP_COMMIT, LD_LIBRARY_PATH
qwen3_run_tool() {
  local tool_name="$1" bin_dir
  # The tool name is consumed here so the rest of the arguments pass through untouched.
  bin_dir="$(qwen3_bin_dir)"
  shift
  # LD_LIBRARY_PATH backs up the $ORIGIN rpath in case the tree was moved.
  LD_LIBRARY_PATH="$bin_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$bin_dir/$tool_name" "$@"
}

# qwen3_frames_per_char_tenths — print generation frames per character (x10) for a language.
# Args:    $1 <language code, optional>
# Returns: 0 always; stdout: 15 (alphabetic scripts), 30 (ko) or 40 (zh, ja)
# Globals: none
qwen3_frames_per_char_tenths() {
  # Logographic text carries a whole syllable per character, so each takes far longer to say.
  case "${1:-}" in
    zh|ja) printf '40' ;;
    ko) printf '30' ;;
    # Latin, Cyrillic and Greek scripts need about 1.5 frames per character.
    *) printf '15' ;;
  esac
}

# qwen3_max_frames — compute the generation cap for a text so a runaway cannot loop on.
# Args:    $1 <text to speak>; $2 <language code, optional>
# Returns: 0 always; stdout: max_new_tokens (12.5 frames = 1 s of audio)
# Globals: none
qwen3_max_frames() {
  local text="$1" tenths
  tenths="$(qwen3_frames_per_char_tenths "${2:-}")"
  # 1.5 frames per character (~8 chars/s, slower than speech) for alphabets, more for CJK.
  printf '%s' "$(( ${#text} * tenths / 10 + 40 ))"
}

# qwen3_runaway_seconds — print the audio length above which a render counts as runaway.
# Args:    $1 <max frames of the request>
# Returns: 0 always; stdout: seconds with three decimals (80% of the cap's audio length)
# Globals: none
# Notes:   A runaway never emits end-of-speech, so it always ends at the cap (>= 80% of it).
qwen3_runaway_seconds() {
  local millis=$(( $1 * 64 ))
  # 12.5 frames per second * 1000 ms / 0.8 -> frames * 64 ms.
  printf '%d.%03d' "$(( millis / 1000 ))" "$(( millis % 1000 ))"
}

# qwen3_voice_field — print the JSON member that selects the voice (empty for the built-in one).
# Args:    $1 <voice name>
# Returns: 0 always; stdout: ',"voice":"<name>"' or nothing for the Base talker's own voice
# Globals: reads VOICE_BASE_DEFAULT
qwen3_voice_field() {
  # A request without a voice is how the server asks the Base talker for its built-in voice.
  [ "$1" != "$VOICE_BASE_DEFAULT" ] || return 0
  printf ',"voice":"%s"' "$(json_escape "$1")"
}

# qwen3_seed_field — print the JSON member that fixes the sampling seed, if one applies.
# Args:    $1 <seed override, optional>
# Returns: 0 always; stdout: ',"seed":<n>' or nothing
# Globals: reads QWEN_SEED (optional)
qwen3_seed_field() {
  local seed="${1:-${QWEN_SEED:-}}"
  # Without a numeric seed the server picks a random one, which is the normal case.
  [[ "$seed" =~ ^[0-9]+$ ]] && printf ',"seed":%s' "$seed"
  return 0
}

# qwen3_request_json — build the JSON body of one speech request.
# Args:    $1 <text>; $2 <voice name>; $3 <language name, e.g. German>; $4 <max frames>;
#          $5 <seed override, optional>; $6 <response format wav|pcm, default wav>
# Returns: 0 always; stdout: JSON document
# Globals: reads QWEN_SEED (optional)
qwen3_request_json() {
  local text
  # Escaping keeps quotes and newlines in the text from breaking the document.
  text="$(json_escape "$1")"
  # wav = one-shot file for the append-play pipeline; pcm = the stream of the first chunk.
  printf '{"input":"%s"%s,"language":"%s",' "$text" "$(qwen3_voice_field "$2")" "$3"
  printf '"response_format":"%s","max_new_tokens":%s%s}' "${6:-wav}" "$4" \
    "$(qwen3_seed_field "${5:-}")"
}

# qwen3_request_timeout — print the per-request time limit in seconds, sanitised.
# Args:    none
# Returns: 0 always; stdout: a positive integer (120 when the setting is not a number)
# Globals: reads QWEN_REQUEST_TIMEOUT
qwen3_request_timeout() {
  # curl treats a junk --max-time as an error, which would fail every single chunk.
  if [[ "$QWEN_REQUEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$QWEN_REQUEST_TIMEOUT"
  else
    printf '120'
  fi
}

# qwen3_post_speech — send one prepared request body and store the WAV reply.
# Args:    $1 <port>; $2 <request body file>; $3 <output wav>
# Returns: 0 on a valid WAV; 1 on a server-side error; 2 when the server is unreachable
# Globals: reads QWEN_REQUEST_TIMEOUT
qwen3_post_speech() {
  local port="$1" body_file="$2" out_file="$3" http_code curl_status=0
  # --noproxy: a proxy env var must never intercept loopback traffic.
  http_code="$(curl -sS --noproxy '*' --max-time "$(qwen3_request_timeout)" -o "$out_file.part" \
    -w '%{http_code}' -H 'Content-Type: application/json' --data-binary "@$body_file" \
    "http://127.0.0.1:$port/v1/audio/speech" 2>/dev/null)" || curl_status=$?
  # A failed transfer leaves no usable file; drop whatever curl wrote.
  [ "$curl_status" -eq 0 ] || rm -f "$out_file.part"
  # Connection refused / empty reply / reset all mean the worker is gone (retryable).
  case "$curl_status" in
    0) ;;
    7|52|56) return 2 ;;
    # Any other curl failure (timeout, HTTP error) only affects this chunk.
    *) return 1 ;;
  esac
  # Anything but HTTP 200 with a RIFF header is an error body, not audio.
  if [ "$http_code" = 200 ] && [ "$(head -c4 "$out_file.part")" = "RIFF" ]; then
    mv -f "$out_file.part" "$out_file"
    return 0
  fi
  # Keep the server's error text for diagnosis, then drop the bogus file.
  worker_log "speech request failed: HTTP $http_code $(head -c200 "$out_file.part" 2>/dev/null)"
  rm -f "$out_file.part"
  return 1
}

# qwen3_synthesize — one request/response round trip into a WAV file.
# Args:    $1 <port>; $2 <text>; $3 <voice>; $4 <language name>; $5 <max frames>;
#          $6 <output wav>; $7 <seed override, may be empty>
# Returns: 0 on a valid WAV; 1 on a server-side failure; 2 when the worker is unreachable
# Globals: reads QWEN_REQUEST_TIMEOUT; touches the worker's last-use file
qwen3_synthesize() {
  local port="$1" body_file status=0
  # The body goes through a private file so long text never hits the argument-length limit.
  body_file="$(temp_file)" || return 1
  qwen3_request_json "$2" "$3" "$4" "$5" "$7" > "$body_file"
  # The in-flight mark stops the idle timer from cutting a long synthesis short.
  worker_request_begin
  worker_touch
  qwen3_post_speech "$port" "$body_file" "$6" || status=$?
  # The idle timer restarts when the answer arrived.
  worker_touch
  worker_request_end
  # The temp file may contain the user's text, so it never outlives the request.
  rm -f "$body_file"
  return "$status"
}

# qwen3_retry_seed — pick a fresh random seed for a second attempt.
# Args:    none
# Returns: 0 always; stdout: a number below 2^31
# Globals: reads RANDOM, QWEN_SEED
qwen3_retry_seed() {
  local seed
  seed=$(( (RANDOM << 15 | RANDOM) + 1 ))
  # A user-fixed seed would repeat the same bad output, so the retry must differ from it.
  [ "$seed" != "${QWEN_SEED:-}" ] || seed=$(( seed + 1 ))
  printf '%s' "$seed"
}

# qwen3_render_checked — synthesize a chunk and retry once with a new seed on bad audio.
# Args:    $1 <port>; $2 <text>; $3 <voice>; $4 <language code>; $5 <language name>; $6 <wav>
# Returns: 0 on usable audio; 1 on failure or two bad renders; 2 when the worker is unreachable
# Globals: writes the log of the worker
qwen3_render_checked() {
  local port="$1" text="$2" voice="$3" lang="$4" language_name="$5" out_file="$6"
  local max_frames attempt seed="" gate_status
  # The cap grows with the text and the script of the language.
  max_frames="$(qwen3_max_frames "$text" "$lang")"
  for attempt in 1 2; do
    qwen3_synthesize "$port" "$text" "$voice" "$language_name" "$max_frames" "$out_file" "$seed" ||
      # The status of the failed request tells the caller whether a restart can help.
      return $?
    gate_status=0
    wav_finish "$out_file" "$(qwen3_runaway_seconds "$max_frames")" || gate_status=$?
    # Status 0 means the audio passed the gate (and is normalised in place).
    [ "$gate_status" -ne 0 ] || return 0
    # Only a new seed can change a deterministic bad sample, so the second try uses one.
    worker_log "render attempt $attempt rejected by the audio check (status $gate_status)"
    seed="$(qwen3_retry_seed)"
  done
  rm -f "$out_file"
  # Two bad renders: the caller falls back to Piper for this chunk.
  return 1
}

# qwen3_resolve_target — find the port, voice and language name a chunk would be sent with.
# Args:    $1 <language code>
# Returns: 0 on success; 1 for an unsupported language or missing voice; 2 when the worker is
#          unreachable; stdout: "<port>TAB<voice>TAB<language name>"
# Globals: reads WORKER_DIR (and the voice settings via voice_for_lang)
qwen3_resolve_target() {
  local port voice language_name
  # A port file alone proves nothing (a killed worker leaves it, and the port may be reused):
  # the worker and its tts-server must both be alive before the user's text is sent anywhere.
  worker_pid_alive && worker_server_alive || return 2
  port="$(worker_port)" || return 2
  # Unsupported language or no usable voice: nothing the worker could fix.
  language_name="$(qwen3_language_name "$1")" || return 1
  voice="$(voice_for_lang "$1")" || { worker_log "no voice for '$1'"; return 1; }
  printf '%s\t%s\t%s' "$port" "$voice" "$language_name"
}

# qwen3_render — synthesize one chunk through the warm server into a WAV file.
# Args:    $1 <language code>; $2 <text>; $3 <output wav path>
# Returns: 0 on success; 1 on a server-side failure; 2 when the worker is unreachable
# Globals: reads WORKER_DIR (and the voice settings via voice_for_lang)
qwen3_render() {
  local lang="$1" text="$2" out_file="$3" target port voice language_name
  # The same lookup serves the streamed first chunk (see stream.sh).
  target="$(qwen3_resolve_target "$lang")" || return $?
  IFS=$'\t' read -r port voice language_name <<< "$target"
  qwen3_render_checked "$port" "$text" "$voice" "$lang" "$language_name" "$out_file"
}
