#!/usr/bin/env bash
# lib/model.sh — voice catalog + install / list / remove / default.
# Security (URL scheme, extension, path-traversal, atomic download) lives here,
# so the GUI inherits it by shelling out to these subcommands.

HF="https://huggingface.co/rhasspy/piper-voices/resolve/main"
catalog_lines() {
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

sanitize_lang() {
  [[ "$1" =~ ^[a-z]{2,3}$ ]] || die "invalid language code: '$1' (expected 2-3 lowercase letters)"
  printf '%s' "$1"
}
validate_url() {
  [[ "$1" =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'\(\)\*\+,\;=%-]+$ ]] || die "refusing non-https or malformed URL: $1"
}
fetch_file() {
  local url="$1" dest="$2" tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || die "cannot create temp file"
  if curl -fL --retry 2 --connect-timeout 20 -o "$tmp" "$url"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"; die "download failed: $url"
  fi
}

model_do_install() {
  local lang model base dir onnx json
  lang="$(sanitize_lang "$1")"; model="$2"; base="$3"
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid model name: $model"
  validate_url "$base/$model.onnx"; validate_url "$base/$model.onnx.json"
  dir="$MODELS_DIR/$lang"; mkdir -p "$dir"
  onnx="$dir/$model.onnx"; json="$dir/$model.onnx.json"
  log "Downloading $model → $dir"
  fetch_file "$base/$model.onnx"      "$onnx"
  fetch_file "$base/$model.onnx.json" "$json"
  [ -s "$onnx" ] || { rm -f "$onnx" "$json"; die "downloaded model is empty"; }
  log "Installed: $lang/$model"
}

cmd_model() {
  load_config
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      local porcelain=0; [ "${1:-}" = "--porcelain" ] && porcelain=1
      local last=""; [ -f "$LAST_MODEL_FILE" ] && last="$(cat "$LAST_MODEL_FILE" 2>/dev/null || true)"
      [ -d "$MODELS_DIR" ] || { [ "$porcelain" -eq 1 ] || echo "No models installed."; return 0; }
      local found=0 f lang name size isdef islast defvar
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        found=1
        lang="$(basename "$(dirname "$f")")"; name="$(basename "$f" .onnx)"
        size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
        defvar="VOICE_${lang}"; isdef=0; [ "${!defvar:-}" = "$f" ] && isdef=1
        islast=0; [ "$f" = "$last" ] && islast=1
        if [ "$porcelain" -eq 1 ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$lang/$name" "$lang" "$name" "$size" "$isdef" "$islast"
        else
          local marks=""; [ "$isdef" -eq 1 ] && marks="$marks [default]"; [ "$islast" -eq 1 ] && marks="$marks [last used]"
          printf '  %-8s %-28s %6s MB%s\n' "$lang" "$name" \
            "$(awk -v b="$size" 'BEGIN{printf "%.1f", b/1048576}')" "$marks"
        fi
      done < <(find "$MODELS_DIR" -type f -name '*.onnx' 2>/dev/null | LC_ALL=C sort)
      [ "$found" -eq 1 ] || [ "$porcelain" -eq 1 ] || echo "No models installed." ;;
    catalog)
      if [ "${1:-}" = "--porcelain" ]; then
        catalog_lines | while IFS='|' read -r key lang model base quality label; do
          local installed=0; [ -f "$MODELS_DIR/$lang/$model.onnx" ] && installed=1
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$lang" "$model" "$quality" "$installed" "$label"
        done
      else
        echo "Available voices (key — description):"
        catalog_lines | while IFS='|' read -r key lang model base quality label; do
          local mark=""; [ -f "$MODELS_DIR/$lang/$model.onnx" ] && mark="  ✓ installed"
          printf '  %-20s %s%s\n' "$key" "$label" "$mark"
        done
      fi ;;
    install)
      local key="${1:-}"; [ -n "$key" ] || die "usage: hyprland-tts model install <key>  (see 'model catalog')"
      local line; line="$(catalog_lines | awk -F'|' -v k="$key" '$1==k{print; exit}')"
      [ -n "$line" ] || die "unknown catalog key: $key  (see 'model catalog')"
      local lang model base
      IFS='|' read -r _ lang model base _ _ <<< "$line"
      model_do_install "$lang" "$model" "$base" ;;
    install-url)
      local lang="${1:-}" onnx_url="${2:-}" json_url="${3:-}"
      [ -n "$lang" ] && [ -n "$onnx_url" ] || die "usage: hyprland-tts model install-url <lang> <onnx-url> [json-url]"
      lang="$(sanitize_lang "$lang")"
      validate_url "$onnx_url"; [[ "$onnx_url" =~ \.onnx$ ]] || die "onnx URL must end in .onnx"
      [ -n "$json_url" ] || json_url="${onnx_url}.json"
      validate_url "$json_url"; [[ "$json_url" =~ \.onnx\.json$ ]] || die "json URL must end in .onnx.json"
      local model base
      model="$(basename "$onnx_url" .onnx)"; base="$(dirname "$onnx_url")"
      model_do_install "$lang" "$model" "$base"
      [ -s "$MODELS_DIR/$lang/$model.onnx.json" ] || fetch_file "$json_url" "$MODELS_DIR/$lang/$model.onnx.json" ;;
    remove)
      local id="${1:-}"; [ -n "$id" ] || die "usage: hyprland-tts model remove <lang/name>"
      [[ "$id" == */* ]] || die "id must be <lang>/<name>"
      local lang name f; lang="$(sanitize_lang "${id%%/*}")"; name="${id#*/}"
      [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid model name: $name"
      f="$MODELS_DIR/$lang/$name.onnx"; [ -f "$f" ] || die "no such model: $id"
      rm -f "$f" "${f}.json"; log "Removed: $id"
      local defvar="VOICE_${lang}"; [ "${!defvar:-}" = "$f" ] && unset_config_var "$defvar"
      [ -f "$LAST_MODEL_FILE" ] && [ "$(cat "$LAST_MODEL_FILE" 2>/dev/null)" = "$f" ] && rm -f "$LAST_MODEL_FILE"
      rmdir "$MODELS_DIR/$lang" 2>/dev/null || true ;;
    default)
      local id="${1:-}"; [ -n "$id" ] || die "usage: hyprland-tts model default <lang/name>"
      [[ "$id" == */* ]] || die "id must be <lang>/<name>"
      local lang name f; lang="$(sanitize_lang "${id%%/*}")"; name="${id#*/}"
      f="$MODELS_DIR/$lang/$name.onnx"; [ -f "$f" ] || die "no such model: $id"
      set_config_var "VOICE_${lang}" "$f"; log "Default voice for '$lang' set to $name" ;;
    *) die "unknown model subcommand: $sub" ;;
  esac
}
