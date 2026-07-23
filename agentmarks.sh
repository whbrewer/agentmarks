# agentmarks — bashmarks-style bookmarks for coding-agent sessions
# (Claude Code and Codex CLI).
# Source from .bashrc:  source ~/.local/bin/agentmarks.sh
#
#   xs <name> [note...]    save a mark for the current/most-recent session here
#   xg [name]              cd to the mark's dir and resume its session
#   xl [-l|--long]         list marks (-l adds the first-message preview)
#   xd <name>              remove a mark
#   xq                     is this session / directory marked?
#   xj [pattern]           journal of past sessions, cross-referenced with marks
#
# State lives under ~/.agentmarks/:
#   marks.jsonl  one JSON object per line, one per mark:
#                {name, dir, session_id, note, date, first_message, home, tool}
#   journal.tsv  one line per ended session, written by the SessionEnd hook
# where tool is "claude" or "codex" (empty = claude, for old marks) and
# home is the CLAUDE_CONFIG_DIR / CODEX_HOME the session lives in, so
# marks from different accounts and tools coexist and resume correctly.
# marks.jsonl requires jq, already a hard dependency (am_first_msg etc.);
# JSON sidesteps two TSV foot-guns a plain delimiter has: notes/messages
# containing a literal tab no longer misalign columns, and a field left
# empty (e.g. old-format home) can't shift every field after it (bash's
# `read` collapses adjacent tab delimiters since tab counts as IFS
# whitespace regardless of what IFS is set to).
#
# Candidate homes when guessing: $AGENTMARKS_CONFIG_DIRS (colon-separated)
# else every existing ~/.claude*; $AGENTMARKS_CODEX_HOMES else $CODEX_HOME
# else every existing ~/.codex*.

# Resolved inside each function (not at source time): Claude Code's shell
# snapshots restore functions but not unexported variables, so a top-level
# assignment would be lost in `!` shells inside sessions.

# One-time migration from the old flat dotfiles (~/.agentmarks as a plain
# file, ~/.agentmarks-journal) to the ~/.agentmarks/ directory layout.
# Cheap and idempotent -- safe to call from every command; once migrated
# it's just a couple of stat checks that find nothing left to do.
am_migrate () {
  local dir="$HOME/.agentmarks"
  if [ -f "$dir" ] && [ ! -d "$dir" ]; then
    # The old marks file and the new marks directory share this exact
    # path, so the file has to move out of the way before mkdir can
    # claim it.
    local tmp; tmp="$(mktemp "$HOME/.agentmarks-migrate.XXXXXX")"
    mv "$dir" "$tmp"
    mkdir -p "$dir"
    mv "$tmp" "$dir/marks.tsv"
  else
    mkdir -p "$dir"
  fi
  if [ -f "$HOME/.agentmarks-journal" ] && [ ! -f "$dir/journal.tsv" ]; then
    mv "$HOME/.agentmarks-journal" "$dir/journal.tsv"
  fi
  rm -f "$HOME/.agentmarks-journal.lock" "$HOME/.agentmarks-journal.tmp" 2>/dev/null
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
}

am_claude_dirs () {
  if [ -n "$AGENTMARKS_CONFIG_DIRS" ]; then
    printf '%s\n' "$AGENTMARKS_CONFIG_DIRS" | tr ':' '\n'
  else
    local d
    for d in "$HOME"/.claude "$HOME"/.claude-*; do
      [ -d "$d/projects" ] && printf '%s\n' "$d"
    done
  fi
}

