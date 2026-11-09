#!/usr/bin/env bash
# lib/text.sh — voiceover text optimizer + sentence chunking (bash fallback path).
#
# normalize_text: stdin -> stdout. Classifies every blank-line separated PARAGRAPH as
# code or prose (a prose document with one embedded snippet must not be judged as a
# whole) and cleans it: prose loses markdown/URL/whitespace noise, code gets operators
# turned into words. chunk_text: stdin -> stdout, one sentence-sized chunk per line.
#
# The primary path is lib/py/htts_markup.py (identical behaviour, one process instead of
# ~10 per paragraph); this file stays as the fallback when Python or the model is missing.
# List/quote/heading markers are stripped at the START of a line only: stripping them
# mid-line turned "am 3. Oktober" into "am Oktober" (fixed in both implementations).

# Characters whose density marks code (see looks_like_code); used by tr -dc.
CODE_SYMBOL_CHARS='{}();=<>!&|'
# Keywords common to mainstream programming languages (extended below to stay short).
CODE_KEYWORD_REGEX='\b(function|def|class|return|import|export|const|let|var|public|private'
# Second half of the keyword alternation.
CODE_KEYWORD_REGEX+='|static|void|struct|impl|fn|package|namespace|elif|elsif|endif|foreach)\b'

# normalize_text — clean a whole selection paragraph by paragraph (prose vs. code).
# Args:    none (reads the raw text on stdin)
# Returns: 0 always; stdout: cleaned text, code lines newline-separated, prose one line
# Globals: none
normalize_text() {
  # Capture the selection; $(...) drops trailing newlines like the Python port does.
  local input block cleaned out=""
  input="$(cat)"
  # Fence marker lines become blank lines so fenced code is its own paragraph.
  input="$(strip_fence_lines <<< "$input")"
  while IFS= read -r -d '' block; do
    # Whitespace-only paragraphs carry nothing.
    [ -n "${block//[[:space:]]/}" ] || continue
    # Code and prose paragraphs take different cleaning paths.
    cleaned="$(clean_paragraph "$block")"
    [ -n "${cleaned//[[:space:]]/}" ] || continue
    # Join to what we have so far, adding a period where none ends the previous one.
    out="$(join_paragraph "$out" "$cleaned")"
  done < <(split_paragraphs <<< "$input")
  printf '%s' "$out"
}

# strip_fence_lines — turn markdown code-fence marker lines into empty lines.
# Args:    none (stdin text)
# Returns: 0 always; stdout: the text with fence lines blanked
# Globals: none
strip_fence_lines() {
  sed -E 's/^[[:space:]]*```.*$//'
}

# split_paragraphs — emit NUL-terminated paragraphs (blocks separated by empty lines).
# Args:    none (stdin text)
# Returns: 0 always; stdout: NUL-terminated paragraph records
# Globals: none
split_paragraphs() {
  awk 'BEGIN{RS=""; ORS="\0"} {print}'
}

# clean_paragraph — route one paragraph to the code or the prose cleaner.
# Args:    $1 paragraph text
# Returns: 0 always; stdout: cleaned paragraph
# Globals: none
clean_paragraph() {
  local block="$1"
  # Classification decides which cleaner runs.
  if looks_like_code "$block"; then
    printf '%s' "$block" | normalize_code
  else
    printf '%s' "$block" | normalize_prose
  fi
}

# join_paragraph — append a cleaned paragraph, separated by a space or ". ".
# Args:    $1 text so far (may be empty) | $2 paragraph to append
# Returns: 0 always; stdout: the joined text
# Globals: none
join_paragraph() {
  local so_far="$1" addition="$2"
  # The first paragraph starts the text.
  [ -n "$so_far" ] || { printf '%s' "$addition"; return 0; }
  case "$so_far" in
    *[.\!?:\;]) printf '%s %s' "$so_far" "$addition" ;;  # already ends a clause
    *)          printf '%s. %s' "$so_far" "$addition" ;;
  esac
}

