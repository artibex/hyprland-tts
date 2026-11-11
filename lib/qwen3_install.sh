#!/usr/bin/env bash
# lib/qwen3_install.sh — user-space install of the Qwen3-TTS engine: a pinned qwentts.cpp
# build (Vulkan or CPU) plus sha256-verified GGUF weights, all below $XDG_DATA_HOME.
# Nothing here needs root; missing build tools are reported with the package to install.

# Pinned source of the engine; the commit is verified after the shallow fetch.
QWEN_CPP_REPO="https://github.com/ServeurpersoCom/qwentts.cpp"
# Pinned Hugging Face repository and revision of the Apache-2.0 GGUF weights.
QWEN_HF_REPO="https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF"
QWEN_HF_REVISION="b7ee2e8c7459c3bea99da23e3d178125a7d1713c"
# SHA-256 of every weight file, keyed by role; downloads are rejected on any mismatch.
declare -gA QWEN3_SHA256=(
  [customvoice]="4eb38675c736ed6ac72012846ac8d6ef80e5af8bc05726870f0b3a6569588519"
  [base]="d54dbaf10591421fa764ed630d764efa717ae40cd959bd48c66d4eb1af226426"
  # The codec is needed by every variant.
  [codec]="1883beeed99348fc35e23dd225e9082f93f6f8c109330a33d935baa8acdbfd94"
)
# Byte size of every weight file, keyed by role; only used for progress percentages.
declare -gA QWEN3_BYTES=(
  [customvoice]=968588544 [base]=992615488 [codec]=291150624
)
# Seconds between progress lines of a download or compile run without a terminal.
QWEN_PROGRESS_INTERVAL="${QWEN_PROGRESS_INTERVAL:-5}"
# Khronos headers, fetched only when the system has none (pinned tag and its commit).
VULKAN_HEADERS_REPO="https://github.com/KhronosGroup/Vulkan-Headers"
VULKAN_HEADERS_COMMIT="88487f687f3100ebe1d3559a8a34d971ee85b977"
SPIRV_HEADERS_REPO="https://github.com/KhronosGroup/SPIRV-Headers"
# The commit, not the movable tag, is what gets verified after cloning.
SPIRV_HEADERS_COMMIT="496543121ce6419f23d6fa5d7194ba66c36212d2"

# qwen3_asset_lines — print the pinned weight table.
# Args:    none
# Returns: 0 always; stdout: lines "<role>|<file>|<sha256>|<bytes>"
# Globals: reads QWEN3_SHA256, HTTS_TEST_ASSET_TABLE (test seam: alternative table file)
qwen3_asset_lines() {
  local role
  # The test seam lets the suite exercise the installer with tiny fixture files.
  if [ -n "${HTTS_TEST_ASSET_TABLE:-}" ]; then cat -- "$HTTS_TEST_ASSET_TABLE"; return 0; fi
  for role in customvoice base codec; do
    printf '%s|%s|%s|%s\n' "$role" "$(qwen3_model_file "$role")" "${QWEN3_SHA256[$role]}" \
      "${QWEN3_BYTES[$role]}"
  done
}

# qwen3_asset_field — read one column of a role's row in the weight table.
# Args:    $1 <role>; $2 <field number: 2=file 3=sha256 4=bytes>
# Returns: 0 when the role exists; 1 otherwise; stdout: the field value
# Globals: none
qwen3_asset_field() {
  local value
  # No early awk exit: under pipefail it would SIGPIPE the producer and abort the caller.
  value="$(qwen3_asset_lines |
    awk -F'|' -v role="$1" -v col="$2" '$1==role && !seen{print $col; seen=1}')"
  # An empty answer means the role is not in the table.
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# qwen3_asset_base — print the base URL weights are downloaded from.
# Args:    none
# Returns: 0 always; stdout: URL prefix without trailing slash
# Globals: reads HTTS_QWEN_ASSET_BASE (test seam), QWEN_HF_REPO, QWEN_HF_REVISION
qwen3_asset_base() {
  # The override stays hash-checked, so it cannot smuggle in different weights.
  printf '%s' "${HTTS_QWEN_ASSET_BASE:-$QWEN_HF_REPO/resolve/$QWEN_HF_REVISION}"
}

