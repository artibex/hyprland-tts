#!/usr/bin/env bash
# lib/worker.sh — on-demand warm worker: starts the Qwen3 tts-server on the first speak,
# keeps it for WORKER_IDLE_MINUTES without requests, then exits. State lives in WORKER_DIR
# (pid, port, ready, last-use, lock, logs), separate from the player's wiped RUN_DIR.

# worker_file — print the path of a state file inside WORKER_DIR.
# Args:    $1 <file name>
# Returns: 0 always; stdout: absolute path
# Globals: reads WORKER_DIR
worker_file() {
  # Every state file name is built here, so the directory layout can change in one place.
  printf '%s/%s' "$WORKER_DIR" "$1"
}

# worker_log — append a diagnostic line to the worker log.
# Args:    $1 <message>
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_log() {
  # The log directory may not exist yet when a render fails before the first start.
  [ -d "$WORKER_DIR" ] || return 0
  printf '%s %s\n' "$(date +%H:%M:%S)" "$1" >> "$(worker_file worker.log)" 2>/dev/null || true
}

# worker_prepare_dir — create WORKER_DIR privately and refuse one that is not ours.
# Args:    none
# Returns: 0 when usable (mode 700, ours, no symlink); 1 otherwise
# Globals: reads WORKER_DIR
worker_prepare_dir() {
  # Port, pid and request bodies live here, so a shared /tmp fallback must be private.
  ensure_private_dir "$WORKER_DIR"
}

