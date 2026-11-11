#!/usr/bin/env bash
# tests/test_pyenv.sh — interpreter/model discovery and the model download of `deps`.
#
# Offline: a stub `curl` on PATH serves a tiny fixture, and the expected checksum is
# overridden for the test, so the real 938 KB model and the network are never touched.
# The pip install of the venv is NOT exercised here (it needs network and a compiler);
# it was verified by hand, see the final report.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

# t_pass — record a passing check.
# Args:    $1 description
# Returns: 0 always
# Globals: writes PASS
t_pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }

# t_fail — record a failing check.
# Args:    $1 description | $2 detail (optional)
# Returns: 0 always
# Globals: writes FAIL
t_fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s %s\n' "$1" "${2:-}"; }

# assert_eq — compare two strings.
# Args:    $1 expected | $2 actual | $3 description
# Returns: 0 always
# Globals: none
assert_eq() {
  if [ "$1" = "$2" ]; then t_pass "$3"; else t_fail "$3" "(expected '$1', got '$2')"; fi
}

# assert_rc — compare an exit status.
# Args:    $1 expected | $2 actual | $3 description
# Returns: 0 always
# Globals: none
assert_rc() { assert_eq "$1" "$2" "$3 (exit status)"; }

# setup_sandbox — isolated HOME/XDG tree, libraries and a stub curl.
# Args:    none
# Returns: 0 always
# Globals: writes SANDBOX, FIXTURE, CURL_LOG and PATH
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home" XDG_DATA_HOME="$SANDBOX/data" XDG_CACHE_HOME="$SANDBOX/cache"
  mkdir -p "$HOME" "$SANDBOX/bin"
  unset HTTS_PYTHON HTTS_LID_MODEL HTTS_PY_DIR LIBDIR
  FIXTURE="$SANDBOX/fixture.ftz"
  CURL_LOG="$SANDBOX/curl.log"
  printf 'tiny model fixture' > "$FIXTURE"
  # The stub copies the fixture to the -o target and records the full command line.
  cat > "$SANDBOX/bin/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$CURL_LOG"
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && cp "${FIXTURE_SOURCE:-$FIXTURE}" "\$2"; shift; done
STUB
  chmod +x "$SANDBOX/bin/curl"
  PATH="$SANDBOX/bin:$PATH"
  # shellcheck source=/dev/null
  for module in common pyenv; do source "$REPO/lib/$module.sh"; done
}

# test_paths — data dir, venv dir and helper dir resolution.
# Args:    none
# Returns: 0 always
# Globals: none
test_paths() {
  assert_eq "$XDG_DATA_HOME/hyprland-tts" "$(pyenv_data_dir)" "data dir follows XDG_DATA_HOME"
  assert_eq "$XDG_DATA_HOME/hyprland-tts/venv" "$(pyenv_venv_dir)" "venv lives in the data dir"
  assert_eq "$REPO/lib/py" "$(py_helpers_dir)" "helper dir defaults to the checkout"
  assert_eq "/x/py" "$(HTTS_PY_DIR=/x/py py_helpers_dir)" "HTTS_PY_DIR override"
  mkdir -p "$SANDBOX/lib/py"
  assert_eq "$SANDBOX/lib/py" "$(LIBDIR="$SANDBOX/lib" py_helpers_dir)" "installed LIBDIR/py is used"
}

# test_pyenv_python — override, venv marker and "nothing usable".
# Args:    none
# Returns: 0 always
# Globals: none
test_pyenv_python() {
  local venv rc
  venv="$(pyenv_venv_dir)"
  # Without override, venv or system packages there is no interpreter (CI/dev boxes may differ).
  if ! system_python_has_deps; then
    pyenv_python > /dev/null
    assert_rc 1 "$?" "no venv, no system packages -> not usable"
  fi
  mkdir -p "$venv/bin"
  printf '#!/bin/sh\n' > "$venv/bin/python3"
  chmod +x "$venv/bin/python3"
  if ! system_python_has_deps; then
    pyenv_python > /dev/null
    assert_rc 1 "$?" "venv without marker is not trusted"
  fi
  : > "$venv/.deps-ok"
  assert_eq "$venv/bin/python3" "$(pyenv_python)" "venv with marker is used"
  assert_eq "$SANDBOX/bin/curl" "$(HTTS_PYTHON="$SANDBOX/bin/curl" pyenv_python)" "HTTS_PYTHON override wins"
  HTTS_PYTHON=/nonexistent pyenv_python > /dev/null
  rc=$?
  assert_rc 1 "$rc" "non-executable override means no Python"
}

# test_model_search_order — override, user dir, system dir.
# Args:    none
# Returns: 0 always
# Globals: none
test_model_search_order() {
  local user_model
  user_model="$(pyenv_data_dir)/langid/$LID_MODEL_NAME"
  if [ ! -f "$LID_MODEL_SYSTEM_DIR/$LID_MODEL_NAME" ]; then
    langid_model_path > /dev/null
    assert_rc 1 "$?" "no model anywhere -> failure"
  fi
  mkdir -p "$(dirname "$user_model")"
  : > "$user_model"
  assert_eq "$user_model" "$(langid_model_path)" "user data dir model is found"
  assert_eq "$FIXTURE" "$(HTTS_LID_MODEL="$FIXTURE" langid_model_path)" "HTTS_LID_MODEL wins"
  rm -rf "$(pyenv_data_dir)"
}

