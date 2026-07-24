# xmarks — bashmarks-style bookmarks for coding-agent sessions
# (Claude Code and Codex CLI).
# Source from .bashrc:  source ~/.local/bin/xmarks.sh
#
#   xs <name> [note...]    star the current/most-recent session here; an
#                          explicit [note...] always overwrites whatever
#                          description (auto or previous) was showing
#   xg [name|hash]         cd to its dir and resume the session (a
#                          starred name from xl, or any session's HASH
#                          from xj — no xs needed)
#   xl [-l|--long]         list starred sessions (-l shows ACCOUNT, the
#                          full path, and the untruncated NOTE/SUMMARY)
#   xd <name>              un-star a session (kept in xj, just drops out
#                          of xl — nothing is deleted)
#   xq                     is this session / directory starred?
#   xj [-l|--long] [pattern]  every session, oldest to newest (latest at
#                          the bottom); each row's HASH is an xg shortcut
#                          (-l adds ACCOUNT and the full path/SUMMARY)
#
# All state lives in one file, ~/.xmarks/sessions.jsonl, one JSON object
# per session:
#   {date, session_id, dir, home, tool, reason, summary, starred, name, note}
# date/reason/summary are auto-tracked by the hooks: the UserPromptSubmit
# hook seeds a row right after the first prompt (reason "in_progress",
# summary = that prompt's own text, no LLM call), so a session that dies
# without a clean exit -- a dropped SSH connection, say -- still shows up
# instead of vanishing entirely; SessionEnd overwrites reason/summary with
# the real outcome (a heuristic first message, patched in place with an
# LLM summary shortly after, unless XMARKS_AUTOSUMMARY=first).
# starred/name/note are only ever set by `xs` and cleared by `xd` (which
# un-stars rather than deleting the row). note is optional free text
# that, when given, always wins over summary for display; when absent,
# listings fall back to the auto summary -- so a session never needs a
# manual description to be meaningfully listed.
# tool is "claude" or "codex" (default "claude") and home is the
# CLAUDE_CONFIG_DIR / CODEX_HOME the session lives in, so sessions from
# different accounts and tools coexist and resume correctly.
#
# Candidate homes when guessing: $XMARKS_CONFIG_DIRS (colon-separated)
# else every existing ~/.claude*; $XMARKS_CODEX_HOMES else $CODEX_HOME
# else every existing ~/.codex*.

# Resolved inside each function (not at source time): Claude Code's shell
# snapshots restore functions but not unexported variables, so a top-level
# assignment would be lost in `!` shells inside sessions.

