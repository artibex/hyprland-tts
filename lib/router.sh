#!/usr/bin/env bash
# lib/router.sh — language detection + voice-model resolution.
# Resolution order: detected language -> explicit fallback voice (user-set,
# see 'model fallback') -> last-used model -> English -> any.

REGEX_DE='[ÄäÖöÜüß]|(^|[^[:alpha:]])(der|die|das|ist|und|nicht|ich|mit|von|dem|den|ein|eine|auch|aber|sind|wird)([^[:alpha:]]|$)'
REGEX_FR='[ÉéÈèÇçÀàÙùÂâÊêÎîÔôÛûËëÏï]|(^|[^[:alpha:]])(le|la|les|est|une|des|que|dans|pour|avec|vous|nous|cette|être)([^[:alpha:]]|$)'
REGEX_ES='[Ññ¿¡áíóúÁÍÓÚ]|(^|[^[:alpha:]])(el|los|las|una|unos|unas|que|con|para|por|pero|esto|esta|donde)([^[:alpha:]]|$)'
REGEX_EN='(^|[^[:alpha:]])(the|and|is|are|you|to|of|in|that|it|for|with|this|have|not|was)([^[:alpha:]]|$)'

first_model_in() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  find "$dir" -maxdepth 1 -type f -name '*.onnx' 2>/dev/null | LC_ALL=C sort | head -n1
}

configured_voice_for() {
  local var="VOICE_${1}" val
  val="${!var:-}"
  [ -n "$val" ] && [ -f "$val" ] && printf '%s' "$val"
}

model_for_lang() {
  local lang="$1" m
  m="$(configured_voice_for "$lang")" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  m="$(first_model_in "$MODELS_DIR/$lang")" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  return 1
}

detect_lang() {
  local text="$1"
  if [[ "$text" =~ $REGEX_DE ]]; then echo de; return; fi
  if [[ "$text" =~ $REGEX_FR ]]; then echo fr; return; fi
  if [[ "$text" =~ $REGEX_ES ]]; then echo es; return; fi
  if [[ "$text" =~ $REGEX_EN ]]; then echo en; return; fi
  echo ""
}

resolve_model() {
  local text="$1" lang m
  lang="$(detect_lang "$text")"
  if [ -n "$lang" ]; then
    m="$(model_for_lang "$lang")" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  fi
  # undetected/unavailable -> explicit user-set fallback voice takes priority
  # over the auto "last used" heuristic, since it's a deliberate choice
  # (see 'hyprland-tts model fallback', GUI: Voices > Fallback voice)
  if [ -n "${FALLBACK_VOICE:-}" ] && [ -f "$FALLBACK_VOICE" ]; then
    printf '%s' "$FALLBACK_VOICE"; return 0
  fi
  # otherwise reuse last model actually used (Bug 1 fix)
  if [ -f "$LAST_MODEL_FILE" ]; then
    m="$(cat "$LAST_MODEL_FILE" 2>/dev/null || true)"
    [ -n "$m" ] && [ -f "$m" ] && { printf '%s' "$m"; return 0; }
  fi
  m="$(model_for_lang en)" && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  m="$(find "$MODELS_DIR" -type f -name '*.onnx' 2>/dev/null | LC_ALL=C sort | head -n1 || true)"
  [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  return 1
}

remember_model() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$LAST_MODEL_FILE" 2>/dev/null || true
}