# qwen3_url_protocols — print the curl --proto value allowed for downloads.
# Args:    none
# Returns: 0 always; stdout: curl protocol list
# Globals: reads HTTS_QWEN_ASSET_BASE
qwen3_url_protocols() {
  # Production is https only; the test seam additionally allows local fixtures.
  if [ -n "${HTTS_QWEN_ASSET_BASE:-}" ]; then printf '=https,file,http'; else printf '=https'; fi
}

# qwen3_url_allowed — check a download URL against the active protocol policy.
# Args:    $1 <url>
# Returns: 0 when allowed; 1 otherwise
# Globals: reads HTTS_QWEN_ASSET_BASE
qwen3_url_allowed() {
  # LC_ALL=C keeps the character ranges ASCII-only (UTF-8 ranges would also match letters like "ä").
  local LC_ALL=C
  # https is always fine; local fixtures only count when the test seam is set.
  [[ "$1" =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'\(\)\*\+,\;=%-]+$ ]] && return 0
  [ -n "${HTTS_QWEN_ASSET_BASE:-}" ] && [[ "$1" =~ ^(file:///|http://127\.0\.0\.1[:/]) ]]
}

# qwen3_file_sha256 — print the SHA-256 of a file.
# Args:    $1 <path>
# Returns: 0 on success; 1 when unreadable; stdout: lowercase hex digest
# Globals: none
qwen3_file_sha256() {
  local digest
  digest="$(sha256sum -- "$1" 2>/dev/null)" || return 1
  # sha256sum prints "<digest>  <name>"; only the digest is wanted.
  printf '%s' "${digest%% *}"
}

# qwen3_megabytes — format a byte count as whole megabytes.
# Args:    $1 <bytes>
# Returns: 0 always; stdout: e.g. "512 MB"
# Globals: none
qwen3_megabytes() {
  printf '%s MB' "$(( ${1:-0} / 1048576 ))"
}

# qwen3_progress_line — print one download progress line to stderr.
# Args:    $1 <label>; $2 <part file>; $3 <expected bytes or 0>
# Returns: 0 always
# Globals: none
qwen3_progress_line() {
  local size
  size="$(stat -c %s "$2" 2>/dev/null || echo 0)"
  # With a known total the line carries a percentage the GUI can turn into a bar.
  if [ "${3:-0}" -gt 0 ]; then
    log "  progress: $1 $(qwen3_megabytes "$size") of $(qwen3_megabytes "$3")" \
      "($(( size * 100 / $3 ))%)"
  else
    log "  progress: $1 $(qwen3_megabytes "$size")"
  fi
}

# qwen3_curl_download — run the download; on a terminal with curl's bar, else with progress lines.
# Args:    $1 <url>; $2 <part file>; $3 <expected bytes or 0>
# Returns: curl's exit status
# Globals: reads QWEN_PROGRESS_INTERVAL
qwen3_curl_download() {
  local curl_pid
  local -a curl_args=(-fL --retry 3 --connect-timeout 20 --proto "$(qwen3_url_protocols)"
    --proto-redir '=https' -C - -o "$2" "$1")
  # A terminal gets curl's own progress bar; everything else gets one line per interval.
  if [ -t 2 ]; then curl --progress-bar "${curl_args[@]}"; return; fi
  curl -sS "${curl_args[@]}" &
  curl_pid=$!
  # Report only while the transfer is still running.
  while kill -0 "$curl_pid" 2>/dev/null; do
    sleep "$QWEN_PROGRESS_INTERVAL"
    # The download may finish during the sleep; only report while it still runs.
    ! kill -0 "$curl_pid" 2>/dev/null || qwen3_progress_line "$(basename "$2" .part)" "$2" "$3"
  done
  wait "$curl_pid"
}

# qwen3_fetch_verified — download a file over https and keep it only if the SHA-256 matches.
# Args:    $1 <url>; $2 <expected sha256>; $3 <destination path>; $4 <expected bytes, optional>
# Returns: 0 when stored; exits 1 via die on a bad URL, failed download or hash mismatch
# Globals: reads HTTS_QWEN_ASSET_BASE
qwen3_fetch_verified() {
  local url="$1" expected="$2" dest="$3" part="$3.part" actual
  qwen3_url_allowed "$url" || die "refusing non-https or malformed URL: $url"
  # --proto-redir keeps a hostile redirect from downgrading to http; -C - resumes a part file.
  qwen3_curl_download "$url" "$part" "${4:-0}" || { rm -f "$part"; die "download failed: $url"; }
  actual="$(qwen3_file_sha256 "$part")" || die "cannot hash $part"
  # A mismatch means a corrupted or substituted file: never let it into place.
  [ "$actual" = "$expected" ] || { rm -f "$part"; die "sha256 mismatch for $(basename "$dest")"; }
  mv -f -- "$part" "$dest"
}

# qwen3_download_model — fetch one weight file unless a verified copy is already there.
# Args:    $1 <role: customvoice|base|codec>
# Returns: 0 when the verified file is in place; exits 1 via die on failure
# Globals: reads ENGINES_DIR
qwen3_download_model() {
  local file_name expected target
  file_name="$(qwen3_asset_field "$1" 2)" || die "unknown model role: $1"
  # Both columns come from the same table row, so they cannot disagree.
  expected="$(qwen3_asset_field "$1" 3)"
  target="$(qwen3_model_path "$1")"
  mkdir -p "$(dirname "$target")"
  # Re-hashing a present file makes the install idempotent and self-healing.
  if [ -f "$target" ] && [ "$(qwen3_file_sha256 "$target")" = "$expected" ]; then
    log "  $file_name already present and verified"
    return 0
  fi
  # Progress feedback: the files are several hundred megabytes.
  log "  downloading $file_name ..."
  qwen3_fetch_verified "$(qwen3_asset_base)/$file_name" "$expected" "$target" \
    "$(qwen3_asset_field "$1" 4 || echo 0)"
}

# qwen3_parse_install_args — validate the arguments of `engine install`.
# Args:    $1 <engine, must be qwen3>; then optional --cpu|--vulkan and --variant <name>
# Returns: 0 on success; exits 1 via die on bad input; stdout: "<build> <variant>"
# Globals: reads QWEN_VARIANT
qwen3_parse_install_args() {
  local build="auto" variant="$QWEN_VARIANT"
  [ "${1:-}" = "qwen3" ] ||
    # Show the full syntax because this is the most likely user mistake.
    die "usage: hyprland-tts engine install qwen3 [--cpu|--vulkan] [--variant base|customvoice]"
  shift
  while [ "$#" -gt 0 ]; do
    # Options may come in any order; each one consumes its own arguments.
    case "$1" in
      --cpu) build="cpu" ;;
      --vulkan) build="vulkan" ;;
      # The value follows the flag, so it is validated and then skipped.
      --variant) [ "$#" -ge 2 ] || die "--variant needs a value"; variant="$2"; shift ;;
      *) die "unknown option for engine install: $1" ;;
    esac
    shift
  done
  # Only the two model families that exist may be installed.
  case "$variant" in
    base|customvoice) ;;
    *) die "invalid variant '$variant' (base|customvoice)" ;;
  esac
  # Two words on stdout; the caller splits them with read.
  printf '%s %s' "$build" "$variant"
}

