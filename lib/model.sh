#!/usr/bin/env bash
# lib/model.sh — Piper voice catalog + install / list / remove / default / fallback.
# Security (URL scheme, extension, path traversal, atomic download) lives here, so the GUI
# inherits it by shelling out to these subcommands.

# Base URL of the Piper voice repository.
HF="https://huggingface.co/rhasspy/piper-voices/resolve/main"

# catalog_lines — print the voice catalog.
# Args:    none
# Returns: 0 always; stdout: "key|lang|model|base url|quality|label" lines
# Globals: reads HF
catalog_lines() {
  # The unquoted heredoc delimiter lets $HF expand inside the table.
  cat <<CATALOG
en-ryan-high|en|en_US-ryan-high|$HF/en/en_US/ryan/high|high|English (US) — Ryan
en-amy-medium|en|en_US-amy-medium|$HF/en/en_US/amy/medium|medium|English (US) — Amy
en-alba-medium|en|en_GB-alba-medium|$HF/en/en_GB/alba/medium|medium|English (GB) — Alba
de-thorsten-high|de|de_DE-thorsten-high|$HF/de/de_DE/thorsten/high|high|German — Thorsten
fr-siwis-medium|fr|fr_FR-siwis-medium|$HF/fr/fr_FR/siwis/medium|medium|French — Siwis
es-carlfm-x_low|es|es_ES-carlfm-x_low|$HF/es/es_ES/carlfm/x_low|x_low|Spanish — Carlfm
it-riccardo-x_low|it|it_IT-riccardo-x_low|$HF/it/it_IT/riccardo/x_low|x_low|Italian — Riccardo
CATALOG
}

# sanitize_lang — accept only a plain two or three letter language code.
# Args:    $1 <candidate>
# Returns: 0 when valid, stdout: the code; exits 1 via die otherwise
# Globals: none
sanitize_lang() {
  # The code becomes part of a path, so anything but lowercase letters is refused.
  [[ "$1" =~ ^[a-z]{2,3}$ ]] || die "invalid language code: '$1' (expected 2-3 lowercase letters)"
  printf '%s' "$1"
}

