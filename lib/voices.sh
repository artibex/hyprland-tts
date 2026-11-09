#!/usr/bin/env bash
# lib/voices.sh — voice management for the Qwen3 engine: per-language voice choice,
# cloned-voice storage ($XDG_DATA_HOME/hyprland-tts/voices/<name>/) and the `voice` CLI.
# A cloned voice directory holds ref.wav, ref.txt, ref.spk, ref.rvq and LICENSE or ATTRIBUTION.md.

# Reserved voice name: a Base-model request without any voice (the talker's built-in voice).
VOICE_BASE_DEFAULT="base-default"

# voice_system_roots — print the read-only voice directories shipped with the package.
# Args:    none
# Returns: 0 always; stdout: one existing directory per line
# Globals: reads HYPRLAND_TTS_SYSTEM_VOICES, LIBDIR
voice_system_roots() {
  local candidate
  # Override first (tests, custom installs), then installed and git-checkout layouts.
  for candidate in "${HYPRLAND_TTS_SYSTEM_VOICES:-}" \
    "${LIBDIR:-/nonexistent}/../../share/hyprland-tts/shipped-voices" \
    "${LIBDIR:-/nonexistent}/../share/voices"; do
    # Skip empty and missing candidates so callers only see real directories.
    [ -n "$candidate" ] && [ -d "$candidate" ] && printf '%s\n' "$candidate"
  done
  return 0
}

# voice_dir_for — find the directory of a cloned voice, user copies before shipped ones.
# Args:    $1 <voice name>
# Returns: 0 when found; 1 when no complete voice of that name exists; stdout: directory
# Globals: reads USER_VOICES_DIR
voice_dir_for() {
  local root
  local -a system_roots
  # An array keeps directory names with blanks intact.
  mapfile -t system_roots < <(voice_system_roots)
  # The user's own voice shadows a shipped voice of the same name.
  for root in "$USER_VOICES_DIR" "${system_roots[@]}"; do
    # Only a directory with both latents is a usable voice.
    if [ -s "$root/$1/ref.spk" ] && [ -s "$root/$1/ref.rvq" ]; then
      printf '%s' "$root/$1"
      return 0
    fi
  done
  # No voice directory matched in any root.
  return 1
}