# qwen3_have_libvulkan_dev — tell whether the Vulkan loader's development symlink exists.
# Args:    none
# Returns: 0 when libvulkan.so is installed; 1 otherwise
# Globals: none
qwen3_have_libvulkan_dev() {
  local dir
  # CMake's find_package(Vulkan) links against the unversioned libvulkan.so.
  for dir in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/local/lib; do
    [ -e "$dir/libvulkan.so" ] && return 0
  done
  return 1
}

# qwen3_vulkan_usable — decide whether a Vulkan build is worth trying on this machine.
# Args:    none
# Returns: 0 when loader, a GPU driver (ICD) and glslc are present; 1 otherwise
# Globals: none
qwen3_vulkan_usable() {
  local icd_dir found_icd=1
  # Without an installed ICD json there is no Vulkan driver, so the GPU path cannot run.
  for icd_dir in /usr/share/vulkan/icd.d /etc/vulkan/icd.d; do
    compgen -G "$icd_dir/*.json" >/dev/null && found_icd=0
  done
  # The shader compiler is a hard build requirement of ggml-vulkan.
  [ "$found_icd" -eq 0 ] && qwen3_have_libvulkan_dev && have glslc
}

# qwen3_system_vulkan_headers — tell whether the system provides Vulkan and SPIR-V headers.
# Args:    none
# Returns: 0 when both header sets and the SPIRV-Headers cmake config exist; 1 otherwise
# Globals: none
qwen3_system_vulkan_headers() {
  # All three are needed: vulkan.h, spirv.hpp and the cmake package ggml looks up.
  [ -f /usr/include/vulkan/vulkan.h ] && [ -f /usr/include/spirv/unified1/spirv.hpp ] &&
    { [ -f /usr/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake ] ||
      [ -f /usr/lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake ]; }
}

