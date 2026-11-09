#!/usr/bin/env bash
# lib/common.sh — shared paths, config, defaults and helpers.
# Sourced by bin/hyprland-tts. No side effects beyond defining variables and functions.

# --- XDG paths (honour overrides; fall back to the specification's defaults) ---
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
# The cache directory holds only disposable data.
: "${XDG_CACHE_HOME:=$HOME/.cache}"

MODELS_DIR="$XDG_DATA_HOME/piper-tts"
STATE_DIR="$XDG_STATE_HOME/piper-tts"
# Where the router remembers the last Piper voice.
LAST_MODEL_FILE="$STATE_DIR/last-model"
CONFIG_DIR="$XDG_CONFIG_HOME/piper-tts"
CONFIG_FILE="$CONFIG_DIR/config"
# Without a runtime directory the /tmp fallback names carry the user id, so users never share one.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  RUNTIME_BASE="$XDG_RUNTIME_DIR"
  RUNTIME_NAME_SUFFIX=""
else
  # The /tmp fallback is shared, so its names carry the user id.
  RUNTIME_BASE="/tmp"
  RUNTIME_NAME_SUFFIX="-$EUID"
fi
# The per-speak player directory; wiped on every speak, so nothing durable lives here.
RUN_DIR="${HYPRLAND_TTS_RUN_DIR:-$RUNTIME_BASE/hyprland-tts$RUNTIME_NAME_SUFFIX}"
# The warm-engine worker keeps its state apart from RUN_DIR so a new speak cannot wipe it.
WORKER_DIR="${HYPRLAND_TTS_WORKER_DIR:-$RUNTIME_BASE/hyprland-tts-worker$RUNTIME_NAME_SUFFIX}"
# Durable data of the 2.0 engine layer: installed engines and cloned voices.
HTTS_DATA_DIR="$XDG_DATA_HOME/hyprland-tts"
ENGINES_DIR="$HTTS_DATA_DIR/engines"
USER_VOICES_DIR="$HTTS_DATA_DIR/voices"
# Disposable caches (compiled Python bytecode, dependency check results).
HTTS_CACHE_DIR="$XDG_CACHE_HOME/hyprland-tts"

# Hyprland integration files written by `hyprland-tts setup`.
HYPR_DIR="$XDG_CONFIG_HOME/hypr"
TTS_CONF="$HYPR_DIR/tts.conf"
TTS_LUA="$HYPR_DIR/tts.lua"
# Hyprland's own configuration files, which setup links into.
MAIN_CONF="$HYPR_DIR/hyprland.conf"
MAIN_LUA="$HYPR_DIR/hyprland.lua"

# --- Tunable defaults (overridable via CONFIG_FILE) ---
PIPER_BIN="${PIPER_BIN:-piper-tts}"
MPV_BIN="${MPV_BIN:-mpv}"
DEFAULT_SPEED="${DEFAULT_SPEED:-1.0}"
# Speed limits and step of the faster/slower controls.
SPEED_MIN="0.5"
SPEED_MAX="3.0"
SPEED_STEP="0.2"
# Maximum characters per synthesized chunk.
CHUNK_MAX="240"
# Longest selection that is spoken (characters); more is cut off with a notice.
SELECTION_MAX_CHARS="${SELECTION_MAX_CHARS:-200000}"

# Engine selection: auto = qwen3 when installed, otherwise piper.
ENGINE="${ENGINE:-auto}"
# Which Qwen3 talker is loaded: base (native cloned voices, default) or customvoice (presets).
QWEN_VARIANT="${QWEN_VARIANT:-base}"
# Minutes without a request before the warm worker exits (0 = never).
WORKER_IDLE_MINUTES="${WORKER_IDLE_MINUTES:-10}"
# Language assumed by the text router when detection finds nothing usable.
DEFAULT_LANG="${DEFAULT_LANG:-en}"
# Seconds the worker may take to load the model before the start counts as failed.
QWEN_START_TIMEOUT="${QWEN_START_TIMEOUT:-90}"
# 1 = bring every rendered chunk to one loudness so voices switch without volume jumps.
NORMALIZE_LOUDNESS="${NORMALIZE_LOUDNESS:-1}"
# Seconds one synthesis request may take before the chunk falls back to Piper.
QWEN_REQUEST_TIMEOUT="${QWEN_REQUEST_TIMEOUT:-120}"

# --- Keybind model: actions are the single source of truth (KEY_<action> overrides) ---
ACTION_ORDER=(speak stop next prev faster slower toggle restart)

declare -gA ACTION_DEFAULT_KEY=(
  [speak]="SUPER, A"
  # Core shortcuts keep their original defaults (Agent.md §5).
  [stop]="SUPER, ESCAPE"
  [next]="SUPER ALT, right"
  [prev]="SUPER ALT, left"
  # Playback controls default to SUPER+ALT combinations.
  [faster]="SUPER ALT, up"
  [slower]="SUPER ALT, down"
  [toggle]="SUPER ALT, space"
  # Restart replays the current sentence.
  [restart]="SUPER ALT, R"
)
declare -gA ACTION_CMD=(
  # The hyprland-tts subcommand each shortcut runs.
  [speak]="speak"        [stop]="stop"
  [next]="ctl next"      [prev]="ctl prev"
  [faster]="ctl faster"  [slower]="ctl slower"
  # One key pauses and resumes; restart seeks to the sentence start.
  [toggle]="ctl toggle"  [restart]="ctl restart"
)
declare -gA ACTION_LABEL=(
  # Names shown in listings, the setup summary and the GUI.
  [speak]="Speak selection"
  [stop]="Stop speech"
  [next]="Next sentence"      [prev]="Previous sentence"
  # Speed controls and the pause toggle close the table.
  [faster]="Speed up"         [slower]="Slow down"
  [toggle]="Pause / resume"   [restart]="Replay sentence"
)

