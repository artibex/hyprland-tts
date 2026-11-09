#!/usr/bin/env bash
# lib/pyenv.sh — optional Python helper environment (fastText + num2words) and its model.
#
# The text helpers in lib/py/ need two small PyPI packages and one 938 KB model file.
# `hyprland-tts deps install` creates a private venv under $XDG_DATA_HOME/hyprland-tts/,
# installs PINNED, HASH-CHECKED packages and downloads the model over https with a
# sha256 check. Nothing runs as root and nothing is written outside the user's data dir.
# When the AUR packages (python-fasttext-predict, python-num2words) are installed
# system-wide, no venv is needed. Every caller must treat "no Python" as a normal case
# and fall back to the bash path (see router.sh::prepare_chunks).
#
# Needs from common.sh: log, have. Sourced only; no side effects besides the constants.

# fastText language-identification model (CC-BY-SA-3.0), fetched at install time.
LID_MODEL_URL='https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz'
# Expected checksum of the model file; a mismatch deletes the download.
LID_MODEL_SHA256='8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83'
# File name of the model inside the langid directories.
LID_MODEL_NAME='lid.176.ftz'
# System-wide model location used by distribution packages.
LID_MODEL_SYSTEM_DIR='/usr/share/hyprland-tts'

# pyenv_data_dir — print the per-user data directory of the helper environment.
# Args:    none
# Returns: 0 always; stdout: $XDG_DATA_HOME/hyprland-tts (default ~/.local/share/...)
# Globals: reads XDG_DATA_HOME, HOME
pyenv_data_dir() {
  printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/hyprland-tts"
}

# pyenv_venv_dir — print the directory of the private virtual environment.
# Args:    none
# Returns: 0 always; stdout: the venv path
# Globals: reads XDG_DATA_HOME, HOME
pyenv_venv_dir() {
  printf '%s/venv' "$(pyenv_data_dir)"
}

# py_helpers_dir — print the directory that holds htts_text.py and its modules.
# Args:    none
# Returns: 0 always; stdout: the lib/py directory
# Globals: reads HTTS_PY_DIR, LIBDIR
# Notes:   Falls back to the directory of this file so git checkouts work unconfigured.
py_helpers_dir() {
  local here
  # An explicit override (tests, development) wins.
  [ -z "${HTTS_PY_DIR:-}" ] || { printf '%s' "$HTTS_PY_DIR"; return 0; }
  # The dispatcher's LIBDIR is the installed location.
  [ -z "${LIBDIR:-}" ] || [ ! -d "$LIBDIR/py" ] || { printf '%s/py' "$LIBDIR"; return 0; }
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/py' "$here"
}

# pyenv_check_key — build a cache key that changes when an interpreter or its packages change.
# Args:    $1.. <paths whose modification times matter (interpreter, site-packages, markers)>
# Returns: 0 always; stdout: a checksum number
# Globals: none
pyenv_check_key() {
  # Names and modification times of the interpreter and its package directories identify a state.
  stat -L -c '%n %.9Y %s %i' "$@" 2>/dev/null | cksum | cut -d' ' -f1
}

# pyenv_import_ok — run the real import check for an interpreter, cached until something changes.
# Args:    $1 <python interpreter>; $2.. <paths that invalidate the cached answer>
# Returns: 0 when fasttext and num2words import; 1 otherwise
# Globals: reads HTTS_CACHE_DIR
# Notes:   The check costs ~100 ms, so the answer (also a failure) is cached per interpreter state.
pyenv_import_ok() {
  local python="$1" cache_file
  shift
  # One cache file per interpreter state.
  cache_file="$HTTS_CACHE_DIR/import-check-$(pyenv_check_key "$python" "$@")"
  # A cached verdict is valid for exactly this interpreter and package state.
  if [ -f "$cache_file" ]; then [ "$(cat "$cache_file")" = "ok" ]; return; fi
  mkdir -p "$HTTS_CACHE_DIR"
  if "$python" -c 'import fasttext, num2words' >/dev/null 2>&1; then
    # Remember the success until the interpreter or its packages change.
    printf 'ok' > "$cache_file"
    return 0
  fi
  printf 'fail' > "$cache_file"
  # The interpreter cannot import the helper packages.
  return 1
}

# system_python_has_deps — check for AUR-installed fasttext + num2words with a real import.
# Args:    none
# Returns: 0 when /usr/bin/python3 can import both packages; 1 otherwise
# Globals: none
system_python_has_deps() {
  local -a site_dirs
  [ -x /usr/bin/python3 ] || return 1
  # Site-package directories of every installed minor version invalidate the cached verdict.
  mapfile -t site_dirs < <(compgen -G '/usr/lib/python3*/site-packages' || true)
  pyenv_import_ok /usr/bin/python3 "${site_dirs[@]}"
}