# worker_pid_alive — tell whether a live hyprland-tts worker process owns the pid file.
# Args:    none
# Returns: 0 when the pid is alive and really a __worker; 1 otherwise
# Globals: reads WORKER_DIR
worker_pid_alive() {
  local pid
  pid="$(cat "$(worker_file pid)" 2>/dev/null)" || return 1
  # Digits only: the file is ours, but a corrupt one must not reach kill or /proc paths.
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # Matching the command line defeats pid reuse after a crash or reboot.
  [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- '__worker'
}

# worker_port — print the port of the running server.
# Args:    none
# Returns: 0 when a port file exists; 1 otherwise; stdout: port number
# Globals: reads WORKER_DIR
worker_port() {
  local port
  port="$(cat "$(worker_file port)" 2>/dev/null)" || return 1
  # Reject anything that is not a plain port number.
  [[ "$port" =~ ^[0-9]{2,5}$ ]] || return 1
  printf '%s' "$port"
}

# worker_http_ok — probe the server's health endpoint on loopback.
# Args:    $1 <port>
# Returns: 0 when the server answers 200; 1 otherwise
# Globals: none
worker_http_ok() {
  # Short timeout: a hung server must not stall every speak.
  curl -fsS --noproxy '*' --max-time 2 -o /dev/null "http://127.0.0.1:$1/health" 2>/dev/null
}

# worker_ready — tell whether the worker is up and the server answers.
# Args:    none
# Returns: 0 when serving requests; 1 otherwise
# Globals: reads WORKER_DIR
worker_ready() {
  local port
  # The ready file is written only after the model loaded and voices registered.
  [ -f "$(worker_file ready)" ] && worker_pid_alive || return 1
  port="$(worker_port)" || return 1
  worker_http_ok "$port"
}

# worker_touch — record a request so the idle timer restarts.
# Args:    none
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_touch() {
  # The file's mtime is the last-use timestamp; no content needed.
  [ -d "$WORKER_DIR" ] && touch "$(worker_file last-use)" 2>/dev/null
  return 0
}

# worker_kill_pidfile_process — terminate the process a pid file names, if it matches a pattern.
# Args:    $1 <pid file name>; $2 <command-line pattern the process must match>
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_kill_pidfile_process() {
  local pid waited=0
  pid="$(cat "$(worker_file "$1")" 2>/dev/null)" || return 0
  # Digits only: a corrupt pid file must never reach kill.
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  # Never signal a recycled pid that now belongs to an unrelated program.
  [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$2" || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  # Give it up to 5 s to exit cleanly, then force it.
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  # Force the exit if the polite SIGTERM was ignored or too slow.
  kill -KILL "$pid" 2>/dev/null || true
}

# worker_clear_state — remove the files describing a (dead) worker; logs are kept.
# Args:    none
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_clear_state() {
  # The failed marker goes too, so an old failure cannot abort a fresh start.
  rm -f "$(worker_file pid)" "$(worker_file port)" "$(worker_file ready)" \
    "$(worker_file server.pid)" "$(worker_file failed)" "$(worker_file variant)"
}

# worker_clear_stale — recover from a crashed worker: kill its orphaned server, drop state.
# Args:    none
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_clear_stale() {
  # A worker killed with SIGKILL leaves its 1 GB server behind; reap it by pid file.
  worker_kill_pidfile_process server.pid tts-server
  worker_clear_state
}

# worker_server_alive — tell whether the pid file names a live tts-server process.
# Args:    none
# Returns: 0 when the server process exists and really is a tts-server; 1 otherwise
# Globals: reads WORKER_DIR
worker_server_alive() {
  local pid
  pid="$(cat "$(worker_file server.pid)" 2>/dev/null)" || return 1
  # Digits only, and the command line must match, so a recycled pid never counts.
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- 'tts-server'
}

# worker_request_begin — mark a request of this process as in flight.
# Args:    none
# Returns: 0 always
# Globals: reads WORKER_DIR, BASHPID
worker_request_begin() {
  # The idle timer must not stop the worker under a request that is still being synthesized.
  [ -d "$WORKER_DIR" ] && : > "$(worker_file "inflight.$BASHPID")"
  return 0
}

# worker_request_end — remove this process's in-flight mark.
# Args:    none
# Returns: 0 always
# Globals: reads WORKER_DIR, BASHPID
worker_request_end() {
  rm -f "$(worker_file "inflight.$BASHPID")"
}

# worker_requests_in_flight — tell whether a live process has a request running.
# Args:    none
# Returns: 0 when at least one request is in flight; 1 otherwise
# Globals: reads WORKER_DIR
worker_requests_in_flight() {
  local mark
  for mark in "$WORKER_DIR"/inflight.*; do
    # An unmatched glob stays literal; skip it.
    [ -e "$mark" ] || continue
    # A mark of a dead process (killed player) is stale and removed.
    if kill -0 "${mark##*.}" 2>/dev/null; then return 0; fi
    rm -f "$mark"
  done
  return 1
}

# worker_idle_minutes — print the idle limit in minutes, re-read from the config file.
# Args:    none
# Returns: 0 always; stdout: minutes (10 when unset or not a number)
# Globals: reads CONFIG_FILE, WORKER_IDLE_MINUTES
# Notes:   Re-reading lets `engine config idle` act on a running worker without a restart.
worker_idle_minutes() {
  local minutes="$WORKER_IDLE_MINUTES"
  # The config file is the source of truth; its last assignment wins like in a sourced file.
  [ ! -f "$CONFIG_FILE" ] ||
    minutes="$(grep -E '^WORKER_IDLE_MINUTES=[0-9]+$' "$CONFIG_FILE" |
      tail -n1 | cut -d= -f2 || true)"
  # A value that is not a plain number falls back to the process setting.
  [[ "$minutes" =~ ^[0-9]+$ ]] || minutes="$WORKER_IDLE_MINUTES"
  # An unparsable value falls back to the documented default of 10.
  [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=10
  printf '%s' "$minutes"
}

# worker_idle_seconds — print the configured idle limit in seconds.
# Args:    none
# Returns: 0 always; stdout: seconds, 0 meaning "never exit"
# Globals: reads WORKER_IDLE_SECONDS (test override), WORKER_IDLE_MINUTES
worker_idle_seconds() {
  # The seconds override exists so tests can observe an idle exit within seconds.
  if [[ "${WORKER_IDLE_SECONDS:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$WORKER_IDLE_SECONDS"
    return 0
  fi
  # Minutes (live from the config) become seconds for the timer.
  printf '%s' "$(( $(worker_idle_minutes) * 60 ))"
}

# worker_idle_expired — tell whether the last request is older than the idle limit.
# Args:    none
# Returns: 0 when the worker should exit; 1 otherwise
# Globals: reads WORKER_DIR
worker_idle_expired() {
  local limit age
  limit="$(worker_idle_seconds)"
  # A limit of 0 keeps the worker alive until `engine stop`.
  [ "$limit" -gt 0 ] || return 1
  # A request that is still being synthesized keeps the worker, however old last-use is.
  ! worker_requests_in_flight || return 1
  # No last-use file yet means the worker only just started.
  age="$(file_age_seconds "$(worker_file last-use)")" || return 1
  [ "$age" -ge "$limit" ]
}

# worker_pick_port — choose a random unused loopback port.
# Args:    none
# Returns: 0 always; stdout: port number
# Globals: none
worker_pick_port() {
  local port
  while :; do
    # Random ports in the unprivileged range avoid clashes between users and restarts.
    port=$(( 20000 + RANDOM % 20000 ))
    # A successful connect means something already listens there; pick again.
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || break
  done
  printf '%s' "$port"
}

# worker_start_timeout — print the model-load timeout in seconds, sanitised.
# Args:    none
# Returns: 0 always; stdout: a positive integer (90 when the setting is not a number)
# Globals: reads QWEN_START_TIMEOUT
worker_start_timeout() {
  # A junk value from a hand-edited config must not turn the arithmetic below into 0.
  if [[ "$QWEN_START_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$QWEN_START_TIMEOUT"
  else
    printf '90'
  fi
}

# worker_launch_server — start tts-server on one device/port and wait until it is healthy.
# Args:    $1 <device, e.g. Vulkan0 or CPU>; $2 <port>
# Returns: 0 when healthy; 1 when it died; 3 when it timed out (it is killed then)
# Globals: reads QWEN_VARIANT, QWEN_START_TIMEOUT; writes server.pid and server.log
worker_launch_server() {
  local device="$1" port="$2" bin_dir server_pid waited=0 limit=$(( $(worker_start_timeout) * 5 ))
  bin_dir="$(qwen3_bin_dir)"
  # Started directly (not via a function) so $! is the server itself, not a subshell.
  # Bound to 127.0.0.1 explicitly: the default is also loopback, but we never rely on it.
  LD_LIBRARY_PATH="$bin_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$bin_dir/tts-server" \
    --model "$(qwen3_model_path "$QWEN_VARIANT")" --codec "$(qwen3_model_path codec)" \
    --device "$device" --host 127.0.0.1 --port "$port" >> "$(worker_file server.log)" 2>&1 &
  server_pid=$!
  printf '%s\n' "$server_pid" > "$(worker_file server.pid)"
  # Poll every 0.2 s; an early exit (bad device, busy port) ends the wait at once.
  while kill -0 "$server_pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    worker_http_ok "$port" && return 0
    sleep 0.2
    # One poll step done; the loop bound turns this into a timeout.
    waited=$((waited + 1))
  done
  # A server that is still alive here hung while loading; a dead one failed on its own.
  if kill -0 "$server_pid" 2>/dev/null; then
    kill -KILL "$server_pid" 2>/dev/null || true
    return 3
  fi
  # The server process ended on its own (bad device or busy port).
  return 1
}

# worker_port_conflict — tell whether the last server start failed because the port was taken.
# Args:    none
# Returns: 0 when the server log says so; 1 otherwise
# Globals: reads WORKER_DIR
worker_port_conflict() {
  tail -n 20 "$(worker_file server.log)" 2>/dev/null |
    grep -qiE 'address already in use|failed to (bind|listen)|EADDRINUSE'
}

# worker_remember_failed_device — note that a device failed so the next start skips it for a while.
# Args:    $1 <device>
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_remember_failed_device() {
  # CPU is the last resort and is always tried, so only accelerators are remembered.
  [ "$1" = "CPU" ] || printf '%s %s\n' "$1" "$(epoch_now)" >> "$(worker_file failed-device)"
}

# worker_device_failed_recently — tell whether a device failed within the last ten minutes.
# Args:    $1 <device>
# Returns: 0 when a failure was recorded less than 600 s ago; 1 otherwise
# Globals: reads WORKER_DIR
worker_device_failed_recently() {
  local device when
  # Each line is "<device> <epoch>"; a stale entry is simply ignored.
  while read -r device when; do
    [ "$device" = "$1" ] && [ $(( $(epoch_now) - when )) -lt 600 ] && return 0
  done 2>/dev/null < "$(worker_file failed-device)"
  # No recent failure is recorded for this device.
  return 1
}

# worker_devices — list the devices to try, preferred first, CPU always last.
# Args:    none
# Returns: 0 always; stdout: one device per line, no duplicates
# Globals: reads QWEN_DEVICE, the install's engine.conf via qwen3_device and failed-device
worker_devices() {
  local primary
  primary="$(qwen3_device)"
  # The preferred device comes first, unless it hung or crashed a moment ago.
  worker_device_failed_recently "$primary" || printf '%s\n' "$primary"
  # The Vulkan build also contains the CPU backend, so CPU is always a valid fallback.
  [ "$primary" = "CPU" ] || printf 'CPU\n'
}

# worker_boot — start the server, trying the preferred device first and CPU as the fallback.
# Args:    none
# Returns: 0 when a server runs (port file written); 1 when every attempt failed
# Globals: writes WORKER_DIR/port, server.log, failed-device
worker_boot() {
  local device port attempt status
  for device in $(worker_devices); do
    # Three random ports make a lost bind race harmless.
    for attempt in 1 2 3; do
      port="$(worker_pick_port)"
      worker_log "starting tts-server on $device port $port (attempt $attempt)"
      # Reset per attempt so an old failure cannot leak into the next one.
      status=0
      worker_launch_server "$device" "$port" || status=$?
      [ "$status" -ne 0 ] || { printf '%s\n' "$port" > "$(worker_file port)"; return 0; }
      # Only a taken port deserves another port; a hung or crashed device goes to the next one.
      if [ "$status" -ne 1 ] || ! worker_port_conflict; then break; fi
    done
    worker_remember_failed_device "$device"
  done
  # Every device and port attempt failed.
  return 1
}

# worker_fail — record why the worker could not start so waiting clients stop early.
# Args:    $1 <reason>
# Returns: 0 always
# Globals: writes WORKER_DIR/failed
worker_fail() {
  # Clients poll for this file instead of waiting out the whole start timeout.
  printf '%s\n' "$1" > "$(worker_file failed)"
  worker_log "FAILED: $1"
}

# worker_cleanup — stop the server and remove state files that still belong to this worker.
# Args:    none
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_cleanup() {
  local owner
  owner="$(cat "$(worker_file pid)" 2>/dev/null || true)"
  # Only touch the shared files if they still describe this process, not a newer worker.
  [ "$owner" = "$$" ] || return 0
  worker_kill_pidfile_process server.pid tts-server
  rm -f "$(worker_file pid)" "$(worker_file port)" "$(worker_file ready)" \
    "$(worker_file server.pid)" "$(worker_file variant)"
  # Leave a trace in the log for diagnosing unexpected exits.
  worker_log "worker exit"
}

# worker_confirm_idle — re-check the idle limit under the lock and shut down inside it.
# Args:    none
# Returns: 0 when the worker was shut down (state removed, server killed); 1 when it keeps running
# Globals: reads WORKER_DIR
# Notes:   Shutting down inside the lock: a waiting client finds no worker and starts a new one.
worker_confirm_idle() {
  # ensure and kick touch last-use under this lock; running requests are covered by in-flight marks.
  (
    flock -w 5 9 || exit 1
    worker_idle_expired || exit 1
    # Removing the state before the lock is released avoids a half-dead worker (pid alive,
    # not ready) that a client would wait for in vain.
    worker_kill_pidfile_process server.pid tts-server
    rm -f "$(worker_file pid)" "$(worker_file port)" "$(worker_file ready)" \
      "$(worker_file server.pid)" "$(worker_file variant)"
  # Descriptor 9 is the shared start lock, released when this subshell ends.
  ) 9> "$(worker_file lock)"
}

# worker_idle_loop — block until the server dies or the idle limit passes.
# Args:    none
# Returns: 0 when the worker should exit
# Globals: reads WORKER_DIR
worker_idle_loop() {
  local server_pid
  while :; do
    # A missing pid file is read as empty, which kill -0 rejects below.
    server_pid="$(cat "$(worker_file server.pid)" 2>/dev/null || true)"
    # A crashed server leaves nothing to keep warm.
    kill -0 "$server_pid" 2>/dev/null || { worker_log "server died"; return 0; }
    worker_idle_expired && worker_confirm_idle && { worker_log "idle exit"; return 0; }
    # sleep in the background + wait lets a TERM trap fire immediately.
    sleep 1 &
    wait $! || true
  done
}

# worker_trim_log — shrink a log file that grew beyond one megabyte to its last 256 KB.
# Args:    $1 <log file name inside WORKER_DIR>
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_trim_log() {
  local path
  path="$(worker_file "$1")"
  # Small or missing logs need nothing.
  [ "$(stat -c %s "$path" 2>/dev/null || echo 0)" -gt 1048576 ] || return 0
  tail -c 262144 "$path" > "$path.new" && mv -f "$path.new" "$path"
}

# worker_housekeeping — keep the worker directory small: trim logs, drop old temp files.
# Args:    none
# Returns: 0 always
# Globals: reads WORKER_DIR
worker_housekeeping() {
  # Logs are appended forever otherwise; a megabyte of history is plenty for diagnosis.
  worker_trim_log server.log
  worker_trim_log worker.log
  # Request bodies of killed players would otherwise stay (they hold the user's text).
  find "$WORKER_DIR" -maxdepth 1 -name 'tmp.*' -mmin +10 -delete 2>/dev/null || true
}

# run_worker — entry point of the detached `__worker` process.
# Args:    none
# Returns: 0 when it ended normally; 1 when the engine could not start
# Globals: reads WORKER_DIR, QWEN_VARIANT; writes the worker state files
run_worker() {
  load_config
  worker_prepare_dir || exit 1
  # Runs when the idle limit passes, on `engine stop`, and on any early failure.
  trap 'worker_cleanup; exit 0' TERM INT HUP
  trap 'worker_cleanup' EXIT
  worker_housekeeping
  # Leftovers of an earlier run must not make this start look failed or ready.
  rm -f "$(worker_file failed)" "$(worker_file ready)"
  # Record the variant before the pid: a client that sees a live pid must also see the variant.
  printf '%s\n' "$QWEN_VARIANT" > "$(worker_file variant)"
  # Publish our pid last so clients never see a half-initialised worker as alive.
  printf '%s\n' "$$" > "$(worker_file pid)"
  qwen3_installed || { worker_fail "qwen3 engine is not installed"; exit 1; }
  worker_boot || { worker_fail "tts-server did not start (see server.log)"; exit 1; }
  # Cloned voices must be known to the server before the first request arrives.
  voice_register_all "$(worker_port)"
  # Touch before publishing "ready" so the idle timer starts from a fresh timestamp.
  worker_touch
  : > "$(worker_file ready)"
  worker_idle_loop
}

# worker_spawn — launch a detached worker without keeping the caller's lock descriptor.
# Args:    none
# Returns: 0 always
# Globals: reads HTTS_SELF
worker_spawn() {
  # fd 9 (the start lock) is closed for the child, or the worker would hold the lock forever.
  setsid -f "${HTTS_SELF:-$0}" __worker >/dev/null 2>&1 < /dev/null 9>&- ||
    ( "${HTTS_SELF:-$0}" __worker >/dev/null 2>&1 < /dev/null 9>&- & )
}

# worker_wait_ready — wait until the worker serves requests, fails, or times out.
# Args:    none
# Returns: 0 when ready; 1 on failure or timeout
# Globals: reads QWEN_START_TIMEOUT, WORKER_DIR
worker_wait_ready() {
  local waited=0 limit=$(( ($(worker_start_timeout) + 10) * 10 ))
  while [ "$waited" -lt "$limit" ]; do
    # Ready means the model is loaded, voices are registered and health answers.
    worker_ready && return 0
    # An explicit failure marker or a dead pid ends the wait early.
    [ ! -f "$(worker_file failed)" ] || return 1
    [ ! -f "$(worker_file pid)" ] || worker_pid_alive || return 1
    sleep 0.1
    # One 0.1 s poll step done; the loop bound turns this into the start timeout.
    waited=$((waited + 1))
  done
  return 1
}

# worker_variant_matches — tell whether the running worker serves the configured variant.
# Args:    none
# Returns: 0 when the recorded variant equals QWEN_VARIANT; 1 otherwise
# Globals: reads QWEN_VARIANT, WORKER_DIR
worker_variant_matches() {
  # A worker started before a config change keeps serving the old talker until restarted.
  [ "$(cat "$(worker_file variant)" 2>/dev/null)" = "$QWEN_VARIANT" ]
}

# worker_variant_conflicts — tell whether a recorded variant differs from the configured one.
# Args:    none
# Returns: 0 when a variant is recorded and differs; 1 when equal or not recorded yet
# Globals: reads QWEN_VARIANT, WORKER_DIR
worker_variant_conflicts() {
  local recorded
  # No record yet means the worker is still booting: never kill it for that (a race once did).
  recorded="$(cat "$(worker_file variant)" 2>/dev/null)" || return 1
  [ "$recorded" != "$QWEN_VARIANT" ]
}

# worker_ensure_locked — under the start lock: reuse, wait for, or (re)start the worker.
# Args:    none
# Returns: 0 when the worker serves requests afterwards; 1 otherwise
# Globals: reads WORKER_DIR
worker_ensure_locked() {
  # Touching first stops a worker that is about to idle out from leaving mid-handshake.
  worker_touch
  worker_ready && worker_variant_matches && return 0
  # The user switched variants (customvoice <-> base): the old worker must make way.
  if worker_pid_alive && worker_variant_conflicts; then worker_stop; fi
  # A live but not-yet-ready worker is still loading: wait, never start a second one.
  if worker_pid_alive; then worker_wait_ready; return; fi
  worker_clear_stale
  worker_spawn
  # The fresh worker needs time to load the model, so wait for it.
  worker_wait_ready
}

# worker_ensure — make sure a worker is serving, starting it when needed (race-safe).
# Args:    none
# Returns: 0 when ready; 1 when it cannot start
# Globals: reads WORKER_DIR
worker_ensure() {
  worker_prepare_dir || return 1
  have flock || { worker_log "flock missing"; return 1; }
  # The subshell owns fd 9, so the lock is released as soon as the check finishes.
  ( flock -w $(( $(worker_start_timeout) + 30 )) 9 || exit 1; worker_ensure_locked ) \
    9> "$(worker_file lock)"
}

# worker_kick — start the worker in the background without waiting (warm-up on speak).
# Args:    none
# Returns: 0 always (best effort)
# Globals: reads WORKER_DIR
worker_kick() {
  worker_prepare_dir || return 0
  have flock || return 0
  # -n: if another process is already starting the worker there is nothing to do.
  (
    flock -n 9 || exit 0
    worker_touch
    worker_ready && exit 0
    # A live worker that is still loading must not be started a second time.
    worker_pid_alive && exit 0
    worker_clear_stale
    worker_spawn
  # A lock held by someone else means they are already starting the worker.
  ) 9> "$(worker_file lock)" || true
  return 0
}

# worker_stop — stop the worker and its server.
# Args:    none
# Returns: 0 always; stdout: nothing
# Globals: reads WORKER_DIR
worker_stop() {
  # TERM makes the worker's trap kill the server and remove its own state.
  worker_kill_pidfile_process pid __worker
  # Sweep up anything a crashed worker left behind (orphan server, stale files).
  worker_clear_stale
  # An explicit stop is also the user's way to retry an accelerator that failed earlier.
  rm -f "$(worker_file failed-device)"
}

# worker_state — print the worker's lifecycle state as one word.
# Args:    none
# Returns: 0 always; stdout: stopped | starting | running
# Globals: reads WORKER_DIR
worker_state() {
  # Not running covers "never started", "idled out" and "crashed".
  worker_pid_alive || { printf 'stopped'; return 0; }
  # A live pid that does not answer yet is still loading the model.
  worker_ready || { printf 'starting'; return 0; }
  printf 'running'
}

# worker_status_line — describe the worker for `engine status`.
# Args:    none
# Returns: 0 always; stdout: one human-readable line
# Globals: reads WORKER_DIR
worker_status_line() {
  local state
  state="$(worker_state)"
  # Only a running worker has a port and an idle limit to report.
  [ "$state" = "running" ] || { printf '%s' "$state"; return 0; }
  # Remaining idle time tells the user when the 1 GB of RAM will be released.
  printf 'running (pid %s, port %s, idle limit %ss)' \
    "$(cat "$(worker_file pid)")" "$(worker_port)" "$(worker_idle_seconds)"
}