# code_signal_symbols — signal 1: more than 4% of the characters are braces/operators.
# Args:    $1 text
# Returns: 0 when the symbol density is above the threshold; 1 otherwise
# Globals: reads CODE_SYMBOL_CHARS
code_signal_symbols() {
  local text="$1" total symbol_count
  total=${#text}
  # tr -dc keeps only the symbol characters, wc counts them.
  symbol_count=$(printf '%s' "$text" | tr -dc "$CODE_SYMBOL_CHARS" | wc -c)
  awk -v s="$symbol_count" -v t="$total" 'BEGIN{ exit !(t>0 && s/t > 0.04) }'
}

# code_signal_keywords — signal 2: a keyword of a mainstream language is present.
# Args:    $1 text
# Returns: 0 when a keyword matches; 1 otherwise
# Globals: reads CODE_KEYWORD_REGEX
code_signal_keywords() {
  printf '%s' "$1" | grep -Eq "$CODE_KEYWORD_REGEX"
}

# code_signal_indent — signal 3: two or more indented lines (bodies of blocks).
# Args:    $1 text
# Returns: 0 when at least two lines are indented; 1 otherwise
# Globals: none
code_signal_indent() {
  local indented
  # The tab is written as a literal one because grep warns about the \t escape.
  indented=$(printf '%s' "$1" | grep -Ec $'^([[:space:]]{2,}|\t)[^[:space:]]')
  # Two indented lines are enough to call it a block body.
  [ "$indented" -ge 2 ]
}

# code_signal_identifiers — signal 4: camelCase or snake_case identifiers are present.
# Args:    $1 text
# Returns: 0 when an identifier style matches; 1 otherwise
# Globals: none
code_signal_identifiers() {
  printf '%s' "$1" | grep -Eq '[a-z][A-Z]|[a-zA-Z][0-9]*_[a-zA-Z]'
}

# looks_like_code — best-effort code heuristic: at least 2 of 4 independent signals agree.
# Args:    $1 paragraph text
# Returns: 0 when it looks like code; 1 otherwise (also for empty text)
# Globals: none
# Notes:   Not a parser; very short snippets may go either way, which is harmless.
looks_like_code() {
  local text="$1" score=0
  [ "${#text}" -gt 0 ] || return 1
  # Each independent signal adds one point.
  code_signal_symbols "$text" && score=$((score + 1))
  code_signal_keywords "$text" && score=$((score + 1))
  code_signal_indent "$text" && score=$((score + 1))
  # camelCase/snake_case is the last independent signal.
  code_signal_identifiers "$text" && score=$((score + 1))
  [ "$score" -ge 2 ]
}

# code_operators_to_words — spell meaningful operators as words (longest match first).
# Args:    none (stdin code)
# Returns: 0 always; stdout: code with operators as words
# Globals: none
code_operators_to_words() {
  sed -E \
    -e 's/===/ strictly equals /g' -e 's/!==/ strictly not equal to /g' \
    -e 's/==/ equals /g' -e 's/!=/ not equal to /g' \
    -e 's/<=/ less than or equal to /g' -e 's/>=/ greater than or equal to /g' \
    -e 's/=>/ arrow /g' -e 's/->/ arrow /g' -e 's/&&/ and /g' -e 's/\|\|/ or /g' \
    -e 's/\+=/ plus equals /g' -e 's/-=/ minus equals /g' -e 's/::/ scope /g'
}

# code_strip_comment_markers — drop comment markers but keep the comment text.
# Args:    none (stdin code)
# Returns: 0 always; stdout: code without //, #, /* and */ markers
# Globals: none
code_strip_comment_markers() {
  sed -E \
    -e 's|^([[:space:]]*)//+[[:space:]]?|\1|' -e 's|^([[:space:]]*)#+[[:space:]]?|\1|' \
    -e 's|/\*+[[:space:]]?||g' -e 's|[[:space:]]?\*+/||g'
}

# code_split_identifiers — split camelCase/snake_case, turn structure into breaks.
# Args:    none (stdin code)
# Returns: 0 always; stdout: pronounceable words; braces/semicolons became periods
# Globals: none
# Notes:   Brackets become a SPACE, not nothing, so getName(user) never glues to Nameuser.
code_split_identifiers() {
  sed -E \
    -e 's/([a-z0-9])([A-Z])/\1 \2/g' -e 's/_/ /g' \
    -e 's/[{};]/./g' -e 's/[][()]/ /g'
}

# code_drop_empty_lines — remove lines that only contain periods and whitespace.
# Args:    none (stdin lines)
# Returns: 0 always; stdout: the remaining lines
# Globals: none
code_drop_empty_lines() {
  awk '{ t=$0; gsub(/[.[:space:]]/, "", t); if (t != "") print }'
}

# tidy_code_lines — collapse whitespace and stray punctuation in code lines.
# Args:    none (stdin lines)
# Returns: 0 always; stdout: the tidy lines
# Globals: none
tidy_code_lines() {
  sed -E \
    -e 's/[[:space:]]+/ /g' -e 's/[[:space:]]+([.!?,;:])/\1/g' \
    -e 's/\.{2,}/./g' -e 's/^[[:space:]]+|[[:space:]]+$//g'
}

# normalize_code — make source code listenable instead of an unbroken buzz of punctuation.
# Args:    none (stdin code)
# Returns: 0 always; stdout: speakable lines
# Globals: none
# Notes:   Text transform, not a parser: it cannot tell a "//" string from a comment.
normalize_code() {
  # One small stage per concern, chained in the order the rules depend on.
  code_operators_to_words \
    | code_strip_comment_markers \
    | code_split_identifiers \
    | code_drop_empty_lines \
    | tidy_code_lines
}

# prose_strip_invisible — remove NBSP/zero-width/BOM/soft-hyphen bytes (UTF-8 aware).
# Args:    none (stdin text)
# Returns: 0 always; stdout: text without invisible characters
# Globals: none
# Notes:   tr does NOT understand \xNN, so this must be sed under LC_ALL=C.
prose_strip_invisible() {
  LC_ALL=C sed -E \
    -e 's/\xc2\xa0/ /g' -e 's/\xe2\x80\x8b//g' -e 's/\xe2\x80\x8c//g' \
    -e 's/\xe2\x80\x8d//g' -e 's/\xef\xbb\xbf//g' -e 's/\xc2\xad//g'
}

# prose_strip_markdown — rewrite markdown/links/e-mail into plain speakable text.
# Args:    none (stdin text)
# Returns: 0 always; stdout: text without markdown syntax
# Globals: none
prose_strip_markdown() {
  sed -E \
    -e 's/!\[([^]]*)\]\([^)]*\)/\1/g' -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    -e 's#https?://[^[:space:]]+#(link)#g' -e 's#www\.[^[:space:]]+#(link)#g' \
    -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/(email)/g' \
    -e 's/`+//g' -e 's/(\*\*|\*|~~)//g' \
    -e 's/^([[:space:]]*)#{1,6}[[:space:]]+/\1/' -e 's/^([[:space:]]*)>[[:space:]]+/\1/' \
    -e 's/^([[:space:]]*)[-*+•][[:space:]]+/\1/' \
    -e 's/^([[:space:]]*)[0-9]+[.)][[:space:]]+/\1/' \
    -e 's/[[:space:]]*\|[[:space:]]*/, /g' \
    -e 's/([-=*.#~])\1{2,}/ /g' -e 's/([.!?,;:])\1+/\1/g' \
    -e 's/([[:space:]][-–—]){2,}[[:space:]]/ /g'
}

# prose_join_lines — join lines into one; blank lines become sentence breaks.
# Args:    none (stdin lines)
# Returns: 0 always; stdout: a single line
# Globals: none
prose_join_lines() {
  awk '
    # Trim every line; empty lines only mark a pending sentence break.
    { line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") { pending_break=1; next }
      # Lines without any letter or digit (decorative separators) are skipped.
      stripped=line; gsub(/[[:alnum:]]/, "", stripped)
      if (stripped == line) next
      # A break ends the sentence unless the text already ends with punctuation.
      if (out != "") {
        if (pending_break) out = (out ~ /[.!?:;,]$/) ? out " " : out ". "
        else out = out " "
      }
      # Append the line and clear the pending break.
      out = out line; pending_break=0 }
    END { print out }'
}

# prose_tidy — final whitespace and punctuation tidy-up of the joined line.
# Args:    none (stdin line)
# Returns: 0 always; stdout: the tidy line
# Globals: none
prose_tidy() {
  sed -E \
    -e 's/[[:space:]]+/ /g' -e 's/[[:space:]]+([.!?,;:])/\1/g' \
    -e 's/([.!?])[.]+/\1/g' -e 's/(\. ){2,}/. /g' -e 's/^[ ,]+//; s/[[:space:]]+$//'
}

# normalize_prose — strip markdown, links and decoration so prose reads naturally.
# Args:    none (stdin paragraph)
# Returns: 0 always; stdout: one line of cleaned prose (meaning preserved)
# Globals: none
normalize_prose() {
  # Byte-level invisibles first, then control whitespace to plain spaces.
  prose_strip_invisible \
    | tr '\t\r\v\f' '    ' \
    | prose_strip_markdown \
    | prose_join_lines \
    | prose_tidy
}

# split_sentence_ends — put a newline after sentence-ending punctuation and after ; and :.
# Args:    none (stdin text)
# Returns: 0 always; stdout: text with one sentence-sized piece per line
# Globals: none
split_sentence_ends() {
  sed -E 's/([.!?…]+)([[:space:]]|$)/\1\n/g; s/([;:])[[:space:]]/\1\n/g'
}

# wrap_long_lines — cut lines longer than a limit at the last space before it.
# Args:    $1 maximum characters per line
# Returns: 0 always; stdout: lines no longer than the limit (unless unbreakable)
# Globals: none
wrap_long_lines() {
  awk -v max="$1" '
    # Cut at the last space inside the limit; hard-cut an unbreakable run.
    { line=$0
      while (length(line) > max) {
        cut=max
        # Walk back to the last space inside the limit.
        while (cut > 1 && substr(line, cut, 1) != " ") cut--
        if (cut <= 1) cut=max
        # Emit the head of the line and continue with the rest.
        chunk=substr(line, 1, cut); sub(/ +$/, "", chunk)
        if (length(chunk) > 0) print chunk
        line=substr(line, cut+1); sub(/^ +/, "", line)
      }
      # Whatever is left fits within the limit.
      if (length(line) > 0) print line }'
}

# chunk_text — split text into sentence-sized chunks, one per line.
# Args:    none (stdin text)
# Returns: 0 always; stdout: chunks, wrapped at CHUNK_MAX (default 240) characters
# Globals: reads CHUNK_MAX
chunk_text() {
  # Sentence ends become newlines, blank lines are dropped, long lines wrapped.
  split_sentence_ends | awk 'NF' | wrap_long_lines "${CHUNK_MAX:-240}"
}
