#!/usr/bin/env bash
# tests/test_engine_install.sh — `engine install` argument validation, https-only + sha256
# verification, idempotence, the full flow with fake git/cmake (no network), and removal.
# Test code favours readable assertions over strict shellcheck style (A && B || C, quoting).
# shellcheck disable=SC2119,SC2015,SC2016,SC2010
set -uo pipefail
# shellcheck source=lib/test_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/test_helpers.sh"

# make_assets — create tiny fixture weights plus a matching pin table and point the seams at them.
# Args:    $1 <optional: "bad" to publish a table with a wrong sha for the codec>
# Returns: 0 always
# Globals: reads TEST_ROOT; exports HTTS_QWEN_ASSET_BASE and HTTS_TEST_ASSET_TABLE
make_assets() {
  local role file sha
  mkdir -p "$TEST_ROOT/assets"
  : > "$TEST_ROOT/table"
  for role in customvoice base codec; do
    file="$(lib_eval "qwen3_model_file $role")"
    printf 'fixture-%s' "$role" > "$TEST_ROOT/assets/$file"
    sha="$(sha256sum "$TEST_ROOT/assets/$file" | cut -d' ' -f1)"
    [ "$1" = "bad" ] && [ "$role" = "codec" ] && sha="$(printf '0%.0s' $(seq 64))"
    printf '%s|%s|%s|1\n' "$role" "$file" "$sha" >> "$TEST_ROOT/table"
  done
  export HTTS_QWEN_ASSET_BASE="file://$TEST_ROOT/assets" HTTS_TEST_ASSET_TABLE="$TEST_ROOT/table"
}

# make_fake_toolchain — fake git and cmake that "build" the fake server, logging every call.
# Args:    none
# Returns: 0 always
# Globals: reads TEST_ROOT, TEST_REPO_DIR; exports FAKE_BUILD_LOG
make_fake_toolchain() {
  export FAKE_BUILD_LOG="$TEST_ROOT/build.log" FAKE_SERVER_SRC="$TEST_REPO_DIR/tests/lib/fake_tts_server.py"
  cat > "$TEST_ROOT/fakebin/git" <<'FAKE'
#!/usr/bin/env bash
echo "git $*" >> "$FAKE_BUILD_LOG"
dir="."
while [ "$#" -gt 0 ]; do
  case "$1" in -C) dir="$2"; shift 2 ;; -c) shift 2 ;; *) break ;; esac
done
case "$1" in
  init) mkdir -p "${@: -1}" ;;
  fetch) printf '%s' "${@: -1}" > "$dir/.fake_commit" ;;
  rev-parse) printf '%s\n' "${FAKE_GIT_HEAD:-$(cat "$dir/.fake_commit")}" ;;
esac
exit 0
FAKE
  cat > "$TEST_ROOT/fakebin/cmake" <<'FAKE'
#!/usr/bin/env bash
echo "cmake $*" >> "$FAKE_BUILD_LOG"
if [ "$1" = "--build" ]; then
  build="$2"
  printf '[ 50%%] Building CXX object fake.o\n'
  sleep "${FAKE_BUILD_SLEEP:-0}"
  cp "$FAKE_SERVER_SRC" "$build/tts-server"
  printf '#!/bin/sh\nexit 0\n' > "$build/qwen-codec"
  touch "$build/libggml.so.0.29.0"
  ln -sf libggml.so.0.29.0 "$build/libggml.so.0"
  chmod +x "$build/tts-server" "$build/qwen-codec"
else
  while [ "$#" -gt 0 ]; do [ "$1" = "-B" ] && mkdir -p "$2"; shift; done
fi
exit 0
FAKE
  chmod +x "$TEST_ROOT/fakebin/git" "$TEST_ROOT/fakebin/cmake"
}

# case_install_argument_validation — typos never start a download or a build.
# Args:    none
# Returns: 0 always
# Globals: none
case_install_argument_validation() {
  htts engine install >/dev/null 2>&1;                        assert_rc 1 "$?" "no engine name"
  htts engine install piper >/dev/null 2>&1;                  assert_rc 1 "$?" "wrong engine name"
  htts engine install qwen3 --bogus >/dev/null 2>&1;          assert_rc 1 "$?" "unknown option"
  htts engine install qwen3 --variant huge >/dev/null 2>&1;   assert_rc 1 "$?" "invalid variant"
  htts engine install qwen3 --variant >/dev/null 2>&1;        assert_rc 1 "$?" "variant without value"
  htts engine remove piper >/dev/null 2>&1;                   assert_rc 1 "$?" "remove wrong engine"
  assert_no_file "$XDG_DATA_HOME/hyprland-tts/engines/qwentts" "nothing created by failed installs"
}