am_codex_homes () {
  if [ -n "$AGENTMARKS_CODEX_HOMES" ]; then
    printf '%s\n' "$AGENTMARKS_CODEX_HOMES" | tr ':' '\n'
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
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks/marks.jsonl}"
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
  local first; first="$(am_first_msg "$file")"
  {
    [ -f "$AGENTMARKS_FILE" ] && jq -c --arg n "$name" 'select(.name != $n)' "$AGENTMARKS_FILE"
    jq -n -c \
      --arg name "$name" --arg dir "$markdir" --arg sid "$sid" \
      --arg note "${note:--}" --arg date "$(date '+%F %H:%M')" \
      --arg first "${first:--}" --arg home "$home" --arg tool "$tool" \
      '{name: $name, dir: $dir, session_id: $sid, note: $note, date: $date,
        first_message: $first, home: $home, tool: $tool}'
  } > "$AGENTMARKS_FILE.tmp" && mv "$AGENTMARKS_FILE.tmp" "$AGENTMARKS_FILE"
  echo "marked '$name' → $sid  [$tool/$(am_account "$home")]  ($markdir)"
}

xg () {
  am_migrate
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks/marks.jsonl}"
  [ -s "$AGENTMARKS_FILE" ] || { echo "xg: no marks yet" >&2; return 1; }
  local name="$1" line
  if [ -z "$name" ]; then
    if command -v fzf >/dev/null 2>&1; then
      line="$(jq -r '[.name, .note, .first_message] | @tsv' "$AGENTMARKS_FILE" \
        | fzf --delimiter='\t' --with-nth=1,2,3)" || return 1
      name="$(printf '%s' "$line" | cut -f1)"
    else
      xl; printf 'usage: xg <name>\n' >&2; return 1
    fi
  fi
  line="$(jq -c --arg n "$name" 'select(.name == $n)' "$AGENTMARKS_FILE" | tail -1)"
  [ -n "$line" ] || { echo "xg: no such mark: $name" >&2; return 1; }
  local dir sid home tool
  dir="$(jq -r '.dir' <<<"$line")"
  sid="$(jq -r '.session_id' <<<"$line")"
  home="$(jq -r '.home' <<<"$line")"
  tool="$(jq -r '.tool' <<<"$line")"
  tool="${tool:-claude}"
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
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks/marks.jsonl}"
  local long=0
  case "$1" in -l|--long|--full) long=1 ;; esac
  [ -s "$AGENTMARKS_FILE" ] || { echo "xl: no marks yet" >&2; return 1; }
  # TOOL is only worth a column when marks actually mix tools; with every
  # session on claude (the common case) it's a repeated no-op value.
  local show_tool=0
  [ "$(jq -s 'any(.[]; .tool == "codex")' "$AGENTMARKS_FILE")" = true ] && show_tool=1
  { if [ "$long" = 1 ]; then
      if [ "$show_tool" = 1 ]; then
        printf 'NAME\tTOOL\tACCOUNT\tDIR\tNOTE\tDATE\tFIRST MESSAGE\n'
      else
        printf 'NAME\tACCOUNT\tDIR\tNOTE\tDATE\tFIRST MESSAGE\n'
      fi
    else
      if [ "$show_tool" = 1 ]; then
        printf 'NAME\tTOOL\tACCOUNT\tDIR\tNOTE\tDATE\n'
      else
        printf 'NAME\tACCOUNT\tDIR\tNOTE\tDATE\n'
      fi
    fi
    local IFS=$'\x1f' name dir sid note date first home tool
    local maxlen="${AGENTMARKS_NOTE_MAXLEN:-52}"
    while read -r name dir sid note date first home tool; do
      tool="${tool:-claude}"
      [ -n "$home" ] || { [ "$tool" = codex ] && home="$HOME/.codex" || home="$HOME/.claude"; }
      case "$dir" in
        "$HOME") dir="~" ;;
        "$HOME"/*) dir="~${dir#"$HOME"}" ;;
      esac
      if [ "$long" = 1 ]; then
        if [ "$show_tool" = 1 ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$tool" "$(am_account "$home")" "$dir" "$note" "$date" "$first"
        else
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$(am_account "$home")" "$dir" "$note" "$date" "$first"
        fi
      else
        if [ "$show_tool" = 1 ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$tool" "$(am_account "$home")" "$dir" "$(am_truncate "$note" "$maxlen")" "$date"
        else
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$(am_account "$home")" "$dir" "$(am_truncate "$note" "$maxlen")" "$date"
        fi
      fi
    done < <(jq -r '[.name, .dir, .session_id, .note, .date, .first_message, .home, .tool]
                    | join("")' "$AGENTMARKS_FILE")
  } | column -t -s"$(printf '\t')"
}

# xj: journal of ended sessions, written by the agentmarks-sessionend hook
# (make install-hook). Newest first; optional pattern filters, else last 20.
xj () {
  am_migrate
  local j="${AGENTMARKS_JOURNAL:-$HOME/.agentmarks/journal.tsv}"
  local marksfile="${AGENTMARKS_FILE:-$HOME/.agentmarks/marks.jsonl}"
  [ -s "$j" ] || {
    echo "xj: no journal yet — install the SessionEnd hook: make install-hook" >&2
    return 1
  }
  { printf 'DATE\tMARK\tACCOUNT\tDIR\tSUMMARY\n'
    local IFS=$'\t' date sid dir home reason summary mark
    tac "$j" | { [ -n "$1" ] && grep -i -- "$1" || head -20; } \
    | while read -r date sid dir home reason summary; do
        mark="$(jq -r --arg s "$sid" 'select(.session_id == $s) | .name' "$marksfile" 2>/dev/null | head -1)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$date" "${mark:--}" "$(am_account "$home")" "$dir" "$summary"
      done
  } | column -t -s"$(printf '\t')"
}

# xq: is this session saved? Inside a Claude Code session (`! xq`) checks
# that exact session; outside, shows any marks for the current directory.
xq () {
  am_migrate
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks/marks.jsonl}"
  local hits
  if [ -n "$CLAUDE_CODE_SESSION_ID" ]; then
    hits="$(jq -r --arg s "$CLAUDE_CODE_SESSION_ID" \
      'select(.session_id == $s) | "  " + .name + "  (" + .note + ")"' "$AGENTMARKS_FILE" 2>/dev/null)"
    if [ -n "$hits" ]; then
      echo "this session is marked:"; printf '%s\n' "$hits"
    else
      echo "this session is NOT marked — save it with: xs <name> [note...]"
      return 1
    fi
  else
    hits="$(jq -r --arg d "$PWD" \
      'select(.dir == $d) | "  " + .name + "  (" + .note + ")"' "$AGENTMARKS_FILE" 2>/dev/null)"
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
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks/marks.jsonl}"
  [ -n "$1" ] || { echo "usage: xd <name>" >&2; return 1; }
  [ -s "$AGENTMARKS_FILE" ] || { echo "xd: no marks yet" >&2; return 1; }
  jq -e --arg n "$1" 'select(.name == $n)' "$AGENTMARKS_FILE" >/dev/null 2>&1 \
    || { echo "xd: no such mark: $1" >&2; return 1; }
  jq -c --arg n "$1" 'select(.name != $n)' "$AGENTMARKS_FILE" > "$AGENTMARKS_FILE.tmp" \
    && mv "$AGENTMARKS_FILE.tmp" "$AGENTMARKS_FILE"
  echo "removed '$1'"
}

# Tab completion for mark names on xg/xd (and xs, so overwriting an
# existing mark can be completed too). Bash only -- zsh users with
# bashcompinit loaded will pick this up as well since it uses the same
# `complete` builtin, but this isn't tested under plain zsh.
am_complete () {
  local f="${AGENTMARKS_FILE:-$HOME/.agentmarks/marks.jsonl}"
  [ -r "$f" ] || return 0
  local cur=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=( $(compgen -W "$(jq -r '.name' "$f" 2>/dev/null)" -- "$cur") )
}
if [ -n "$BASH_VERSION" ]; then
  complete -F am_complete xg xd xs
fi
