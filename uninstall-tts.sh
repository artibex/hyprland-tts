#!/usr/bin/env bash
# ==============================================================================
# hyprland-tts — local uninstaller (for the git-checkout / ~/.local install)
# ------------------------------------------------------------------------------
# If you installed via the AUR package, remove it with your package manager
# instead:  yay -Rns hyprland-tts   (and run `hyprland-tts purge` first if you
# also want to delete downloaded voices).
# ==============================================================================
set -euo pipefail

# The checkout this script lives in (symlinks resolved) and the install prefix.
REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX="$HOME/.local"

# print_banner — print the uninstaller's title block.
# Args:    none
# Returns: 0 always
# Globals: none
print_banner() {
  cat <<'TEXT'
=================================================
   hyprland-tts — local uninstaller
=================================================
TEXT
}

# run_cli — run the installed hyprland-tts (PATH first, then the local prefix), ignoring failure.
# Args:    $1.. <hyprland-tts arguments>
# Returns: 0 always (also when no installed copy exists)
# Globals: reads PREFIX
run_cli() {
  # The command on PATH wins; the prefix copy covers a PATH without ~/.local/bin.
  if command -v hyprland-tts >/dev/null 2>&1; then
    hyprland-tts "$@" || true
  elif [ -x "$PREFIX/bin/hyprland-tts" ]; then
    # A failing subcommand must not stop the rest of the uninstall.
    "$PREFIX/bin/hyprland-tts" "$@" || true
  fi
}

# ask_purge — ask whether downloaded voices and settings should be deleted too.
# Args:    none
# Returns: 0 for yes; 1 for anything else
# Globals: none
ask_purge() {
  local answer
  read -rp "Also delete downloaded voice models and settings? [y/N]: " answer
  # Only an explicit yes deletes data.
  [[ "$answer" =~ ^[Yy]$ ]]
}

# remove_program_files — remove the installed program files via the Makefile.
# Args:    none
# Returns: 0 always
# Globals: reads REPO_DIR, PREFIX
remove_program_files() {
  echo "Removing program files from $PREFIX ..."
  # A failing make (files already gone) must not stop the farewell message.
  make -C "$REPO_DIR" PREFIX="$PREFIX" uninstall >/dev/null || true
}

# print_farewell — say what was kept and how to remove the engine data.
# Args:    none
# Returns: 0 always
# Globals: none
print_farewell() {
  cat <<'TEXT'

=================================================
 Uninstall complete.
 System packages (piper-tts-bin, wl-clipboard, alsa-utils) were kept.
 A Qwen3 engine (~1.3 GB) lives in ~/.local/share/hyprland-tts; delete it with
 'hyprland-tts engine remove qwen3' BEFORE uninstalling, or rm -rf that directory.
=================================================
TEXT
}

# main — stop the worker, unwire Hyprland, optionally purge, then remove the program files.
# Args:    none
# Returns: 0 on success
# Globals: none
main() {
  print_banner
  # 0. Stop the warm Qwen3 worker (if any) so no tts-server keeps running after removal.
  run_cli engine stop
  # 1. Remove per-user Hyprland wiring (keybinds + hyprland.conf source line).
  run_cli uninstall
  # 2. Optionally remove downloaded voices / state / config / engine data.
  if ask_purge; then run_cli purge; fi
  remove_program_files
  print_farewell
}

# Everything above only defines functions.
main "$@"