# One-time migration from the old flat dotfiles (~/.xmarks as a plain
# file, ~/.xmarks-journal) to the ~/.xmarks/ directory layout, then from
# TSV to JSONL, then from separate marks.jsonl/journal.jsonl to one
# sessions.jsonl. Cheap and idempotent -- safe to call from every
# command; once migrated it's just a few stat checks that find nothing
# left to do.
am_migrate () {
  local dir="$HOME/.xmarks"
  # One-time migration from the pre-rename ~/.agentmarks/ directory (the
  # repo was called agentmarks before it became xmarks).
  if [ -d "$HOME/.agentmarks" ] && [ ! -e "$dir" ]; then
    mv "$HOME/.agentmarks" "$dir"
  fi
  if [ -f "$dir" ] && [ ! -d "$dir" ]; then
    # The old marks file and the new marks directory share this exact
    # path, so the file has to move out of the way before mkdir can
    # claim it.
    local tmp; tmp="$(mktemp "$HOME/.xmarks-migrate.XXXXXX")"
    mv "$dir" "$tmp"
    mkdir -p "$dir"
    mv "$tmp" "$dir/marks.tsv"
  else
    mkdir -p "$dir"
  fi
  if [ -f "$HOME/.xmarks-journal" ] && [ ! -f "$dir/journal.tsv" ]; then
    mv "$HOME/.xmarks-journal" "$dir/journal.tsv"
  fi
  rm -f "$HOME/.xmarks-journal.lock" "$HOME/.xmarks-journal.tmp" 2>/dev/null
  # TSV -> JSONL, one-time: the old marks.tsv (8 tab-separated columns) is
  # kept as marks.tsv.bak rather than deleted, so a conversion mistake is
  # recoverable. jq's split("\t") -- unlike bash's `read` -- doesn't
  # collapse adjacent delimiters, so old rows with an empty field convert
  # correctly.
  if [ -f "$dir/marks.tsv" ] && [ ! -f "$dir/marks.jsonl" ]; then
    jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t"))
      | .[]
      | {name: .[0], dir: .[1], session_id: .[2], note: .[3], date: .[4],
         first_message: .[5], home: .[6],
         tool: (if (.[7] // "") == "" then "claude" else .[7] end)}
    ' "$dir/marks.tsv" > "$dir/marks.jsonl" \
      && mv "$dir/marks.tsv" "$dir/marks.tsv.bak"
  fi
  # Same TSV -> JSONL move for the journal (date, session_id, dir, home,
  # reason, summary), kept as journal.tsv.bak.
  if [ -f "$dir/journal.tsv" ] && [ ! -f "$dir/journal.jsonl" ]; then
    jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t"))
      | .[]
      | {date: .[0], session_id: .[1], dir: .[2], home: .[3], reason: .[4],
         summary: .[5]}
    ' "$dir/journal.tsv" > "$dir/journal.jsonl" \
      && mv "$dir/journal.tsv" "$dir/journal.tsv.bak"
  fi
  # marks.jsonl + journal.jsonl -> one sessions.jsonl: a mark becomes
  # starred=true (+ name/note) on the journal row for the same session
  # id. A marked session with no matching journal row at all (a codex
  # mark -- the hooks are Claude-only -- or a mark that predates the
  # journal) becomes its own starred-only row instead. Both source files
  # are kept as .bak, never deleted.
  if { [ -f "$dir/marks.jsonl" ] || [ -f "$dir/journal.jsonl" ]; } \
       && [ ! -f "$dir/sessions.jsonl" ]; then
    if jq -nc \
      --slurpfile marks <(cat "$dir/marks.jsonl" 2>/dev/null) \
      --slurpfile journal <(cat "$dir/journal.jsonl" 2>/dev/null) '
      ($marks | map({key: .session_id, value: .}) | from_entries) as $markidx
      | ($journal | map(.session_id)) as $jsids
      | ($journal | map(
          . as $j
          | ($markidx[$j.session_id] // null) as $m
          | {date: $j.date, session_id: $j.session_id, dir: $j.dir,
             home: $j.home, tool: ($m.tool // "claude"),
             reason: $j.reason, summary: $j.summary,
             starred: ($m != null), name: ($m.name // null),
             note: (if $m != null and ($m.note // "-") != "-"
                    then $m.note else null end)}
        )) as $fromjournal
      | ($marks | map(select((.session_id as $sid | $jsids | index($sid)) == null))
                | map({date: .date, session_id: .session_id, dir: .dir,
                       home: .home, tool: (.tool // "claude"), reason: null,
                       summary: (if (.first_message // "-") == "-"
                                 then null else .first_message end),
                       starred: true, name: .name,
                       note: (if (.note // "-") == "-"
                              then null else .note end)})) as $marksonly
      | ($fromjournal + $marksonly)[]
    ' > "$dir/sessions.jsonl.new" && [ -s "$dir/sessions.jsonl.new" ]; then
      mv "$dir/sessions.jsonl.new" "$dir/sessions.jsonl"
      [ -f "$dir/marks.jsonl" ] && mv "$dir/marks.jsonl" "$dir/marks.jsonl.bak"
      [ -f "$dir/journal.jsonl" ] && mv "$dir/journal.jsonl" "$dir/journal.jsonl.bak"
    else
      # Conversion failed (or produced nothing) -- leave the source files
      # in place untouched rather than risk losing marks/journal history;
      # am_migrate will just retry next time it's called.
      rm -f "$dir/sessions.jsonl.new"
    fi
  fi
}

am_claude_dirs () {
  if [ -n "$XMARKS_CONFIG_DIRS" ]; then
    printf '%s\n' "$XMARKS_CONFIG_DIRS" | tr ':' '\n'
  else
    local d
    for d in "$HOME"/.claude "$HOME"/.claude-*; do
      [ -d "$d/projects" ] && printf '%s\n' "$d"
    done
  fi
}

am_codex_homes () {
  if [ -n "$XMARKS_CODEX_HOMES" ]; then
    printf '%s\n' "$XMARKS_CODEX_HOMES" | tr ':' '\n'
  elif [ -n "$CODEX_HOME" ]; then
    printf '%s\n' "$CODEX_HOME"
  else
    local d
    for d in "$HOME"/.codex "$HOME"/.codex-*; do
      [ -d "$d/sessions" ] && printf '%s\n' "$d"
    done
  fi
}

am_proj_dir () {
  # Claude Code stores sessions under <config_dir>/projects/<munged cwd>,
  # where every non-alphanumeric character of the cwd becomes '-'.
  printf '%s/projects/%s' "$1" "$(printf '%s' "$2" | sed 's/[^A-Za-z0-9]/-/g')"
}

am_codex_latest () {
  # Newest codex session for cwd $2 under home $1. Codex files are date-
  # organized with no per-project dir, so scan newest-first (path order is
  # chronological) and match session_meta.cwd on line one.
  local f
  while IFS= read -r f; do
    if [ "$(head -1 "$f" | jq -r '.payload.cwd // empty' 2>/dev/null)" = "$2" ]; then
      printf '%s\n' "$f"; return 0
    fi
  done < <(find "$1/sessions" -name '*.jsonl' 2>/dev/null | sort -r | head -200)
  return 1
}

am_is_codex () {
  # Codex rollout files start with a session_meta record.
  head -c 200 "$1" 2>/dev/null | grep -q '"type":"session_meta"'
}

am_account () {
  # Short display name for a home dir: ~/.claude-work → work, ~/.codex → default.
  local b; b="$(basename "$1")"
  case "$b" in
    .claude|.codex) echo default ;;
    .claude-*) echo "${b#.claude-}" ;;
    .codex-*) echo "${b#.codex-}" ;;
    *) echo "$b" ;;
  esac
}

am_truncate () {
  # Truncate $1 to at most $2 chars total, ellipsis included, so the
  # displayed width never exceeds $2 (e.g. "traced Fugaku embedding
  # privacy risk, AIDRIN metrics" is exactly 52 chars, the default cap).
  local s="$1" max="$2"
  if [ "${#s}" -gt "$max" ]; then
    printf '%s...' "${s:0:$((max - 3))}"
  else
    printf '%s' "$s"
  fi
}

am_display_dir () {
  # $1 = raw dir, $2 = "1" for the full ~-shortened path (xl/xj -l); else
  # just the basename, so default listings stay narrow.
  local dir="$1"
  case "$dir" in
    "$HOME") dir="~" ;;
    "$HOME"/*) dir="~${dir#"$HOME"}" ;;
  esac
  if [ "$2" != 1 ] && [ "$dir" != "~" ] && [ "$dir" != "/" ]; then
    dir="$(basename "$dir")"
  fi
  printf '%s' "$dir"
}

am_first_msg () {
  # First real user message of a session file ($1), one line, trimmed.
  if am_is_codex "$1"; then
    jq -r 'select(.type == "event_msg" and .payload.type == "user_message")
           | .payload.message' "$1" 2>/dev/null
  else
    jq -r 'select(.type == "user" and .isSidechain != true)
           | .message.content
           | if type == "string" then .
             else (map(select(.type == "text") | .text) | join(" ")) end' \
        "$1" 2>/dev/null
  fi | sed 's/^[[:space:]]*//' | grep -v -e '^<' -e '^$' \
     | head -1 | tr '\t' ' ' | cut -c1-70
}

xs () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  [ -n "$1" ] || { echo "usage: xs <name> [note...]" >&2; return 1; }
  local name="$1"; shift
  local note="$*"
  local sid file home tool markdir="$PWD"
  if [ -n "$CLAUDE_CODE_SESSION_ID" ]; then
    # Running inside a Claude Code session (e.g. via `! xs foo`): no guessing.
    # (Codex exports no session id to child shells, so no codex equivalent.)
    tool=claude
    sid="$CLAUDE_CODE_SESSION_ID"
    home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    file="$(am_proj_dir "$home" "$PWD")/$sid.jsonl"
    # The shell may have cd'd away from the session's start dir; find the
    # session by id and mark its real cwd, so xg lands in the right place.
    [ -f "$file" ] \
      || file="$(find "$home/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1)"
    if [ -f "$file" ]; then
      markdir="$(grep -o '"cwd":"[^"]*"' "$file" | head -1 | cut -d'"' -f4)"
      markdir="${markdir:-$PWD}"
    fi
  else
    # Newest session for this dir across all claude config dirs + codex homes.
    local d f files=()
    while IFS= read -r d; do
      files+=( "$(am_proj_dir "$d" "$PWD")"/*.jsonl )
    done < <(am_claude_dirs)
    while IFS= read -r d; do
      f="$(am_codex_latest "$d" "$PWD")" && files+=( "$f" )
    done < <(am_codex_homes)
    file="$(ls -t "${files[@]}" 2>/dev/null | head -1)"
    [ -n "$file" ] || { echo "xs: no claude/codex sessions found for $PWD" >&2; return 1; }
    if am_is_codex "$file"; then
      tool=codex
      home="${file%/sessions/*}"
      sid="$(head -1 "$file" | jq -r '.payload.id')"
    else
      tool=claude
      home="${file%/projects/*}"
      sid="$(basename "$file" .jsonl)"
    fi
  fi
  # Preserve date/reason/summary from any row the hooks already wrote for
  # this session -- only starred/name/note/dir/home/tool change here. A
  # brand-new row (no hook has run yet, or a codex session the hooks never
  # touch) falls back to the session's first message as its summary.
  local existing date reason summary
  existing="$([ -f "$SESSIONS_FILE" ] && jq -c --arg s "$sid" 'select(.session_id == $s)' "$SESSIONS_FILE" | tail -1)"
  if [ -n "$existing" ]; then
    date="$(jq -r '.date' <<<"$existing")"
    reason="$(jq -r '.reason // empty' <<<"$existing")"
    summary="$(jq -r '.summary // empty' <<<"$existing")"
  else
    date="$(date '+%F %H:%M')"
    reason=""
    summary="$(am_first_msg "$file")"
  fi
  (
    flock -w 5 200 || true
    {
      # An explicit `xs` always wins the name -- if some other row already
      # has it, that row is un-starred (kept, per xd's own convention)
      # rather than leaving two starred rows sharing one name.
      [ -f "$SESSIONS_FILE" ] && jq -c --arg s "$sid" --arg n "$name" \
        'select(.session_id != $s)
         | if .name == $n then (.starred = false | .name = null | .note = null) else . end' \
        "$SESSIONS_FILE"
      jq -nc --arg date "$date" --arg sid "$sid" --arg dir "$markdir" \
        --arg home "$home" --arg tool "$tool" --arg reason "$reason" --arg summary "$summary" \
        --arg name "$name" --arg note "$note" \
        '{date: $date, session_id: $sid, dir: $dir, home: $home, tool: $tool,
          reason: (if $reason == "" then null else $reason end),
          summary: (if $summary == "" then null else $summary end),
          starred: true, name: $name,
          note: (if $note == "" then null else $note end)}'
    } > "$SESSIONS_FILE.tmp" && mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
  ) 200>"$SESSIONS_FILE.lock"
  echo "marked '$name' → $sid  [$tool/$(am_account "$home")]  ($markdir)"
}

xg () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  [ -s "$SESSIONS_FILE" ] || { echo "xg: no sessions yet" >&2; return 1; }
  local name="$1" line
  if [ -z "$name" ]; then
    if command -v fzf >/dev/null 2>&1; then
      line="$(jq -r 'select(.starred == true) | [.name, (.note // .summary // "-"), (.summary // "-")] | @tsv' "$SESSIONS_FILE" \
        | fzf --delimiter='\t' --with-nth=1,2,3)" || return 1
      name="$(printf '%s' "$line" | cut -f1)"
    else
      xl; printf 'usage: xg <name|hash>\n' >&2; return 1
    fi
  fi
  local dir sid home tool
  line="$(jq -c --arg n "$name" 'select(.starred == true and .name == $n)' "$SESSIONS_FILE" | tail -1)"
  if [ -z "$line" ]; then
    # Not a starred name -- try it as an xj HASH (a session_id prefix), so
    # sessions never explicitly `xs`'d are still one command to resume.
    line="$(jq -c --arg h "$name" 'select(.session_id | startswith($h))' "$SESSIONS_FILE" | tail -1)"
  fi
  [ -n "$line" ] || { echo "xg: no such mark or session: $name" >&2; return 1; }
  dir="$(jq -r '.dir' <<<"$line")"
  sid="$(jq -r '.session_id' <<<"$line")"
  home="$(jq -r '.home' <<<"$line")"
  tool="$(jq -r '.tool // "claude"' <<<"$line")"
  [ -d "$dir" ] || { echo "xg: directory gone: $dir" >&2; return 1; }
  cd "$dir" || return 1
  if [ "$tool" = codex ]; then
    home="${home:-$HOME/.codex}"
    if [ -z "$(find "$home/sessions" -name "*$sid.jsonl" -print -quit 2>/dev/null)" ]; then
      echo "xg: codex session $sid no longer exists in $home — you're in $dir" >&2
      return 1
    fi
    CODEX_HOME="$home" codex resume "$sid"
  else
    home="${home:-$HOME/.claude}"
    if [ ! -f "$(am_proj_dir "$home" "$dir")/$sid.jsonl" ]; then
      echo "xg: session $sid no longer exists in $home — you're in $dir" >&2
      return 1
    fi
    CLAUDE_CONFIG_DIR="$home" claude --resume "$sid"
  fi
}

xl () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  local long=0
  case "$1" in -l|--long|--full) long=1 ;; esac
  [ -s "$SESSIONS_FILE" ] || { echo "xl: no marks yet" >&2; return 1; }
  # TOOL is only worth a column when marks actually mix tools; with every
  # session on claude (the common case) it's a repeated no-op value.
  local show_tool=0
  [ "$(jq -s '[.[] | select(.starred == true)] | any(.[]; .tool == "codex")' "$SESSIONS_FILE")" = true ] && show_tool=1
  { if [ "$long" = 1 ]; then
      if [ "$show_tool" = 1 ]; then
        printf 'NAME\tTOOL\tACCOUNT\tDIR\tNOTE\tDATE\tSUMMARY\n'
      else
        printf 'NAME\tACCOUNT\tDIR\tNOTE\tDATE\tSUMMARY\n'
      fi
    else
      if [ "$show_tool" = 1 ]; then
        printf 'NAME\tTOOL\tACCOUNT\tDIR\tNOTE\tDATE\n'
      else
        printf 'NAME\tACCOUNT\tDIR\tNOTE\tDATE\n'
      fi
    fi
    local IFS=$'\x1f' name dir sid note date summary home tool
    local maxlen="${XMARKS_NOTE_MAXLEN:-52}"
    while read -r name dir sid note date summary home tool; do
      tool="${tool:-claude}"
      [ -n "$home" ] || { [ "$tool" = codex ] && home="$HOME/.codex" || home="$HOME/.claude"; }
      dir="$(am_display_dir "$dir" "$long")"
      if [ "$long" = 1 ]; then
        if [ "$show_tool" = 1 ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$tool" "$(am_account "$home")" "$dir" "${note:--}" "$date" "${summary:--}"
        else
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$(am_account "$home")" "$dir" "${note:--}" "$date" "${summary:--}"
        fi
      else
        local shown="${note:-$summary}"; shown="${shown:--}"
        if [ "$show_tool" = 1 ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$tool" "$(am_account "$home")" "$dir" "$(am_truncate "$shown" "$maxlen")" "$date"
        else
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$(am_account "$home")" "$dir" "$(am_truncate "$shown" "$maxlen")" "$date"
        fi
      fi
    done < <(jq -r 'select(.starred == true)
                    | [.name, .dir, .session_id, (.note // ""), .date, (.summary // ""), .home, .tool]
                    | join("\u001f")' "$SESSIONS_FILE")
  # -c 1000: util-linux column -t silently drops trailing columns that don't
  # fit the terminal width instead of wrapping -- a wide -l row would
  # otherwise lose SUMMARY with no indication anything was cut.
  } | column -t -s"$(printf '\t')" -c 1000
}

# xj: every session, written by the hooks (make install-hook). Oldest-to-
# newest (latest at the bottom); optional pattern filters, else last 20.
# -l/--long adds ACCOUNT and the full path/untruncated SUMMARY (default
# view drops ACCOUNT, shows just the dir basename, and shortens SUMMARY
# to keep columns narrow).
xj () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  local long=0
  case "$1" in -l|--long|--full) long=1; shift ;; esac
  [ -s "$SESSIONS_FILE" ] || {
    echo "xj: no journal yet — install the SessionEnd hook: make install-hook" >&2
    return 1
  }
  { if [ "$long" = 1 ]; then
      printf 'DATE\tHASH\tMARK\tACCOUNT\tDIR\tSUMMARY\n'
    else
      printf 'DATE\tHASH\tMARK\tDIR\tSUMMARY\n'
    fi
    # \x1f (not a literal tab) joins these fields: summary/reason can be
    # null for a marks-only historical row with no journal entry, and
    # bash's `read` collapses adjacent tab delimiters (tab counts as IFS
    # whitespace regardless of what IFS is set to) which would silently
    # shift every field after an empty one.
    local IFS=$'\x1f' date sid dir home reason summary mark
    local maxlen="${XMARKS_NOTE_MAXLEN:-52}"
    tac "$SESSIONS_FILE" | { [ -n "$1" ] && grep -i -- "$1" || head -20; } | tac \
    | jq -r '[.date, .session_id, .dir, .home, (.reason // ""), (.summary // ""),
              (if .starred == true then .name else "-" end)] | join("\u001f")' \
    | while read -r date sid dir home reason summary mark; do
        dir="$(am_display_dir "$dir" "$long")"
        if [ "$long" = 1 ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$date" "${sid:0:6}" "$mark" "$(am_account "$home")" "$dir" "$summary"
        else
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "$date" "${sid:0:6}" "$mark" "$dir" "$(am_truncate "$summary" "$maxlen")"
        fi
      done
  # -c 1000: same column -t width-truncation quirk as xl -- without it a
  # long -l SUMMARY silently vanishes instead of wrapping.
  } | column -t -s"$(printf '\t')" -c 1000
}

# xq: is this session saved? Inside a Claude Code session (`! xq`) checks
# that exact session; outside, shows any starred sessions for the current
# directory.
xq () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  local hits
  if [ -n "$CLAUDE_CODE_SESSION_ID" ]; then
    hits="$(jq -r --arg s "$CLAUDE_CODE_SESSION_ID" \
      'select(.session_id == $s and .starred == true) | "  " + .name + "  (" + (.note // .summary // "-") + ")"' \
      "$SESSIONS_FILE" 2>/dev/null)"
    if [ -n "$hits" ]; then
      echo "this session is marked:"; printf '%s\n' "$hits"
    else
      echo "this session is NOT marked — save it with: xs <name> [note...]"
      return 1
    fi
  else
    hits="$(jq -r --arg d "$PWD" \
      'select(.dir == $d and .starred == true) | "  " + .name + "  (" + (.note // .summary // "-") + ")"' \
      "$SESSIONS_FILE" 2>/dev/null)"
    if [ -n "$hits" ]; then
      echo "marks for $PWD:"; printf '%s\n' "$hits"
    else
      echo "no marks for $PWD"
      return 1
    fi
  fi
}

xd () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  [ -n "$1" ] || { echo "usage: xd <name>" >&2; return 1; }
  [ -s "$SESSIONS_FILE" ] || { echo "xd: no marks yet" >&2; return 1; }
  jq -e --arg n "$1" 'select(.starred == true and .name == $n)' "$SESSIONS_FILE" >/dev/null 2>&1 \
    || { echo "xd: no such mark: $1" >&2; return 1; }
  (
    flock -w 5 200 || true
    jq -c --arg n "$1" \
      'if .starred == true and .name == $n then (.starred = false | .name = null | .note = null) else . end' \
      "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp" && mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
  ) 200>"$SESSIONS_FILE.lock"
  echo "unmarked '$1' (session kept — see xj)"
}

# Tab completion for starred names on xd/xs (so overwriting an existing
# mark can be completed too) and for xg, which also completes journal
# HASHes so an unstarred session is still tab-completable. Bash only --
# zsh users with bashcompinit loaded will pick this up as well since it
# uses the same `complete` builtin, but this isn't tested under plain zsh.
am_complete () {
  local f="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  [ -r "$f" ] || return 0
  local cur=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=( $(compgen -W "$(jq -r 'select(.starred == true) | .name' "$f" 2>/dev/null)" -- "$cur") )
}
am_complete_xg () {
  local f="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  [ -r "$f" ] || return 0
  local names hashes
  names="$(jq -r 'select(.starred == true) | .name' "$f" 2>/dev/null)"
  hashes="$(jq -r '.session_id[0:6]' "$f" 2>/dev/null)"
  local cur=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=( $(compgen -W "$names $hashes" -- "$cur") )
}
if [ -n "$BASH_VERSION" ]; then
  complete -F am_complete_xg xg
  complete -F am_complete xd xs
fi
