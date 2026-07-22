# agentmarks — bashmarks-style bookmarks for coding-agent sessions
# (Claude Code and Codex CLI).
# Source from .bashrc:  source ~/.local/bin/agentmarks.sh
#
#   xs <name> [note...]    save a mark for the current/most-recent session here
#   xg [name]              cd to the mark's dir and resume its session
#   xl                     list marks
#   xd <name>              remove a mark
#
# Marks live in ~/.agentmarks, one TSV line per mark:
#   name  dir  session_id  note  date  first-user-message  home_dir  tool
# where tool is "claude" or "codex" (empty = claude, for old marks) and
# home_dir is the CLAUDE_CONFIG_DIR / CODEX_HOME the session lives in, so
# marks from different accounts and tools coexist and resume correctly.
#
# Candidate homes when guessing: $AGENTMARKS_CONFIG_DIRS (colon-separated)
# else every existing ~/.claude*; $AGENTMARKS_CODEX_HOMES else $CODEX_HOME
# else every existing ~/.codex*.

# Resolved inside each function (not at source time): Claude Code's shell
# snapshots restore functions but not unexported variables, so a top-level
# assignment would be lost in `!` shells inside sessions.

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
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks}"
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
    [ -f "$AGENTMARKS_FILE" ] && awk -F'\t' -v n="$name" '$1 != n' "$AGENTMARKS_FILE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$markdir" "$sid" "${note:--}" "$(date +%F)" "${first:--}" "$home" "$tool"
  } > "$AGENTMARKS_FILE.tmp" && mv "$AGENTMARKS_FILE.tmp" "$AGENTMARKS_FILE"
  echo "marked '$name' → $sid  [$tool/$(am_account "$home")]  ($markdir)"
}

xg () {
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks}"
  [ -s "$AGENTMARKS_FILE" ] || { echo "xg: no marks yet" >&2; return 1; }
  local name="$1" line
  if [ -z "$name" ]; then
    if command -v fzf >/dev/null 2>&1; then
      line="$(fzf --delimiter='\t' --with-nth=1,4,6 < "$AGENTMARKS_FILE")" || return 1
      name="$(printf '%s' "$line" | cut -f1)"
    else
      xl; printf 'usage: xg <name>\n' >&2; return 1
    fi
  fi
  line="$(awk -F'\t' -v n="$name" '$1 == n' "$AGENTMARKS_FILE")"
  [ -n "$line" ] || { echo "xg: no such mark: $name" >&2; return 1; }
  local dir sid home tool
  dir="$(printf '%s' "$line" | cut -f2)"
  sid="$(printf '%s' "$line" | cut -f3)"
  home="$(printf '%s' "$line" | cut -f7)"
  tool="$(printf '%s' "$line" | cut -f8)"
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
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks}"
  [ -s "$AGENTMARKS_FILE" ] || { echo "xl: no marks yet" >&2; return 1; }
  { printf 'NAME\tTOOL\tACCOUNT\tDIR\tNOTE\tDATE\tFIRST MESSAGE\n'
    local IFS=$'\t' name dir sid note date first home tool
    while read -r name dir sid note date first home tool; do
      tool="${tool:-claude}"
      [ -n "$home" ] || { [ "$tool" = codex ] && home="$HOME/.codex" || home="$HOME/.claude"; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$tool" "$(am_account "$home")" "$dir" "$note" "$date" "$first"
    done < "$AGENTMARKS_FILE"
  } | column -t -s"$(printf '\t')"
}

xd () {
  local AGENTMARKS_FILE="${AGENTMARKS_FILE:-$HOME/.agentmarks}"
  [ -n "$1" ] || { echo "usage: xd <name>" >&2; return 1; }
  [ -s "$AGENTMARKS_FILE" ] || { echo "xd: no marks yet" >&2; return 1; }
  grep -q "^$1$(printf '\t')" "$AGENTMARKS_FILE" \
    || { echo "xd: no such mark: $1" >&2; return 1; }
  awk -F'\t' -v n="$1" '$1 != n' "$AGENTMARKS_FILE" > "$AGENTMARKS_FILE.tmp" \
    && mv "$AGENTMARKS_FILE.tmp" "$AGENTMARKS_FILE"
  echo "removed '$1'"
}