# case_sha256_mismatch_is_rejected — a corrupted download never lands in the models directory.
# Args:    none
# Returns: 0 always
# Globals: none
case_sha256_mismatch_is_rejected() {
  make_assets bad
  local out target
  out="$(lib_eval 'qwen3_download_model codec' 2>&1)"
  assert_rc 1 "$?" "download with wrong pin fails"
  assert_contains "$out" "sha256 mismatch" "error names the problem"
  target="$(lib_eval 'qwen3_model_path codec')"
  assert_no_file "$target" "file not installed"
  assert_no_file "$target.part" "part file removed"
}

# case_download_verified_and_idempotent — a good file installs; a second run does not refetch.
# Args:    none
# Returns: 0 always
# Globals: none
case_download_verified_and_idempotent() {
  make_assets good
  lib_eval 'qwen3_download_model codec' >/dev/null 2>&1
  assert_rc 0 "$?" "verified download"
  local target; target="$(lib_eval 'qwen3_model_path codec')"
  assert_eq "fixture-codec" "$(cat "$target")" "content installed"
  rm -rf "$TEST_ROOT/assets"
  local out; out="$(lib_eval 'qwen3_download_model codec' 2>&1)"
  assert_rc 0 "$?" "second run works with the source gone"
  assert_contains "$out" "already present and verified" "skipped the download"
  printf 'tampered' > "$target"
  lib_eval 'qwen3_download_model codec' >/dev/null 2>&1
  assert_rc 1 "$?" "a tampered local file is re-downloaded and fails without a source"
}

# case_non_https_urls_are_refused — plain http and file URLs need the explicit test seam.
# Args:    none
# Returns: 0 always
# Globals: none
case_non_https_urls_are_refused() {
  lib_eval "qwen3_fetch_verified http://example.com/x $(printf 'a%.0s' $(seq 64)) '$TEST_ROOT/x'" >/dev/null 2>&1
  assert_rc 1 "$?" "http refused"
  lib_eval "qwen3_fetch_verified file:///etc/hostname $(printf 'a%.0s' $(seq 64)) '$TEST_ROOT/x'" >/dev/null 2>&1
  assert_rc 1 "$?" "file:// refused without the seam"
  lib_eval "qwen3_fetch_verified 'https://huggingface.co/a b' $(printf 'a%.0s' $(seq 64)) '$TEST_ROOT/x'" >/dev/null 2>&1
  assert_rc 1 "$?" "malformed https URL refused"
  assert_no_file "$TEST_ROOT/x" "nothing downloaded"
}

# case_pins_are_complete — the built-in table pins all three files with 64-hex digests.
# Args:    none
# Returns: 0 always
# Globals: none
case_pins_are_complete() {
  local role
  for role in customvoice base codec; do
    [[ "$(lib_eval "qwen3_asset_field $role 3")" =~ ^[0-9a-f]{64}$ ]] &&
      test_pass "$role has a sha256 pin" || test_fail "$role has a sha256 pin"
  done
  assert_eq "de2ad833e9bd5c06082231d1da637789f7562816" "$(lib_eval 'printf %s "$QWEN_CPP_COMMIT"')" "engine commit pinned"
  assert_contains "$(lib_eval 'qwen3_asset_base')" "/resolve/b7ee2e8c7459c3bea99da23e3d178125a7d1713c" "HF revision pinned"
  assert_contains "$(lib_eval 'qwen3_asset_base')" "https://" "weights come over https"
}

# case_missing_tools_are_reported_with_packages — the dependency message names Arch packages.
# Args:    none
# Returns: 0 always
# Globals: none
case_missing_tools_are_reported_with_packages() {
  local missing
  missing="$(lib_eval 'PATH=/nonexistent; qwen3_missing_tools vulkan')"
  assert_contains "$missing" "cmake(cmake)" "cmake reported"
  assert_contains "$missing" "git(git)" "git reported"
  assert_contains "$missing" "glslc(shaderc)" "glslc reported for vulkan"
  missing="$(lib_eval 'PATH=/nonexistent; qwen3_missing_tools cpu')"
  assert_not_contains "$missing" "glslc" "glslc not required for cpu"
}

# case_full_install_flow — fake toolchain: weights verified, binaries published, config updated.
# Args:    none
# Returns: 0 always
# Globals: none
case_full_install_flow() {
  make_assets good
  make_fake_toolchain
  local out tree
  out="$(htts engine install qwen3 --cpu --variant customvoice 2>&1)"
  assert_rc 0 "$?" "install succeeds"
  tree="$(test_engine_tree)"
  assert_file "$tree/bin/tts-server" "tts-server published"
  assert_file "$tree/bin/qwen-codec" "qwen-codec published"
  [ -L "$tree/bin/libggml.so.0" ] && test_pass "shared library symlinks preserved" || test_fail "shared library symlinks preserved"
  assert_eq "BUILD=cpu
DEVICE=CPU" "$(cat "$tree/engine.conf")" "engine.conf records the build"
  assert_file "$tree/models/$(lib_eval 'qwen3_model_file customvoice')" "talker installed"
  assert_file "$tree/models/$(lib_eval 'qwen3_model_file codec')" "codec installed"
  assert_no_file "$tree/.work" "build tree removed"
  assert_contains "$(cat "$FAKE_BUILD_LOG")" "fetch -q --depth 1 origin de2ad833e9bd5c06082231d1da637789f7562816" "pinned commit fetched"
  assert_contains "$(cat "$FAKE_BUILD_LOG")" "-DGGML_BLAS=OFF" "BLAS disabled"
  assert_contains "$(cat "$FAKE_BUILD_LOG")" 'CMAKE_BUILD_RPATH=$ORIGIN' "relocatable rpath"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VARIANT=customvoice" "variant stored"
  assert_contains "$(htts engine status)" "active:   qwen3" "engine usable afterwards"
  assert_contains "$out" "Done." "completion message"
}

