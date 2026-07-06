#!/usr/bin/env bash
# lib/text.sh — voiceover text optimizer + sentence chunking.
#
# normalize_text: stdin -> stdout. Cleans text so Piper reads it smoothly
# WITHOUT changing meaning: strips markup/decoration that causes long dead-air
# pauses, collapses whitespace, and turns unreadable tokens (bare URLs) into
# short spoken stand-ins. Pure text transform — trivially testable.
#
# chunk_text: stdin -> stdout, one sentence-sized chunk per line (the unit the
# player skips by). Long runs are wrapped at word boundaries.

normalize_text() {
  # 1) byte-level strip of NBSP / zero-width / BOM / soft-hyphen. tr does NOT
  #    understand \xNN, so this must be sed under a byte locale (LC_ALL=C).
  LC_ALL=C sed -E 's/\xc2\xa0/ /g; s/\xe2\x80\x8b//g; s/\xe2\x80\x8c//g; s/\xe2\x80\x8d//g; s/\xef\xbb\xbf//g; s/\xc2\xad//g' \
  | tr '\t\r\v\f' '    ' \
  | sed -E '
    # markdown images  ![alt](url)  -> alt   (keep the description)
    s/!\[([^]]*)\]\([^)]*\)/\1/g
    # markdown links   [text](url)   -> text
    s/\[([^]]*)\]\([^)]*\)/\1/g
    # bare URLs -> a short spoken stand-in (avoids reading slashes aloud)
    s#https?://[^[:space:]]+#(link)#g
    s#www\.[^[:space:]]+#(link)#g
    # e-mail addresses -> stand-in
    s/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/(email)/g
    # inline/code fences and *emphasis* markers (leave _ alone: snake_case)
    s/`+//g
    s/(\*\*|\*|~~)//g
    # leading markdown heading / quote / list markers on each segment
    s/(^|[[:space:]])#{1,6}[[:space:]]+/\1/g
    s/(^|[[:space:]])>[[:space:]]+/\1/g
    s/(^|[[:space:]])[-*+•][[:space:]]+/\1/g
    s/(^|[[:space:]])[0-9]+[.)][[:space:]]+/\1/g
    # table pipes -> pause
    s/[[:space:]]*\|[[:space:]]*/, /g
    # collapse long runs of the same punctuation (---- ==== .... !!!! ####)
    s/([-=*.#~])\1{2,}/ /g
    s/([.!?,;:])\1+/\1/g
    # spaced-out separators like " - - - "
    s/([[:space:]][-–—][[:space:]]){2,}/ /g
  ' \
  | awk '
    # drop lines that are only punctuation/symbols (decorative separators),
    # join the rest with single spaces; blank lines become sentence breaks.
    {
      line=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") { pending_break=1; next }
      stripped=line; gsub(/[[:alnum:]]/, "", stripped)
      if (line != "" && stripped == line) next   # symbols-only -> skip
      if (out != "") {
        if (pending_break) out = (out ~ /[.!?:;,]$/) ? out " " : out ". "
        else out = out " "
      }
      out = out line
      pending_break=0
    }
    END { print out }
  ' \
  | sed -E '
    s/[[:space:]]+/ /g              # collapse whitespace
    s/[[:space:]]+([.!?,;:])/\1/g   # no space before punctuation
    s/([.!?])[.]+/\1/g             # ".." -> "."
    s/(\. ){2,}/. /g               # ". . ." from joins -> ". "
    s/^[ ,]+//; s/[[:space:]]+$//  # trim leading commas/space + trailing
  '
}

chunk_text() {
  sed -E 's/([.!?…]+)([[:space:]]|$)/\1\n/g; s/([;:])[[:space:]]/\1\n/g' \
    | awk 'NF' \
    | awk -v max="${CHUNK_MAX:-240}" '
      {
        line=$0
        while (length(line) > max) {
          cut=max
          while (cut > 1 && substr(line, cut, 1) != " ") cut--
          if (cut <= 1) cut=max
          chunk=substr(line, 1, cut); sub(/ +$/, "", chunk)
          if (length(chunk) > 0) print chunk
          line=substr(line, cut+1); sub(/^ +/, "", line)
        }
        if (length(line) > 0) print line
      }'
}