# voice_cloned_names — list usable cloned voices and where they come from.
# Args:    none
# Returns: 0 always; stdout: lines "<name><TAB><user|shipped>", sorted by name
# Globals: reads USER_VOICES_DIR
voice_cloned_names() {
  local root source_label dir name
  local -a system_roots
  # An array keeps directory names with blanks intact.
  mapfile -t system_roots < <(voice_system_roots)
  # Visit the user root first so a user voice wins the de-duplication below.
  for root in "$USER_VOICES_DIR" "${system_roots[@]}"; do
    source_label="shipped"
    [ "$root" = "$USER_VOICES_DIR" ] && source_label="user"
    # Each subdirectory is a candidate voice named after the directory.
    for dir in "$root"/*/; do
      name="$(basename "$dir")"
      # Skip the unexpanded glob and incomplete voices.
      is_safe_name "$name" && [ -s "$dir/ref.spk" ] && [ -s "$dir/ref.rvq" ] &&
        printf '%s\t%s\n' "$name" "$source_label"
    done
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -s -u
  return 0
}

# voice_kind — classify a voice name.
# Args:    $1 <voice name>
# Returns: 0 always; stdout: preset | cloned | builtin | unknown
# Globals: reads QWEN3_PRESETS
voice_kind() {
  local preset
  # Presets are fixed by the CustomVoice model.
  for preset in $QWEN3_PRESETS; do
    [ "$preset" = "$1" ] && { printf 'preset'; return 0; }
  done
  # The Base talker's own voice needs no directory.
  [ "$1" = "$VOICE_BASE_DEFAULT" ] && { printf 'builtin'; return 0; }
  # Anything else must exist as a cloned voice directory.
  if voice_dir_for "$1" >/dev/null; then printf 'cloned'; else printf 'unknown'; fi
}

# voice_default_cloned — pick a cloned voice for a language when none is configured.
# Args:    $1 <language code>
# Returns: 0 when a voice exists; 1 when no clone fits the language; stdout: name
# Globals: reads USER_VOICES_DIR
# Notes:   Order: "<lang>-*" clone, then a clone named "default"; never an unrelated language.
voice_default_cloned() {
  local names match
  names="$(voice_cloned_names | cut -f1)"
  # A voice named like the language ("de-anna") is the intended native voice.
  match="$(printf '%s\n' "$names" | grep -m1 -E "^$1(-|$)" || true)"
  # Next best is a voice called "default", the user's universal choice.
  [ -n "$match" ] || match="$(printf '%s\n' "$names" | grep -m1 -x 'default' || true)"
  # No fitting clone: the caller uses the Base talker's built-in voice instead.
  [ -n "$match" ] || return 1
  printf '%s' "$match"
}

# voice_fits_variant — tell whether the loaded talker can speak a voice.
# Args:    $1 <voice name>
# Returns: 0 for presets on customvoice and clones or the built-in voice on base; 1 otherwise
# Globals: reads QWEN_VARIANT
voice_fits_variant() {
  local kind
  kind="$(voice_kind "$1")"
  # Presets live in the CustomVoice model; clones and the built-in voice need the Base model.
  if [ "$QWEN_VARIANT" = "customvoice" ]; then
    [ "$kind" = "preset" ]
  else
    [ "$kind" = "cloned" ] || [ "$kind" = "builtin" ]
  fi
}

# voice_for_lang — resolve the voice to use for a language.
# Args:    $1 <language code>
# Returns: 0 when a voice is known; 1 for a malformed language; stdout: voice name
# Globals: reads QWEN_VARIANT and QWEN_VOICE_<lang>
# Notes:   Base without a fitting clone answers VOICE_BASE_DEFAULT (request without a voice).
voice_for_lang() {
  local configured_var="QWEN_VOICE_$1" configured
  # Variable names cannot contain dashes, so only plain 2-3 letter codes are looked up.
  [[ "$1" =~ ^[a-z]{2,3}$ ]] || return 1
  configured="${!configured_var:-}"
  # An explicit choice wins, but only when this variant can speak it (else every chunk would fail).
  if is_safe_name "$configured" && voice_fits_variant "$configured"; then
    printf '%s' "$configured"
    return 0
  fi
  # Preset speakers speak every language, so ryan is the sensible universal default.
  [ "$QWEN_VARIANT" = "customvoice" ] && { printf 'ryan'; return 0; }
  # Native clone first; languages without one (pt, ru, zh, ja, ko) use the Base voice itself.
  voice_default_cloned "$1" || printf '%s' "$VOICE_BASE_DEFAULT"
}

# voice_register_one — upload one cloned voice's latents to the running server.
# Args:    $1 <port>; $2 <voice name>; $3 <voice directory>
# Returns: 0 when the server accepted it; 1 otherwise
# Globals: none
voice_register_one() {
  local port="$1" name="$2" dir="$3" body_file ref_text="" status=0
  # ref.txt enables the server's in-context-learning clone mode.
  [ -f "$dir/ref.txt" ] && ref_text="$(tr '\n' ' ' < "$dir/ref.txt")"
  body_file="$(temp_file)" || return 1
  # Latents are binary, so they travel base64-encoded inside the JSON body.
  printf '{"name":"%s","ref_text":"%s","spk_b64":"%s","rvq_b64":"%s"}' \
    "$name" "$(json_escape "$ref_text")" "$(base64 -w0 < "$dir/ref.spk")" \
    "$(base64 -w0 < "$dir/ref.rvq")" > "$body_file"
  curl -fsS --noproxy '*' --max-time 30 -o /dev/null -H 'Content-Type: application/json' \
    --data-binary "@$body_file" "http://127.0.0.1:$port/v1/audio/voices" 2>/dev/null || status=1
  # Always drop the body: it holds the user's reference transcript.
  rm -f "$body_file"
  return "$status"
}

# voice_register_all — register every cloned voice with the server (base variant only).
# Args:    $1 <port>
# Returns: 0 always (failures are logged, never fatal)
# Globals: reads QWEN_VARIANT
voice_register_all() {
  local name dir
  # CustomVoice servers reject registrations, so there is nothing to do.
  [ "$QWEN_VARIANT" = "base" ] || return 0
  while IFS=$'\t' read -r name _; do
    # An empty listing yields one empty line; skip it.
    [ -n "$name" ] || continue
    dir="$(voice_dir_for "$name")" || continue
    # One broken voice must not stop the others from being registered.
    voice_register_one "$1" "$name" "$dir" || worker_log "could not register voice $name"
  done < <(voice_cloned_names)
  return 0
}

# voice_encode_reference — turn a reference WAV into .rvq/.spk latents with qwen-codec.
# Args:    $1 <directory containing ref.wav>
# Returns: 0 when both latents exist afterwards; 1 otherwise
# Globals: reads QWEN_CODEC_DEVICE (default CPU)
voice_encode_reference() {
  # CPU encode of a short clip takes seconds and never competes with the GPU worker.
  qwen3_run_tool qwen-codec --model "$(qwen3_model_path codec)" -i "$1/ref.wav" \
    --talker "$(qwen3_model_path base)" --device "${QWEN_CODEC_DEVICE:-CPU}" >/dev/null || return 1
  # The tool names its outputs after the input; both must exist and be non-empty.
  [ -s "$1/ref.rvq" ] && [ -s "$1/ref.spk" ]
}

# voice_require_encoder — die with a hint unless the base model and codec tool are installed.
# Args:    none
# Returns: 0 when ready; exits 1 via die otherwise
# Globals: reads ENGINES_DIR
voice_require_encoder() {
  # Encoding needs the Base talker even when CustomVoice is the active variant.
  if [ ! -x "$(qwen3_bin_dir)/qwen-codec" ] || [ ! -s "$(qwen3_model_path base)" ]; then
    die "voice cloning needs the Base model: hyprland-tts engine install qwen3 --variant base"
  fi
  [ -s "$(qwen3_model_path codec)" ] || die "codec model missing: reinstall the qwen3 engine"
}

# command_voice_add — implement `voice add <name> <wav> <transcript-file> [--license FILE]`.
# Args:    $1 <name>; $2 <reference wav>; $3 <transcript file>; $4.. optional --license FILE
# Returns: 0 on success; exits 1 via die on any problem
# Globals: reads USER_VOICES_DIR
command_voice_add() {
  local name wav transcript license="" tmp_dir
  name="$(require_safe_name "voice name" "${1:-}")"
  # The built-in Base voice is addressed by that name, so it cannot be a clone's.
  [ "$name" != "$VOICE_BASE_DEFAULT" ] || die "'$name' is reserved for the built-in Base voice"
  # The wav and transcript paths are plain positional arguments.
  wav="${2:-}"; transcript="${3:-}"
  # Optional licence file documents where the reference clip came from.
  [ "${4:-}" != "--license" ] || license="${5:-}"
  [ -f "$wav" ] ||
    die "usage: hyprland-tts voice add <name> <wav> <transcript-file> [--license FILE]"
  # An empty transcript would silently disable the in-context clone mode.
  [ -s "$transcript" ] || die "transcript file missing or empty: $transcript"
  [ ! -e "$USER_VOICES_DIR/$name" ] || die "voice '$name' exists; remove it first"
  # Validate everything that can fail cheaply before a scratch directory holds the user's WAV.
  [ -z "$license" ] || [ -f "$license" ] || die "licence file not found: $license"
  voice_require_encoder
  # Build in a scratch directory so a failed encode never leaves a half voice behind.
  mkdir -p "$USER_VOICES_DIR"
  tmp_dir="$(mktemp -d "$USER_VOICES_DIR/.new-XXXXXX")"
  # Any exit (die, signal) removes the scratch directory; success clears the trap below.
  trap 'rm -rf -- "$tmp_dir"' EXIT
  cp -- "$wav" "$tmp_dir/ref.wav"
  # The transcript sits next to the audio so ref_text can be re-registered later.
  cp -- "$transcript" "$tmp_dir/ref.txt"
  voice_write_license "$tmp_dir" "$license"
  voice_encode_reference "$tmp_dir" ||
    # A failed encode must leave no half-created voice behind.
    { rm -rf "$tmp_dir"; die "encoding failed (is the WAV readable?)"; }
  # The rename is atomic, so readers see either no voice or a complete one.
  mv -T -- "$tmp_dir" "$USER_VOICES_DIR/$name"
  trap - EXIT
  voice_register_if_running "$name"
  # Confirm the new voice to the user.
  log "Voice added: $name"
}

# voice_write_license — store the licence text next to a new voice.
# Args:    $1 <voice directory>; $2 <licence file or empty>
# Returns: 0 on success; exits 1 via die when the licence file is unreadable
# Globals: none
voice_write_license() {
  # A supplied file is copied verbatim so attribution survives.
  if [ -n "$2" ]; then
    [ -f "$2" ] || die "licence file not found: $2"
    cp -- "$2" "$1/LICENSE"
    # The supplied licence is kept; the placeholder below must not replace it.
    return 0
  fi
  # Without one, record that nothing was claimed instead of implying a licence.
  printf 'User-supplied reference recording; no licence information was recorded.\n' > "$1/LICENSE"
}

# voice_register_if_running — hand a new voice to the live server so no restart is needed.
# Args:    $1 <voice name>
# Returns: 0 always (best effort)
# Globals: reads QWEN_VARIANT
voice_register_if_running() {
  local port dir
  # Only the Base server has a registry, and only a running one can be updated.
  [ "$QWEN_VARIANT" = "base" ] && port="$(worker_port)" && worker_ready || return 0
  dir="$(voice_dir_for "$1")" || return 0
  voice_register_one "$port" "$1" "$dir" || log "note: voice registers at the next worker start"
  # Registration is best effort: a missing server is not an error.
  return 0
}

# command_voice_remove — implement `voice remove <name>` for user-added voices.
# Args:    $1 <name>
# Returns: 0 on success; exits 1 via die when the voice is missing or shipped
# Globals: reads USER_VOICES_DIR, CONFIG_FILE
command_voice_remove() {
  local name var
  name="$(require_safe_name "voice name" "${1:-}")"
  # Shipped voices live in a read-only package directory and cannot be removed here.
  [ -d "$USER_VOICES_DIR/$name" ] ||
    die "no user voice named '$name' (shipped voices are read-only)"
  rm -rf -- "${USER_VOICES_DIR:?}/$name"
  # Drop language assignments that would now point at a missing voice.
  [ -f "$CONFIG_FILE" ] || { log "Voice removed: $name"; return 0; }
  while IFS= read -r var; do
    unset_config_var "$var"
  done < <(grep -E "^QWEN_VOICE_[a-z]+=${name}$" "$CONFIG_FILE" | cut -d= -f1)
  # Confirm the removal to the user.
  log "Voice removed: $name"
}

# command_voice_set — implement `voice set <lang> <voice>` and `voice set <lang> --clear`.
# Args:    $1 <language code>; $2 <voice name or --clear>
# Returns: 0 on success; exits 1 via die on invalid language or unknown voice
# Globals: reads QWEN_VARIANT; writes QWEN_VOICE_<lang> in the config file
command_voice_set() {
  local lang="${1:-}" voice="${2:-}" kind
  # Only languages the model speaks may be assigned.
  [[ ",$(qwen3_languages)," == *",$lang,"* ]] ||
    die "usage: hyprland-tts voice set <lang> <voice|--clear>"
  if [ "$voice" = "--clear" ]; then
    # Forget the assignment, then confirm below.
    unset_config_var "QWEN_VOICE_$lang"
    log "Voice for '$lang' reset to the default"
    return 0
  fi
  # From here on the name is validated, so it is safe in paths and config.
  voice="$(require_safe_name "voice name" "$voice")"
  kind="$(voice_kind "$voice")"
  [ "$kind" != "unknown" ] || die "unknown voice '$voice' (see: hyprland-tts voice list)"
  # A preset on the Base model (or a clone on CustomVoice) is stored but cannot be used yet.
  if [ "$kind" = "preset" ] && [ "$QWEN_VARIANT" = "base" ]; then
    log "note: presets need the customvoice variant"
  fi
  if [ "$kind" != "preset" ] && [ "$QWEN_VARIANT" = "customvoice" ]; then
    # Same warning in the opposite direction: clones need the Base talker.
    log "note: clones need the base variant"
  fi
  set_config_var "QWEN_VOICE_$lang" "$voice"
  log "Voice for '$lang' set to $voice"
}

# command_voice_list — implement `voice list [--porcelain]`.
# Args:    $1 <optional --porcelain>
# Returns: 0 always
# Globals: reads QWEN_VARIANT, QWEN3_PRESETS
command_voice_list() {
  local porcelain=0 lang preset name source_label
  [ "${1:-}" = "--porcelain" ] && porcelain=1
  # Plain output is for people; porcelain output is tab-separated for the GUI.
  [ "$porcelain" -eq 1 ] || printf 'variant: %s\n\nlanguage voices:\n' "$QWEN_VARIANT"
  for lang in ${QWEN3_LANGUAGES//,/ }; do
    # Languages without a usable voice are shown as "-" rather than hidden.
    name="$(voice_for_lang "$lang" || printf -- '-')"
    if [ "$porcelain" -eq 1 ]; then printf 'assign\t%s\t%s\n' "$lang" "$name"
    else printf '  %-4s %s\n' "$lang" "$name"; fi
  done
  # Section headings are for humans only; porcelain output stays machine-readable.
  [ "$porcelain" -eq 1 ] || printf '\npresets (customvoice):\n'
  for preset in $QWEN3_PRESETS; do
    if [ "$porcelain" -eq 1 ]; then
      # Porcelain lines are tab-separated: kind, then the name.
      printf 'preset\t%s\n' "$preset"
    else
      printf '  %s\n' "$preset"
    fi
  done
  [ "$porcelain" -eq 1 ] || printf '\ncloned (base):\n'
  # One tab-separated line per cloned voice, already de-duplicated.
  while IFS=$'\t' read -r name source_label; do
    [ -n "$name" ] || continue
    # Same two output styles as above, one line per voice.
    if [ "$porcelain" -eq 1 ]; then
      printf 'cloned\t%s\t%s\n' "$name" "$source_label"
    else
      printf '  %-20s [%s]\n' "$name" "$source_label"
    fi
  done < <(voice_cloned_names)
  # Listing never fails, even when nothing is installed.
  return 0
}

# voice_license_file — find the licence or attribution file of a voice directory.
# Args:    $1 <voice directory>
# Returns: 0 when one exists; 1 otherwise; stdout: its path (LICENSE preferred)
# Globals: none
voice_license_file() {
  local candidate
  # User voices carry LICENSE; shipped voice packs carry ATTRIBUTION.md.
  for candidate in LICENSE ATTRIBUTION.md; do
    [ -s "$1/$candidate" ] && { printf '%s/%s' "$1" "$candidate"; return 0; }
  done
  return 1
}

# command_voice_info — implement `voice info <name>`: key=value facts about one cloned voice.
# Args:    $1 <voice name>
# Returns: 0 when found; exits 1 via die otherwise; stdout: name=, source=, dir=, license=
# Globals: reads USER_VOICES_DIR
command_voice_info() {
  local name dir source_label="shipped"
  name="$(require_safe_name "voice name" "${1:-}")"
  # Only complete voices (both latents) can be described.
  dir="$(voice_dir_for "$name")" ||
    die "no cloned voice named '$name' (see: hyprland-tts voice list)"
  # A voice below the user's data directory is user-owned, everything else ships with the package.
  [ "$(dirname "$dir")" != "$USER_VOICES_DIR" ] || source_label="user"
  printf 'name=%s\nsource=%s\ndir=%s\nlicense=%s\n' "$name" "$source_label" "$dir" \
    "$(voice_license_file "$dir" || true)"
}

# cmd_voice — dispatch the `voice` subcommands.
# Args:    $1 <list|add|remove|set|info>; $2.. <subcommand arguments>
# Returns: 0 on success; exits 1 via die on an unknown subcommand
# Globals: reads the config file via load_config
cmd_voice() {
  local sub="${1:-list}"
  load_config
  # Drop the subcommand name so only its own arguments remain in "$@".
  shift || true
  # Each arm only forwards; the work lives in command_voice_<name>.
  case "$sub" in
    list)   command_voice_list "$@" ;;
    add)    command_voice_add "$@" ;;
    # Removal only touches user-owned voices.
    remove) command_voice_remove "$@" ;;
    set)    command_voice_set "$@" ;;
    info)   command_voice_info "$@" ;;
    # Unknown words list the valid ones.
    *) die "unknown voice subcommand: $sub (list|add|remove|set|info)" ;;
  esac
}
