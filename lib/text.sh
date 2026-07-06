#!/usr/bin/env bash
# lib/text.sh — voiceover text optimizer + sentence chunking.
#
# normalize_text: stdin -> stdout. Dispatches to normalize_code or
# normalize_prose depending on looks_like_code, then hands off to whichever
# cleanup fits: prose gets markdown/URL/whitespace cleanup (meaning preserved);
# code gets syntax-noise reduction so it's not painful to listen to (see below).
#
# chunk_text: stdin -> stdout, one sentence-sized chunk per line (the unit the
# player skips by). Long runs are wrapped at word boundaries.

normalize_text() {
  local input; input="$(cat)"
  if looks_like_code "$input"; then
    printf '%s' "$input" | normalize_code
  else
    printf '%s' "$input" | normalize_prose
  fi
}

# ------------------------------------------------------------------------------
# looks_like_code: best-effort heuristic, not a parser. Scores a few independent
# signals and requires at least 2 to agree, so plain prose with the odd bracket
# or a stray "==" in a sentence doesn't get misclassified. Known limitation:
# very short snippets (a single identifier, one operator) may go either way —
# that's fine, normalize_prose still produces sane (if unremarkable) output.
# ------------------------------------------------------------------------------
looks_like_code() {
  local text="$1" score=0 total syms lines_indented
  total=${#text}
  [ "$total" -gt 0 ] || { return 1; }

  # 1) symbol density: braces/parens/operators are rare in prose, common in code
  syms=$(printf '%s' "$text" | tr -dc '{}();=<>!&|' | wc -c)
  awk -v s="$syms" -v t="$total" 'BEGIN{ exit !(t>0 && s/t > 0.04) }' && score=$((score+1))

  # 2) common keywords across mainstream languages
  printf '%s' "$text" | grep -Eq \
    '\b(function|def|class|return|import|export|const|let|var|public|private|static|void|struct|impl|fn|package|namespace|elif|elsif|endif|foreach)\b' \
    && score=$((score+1))

  # 3) two or more indented lines (bodies of blocks)
  lines_indented=$(printf '%s' "$text" | grep -Ec '^([[:space:]]{2,}|\t)[^[:space:]]')
  [ "$lines_indented" -ge 2 ] && score=$((score+1))

  # 4) camelCase or snake_case identifiers present
  printf '%s' "$text" | grep -Eq '[a-z][A-Z]|[a-zA-Z][0-9]*_[a-zA-Z]' && score=$((score+1))

  [ "$score" -ge 2 ]
}

# ------------------------------------------------------------------------------
# normalize_code: makes source code listenable instead of an unbroken buzz of
# punctuation. Strategy: translate operators that carry meaning into short
# words, drop the comment *markers* while keeping the comment *text* (comments
# are often the most useful thing to hear), split camelCase/snake_case
# identifiers into pronounceable words, and turn braces/semicolons into
# sentence breaks (silent, structural — also what chunk_text splits on) rather
# than reading "open brace" / "semicolon" out loud on every line.
#
# Known limitations: this is a text transform, not a language parser — it
# can't tell a code comment from a string that happens to start with "//", and
# it doesn't attempt to describe control flow. Good enough for "skim this
# function by ear"; not a replacement for reading the code.
# ------------------------------------------------------------------------------
normalize_code() {
  sed -E '
    # multi-char operators first (longest match wins by ordering)
    s/===/ strictly equals /g
    s/!==/ strictly not equal to /g
    s/==/ equals /g
    s/!=/ not equal to /g
    s/<=/ less than or equal to /g
    s/>=/ greater than or equal to /g
    s/=>/ arrow /g
    s/->/ arrow /g
    s/&&/ and /g
    s/\|\|/ or /g
    s/\+=/ plus equals /g
    s/-=/ minus equals /g
    s/::/ scope /g
  ' \
  | sed -E '
    # comment markers: strip the marker, KEEP the comment text
    s|^([[:space:]]*)//+[[:space:]]?|\1|
    s|^([[:space:]]*)#+[[:space:]]?|\1|
    s|/\*+[[:space:]]?||g
    s|[[:space:]]?\*+/||g
  ' \
  | sed -E '
    # split camelCase and snake_case identifiers into words
    s/([a-z0-9])([A-Z])/\1 \2/g
    s/_/ /g
    # braces/semicolons -> sentence breaks (silent; also a chunk_text boundary)
    s/[{};]/./g
    # parens/brackets carry no useful sound -> replace with a space (not
    # nothing!) so "getName(user)" reads as "get Name user", not "Nameuser"
    s/[][()]/ /g
  ' \
  | awk '
    # drop lines that are only periods/whitespace (e.g. a lone closing brace
    # that became "."); a spoken chunk that says nothing is worse than none
    { t=$0; gsub(/[.[:space:]]/, "", t); if (t != "") print }
  ' \
  | sed -E '
    s/[[:space:]]+/ /g
    s/[[:space:]]+([.!?,;:])/\1/g
    s/\.{2,}/./g
    s/^[[:space:]]+|[[:space:]]+$//g
  '
}

normalize_prose() {
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