# validate_url — accept only well-formed https URLs.
# Args:    $1 <url>
# Returns: 0 when valid; exits 1 via die otherwise
# Globals: none
# Notes:   LC_ALL=C: in a UTF-8 locale the ranges A-Z a-z also match letters like "ä".
validate_url() {
  local LC_ALL=C
  [[ "$1" =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'\(\)\*\+,\;=%-]+$ ]] ||
    # Anything else (http, file, odd characters) is refused outright.
    die "refusing non-https or malformed URL: $1"
}

# fetch_file — download a URL atomically into a destination file.
# Args:    $1 <url>; $2 <destination path>
# Returns: 0 when stored; exits 1 via die when the download fails
# Globals: none
fetch_file() {
  local url="$1" dest="$2" temp_file
  temp_file="$(mktemp "${dest}.XXXXXX")" || die "cannot create temp file"
  # The rename makes the file appear completely or not at all.
  if curl -fL --retry 2 --connect-timeout 20 -o "$temp_file" "$url"; then
    mv -f "$temp_file" "$dest"
  else
    rm -f "$temp_file"
    # The partial file is gone, so a failure leaves no half model.
    die "download failed: $url"
  fi
}

# model_do_install — download one Piper model (onnx + json) into the models directory.
# Args:    $1 <language>; $2 <model name>; $3 <base url>
# Returns: 0 when installed; exits 1 via die on bad input or a failed download
# Globals: reads MODELS_DIR
model_do_install() {
  local lang model base dir onnx json
  lang="$(sanitize_lang "$1")"
  # Language is validated; the model and base come from the catalog or the URL.
  model="$2"
  base="$3"
  # The model name becomes a file name, so no slashes or odd characters.
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid model name: $model"
  validate_url "$base/$model.onnx"
  validate_url "$base/$model.onnx.json"
  # One directory per language keeps the catalog layout.
  dir="$MODELS_DIR/$lang"
  mkdir -p "$dir"
  onnx="$dir/$model.onnx"
  # Piper needs the model and its json description side by side.
  json="$dir/$model.onnx.json"
  log "Downloading $model → $dir"
  fetch_file "$base/$model.onnx" "$onnx"
  # The json description is small and fetched second.
  fetch_file "$base/$model.onnx.json" "$json"
  # An empty model file would crash Piper later, so it is removed right away.
  [ -s "$onnx" ] || { rm -f "$onnx" "$json"; die "downloaded model is empty"; }
  log "Installed: $lang/$model"
}

# model_print_row — print one installed model for `model list`.
# Args:    $1 <onnx file>; $2 <last used file>; $3 <porcelain 0|1>
# Returns: 0 always
# Globals: reads FALLBACK_VOICE, VOICE_<lang>
model_print_row() {
  local file="$1" lang name size default_var is_default is_last is_fallback marks=""
  lang="$(basename "$(dirname "$file")")"
  # Directory and file name carry the language and the model name.
  name="$(basename "$file" .onnx)"
  size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
  default_var="VOICE_${lang}"
  # Three independent marks: the language default, the last-used voice and the fallback voice.
  is_default=0; [ "${!default_var:-}" != "$file" ] || is_default=1
  is_last=0; [ "$file" != "$2" ] || is_last=1
  is_fallback=0
  # Marked only when this very file is the configured fallback.
  [ -z "${FALLBACK_VOICE:-}" ] || [ "$file" != "$FALLBACK_VOICE" ] || is_fallback=1
  if [ "$3" -eq 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lang/$name" "$lang" "$name" "$size" \
      "$is_default" "$is_last" "$is_fallback"
    # Porcelain rows carry flags only; the marks are for the plain listing.
    return 0
  fi
  [ "$is_default" -eq 0 ] || marks="$marks [default]"
  [ "$is_fallback" -eq 0 ] || marks="$marks [fallback]"
  # The last-used voice is what the router reuses for undetected text.
  [ "$is_last" -eq 0 ] || marks="$marks [last used]"
  printf '  %-8s %-28s %6s MB%s\n' "$lang" "$name" \
    "$(awk -v b="$size" 'BEGIN{printf "%.1f", b/1048576}')" "$marks"
}

# command_model_list — implement `model list [--porcelain]`.
# Args:    $1 <optional --porcelain>
# Returns: 0 always
# Globals: reads MODELS_DIR, LAST_MODEL_FILE
command_model_list() {
  local porcelain=0 last="" found=0 file
  [ "${1:-}" != "--porcelain" ] || porcelain=1
  # The last-used model is marked in the listing.
  [ ! -f "$LAST_MODEL_FILE" ] || last="$(cat "$LAST_MODEL_FILE" 2>/dev/null || true)"
  # Without a models directory there is nothing to list (porcelain stays silent).
  if [ ! -d "$MODELS_DIR" ]; then
    [ "$porcelain" -eq 1 ] || echo "No models installed."
    return 0
  fi
  # Sorted file names make the listing deterministic.
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    found=1
    # One row per installed model.
    model_print_row "$file" "$last" "$porcelain"
  done < <(find "$MODELS_DIR" -type f -name '*.onnx' 2>/dev/null | LC_ALL=C sort)
  [ "$found" -eq 1 ] || [ "$porcelain" -eq 1 ] || echo "No models installed."
}

# command_model_catalog — implement `model catalog [--porcelain]`.
# Args:    $1 <optional --porcelain>
# Returns: 0 always
# Globals: reads MODELS_DIR
command_model_catalog() {
  local porcelain=0 key lang model quality label installed mark
  [ "${1:-}" != "--porcelain" ] || porcelain=1
  # The headline is for people only.
  [ "$porcelain" -eq 1 ] || echo "Available voices (key — description):"
  while IFS='|' read -r key lang model _ quality label; do
    installed=0
    # The catalog shows what is already on disk.
    [ ! -f "$MODELS_DIR/$lang/$model.onnx" ] || installed=1
    if [ "$porcelain" -eq 1 ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$lang" "$model" "$quality" "$installed" "$label"
    else
      # Plain listing: a tick marks installed voices.
      mark=""
      [ "$installed" -eq 0 ] || mark="  ✓ installed"
      printf '  %-20s %s%s\n' "$key" "$label" "$mark"
    fi
  done < <(catalog_lines)
}

# command_model_install — implement `model install <catalog key>`.
# Args:    $1 <catalog key>
# Returns: 0 on success; exits 1 via die for a missing or unknown key
# Globals: none
command_model_install() {
  local key="${1:-}" line lang model base
  [ -n "$key" ] || die "usage: hyprland-tts model install <key>  (see 'model catalog')"
  # No early awk exit: it could SIGPIPE the producer under pipefail.
  line="$(catalog_lines | awk -F'|' -v k="$key" '$1==k && !seen{print; seen=1}')"
  [ -n "$line" ] || die "unknown catalog key: $key  (see 'model catalog')"
  IFS='|' read -r _ lang model base _ _ <<< "$line"
  # Download, validate and store the chosen model.
  model_do_install "$lang" "$model" "$base"
}

# command_model_install_url — implement `model install-url <lang> <onnx url> [json url]`.
# Args:    $1 <language>; $2 <onnx URL>; $3 <json URL, optional>
# Returns: 0 on success; exits 1 via die on any validation or download problem
# Globals: reads MODELS_DIR
command_model_install_url() {
  local lang="${1:-}" onnx_url="${2:-}" json_url="${3:-}" model base
  # Language and onnx URL are both required.
  if [ -z "$lang" ] || [ -z "$onnx_url" ]; then
    die "usage: hyprland-tts model install-url <lang> <onnx-url> [json-url]"
  fi
  # Everything is validated before the first byte is downloaded.
  lang="$(sanitize_lang "$lang")"
  validate_url "$onnx_url"
  # The extension keeps arbitrary downloads out of the models directory.
  [[ "$onnx_url" =~ \.onnx$ ]] || die "onnx URL must end in .onnx"
  # Without an explicit description URL it sits next to the onnx file.
  [ -n "$json_url" ] || json_url="${onnx_url}.json"
  validate_url "$json_url"
  # Same extension rule for the description file.
  [[ "$json_url" =~ \.onnx\.json$ ]] || die "json URL must end in .onnx.json"
  model="$(basename "$onnx_url" .onnx)"
  base="$(dirname "$onnx_url")"
  # Download, validate and store the model next to its derived json URL.
  model_do_install "$lang" "$model" "$base"
  # A json URL elsewhere than next to the onnx file is fetched separately.
  [ -s "$MODELS_DIR/$lang/$model.onnx.json" ] ||
    fetch_file "$json_url" "$MODELS_DIR/$lang/$model.onnx.json"
}

# model_resolve_file — turn "<lang>/<name>" into the path of an installed model.
# Args:    $1 <id>; $2 <1 to validate the name part, else 0>; $3 <message for an id without slash>
# Returns: 0 when the model exists; exits 1 via die otherwise; stdout: the onnx path
# Globals: reads MODELS_DIR
model_resolve_file() {
  local id="$1" lang name file
  [[ "$id" == */* ]] || die "$3"
  # The language part becomes a directory name, so it is validated.
  lang="$(sanitize_lang "${id%%/*}")"
  name="${id#*/}"
  # Remove needs the stricter check because it deletes files by this name.
  if [ "$2" -eq 1 ]; then
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid model name: $name"
  fi
  file="$MODELS_DIR/$lang/$name.onnx"
  # Only installed models can be resolved.
  [ -f "$file" ] || die "no such model: $id"
  printf '%s' "$file"
}

# model_forget_references — drop config and state that point at a removed model file.
# Args:    $1 <language>; $2 <onnx file>
# Returns: 0 always
# Globals: reads FALLBACK_VOICE, VOICE_<lang>, LAST_MODEL_FILE
model_forget_references() {
  local default_var="VOICE_${1}"
  # Each reference is cleared only when it names exactly this file.
  if [ "${!default_var:-}" = "$2" ]; then unset_config_var "$default_var"; fi
  if [ -n "${FALLBACK_VOICE:-}" ] && [ "$FALLBACK_VOICE" = "$2" ]; then
    unset_config_var "FALLBACK_VOICE"
  fi
  # A stale last-used pointer would make the router pick a missing file.
  if [ -f "$LAST_MODEL_FILE" ] && [ "$(cat "$LAST_MODEL_FILE" 2>/dev/null)" = "$2" ]; then
    rm -f "$LAST_MODEL_FILE"
  fi
}

# command_model_remove — implement `model remove <lang/name>`.
# Args:    $1 <id>
# Returns: 0 on success; exits 1 via die on a bad or unknown id
# Globals: reads MODELS_DIR
command_model_remove() {
  local id="${1:-}" file lang
  [ -n "$id" ] || die "usage: hyprland-tts model remove <lang/name>"
  # The strict name check guards the deletion below.
  file="$(model_resolve_file "$id" 1 "id must be <lang>/<name>")"
  lang="${id%%/*}"
  rm -f "$file" "${file}.json"
  # Confirm first; the cleanup below only drops references.
  log "Removed: $id"
  model_forget_references "$lang" "$file"
  # The language directory disappears with its last model.
  rmdir "$MODELS_DIR/$lang" 2>/dev/null || true
}

# command_model_default — implement `model default <lang/name>`.
# Args:    $1 <id>
# Returns: 0 on success; exits 1 via die on a bad or unknown id
# Globals: writes VOICE_<lang> in the config file
command_model_default() {
  local id="${1:-}" file lang
  [ -n "$id" ] || die "usage: hyprland-tts model default <lang/name>"
  # The model must exist, so the config never points at nothing.
  file="$(model_resolve_file "$id" 0 "id must be <lang>/<name>")"
  lang="${id%%/*}"
  set_config_var "VOICE_${lang}" "$file"
  # Confirm the new default to the user.
  log "Default voice for '$lang' set to ${id#*/}"
}

# command_model_fallback — implement `model fallback [<lang/name>|--clear]`.
# Args:    $1 <optional id or --clear; no argument shows the current fallback>
# Returns: 0 on success; exits 1 via die on a bad or unknown id
# Globals: reads and writes FALLBACK_VOICE in the config file
command_model_fallback() {
  local id="${1:-}" file
  if [ "$id" = "--clear" ]; then
    # Without a fallback the router uses the last-used model.
    unset_config_var "FALLBACK_VOICE"
    log "Cleared fallback voice (last-used model is used instead)"
  elif [ -z "$id" ]; then
    # Show the configured fallback, or explain that none is set.
    if [ -n "${FALLBACK_VOICE:-}" ]; then
      echo "Fallback voice: $FALLBACK_VOICE"
    else
      echo "No fallback voice set (using last-used model when language isn't detected)."
    fi
  else
    # The model must exist, so the config never points at nothing.
    file="$(model_resolve_file "$id" 0 "id must be <lang>/<name> (or '--clear')")"
    set_config_var "FALLBACK_VOICE" "$file"
    log "Fallback voice set to $id (used when the language can't be detected)"
  fi
}

# cmd_model — dispatch the `model` subcommands.
# Args:    $1 <list|catalog|install|install-url|remove|default|fallback>; $2.. <arguments>
# Returns: 0 on success; exits 1 via die on an unknown subcommand
# Globals: reads the config file via load_config
cmd_model() {
  local sub="${1:-list}"
  load_config
  # The subcommand word is consumed; a bare call has nothing to shift.
  shift || true
  case "$sub" in
    list)        command_model_list "$@" ;; # installed voices
    catalog)     command_model_catalog "$@" ;; # downloadable voices
    install)     command_model_install "$@" ;; # by catalog key
    install-url) command_model_install_url "$@" ;; # by explicit https URL
    remove)      command_model_remove "$@" ;; # delete one voice
    default)     command_model_default "$@" ;; # per-language default
    fallback)    command_model_fallback "$@" ;; # voice for undetected text
    *) die "unknown model subcommand: $sub" ;;
  esac
}