# log — print a message to stderr.
# Args:    $1.. <message words, joined by single blanks>
# Returns: 0 always; stderr: the message and a newline
# Globals: none
log() {
  # Messages go to stderr so stdout stays machine-readable for the GUI and scripts.
  printf '%s\n' "$*" >&2
}

# die — print an error and end the program.
# Args:    $1.. <message words; printf %b escapes such as \n are expanded>
# Returns: exits 1; stderr: "error: <message>"
# Globals: none
die() {
  # %b lets callers embed line breaks in one message.
  printf 'error: %b\n' "$*" >&2
  exit 1
}

# have — tell whether a command exists.
# Args:    $1 <command name or path>
# Returns: 0 when found; 1 otherwise
# Globals: none
have() {
  # command -v finds functions, builtins and executables alike.
  command -v "$1" >/dev/null 2>&1
}

# notify — show a desktop notification when notify-send exists (best effort).
# Args:    $1 <title>; $2 <message, optional>
# Returns: 0 always
# Globals: none
# Notes:   Keybind-run actions have no terminal, so a failure would otherwise look like a dead key.
notify() {
  have notify-send || return 0
  notify-send -a "hyprland-tts" -i audio-speakers "$1" "${2:-}" >/dev/null 2>&1 || true
}

# load_config — read the user's config file into the shell.
# Args:    none
# Returns: 0 always (a broken file only produces a warning)
# Globals: reads CONFIG_FILE; the file may assign any setting
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # The config is a sourced bash file by design (see Agent.md); failures keep the defaults.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE" 2>/dev/null || log "warning: could not read $CONFIG_FILE, using defaults"
}

# key_for_action — print the key combination bound to an action.
# Args:    $1 <action name, e.g. speak>
# Returns: 0 always; stdout: the config override KEY_<action> or the default
# Globals: reads KEY_<action>, ACTION_DEFAULT_KEY
key_for_action() {
  local action="$1" override_var="KEY_${1}"
  # An override in the config file beats the built-in default.
  printf '%s' "${!override_var:-${ACTION_DEFAULT_KEY[$action]}}"
}

# config_drop_key — copy the config file without any assignment of a key.
# Args:    $1 <key name>; $2 <output file path>
# Returns: 0 always
# Globals: reads CONFIG_FILE
config_drop_key() {
  # grep -v exits 1 when nothing is left; that only means an empty file, which is fine.
  grep -v -E "^${1}=" "$CONFIG_FILE" > "$2" 2>/dev/null || true
}

# set_config_var — write one KEY=value assignment into the config file (replacing any old one).
# Args:    $1 <key>; $2 <value; stored shell-quoted via printf %q>
# Returns: 0 always
# Globals: writes CONFIG_DIR, CONFIG_FILE
set_config_var() {
  local key="$1" value="$2" tmp="${CONFIG_FILE}.tmp"
  mkdir -p "$CONFIG_DIR"
  # A missing file is created so the rewrite below always has a source.
  touch "$CONFIG_FILE"
  # Rewrite through a temp file and rename, so a crash never truncates the config.
  config_drop_key "$key" "$tmp"
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

# unset_config_var — delete a key from the config file and from the running shell.
# Args:    $1 <key>
# Returns: 0 always
# Globals: writes CONFIG_FILE
# Notes:   The in-shell value must go too: re-sourcing the file cannot unset it (stale combos).
unset_config_var() {
  local tmp="${CONFIG_FILE}.tmp"
  # Dropping the shell variable keeps later generators from using the stale value.
  unset "$1" || true
  [ -f "$CONFIG_FILE" ] || return 0
  config_drop_key "$1" "$tmp"
  # The rename replaces the config in one step.
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

# ensure_private_dir — create a directory only this user can use, or refuse.
# Args:    $1 <directory>
# Returns: 0 when it exists, is ours, is no symlink and has mode 700; 1 otherwise
# Globals: none
# Notes:   /tmp fallbacks are predictable names; a foreign or symlinked directory is an attack.
ensure_private_dir() {
  # A symlink could redirect our files (and rm -rf) somewhere else.
  [ ! -L "$1" ] || return 1
  ( umask 077; mkdir -p -- "$1" ) 2>/dev/null || true
  # Someone else's directory must never receive chunks, sockets or ports.
  [ -d "$1" ] && [ -O "$1" ] || return 1
  # An older, more open directory is tightened instead of trusted.
  chmod 700 -- "$1" 2>/dev/null
}

# temp_file — create a private temporary file for data that may contain the user's text.
# Args:    none
# Returns: 0 on success; 1 when the private directory is unusable; stdout: the file path
# Globals: reads WORKER_DIR
temp_file() {
  # The 0700 worker directory keeps request bodies away from other users of a shared /tmp.
  ensure_private_dir "$WORKER_DIR" || return 1
  mktemp "$WORKER_DIR/tmp.XXXXXX"
}