# pyenv_python — print the interpreter that can run the text helpers.
# Args:    none
# Returns: 0 and the path on stdout when usable; 1 when no usable Python exists
# Globals: reads HTTS_PYTHON (explicit override, tests), HOME, XDG_DATA_HOME
pyenv_python() {
  local venv
  # An explicit override is used as-is, or means "no Python" when it is not executable.
  if [ -n "${HTTS_PYTHON:-}" ]; then
    [ -x "$HTTS_PYTHON" ] && { printf '%s' "$HTTS_PYTHON"; return 0; }
    return 1
  fi
  # The private venv counts once `deps install` has finished (marker file) and still imports:
  # a system Python upgrade can silently break an old venv.
  venv="$(pyenv_venv_dir)"
  if [ -x "$venv/bin/python3" ] && [ -f "$venv/.deps-ok" ] &&
    pyenv_import_ok "$venv/bin/python3" "$venv/.deps-ok" "$venv/pyvenv.cfg"; then
    # The venv is used.
    printf '%s/bin/python3' "$venv"
    return 0
  fi
  # System-wide AUR packages work without any venv.
  system_python_has_deps && { printf '%s' /usr/bin/python3; return 0; }
  return 1
}

# langid_model_path — print the fastText model file if one is installed.
# Args:    none
# Returns: 0 and the path on stdout; 1 when no model file exists
# Globals: reads HTTS_LID_MODEL (override), XDG_DATA_HOME, HOME
langid_model_path() {
  local candidate
  # Search order: override, user data dir, system-wide package location.
  for candidate in "${HTTS_LID_MODEL:-}" \
      "$(pyenv_data_dir)/langid/$LID_MODEL_NAME" "$LID_MODEL_SYSTEM_DIR/$LID_MODEL_NAME"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# deps_sha256_of — print the sha256 digest of a file.
# Args:    $1 file path
# Returns: 0 on success; 1 when the file cannot be read; stdout: the hex digest
# Globals: none
deps_sha256_of() {
  local digest
  digest="$(sha256sum -- "$1" 2> /dev/null)" || return 1
  # The digest is the first field of sha256sum's output.
  printf '%s' "${digest%% *}"
}

# deps_download_model — download the model over https and verify its checksum.
# Args:    none
# Returns: 0 when a verified model is in place (also if it already was); 1 on failure
# Globals: reads LID_MODEL_URL, LID_MODEL_SHA256, LID_MODEL_NAME
deps_download_model() {
  local dir target part
  dir="$(pyenv_data_dir)/langid"
  # Download to a .part file first so a crash never leaves a broken model.
  target="$dir/$LID_MODEL_NAME"
  part="$target.part"
  # An already verified file makes the command idempotent.
  [ "$(deps_sha256_of "$target" || true)" = "$LID_MODEL_SHA256" ] && return 0
  # Only https URLs are ever fetched.
  [[ "$LID_MODEL_URL" == https://* ]] || { log "refusing non-https model URL"; return 1; }
  # Create the target directory and announce the small download.
  mkdir -p "$dir"
  log "downloading $LID_MODEL_NAME (938 KB)"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 20 --max-time 120 \
    -o "$part" "$LID_MODEL_URL" || { rm -f "$part"; log "model download failed"; return 1; }
  # A wrong checksum means a corrupted or tampered file: delete it.
  if [ "$(deps_sha256_of "$part" || true)" != "$LID_MODEL_SHA256" ]; then
    rm -f "$part"
    # Tell the user why nothing was installed.
    log "model checksum mismatch, download discarded"
    return 1
  fi
  mv -f "$part" "$target"
}

# deps_pick_python — choose the interpreter used to create the venv.
# Args:    none
# Returns: 0 and the path on stdout; 1 when no python3 exists
# Globals: reads HTTS_DEPS_PYTHON (override, e.g. a python3.13 from uv)
deps_pick_python() {
  local candidate
  # Override first, then the system interpreter (never a shadowing mise/pyenv shim).
  for candidate in "${HTTS_DEPS_PYTHON:-}" /usr/bin/python3 "$(command -v python3 || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# deps_install_packages — install the pinned, hash-checked packages into the venv.
# Args:    $1 venv directory
# Returns: 0 on success; 1 when pip fails (a hint is printed)
# Globals: none
# Notes:   Python 3.14 has no fasttext-predict wheel yet, so pip builds it (needs g++).
deps_install_packages() {
  local venv="$1" requirements
  requirements="$(py_helpers_dir)/requirements.txt"
  # Without the pinned list nothing can be installed safely.
  [ -f "$requirements" ] || { log "missing $requirements"; return 1; }
  # --require-hashes rejects any file whose sha256 is not pinned; --no-deps keeps it exact.
  if ! "$venv/bin/python3" -m pip install --disable-pip-version-check --no-input \
      --require-hashes --no-deps -r "$requirements"; then
    # Give the two usual remedies for a missing wheel.
    log "pip failed. No wheel for this Python? Install a C++ compiler (pacman -S gcc) or"
    log "set HTTS_DEPS_PYTHON to a python3.9-3.13 (e.g. 'uv python install 3.13')."
    return 1
  fi
}

# deps_install_venv — create the private venv and install the packages (idempotent).
# Args:    none
# Returns: 0 when the venv is ready; 1 on failure
# Globals: none
deps_install_venv() {
  local venv python
  venv="$(pyenv_venv_dir)"
  # A finished venv is kept as it is.
  [ -f "$venv/.deps-ok" ] && return 0
  python="$(deps_pick_python)" || { log "python3 not found"; return 1; }
  # A half-built venv from an earlier failure is rebuilt from scratch.
  rm -rf -- "$venv"
  mkdir -p "$(pyenv_data_dir)"
  "$python" -m venv "$venv" || { log "python -m venv failed (python-venv missing?)"; return 1; }
  # Hash-pinned install; a failure leaves no marker file behind.
  deps_install_packages "$venv" || return 1
  # The import check proves the packages really work before the marker is written.
  "$venv/bin/python3" -c 'import fasttext, num2words' || { log "import check failed"; return 1; }
  : > "$venv/.deps-ok"
}

# deps_install — install venv (unless system-wide packages exist) and the model.
# Args:    none
# Returns: 0 when everything is ready; 1 otherwise
# Globals: none
deps_install() {
  # Refuse root: the files would land in root's home and break the user's setup.
  [ "$(id -u)" -ne 0 ] || { log "run deps as your normal user, not root"; return 1; }
  # System-wide AUR packages make the venv unnecessary.
  if system_python_has_deps; then
    log "system-wide fasttext + num2words found, no venv needed"
  else
    deps_install_venv || return 1
  fi
  # The model is installed last because it is small and idempotent.
  deps_download_model || return 1
  log "deps ready: $(pyenv_python)"
}

# deps_status_porcelain — print the helper state as key=value lines for the GUI.
# Args:    none
# Returns: 0 always; stdout: python=, model=, system_packages=, ready=
# Globals: none
deps_status_porcelain() {
  local python="" model="" system_packages=0 ready=0
  # Empty values mean "missing"; the lookups already print nothing on failure.
  python="$(pyenv_python || true)"
  model="$(langid_model_path || true)"
  system_python_has_deps && system_packages=1
  # Ready needs both the interpreter with its packages and the model file.
  [ -z "$python" ] || [ -z "$model" ] || ready=1
  printf 'python=%s\nmodel=%s\nsystem_packages=%s\nready=%s\n' \
    "$python" "$model" "$system_packages" "$ready"
}

# deps_status — report what is installed.
# Args:    $1 <optional --porcelain>
# Returns: 0 when python helpers and the model are both usable (always 0 for --porcelain)
# Globals: none
deps_status() {
  local python="" model="" missing=0
  # The machine-readable form never fails, so a GUI can read it unconditionally.
  [ "${1:-}" != "--porcelain" ] || { deps_status_porcelain; return 0; }
  # Report each component on its own line.
  if python="$(pyenv_python)"; then log "python: $python"; else
    log "python: missing"; missing=1
  fi
  # The model file is the second prerequisite.
  if model="$(langid_model_path)"; then log "model:  $model"; else
    log "model:  missing"; missing=1
  fi
  # System packages make the venv optional.
  if system_python_has_deps; then log "system packages: yes"; else log "system packages: no"; fi
  # The exit code tells scripts whether the helpers are usable.
  return "$missing"
}

# deps_remove — delete the private venv and the downloaded model.
# Args:    none
# Returns: 0 always
# Globals: none
deps_remove() {
  local data
  data="$(pyenv_data_dir)"
  # Only the two known sub-directories are removed, never the data dir itself.
  [ -n "$data" ] && rm -rf -- "$data/venv" "$data/langid"
  rmdir "$data" 2> /dev/null || true
  log "removed helper venv and model"
}

# cmd_deps — `hyprland-tts deps install|status|remove`.
# Args:    $1 subcommand (install, status, remove)
# Returns: 0 on success; 1 on failure; 2 on a usage error
# Globals: none
cmd_deps() {
  local sub="${1:-status}"
  shift || true
  # Each subcommand maps to one function.
  case "$sub" in
    install) deps_install ;;  # create venv + model, idempotent
    status)  deps_status "$@" ;;   # show what is usable right now
    remove)  deps_remove ;;   # delete venv + model
    *) log "usage: hyprland-tts deps [install|status|remove]"; return 2 ;;
  esac
}