# qwen3_missing_tools — list the build tools that are not installed, as "tool(package)".
# Args:    $1 <build: cpu|vulkan>
# Returns: 0 always; stdout: space-separated entries, empty when nothing is missing
# Globals: none
qwen3_missing_tools() {
  local missing="" entry tool
  # tool:package pairs, so the message can name the Arch package to install.
  for entry in git:git cmake:cmake gcc:gcc g++:gcc make:make curl:curl sha256sum:coreutils \
    flock:util-linux; do
    tool="${entry%%:*}"
    have "$tool" || missing="$missing $tool(${entry#*:})"
  done
  # Vulkan additionally needs the shader compiler and the loader's dev symlink.
  if [ "$1" = "vulkan" ]; then
    have glslc || missing="$missing glslc(shaderc)"
    qwen3_have_libvulkan_dev || missing="$missing libvulkan(vulkan-icd-loader)"
  fi
  # Strip the leading blank left by the concatenation above.
  printf '%s' "${missing# }"
}

# qwen3_check_dependencies — die with an install hint when build tools are missing.
# Args:    $1 <build: cpu|vulkan>
# Returns: 0 when everything is present; exits 1 via die otherwise
# Globals: none
qwen3_check_dependencies() {
  local missing
  missing="$(qwen3_missing_tools "$1")"
  # Nothing missing means the build can start.
  [ -z "$missing" ] && return 0
  die "missing build dependencies: $missing\nInstall the packages, e.g.:" \
    "sudo pacman -S --needed cmake git gcc make shaderc vulkan-icd-loader"
}

# qwen3_git_fetch_pinned — shallow-fetch exactly one commit over https into a directory.
# Args:    $1 <repo url>; $2 <commit sha>; $3 <destination dir>
# Returns: 0 when HEAD equals the pinned commit; exits 1 via die otherwise
# Globals: none
qwen3_git_fetch_pinned() {
  local repo="$1" commit="$2" dest="$3"
  # GIT_ALLOW_PROTOCOL also covers submodules, so no step can fall back to plain git://.
  export GIT_ALLOW_PROTOCOL=https
  rm -rf -- "$dest"
  git init -q "$dest" || die "git init failed"
  # The remote only exists so fetch can name the commit.
  git -C "$dest" remote add origin "$repo"
  git -C "$dest" fetch -q --depth 1 origin "$commit" || die "cannot fetch $commit from $repo"
  git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD || die "checkout failed"
  # Verify the commit actually checked out; a moved ref or hostile mirror fails here.
  [ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ] || die "unexpected commit in $repo"
}

