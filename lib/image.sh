#!/usr/bin/env bash
# lib/image.sh — best-effort "read an image aloud".
#
# A web image's alt-text is NOT reachable here: it lives in the browser DOM, not in the
# clipboard (that would need a browser extension). What a global tool can do, when an image is
# on the clipboard, is read embedded description metadata (exiftool) and then OCR the visible
# text (tesseract). Both are optional; without them nothing is returned and the caller stays
# silent. This is the clean extension point for future sources.

# clipboard_image_mime — find the image type offered by the clipboard.
# Args:    none
# Returns: 0 when an image type is offered; 1 otherwise; stdout: png, jpeg or webp mime type
# Globals: none
clipboard_image_mime() {
  local types
  types="$(wl-paste --list-types 2>/dev/null || true)"
  # PNG first: it is what screenshots and most copy actions produce.
  case "$types" in
    *image/png*)  printf 'image/png' ;;
    *image/jpeg*) printf 'image/jpeg' ;;
    # WebP last: it is the rarest clipboard image type.
    *image/webp*) printf 'image/webp' ;;
    *) return 1 ;;
  esac
}

# image_describe — read text out of an image file: metadata description first, OCR second.
# Args:    $1 <image file>
# Returns: 0 always; stdout: the raw text (possibly empty)
# Globals: none
image_describe() {
  local text=""
  # 1) Embedded description-style metadata; the first non-empty line is the best summary.
  if have exiftool; then
    text="$(exiftool -s3 -Description -Caption-Abstract -ImageDescription -Title -UserComment \
      "$1" 2>/dev/null | awk 'NF' | head -n1 || true)"
  fi
  # 2) OCR fallback when the metadata said nothing.
  if [ -z "${text//[[:space:]]/}" ] && have tesseract; then
    text="$(tesseract "$1" stdout 2>/dev/null | awk 'NF' || true)"
  fi
  printf '%s' "$text"
}

# read_clipboard_image — print the text found in a clipboard image, or nothing.
# Args:    none
# Returns: 0 always; stdout: one line of text, whitespace collapsed (empty when none)
# Globals: none
read_clipboard_image() {
  local mime image_file text=""
  have wl-paste || return 0
  # Only a clipboard that offers an image type is worth reading.
  mime="$(clipboard_image_mime)" || return 0
  image_file="$(mktemp --suffix=.img)" || return 0
  # An empty or failed paste means there is no image to read.
  if wl-paste --type "$mime" > "$image_file" 2>/dev/null && [ -s "$image_file" ]; then
    text="$(image_describe "$image_file")"
  fi
  # The clipboard image may be private: it never outlives this call.
  rm -f "$image_file"
  # Blanks and line breaks become single spaces, the ends are trimmed.
  printf '%s' "${text//[[:space:]]/ }" | sed -E 's/^ +| +$//g'
}
