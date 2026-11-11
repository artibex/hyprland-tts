#!/usr/bin/env bash
# lib/preview.sh — `hyprland-tts preview`: speak a built-in sample sentence of one language
# through the normal player (daemon, mpv, volume and stop key apply), so voices can be tried out.

# Sample sentence per language code; -g keeps the table global when sourced inside a function.
declare -gA PREVIEW_SENTENCES=(
  [de]="Hallo! So klingt diese Stimme auf Deutsch. Gefällt sie dir?"
  [en]="Hello! This is how this voice sounds in English. Do you like it?"
  # Each sentence greets, names the language and asks the listener a short question.
  [fr]="Bonjour ! Voici comment cette voix sonne en français. Elle vous plaît ?"
  [es]="¡Hola! Así suena esta voz en español. ¿Te gusta?"
  [it]="Ciao! Ecco come suona questa voce in italiano. Ti piace?"
  # Every language Qwen3 can speak has a sentence, so any of its voices can be previewed.
  [pt]="Olá! É assim que esta voz soa em português. Você gosta dela?"
  [ru]="Привет! Так звучит этот голос на русском языке. Нравится?"
  [zh]="你好！这是这个声音说中文的效果。你喜欢吗？"
  # Japanese and Korean close the table (the last of the Qwen3 languages).
  [ja]="こんにちは！これがこの声の日本語の響きです。気に入りましたか？"
  [ko]="안녕하세요! 이 목소리는 한국어로 이렇게 들립니다. 마음에 드시나요?"
)
# Shown for a missing or malformed command line.
PREVIEW_USAGE="usage: hyprland-tts preview <lang> [--engine qwen3|piper] [--model <lang>/<name>]"

# preview_sentence — print the built-in sample sentence of a language.
# Args:    $1 <language code>
# Returns: 0 and the sentence on stdout; 1 when the code is malformed or has no sentence
# Globals: reads PREVIEW_SENTENCES
preview_sentence() {
  # A malformed code must not even be used as a table key.
  valid_lang_code "${1:-}" || return 1
  [ -n "${PREVIEW_SENTENCES[$1]:-}" ] || return 1
  printf '%s' "${PREVIEW_SENTENCES[$1]}"
}

# preview_engine_choice — decide which engine a preview forces.
# Args:    $1 <value of --engine, may be empty>; $2 <value of --model, may be empty>
# Returns: 0 and qwen3 | piper | "" (= the active engine) on stdout; exits 1 via die on a
#          conflicting or unknown engine
# Globals: none
preview_engine_choice() {
  # A named Piper voice can only be spoken by Piper.
  if [ -n "$2" ]; then
    [ "$1" != "qwen3" ] || die "--model names a Piper voice; it cannot be used with --engine qwen3"
    # Forcing Piper also keeps an installed Qwen3 from taking over.
    printf 'piper'
    return 0
  fi
  # Without a model the explicit choice (or none) stands, as long as it names an engine.
  case "$1" in
    ''|qwen3|piper) printf '%s' "$1" ;;
    *) die "unknown engine: '$1' (use qwen3 or piper)" ;;
  esac
}

# preview_model_file — resolve the --model id of a preview to an installed voice of the language.
# Args:    $1 <language code>; $2 <id <lang>/<name>>
# Returns: 0 and the onnx path on stdout; exits 1 via die for a bad id or another language
# Globals: reads MODELS_DIR
preview_model_file() {
  local model_file voice_lang
  # Strict name check: the id comes from the command line and becomes a path.
  model_file="$(model_resolve_file "$2" 1 "--model must be <lang>/<name>")" || exit 1
  voice_lang="$(basename "$(dirname "$model_file")")"
  # A French voice reading the German sample would be no preview of anything.
  [ "$voice_lang" = "$1" ] || die "voice '$2' speaks '$voice_lang', not '$1'"
  printf '%s' "$model_file"
}

# preview_check_engine — make sure the engine in force can speak the language.
# Args:    $1 <language code>; $2 <forced engine: qwen3 | piper | "" for the active one>
# Returns: 0 when it can; exits 1 via die otherwise (no notification: a terminal or GUI asked)
# Globals: reads HYPRLAND_TTS_ENGINE (through engine_active), ENGINE, MODELS_DIR
preview_check_engine() {
  local active_engine
  active_engine="$(engine_active)"
  # A forced Qwen3 must really be usable; the speak path would quietly fall back to Piper.
  if [ "$2" = "qwen3" ] && [ "$active_engine" != "qwen3" ]; then
    die "Qwen3 is not usable: $(engine_unusable_reason)"
  fi
  lang_in_csv "$1" "$(engine_languages)" && return 0
  # Piper needs an installed voice per language; Qwen3 has a fixed language list.
  if [ "$active_engine" = "piper" ]; then
    die "no Piper voice installed for '$1' (see: hyprland-tts model catalog)"
  fi
  die "Qwen3 cannot speak '$1'"
}

# cmd_preview — implement `preview <lang> [--engine qwen3|piper] [--model <lang>/<name>]`.
# Args:    $1 <language code>; $2.. <options>
# Returns: 0 once the player started; exits 1 via die on any invalid request
# Globals: reads the config; exports HYPRLAND_TTS_ENGINE / HYPRLAND_TTS_PIPER_MODEL for the daemon
cmd_preview() {
  local lang="${1:-}" engine_option="" model_option="" sentence forced_engine
  load_config
  # The language is mandatory and positional; options follow it.
  [ -n "$lang" ] || die "$PREVIEW_USAGE"
  shift
  # The code names a table key and a voice directory, so it is checked before anything else.
  valid_lang_code "$lang" || die "invalid language code: '$lang' (expected 2-3 lowercase letters)"
  sentence="$(preview_sentence "$lang")" || die "no sample sentence for '$lang'"
  # Options in any order; each takes exactly one value.
  while [ "$#" -gt 0 ]; do
    # Both options take a value; a missing one is a usage error, not an empty choice.
    case "$1" in
      --engine|--model) [ "$#" -ge 2 ] || die "$1 needs a value\n$PREVIEW_USAGE" ;;
      *) die "unknown option: $1\n$PREVIEW_USAGE" ;;
    esac
    # Store the value under its option, then drop both words.
    if [ "$1" = "--engine" ]; then engine_option="$2"; else model_option="$2"; fi
    shift 2
  done
  forced_engine="$(preview_engine_choice "$engine_option" "$model_option")" || exit 1
  # Exported, so the detached __daemon renders with the same engine and voice.
  if [ -n "$forced_engine" ]; then export HYPRLAND_TTS_ENGINE="$forced_engine"; fi
  # The router prefers this file for the preview language (preview_model_for).
  if [ -n "$model_option" ]; then
    HYPRLAND_TTS_PIPER_MODEL="$(preview_model_file "$lang" "$model_option")" || exit 1
    export HYPRLAND_TTS_PIPER_MODEL
  fi
  # Checked after the exports: the forced engine decides which languages count.
  preview_check_engine "$lang" "$forced_engine"
  # The fixed language skips detection: the sample is spoken exactly as that language.
  speak_text "$sentence" "$lang"
  printf 'preview: %s\n' "$lang"
}
