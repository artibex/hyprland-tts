#!/usr/bin/env bash
# lib/image.sh — best-effort "read an image aloud".
#
# IMPORTANT scope note: a web image's alt-text is NOT reachable here — it lives
# in the browser DOM, not the clipboard/selection. Reaching it would require a
# browser extension. What a global tool CAN do, when an image is on the
# clipboard, is:
#   1) read embedded description metadata (exiftool), then
#   2) fall back to OCR of visible text (tesseract).
# Both are optional; if the tools/text are absent we return nothing and the
# caller stays silent. This is the clean extension point for future sources.

# prints extracted text on stdout, or nothing
read_clipboard_image() {
  have wl-paste || return 0
  # is there an image on the clipboard?
  local types; types="$(wl-paste --list-types 2>/dev/null || true)"
  local mime=""
  case "$types" in
    *image/png*)  mime="image/png"  ;;
    *image/jpeg*) mime="image/jpeg" ;;
    *image/webp*) mime="image/webp" ;;
    *) return 0 ;;
  esac

  local tmp; tmp="$(mktemp --suffix=.img)" || return 0
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  wl-paste --type "$mime" > "$tmp" 2>/dev/null || return 0
  [ -s "$tmp" ] || return 0

  local text=""
  # 1) embedded description-style metadata
  if have exiftool; then
    text="$(exiftool -s3 -Description -Caption-Abstract -ImageDescription -Title -UserComment "$tmp" 2>/dev/null \
            | awk 'NF' | head -n1)"
  fi
  # 2) OCR fallback
  if [ -z "${text//[[:space:]]/}" ] && have tesseract; then
    text="$(tesseract "$tmp" stdout 2>/dev/null | awk 'NF')"
  fi

  printf '%s' "${text//[[:space:]]/ }" | sed -E 's/^ +| +$//g'
}