# qwen3_prepare_vulkan_headers — make Vulkan/SPIR-V headers available, fetching if needed.
# Args:    $1 <work directory>
# Returns: 0 on success; exits 1 via die on failure; stdout: extra cmake arguments, one per line
# Globals: none
qwen3_prepare_vulkan_headers() {
  local work="$1"
  # System packages are preferred; nothing extra is passed to cmake then.
  qwen3_system_vulkan_headers && return 0
  log "  system Vulkan/SPIR-V headers not found, fetching pinned Khronos headers"
  qwen3_git_fetch_pinned "$VULKAN_HEADERS_REPO" "$VULKAN_HEADERS_COMMIT" "$work/vulkan-headers" >&2
  # SPIR-V headers are pinned the same way as the Vulkan ones.
  qwen3_git_fetch_pinned "$SPIRV_HEADERS_REPO" "$SPIRV_HEADERS_COMMIT" "$work/spirv-headers" >&2
  # SPIRV-Headers must be cmake-installed so find_package(SPIRV-Headers CONFIG) works.
  cmake -S "$work/spirv-headers" -B "$work/spirv-build" -DCMAKE_INSTALL_PREFIX="$work/prefix" \
    >&2 || die "SPIRV-Headers configure failed"
  cmake --install "$work/spirv-build" >&2 || die "SPIRV-Headers install failed"
  printf '%s\n' "-DVulkan_INCLUDE_DIR=$work/vulkan-headers/include" \
    "-DCMAKE_PREFIX_PATH=$work/prefix" "-DCMAKE_CXX_FLAGS=-I$work/spirv-headers/include"
}

# qwen3_build_jobs — choose the number of parallel compile jobs.
# Args:    none
# Returns: 0 always; stdout: job count (half the cores, at least 1, or QWEN_BUILD_JOBS)
# Globals: reads QWEN_BUILD_JOBS
qwen3_build_jobs() {
  local jobs
  # Half the hardware threads keeps the desktop responsive during a long compile.
  jobs="${QWEN_BUILD_JOBS:-$(( $(nproc) / 2 ))}"
  [[ "$jobs" =~ ^[0-9]+$ ]] && [ "$jobs" -ge 1 ] || jobs=1
  printf '%s' "$jobs"
}

# qwen3_collect_header_args — append the cmake arguments for fetched Vulkan headers to an array.
# Args:    $1 <work directory>; $2 <name of the array to append to>
# Returns: 0 on success; exits 1 via die when the headers cannot be prepared
# Globals: writes the named array
qwen3_collect_header_args() {
  local header_output
  local -n target_array="$2"
  # Captured first: a die inside a process substitution would only end that subshell.
  header_output="$(qwen3_prepare_vulkan_headers "$1")" || die "could not prepare the Vulkan headers"
  [ -z "$header_output" ] || mapfile -t -O "${#target_array[@]}" target_array <<< "$header_output"
}

# qwen3_compile — configure and build tts-server and qwen-codec from a source checkout.
# Args:    $1 <source dir>; $2 <build: cpu|vulkan>; $3 <work dir>
# Returns: 0 on success; exits 1 via die on a build error
# Globals: reads QWEN_BUILD_JOBS
qwen3_compile() {
  local source_dir="$1" build="$2" work="$3" build_dir="$3/build" extra_args=()
  # The BLAS option of upstream's own script fails to link, so it is switched off.
  local common_args=(-DCMAKE_BUILD_TYPE=Release -DGGML_BLAS=OFF "-DCMAKE_BUILD_RPATH=\$ORIGIN")
  # The Vulkan variant needs headers, which may have to be fetched first.
  if [ "$build" = "vulkan" ]; then
    extra_args=("-DGGML_VULKAN=ON")
    qwen3_collect_header_args "$work" extra_args
  fi
  # Configuration prints a lot, so it goes to a log and only a summary is shown.
  log "  configuring ($build) ..."
  cmake -S "$source_dir" -B "$build_dir" "${common_args[@]}" "${extra_args[@]}" \
    >"$work/cmake.log" 2>&1 || die "cmake configure failed, see $work/cmake.log"
  log "  compiling with $(qwen3_build_jobs) jobs (several minutes) ..."
  # The build log, not the terminal, carries the compiler output.
  qwen3_build_with_heartbeat "$build_dir" "$work/build.log" ||
    die "build failed, see $work/build.log"
}

# qwen3_build_percent — read the last "[ 42%]" marker out of a cmake build log.
# Args:    $1 <build log>
# Returns: 0 always; stdout: the percentage number, empty when none was printed yet
# Globals: none
qwen3_build_percent() {
  grep -o '^\[ *[0-9]*%\]' "$1" 2>/dev/null | tail -n1 | sed 's/[^0-9]//g' || true
}

