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
# The per-speak player directory; wiped on every speak, so nothing durable lives here.
RUN_DIR="${HYPRLAND_TTS_RUN_DIR:-$XDG_RUNTIME_DIR/hyprland-tts}"
# The warm-engine worker keeps its state apart from RUN_DIR so a new speak cannot wipe it.
WORKER_DIR="${HYPRLAND_TTS_WORKER_DIR:-$XDG_RUNTIME_DIR/hyprland-tts-worker}"
# Durable data of the 2.0 engine layer: installed engines and cloned voices.
HTTS_DATA_DIR="$XDG_DATA_HOME/hyprland-tts"
ENGINES_DIR="$HTTS_DATA_DIR/engines"
USER_VOICES_DIR="$HTTS_DATA_DIR/voices"

# Hyprland integration files written by `hyprland-tts setup`.
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

# Engine selection: auto = qwen3 when installed, otherwise piper.
ENGINE="${ENGINE:-auto}"
# Which Qwen3 talker is loaded: customvoice (preset speakers) or base (cloned voices).
QWEN_VARIANT="${QWEN_VARIANT:-customvoice}"
# Minutes without a request before the warm worker exits (0 = never).
WORKER_IDLE_MINUTES="${WORKER_IDLE_MINUTES:-10}"
# Language assumed by the text router when detection finds nothing usable.
DEFAULT_LANG="${DEFAULT_LANG:-en}"
# Seconds the worker may take to load the model before the start counts as failed.
QWEN_START_TIMEOUT="${QWEN_START_TIMEOUT:-90}"
# Seconds one synthesis request may take before the chunk falls back to Piper.
QWEN_REQUEST_TIMEOUT="${QWEN_REQUEST_TIMEOUT:-120}"

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

# is_safe_name — tell whether a string is a valid language, voice or engine name.
# Args:    $1 <candidate name>
# Returns: 0 when it matches ^[a-z0-9_-]+$; 1 otherwise; stdout: nothing
# Globals: none
is_safe_name() {
  # Lowercase letters, digits, underscore and dash only keeps paths and JSON injection-free.
  [[ "${1:-}" =~ ^[a-z0-9_-]+$ ]]
}

# require_safe_name — die unless a user-supplied name is valid, else echo it back.
# Args:    $1 <what the name is, for the error>; $2 <candidate name>
# Returns: 0 when valid; exits 1 via die otherwise; stdout: the name
# Globals: none
require_safe_name() {
  # Reject early so a bad name never reaches a path or a request body.
  is_safe_name "$2" || die "invalid $1 '$2' (allowed: lowercase letters, digits, _ and -)"
  # Echo the validated name so callers can use command substitution.
  printf '%s' "$2"
}

# json_escape — escape text so it can sit inside a JSON string literal.
# Args:    $1 <raw text>
# Returns: 0 always; stdout: the escaped text without surrounding quotes
# Globals: none
json_escape() {
  local text="$1"
  # Control characters other than tab/newline/CR are illegal in JSON and meaningless to speak.
  text="$(printf '%s' "$text" | tr -d '\000-\010\013\014\016-\037')"
  # Backslash first, otherwise the escapes added below would be doubled.
  text="${text//\\/\\\\}"
  # Quotes would end the JSON string early.
  text="${text//\"/\\\"}"
  # Newlines, carriage returns and tabs become their JSON escape sequences.
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\t'/\\t}"
  # Printed without a trailing newline so the caller controls framing.
  printf '%s' "$text"
}

# epoch_now — print the current Unix time in seconds.
# Args:    none
# Returns: 0 always; stdout: seconds since the epoch
# Globals: none
epoch_now() {
  # printf's %T avoids forking date on every poll of a wait loop.
  printf '%(%s)T' -1
}

# file_age_seconds — print how many whole seconds ago a file was last modified.
# Args:    $1 <file path>
# Returns: 0 when the file exists; 1 when it is missing; stdout: age in seconds
# Globals: none
file_age_seconds() {
  local modified
  # A missing file has no age; callers treat that as "unknown".
  modified="$(stat -c %Y "$1" 2>/dev/null)" || return 1
  # Subtracting from now gives the idle time in seconds.
  printf '%s' "$(( $(epoch_now) - modified ))"
}