# test_download_model — verified download, idempotence, mismatch and https-only.
# Args:    none
# Returns: 0 always
# Globals: writes LID_MODEL_SHA256, LID_MODEL_URL
test_download_model() {
  local target calls
  target="$(pyenv_data_dir)/langid/$LID_MODEL_NAME"
  LID_MODEL_SHA256="$(deps_sha256_of "$FIXTURE")"
  deps_download_model 2> /dev/null
  assert_rc 0 "$?" "download with matching checksum succeeds"
  assert_eq "$(cat "$FIXTURE")" "$(cat "$target")" "model file is in place"
  assert_eq "1" "$(grep -c -- '--proto =https' "$CURL_LOG")" "curl is restricted to https"
  deps_download_model 2> /dev/null
  calls="$(wc -l < "$CURL_LOG")"
  assert_eq "1" "$calls" "second run is idempotent (no second download)"
  rm -f "$target"
  LID_MODEL_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  deps_download_model 2> /dev/null
  assert_rc 1 "$?" "checksum mismatch fails"
  assert_eq "no" "$([ -e "$target" ] && echo yes || echo no)" "mismatching download is discarded"
  assert_eq "no" "$([ -e "$target.part" ] && echo yes || echo no)" "no .part file is left behind"
  LID_MODEL_URL='http://example.com/lid.176.ftz'
  : > "$CURL_LOG"
  deps_download_model 2> /dev/null
  assert_rc 1 "$?" "non-https URL is refused"
  assert_eq "0" "$(wc -l < "$CURL_LOG")" "curl is not called for a non-https URL"
}

# test_status_and_remove — status exit code and removal.
# Args:    none
# Returns: 0 always
# Globals: none
test_status_and_remove() {
  local data
  data="$(pyenv_data_dir)"
  mkdir -p "$data/venv/bin" "$data/langid"
  : > "$data/langid/$LID_MODEL_NAME"
  cmd_deps remove 2> /dev/null
  assert_eq "no" "$([ -e "$data/venv" ] || [ -e "$data/langid" ] && echo yes || echo no)" "remove deletes venv and model"
  cmd_deps bogus 2> /dev/null
  assert_rc 2 "$?" "unknown subcommand is a usage error"
  if ! system_python_has_deps; then
    cmd_deps status 2> /dev/null
    assert_rc 1 "$?" "status reports missing components with exit 1"
  fi
}

# test_status_porcelain — key=value output for the GUI, never a failing status.
# Args:    none
# Returns: 0 always
# Globals: none
test_status_porcelain() {
  local out
  out="$(HTTS_PYTHON="$SANDBOX/bin/curl" HTTS_LID_MODEL="$FIXTURE" cmd_deps status --porcelain)"
  assert_eq "python=$SANDBOX/bin/curl
model=$FIXTURE
system_packages=$(system_python_has_deps && echo 1 || echo 0)
ready=1" "$out" "porcelain with python and model"
  out="$(HTTS_PYTHON=/nonexistent HTTS_LID_MODEL="$FIXTURE" cmd_deps status --porcelain)"
  assert_eq "ready=0" "$(printf '%s\n' "$out" | grep '^ready=')" "no python -> ready=0"
  assert_eq "python=" "$(printf '%s\n' "$out" | grep '^python=')" "missing python is empty"
  HTTS_PYTHON=/nonexistent cmd_deps status --porcelain > /dev/null
  assert_rc 0 "$?" "porcelain status always succeeds"
}

# test_install_refuses_root — deps install must never run as root.
# Args:    none
# Returns: 0 always
# Globals: none
test_install_refuses_root() {
  printf '#!/bin/sh\necho 0\n' > "$SANDBOX/bin/id"
  chmod +x "$SANDBOX/bin/id"
  deps_install 2> /dev/null
  assert_rc 1 "$?" "deps install refuses to run as root"
  rm -f "$SANDBOX/bin/id"
}

# test_import_check_is_real_and_cached — a venv that cannot import is not trusted; verdicts cache.
# Args:    none
# Returns: 0 always
# Globals: none
test_import_check_is_real_and_cached() {
  local broken="$SANDBOX/broken-python" venv
  # An interpreter whose "import fasttext, num2words" fails (a stale venv after a Python upgrade).
  printf '#!/bin/sh\necho x >> "%s/probe.log"\nexit 1\n' "$SANDBOX" > "$broken"
  chmod +x "$broken"
  pyenv_import_ok "$broken"
  assert_rc 1 "$?" "failing import is detected"
  pyenv_import_ok "$broken"
  assert_eq "1" "$(wc -l < "$SANDBOX/probe.log")" "the verdict is cached (one probe for two calls)"
  # A changed interpreter (new modification time) is probed again, and may now succeed.
  printf '#!/bin/sh\nexit 0\n' > "$broken"
  touch -d '1 hour ago' "$broken"
  pyenv_import_ok "$broken"
  assert_rc 0 "$?" "a fixed interpreter passes after the change"
  # pyenv_python distrusts a marked venv whose interpreter cannot import the packages.
  venv="$(pyenv_venv_dir)"
  mkdir -p "$venv/bin"
  printf '#!/bin/sh\nexit 1\n' > "$venv/bin/python3"
  chmod +x "$venv/bin/python3"
  : > "$venv/.deps-ok"
  if ! system_python_has_deps; then
    pyenv_python > /dev/null
    assert_rc 1 "$?" "stale venv with marker is not used"
  fi
  rm -rf "$venv"
}

# main — run every check and print a summary.
# Args:    none
# Returns: 0 when nothing failed; 1 otherwise
# Globals: reads PASS, FAIL, SANDBOX
main() {
  setup_sandbox
  trap 'rm -rf "$SANDBOX"' EXIT
  test_paths
  test_pyenv_python
  test_model_search_order
  test_download_model
  test_status_and_remove
  test_status_porcelain
  test_import_check_is_real_and_cached
  test_install_refuses_root
  printf '\ntest_pyenv: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

main "$@"