# qwen3_build_with_heartbeat — build tts-server and qwen-codec, reporting progress every interval.
# Args:    $1 <build dir>; $2 <build log>
# Returns: cmake's exit status
# Globals: reads QWEN_PROGRESS_INTERVAL
qwen3_build_with_heartbeat() {
  local build_pid started
  started="$(epoch_now)"
  # Only the two tools we ship are built, which skips tests and examples.
  cmake --build "$1" --target tts-server qwen-codec -j "$(qwen3_build_jobs)" >"$2" 2>&1 &
  build_pid=$!
  while kill -0 "$build_pid" 2>/dev/null; do
    # One line per interval keeps a streaming GUI informed.
    sleep "$QWEN_PROGRESS_INTERVAL"
    # A line per interval shows a streaming GUI that the long compile is still alive.
    ! kill -0 "$build_pid" 2>/dev/null ||
      log "  progress: compiling ${1##*/} ... $(qwen3_build_percent "$2")%" \
        "($(( $(epoch_now) - started ))s)"
  done
  wait "$build_pid"
}

# qwen3_publish_binaries — copy the built tools and shared libraries into the engine's bin/.
# Args:    $1 <build dir>
# Returns: 0 on success; exits 1 via die when a tool is missing
# Globals: reads ENGINES_DIR
qwen3_publish_binaries() {
  local build_dir="$1" bin_dir
  bin_dir="$(qwen3_bin_dir)"
  # Both tools must exist: tts-server speaks, qwen-codec encodes voices.
  if [ ! -x "$build_dir/tts-server" ] || [ ! -x "$build_dir/qwen-codec" ]; then
    die "build produced no binaries"
  fi
  # A running server maps these files; copying over them would fail ("Text file busy") or crash it.
  worker_stop
  mkdir -p "$bin_dir"
  # Libraries first and symlinks preserved (-P), the server last: it marks "installed".
  cp -P "$build_dir"/libggml*.so* "$bin_dir/" 2>/dev/null || true
  cp "$build_dir/qwen-codec" "$bin_dir/qwen-codec"
  cp "$build_dir/tts-server" "$bin_dir/tts-server"
}

# qwen3_write_engine_conf — record which build is installed and which device it should use.
# Args:    $1 <build: cpu|vulkan>
# Returns: 0 always
# Globals: reads ENGINES_DIR
qwen3_write_engine_conf() {
  local device="CPU"
  [ "$1" = "vulkan" ] && device="Vulkan0"
  # engine.conf is sourced later, so it only ever contains plain assignments.
  printf 'BUILD=%s\nDEVICE=%s\n' "$1" "$device" > "$(qwen3_engine_dir)/engine.conf"
}

# qwen3_installed_build — print the build recorded for the installed engine.
# Args:    none
# Returns: 0 when a build is recorded; 1 otherwise; stdout: cpu | vulkan
# Globals: reads ENGINES_DIR
qwen3_installed_build() {
  local BUILD=""
  # Absent or unreadable engine.conf simply means "nothing installed yet".
  [ -f "$(qwen3_engine_dir)/engine.conf" ] && [ -x "$(qwen3_bin_dir)/tts-server" ] || return 1
  # shellcheck disable=SC1091
  source "$(qwen3_engine_dir)/engine.conf"
  [ -n "$BUILD" ] && printf '%s' "$BUILD"
}

# qwen3_build_engine — build (or skip an up-to-date build of) the engine binaries.
# Args:    $1 <build: cpu|vulkan>
# Returns: 0 on success; exits 1 via die on failure
# Globals: reads ENGINES_DIR
qwen3_build_engine() {
  local build="$1" work
  # The same build is already installed: nothing to compile.
  if [ "$(qwen3_installed_build 2>/dev/null)" = "$build" ]; then
    log "  $build build already installed"
    return 0
  fi
  # The work directory sits inside the engine dir so one rm cleans everything.
  work="$(qwen3_engine_dir)/.work"
  rm -rf -- "$work"
  mkdir -p "$work"
  # The commit is fetched shallow, so this is a small download.
  log "  fetching qwentts.cpp $QWEN_CPP_COMMIT ..."
  qwen3_git_fetch_pinned "$QWEN_CPP_REPO" "$QWEN_CPP_COMMIT" "$work/src"
  git -C "$work/src" submodule update --init --depth 1 -q || die "submodule fetch failed"
  # The actual compile; every later step needs its output.
  qwen3_compile "$work/src" "$build" "$work"
  qwen3_publish_binaries "$work/build"
  qwen3_write_engine_conf "$build"
  # The build tree is ~300 MB; only bin/ and models/ stay.
  rm -rf -- "$work"
}