# case_install_defaults_to_base — without --variant the Base talker is fetched and selected.
# Args:    none
# Returns: 0 always
# Globals: none
case_install_defaults_to_base() {
  make_assets good
  make_fake_toolchain
  htts engine install qwen3 --cpu >/dev/null 2>&1
  assert_rc 0 "$?" "install succeeds"
  assert_file "$(test_engine_tree)/models/$(lib_eval 'qwen3_model_file base')" "base talker installed"
  assert_contains "$(cat "$XDG_CONFIG_HOME/piper-tts/config")" "QWEN_VARIANT=base" "base stored"
  assert_contains "$(htts engine status)" "active:   qwen3" "usable without any clone"
}

# case_install_prints_progress_lines — downloads and the compile report on stderr (GUI streams it).
# Args:    none
# Returns: 0 always
# Globals: none
case_install_prints_progress_lines() {
  make_assets good
  make_fake_toolchain
  # A slow curl and a slow build make the polling loops fire at least once.
  printf '#!/bin/sh\nsleep 1.5\nexec %s "$@"\n' "$(command -v curl)" > "$TEST_ROOT/fakebin/curl"
  chmod +x "$TEST_ROOT/fakebin/curl"
  local out
  out="$(FAKE_BUILD_SLEEP=2.5 QWEN_PROGRESS_INTERVAL=1 htts engine install qwen3 --cpu 2>&1 >/dev/null)"
  assert_rc 0 "$?" "install succeeds"
  assert_contains "$out" "progress: qwen-talker-0.6b-base-Q8_0.gguf" "download progress line"
  assert_contains "$out" "progress: compiling build ... 50%" "compile heartbeat with percentage"
}

# case_install_is_idempotent — a second install rebuilds nothing and refetches nothing.
# Args:    none
# Returns: 0 always
# Globals: none
case_install_is_idempotent() {
  make_assets good
  make_fake_toolchain
  htts engine install qwen3 --cpu >/dev/null 2>&1
  local calls_before; calls_before="$(wc -l < "$FAKE_BUILD_LOG")"
  rm -rf "$TEST_ROOT/assets"
  local out; out="$(htts engine install qwen3 --cpu 2>&1)"
  assert_rc 0 "$?" "second install succeeds"
  assert_eq "$calls_before" "$(wc -l < "$FAKE_BUILD_LOG")" "no git/cmake call the second time"
  assert_contains "$out" "cpu build already installed" "build reused"
}

# case_install_stops_on_bad_weights — a hash mismatch aborts before any compile starts.
# Args:    none
# Returns: 0 always
# Globals: none
case_install_stops_on_bad_weights() {
  make_assets bad
  make_fake_toolchain
  htts engine install qwen3 --cpu >/dev/null 2>&1
  assert_rc 1 "$?" "install aborts"
  assert_no_file "$FAKE_BUILD_LOG" "compiler never ran"
  assert_no_file "$(test_engine_tree)/bin/tts-server" "no half install"
}

# case_wrong_commit_is_rejected — a checkout that is not the pinned commit aborts the build.
# Args:    none
# Returns: 0 always
# Globals: none
case_wrong_commit_is_rejected() {
  make_assets good
  make_fake_toolchain
  FAKE_GIT_HEAD="1111111111111111111111111111111111111111" htts engine install qwen3 --cpu >/dev/null 2>&1
  assert_rc 1 "$?" "unexpected commit refused"
  assert_no_file "$(test_engine_tree)/bin/tts-server" "nothing published"
}

# case_remove_deletes_engine_keeps_voices — remove wipes engines but not cloned voices.
# Args:    none
# Returns: 0 always
# Globals: none
case_remove_deletes_engine_keeps_voices() {
  test_install_fake_engine
  mkdir -p "$XDG_DATA_HOME/hyprland-tts/voices/mine"
  htts engine start >/dev/null 2>&1
  htts engine remove qwen3 >/dev/null 2>&1
  assert_rc 0 "$?" "remove"
  assert_no_file "$XDG_DATA_HOME/hyprland-tts/engines/qwentts" "engine tree gone"
  [ -d "$XDG_DATA_HOME/hyprland-tts/voices/mine" ] && test_pass "cloned voices kept" || test_fail "cloned voices kept"
  assert_contains "$(htts engine status)" "worker:   stopped" "worker stopped by remove"
}

test_run_cases
