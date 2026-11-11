#!/usr/bin/env bash
# lib/say.sh — `hyprland-tts say`: speak text from the command line or stdin through the normal
# player (scripts, assistants), so nobody has to overwrite the user's selection to be read aloud.

# Shown for an unknown option or a missing option value.
SAY_USAGE="usage: hyprland-tts say [--lang <code>] [--wait] [--] [<text>...]"
# Seconds between two checks of `--wait`; a reading lasts seconds, so 0.2 s costs nothing.
SAY_WAIT_INTERVAL=0.2

# say_check_lang — make sure a forced language is well-formed and has a voice.
# Args:    $1 <language code given to --lang>
# Returns: 0 when the active engine can speak it; exits 1 via die otherwise (no notification)
# Globals: reads the config through engine_active / engine_languages
say_check_lang() {
  # The code becomes part of a voice lookup, so a malformed one is refused first.
  valid_lang_code "$1" || die "invalid language code: '$1' (expected 2-3 lowercase letters)"
  # Same rule and messages as a voice preview of the active engine (no engine is forced).
  preview_check_engine "$1" ""
}

# say_read_text — print the text to speak: the arguments, or stdin when there are none.
# Args:    $1.. <text words; none or a single "-" means stdin>
# Returns: 0 always; stdout: the text (arguments joined with single spaces)
# Globals: none
say_read_text() {
  # A local IFS makes "$*" join with exactly one space whatever the caller's IFS is.
  local IFS=' '
  # No words, or the conventional "-", hand the whole of stdin over unchanged.
  if [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = "-" ]; }; then
    cat
  else
    printf '%s' "$*"
  fi
}

# say_wait_for_end — block until one player daemon has exited.
# Args:    $1 <daemon pid; empty when no daemon was started>
# Returns: 0 always
# Globals: reads SAY_WAIT_INTERVAL
# Notes:   The pid stops being valid when playback ends, `stop` runs or a new speak replaces it.
say_wait_for_end() {
  # daemon_pid_valid also rejects an empty pid, so text without a speakable word returns at once.
  while daemon_pid_valid "$1"; do
    sleep "$SAY_WAIT_INTERVAL"
  done
}

# cmd_say — implement `say [--lang <code>] [--wait] [--] [<text>...]`.
# Args:    $1.. <options, then the text words>
# Returns: 0 once the player started (with --wait: once it ended); exits 1 via die on a bad
#          option, a language without a voice or nothing to say; stdout: nothing
# Globals: reads the config; reads PIDFILE (set by speak_text through _player_paths)
cmd_say() {
  local forced_lang="" wait_for_end=0 text
  load_config
  # Options come first; the first word that is no option starts the text.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # --lang takes a value, which is checked at once so a typo fails before stdin is read.
      --lang) [ "$#" -ge 2 ] || die "--lang needs a value\n$SAY_USAGE"
        say_check_lang "$2"
        forced_lang="$2" # a one-item language list skips detection in speak_text
        shift 2 ;;
      --wait) wait_for_end=1; shift ;; # block until this reading has ended
      --) shift; break ;; # everything after it is text, even a leading dash
      -) break ;; # the conventional name of stdin, handled by say_read_text
      -*) die "unknown option: $1\n$SAY_USAGE" ;;
      *) break ;; # the first text word
    esac
  done
  text="$(say_read_text "$@")"
  # Whitespace alone would start a player that has nothing to play.
  [ -n "${text//[[:space:]]/}" ] || die "nothing to say"
  # An empty forced language lets speak_text detect over every language of the engine.
  speak_text "$text" "$forced_lang"
  [ "$wait_for_end" -eq 1 ] || return 0
  # The pid file names the daemon this call just started (empty when nothing was speakable).
  say_wait_for_end "$(cat "$PIDFILE" 2>/dev/null || true)"
}
