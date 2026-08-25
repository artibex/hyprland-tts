#!/usr/bin/env bash
# lib/common.sh — shared paths, config, defaults and helpers.
# Sourced by bin/hyprland-tts. No side effects beyond defining vars/functions.

# ------------------------------------------------------------------------------
# XDG paths (honor overrides; fall back to defaults)
# ------------------------------------------------------------------------------
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_RUNTIME_DIR:=/tmp}"

MODELS_DIR="$XDG_DATA_HOME/piper-tts"
STATE_DIR="$XDG_STATE_HOME/piper-tts"
LAST_MODEL_FILE="$STATE_DIR/last-model"
CONFIG_DIR="$XDG_CONFIG_HOME/piper-tts"
CONFIG_FILE="$CONFIG_DIR/config"
RUN_DIR="$XDG_RUNTIME_DIR/hyprland-tts"

HYPR_DIR="$XDG_CONFIG_HOME/hypr"
TTS_CONF="$HYPR_DIR/tts.conf"
TTS_LUA="$HYPR_DIR/tts.lua"
MAIN_CONF="$HYPR_DIR/hyprland.conf"
MAIN_LUA="$HYPR_DIR/hyprland.lua"

# ------------------------------------------------------------------------------
# Tunable defaults (overridable via CONFIG_FILE)
# ------------------------------------------------------------------------------
PIPER_BIN="${PIPER_BIN:-piper-tts}"
MPV_BIN="${MPV_BIN:-mpv}"
DEFAULT_SPEED="${DEFAULT_SPEED:-1.0}"
SPEED_MIN="0.5"
SPEED_MAX="3.0"
SPEED_STEP="0.2"
CHUNK_MAX="240"          # max characters per synthesized chunk

# ------------------------------------------------------------------------------
# Keybind model — actions are the single source of truth. tts.conf is generated
# from these + user overrides (KEY_<action> in the config file), which keeps
# rebinding fully data-driven for the GUI.
# ------------------------------------------------------------------------------
ACTION_ORDER=(speak stop next prev faster slower toggle restart)

declare -gA ACTION_DEFAULT_KEY=(
  [speak]="SUPER, A"
  [stop]="SUPER, ESCAPE"
  [next]="SUPER ALT, right"
  [prev]="SUPER ALT, left"
  [faster]="SUPER ALT, up"
  [slower]="SUPER ALT, down"
  [toggle]="SUPER ALT, space"
  [restart]="SUPER ALT, R"
)
declare -gA ACTION_CMD=(
  [speak]="speak"        [stop]="stop"
  [next]="ctl next"      [prev]="ctl prev"
  [faster]="ctl faster"  [slower]="ctl slower"
  [toggle]="ctl toggle"  [restart]="ctl restart"
)
declare -gA ACTION_LABEL=(
  [speak]="Speak selection"
  [stop]="Stop speech"
  [next]="Next sentence"      [prev]="Previous sentence"
  [faster]="Speed up"         [slower]="Slow down"
  [toggle]="Pause / resume"   [restart]="Replay sentence"
)

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %b\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Best-effort desktop notification. Exists because keybind-triggered actions
# (Hyprland `exec`s them with no terminal attached) can fail in ways `die`'s
# stderr write will never surface to the user — a silent failure looks
# identical to "nothing happened" and "this needs a dependency I don't have".
# Prefer notify-send when available; otherwise no-op.
notify() {
  have notify-send || return 0
  notify-send -a "hyprland-tts" -i audio-speakers "$1" "${2:-}" >/dev/null 2>&1 || true
}

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE" 2>/dev/null || log "warning: could not read $CONFIG_FILE, using defaults"
}

# key currently bound to an action (config override or default)
key_for_action() {
  local action="$1" var="KEY_${1}"
  printf '%s' "${!var:-${ACTION_DEFAULT_KEY[$action]}}"
}

# idempotent whole-key rewrite of a single assignment in the config file
set_config_var() {
  local key="$1" val="$2" tmp
  mkdir -p "$CONFIG_DIR"
  touch "$CONFIG_FILE"
  tmp="${CONFIG_FILE}.tmp"
  grep -v -E "^${key}=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%q\n' "$key" "$val" >> "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

unset_config_var() {
  local key="$1" tmp
  # Also drop the in-shell value: load_config sourced it at command start and
  # re-sourcing the edited file cannot unset it, so generate_tts_conf would
  # keep generating with the stale combo until the next invocation.
  unset "$key" || true
  [ -f "$CONFIG_FILE" ] || return 0
  tmp="${CONFIG_FILE}.tmp"
  grep -v -E "^${key}=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CONFIG_FILE"
}