# qwen3_resolve_build — turn "auto" into a concrete build kind.
# Args:    $1 <auto|cpu|vulkan>
# Returns: 0 on success; exits 1 via die when vulkan is demanded but unusable
# Globals: none; stdout: cpu | vulkan
qwen3_resolve_build() {
  case "$1" in
    auto) if qwen3_vulkan_usable; then printf 'vulkan'; else printf 'cpu'; fi ;;
    vulkan)
      # An explicit --vulkan must not silently turn into a CPU build.
      qwen3_vulkan_usable ||
        die "--vulkan requested but no usable Vulkan setup (loader, driver, glslc)"
      printf 'vulkan' ;;
    # An explicit cpu choice passes through unchanged.
    *) printf '%s' "$1" ;;
  esac
}

# qwen3_select_after_install — select a freshly installed variant, but only on the first install.
# Args:    $1 <variant just installed>
# Returns: 0 always
# Globals: reads CONFIG_FILE; writes QWEN_VARIANT in the config file on a first install
# Notes:   A later install of the other talker must not silently change the voices in use.
qwen3_select_after_install() {
  # No stored choice yet, or the stored one is the one just installed: store it.
  if ! grep -q '^QWEN_VARIANT=' "$CONFIG_FILE" 2>/dev/null || [ "$1" = "$QWEN_VARIANT" ]; then
    QWEN_VARIANT="$1"
    set_config_var QWEN_VARIANT "$1"
    # The new variant is active now.
    return 0
  fi
  # The active talker stays; the user switches deliberately.
  log "Installed variant $1; the active variant stays $QWEN_VARIANT" \
    "(switch: hyprland-tts engine variant $1)"
}

# command_engine_install — implement `engine install qwen3 [--cpu|--vulkan] [--variant V]`.
# Args:    $1 <qwen3>; then options as described
# Returns: 0 on success; exits 1 via die on any failure
# Globals: writes QWEN_VARIANT in the config file; reads ENGINES_DIR
command_engine_install() {
  local build variant parsed
  # Validate first so a typo never starts a download or a long compile.
  parsed="$(qwen3_parse_install_args "$@")" || exit 1
  read -r build variant <<< "$parsed"
  build="$(qwen3_resolve_build "$build")" || exit 1
  # Fail before downloading gigabytes if the build cannot work anyway.
  qwen3_check_dependencies "$build"
  mkdir -p "$ENGINES_DIR"
  # A second concurrent install would corrupt the shared work directory.
  exec 8> "$ENGINES_DIR/.install.lock"
  flock -n 8 || die "another engine install is already running"
  log "Installing the qwen3 engine ($build build, $variant variant)"
  # Weights first: they are cheap to verify and a failure should come before the compile.
  qwen3_download_model "$variant"
  qwen3_download_model codec
  qwen3_build_engine "$build"
  # Select the variant only if the user had not chosen another one.
  qwen3_select_after_install "$variant"
  log "Done. Engine at $(qwen3_engine_dir). Run: hyprland-tts engine status"
}

# command_engine_remove — implement `engine remove qwen3`: stop the worker, delete the install.
# Args:    $1 <qwen3>
# Returns: 0 on success; exits 1 via die on a wrong engine name
# Globals: reads ENGINES_DIR
command_engine_remove() {
  [ "${1:-}" = "qwen3" ] || die "usage: hyprland-tts engine remove qwen3"
  worker_stop
  # Only the engine's own subtree is deleted; cloned voices and config stay.
  rm -rf -- "${ENGINES_DIR:?}/qwentts"
  log "Removed the qwen3 engine and its models (cloned voices and settings were kept)."
}
