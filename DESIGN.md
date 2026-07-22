# agentmarks — bashmarks-style bookmarks for coding-agent sessions

## Goal
Bookmark a Claude Code session the way bashmarks bookmarks directories:
save `<name>` → later jump back with one command that (a) cd's into the
run directory and (b) resumes the exact session, plus a short human note
("the one where we designed the pact schema") so marks stay findable
weeks later.

Bashmarks verbs for reference: `s` save, `g` go, `l` list, `d` delete.
Agentmarks equivalent: `xs`, `xg`, `xl`, `xd`.

## Raw material Claude Code already gives us
- Sessions live at `~/.claude/projects/<munged-cwd>/<session-id>.jsonl`,
  where the munged cwd is the absolute path with `/` (and `.`) turned into
  `-` — e.g. `/home/w1b/stubs` → `-home-w1b-stubs`.
- `claude --resume <session-id>` reopens a specific session;
  `claude -c` only gets you "most recent in this dir", which is exactly
  the fragile thing claudemarks replaces.
- Hooks (SessionStart/Stop) and the statusline both receive `session_id`
  in their JSON input — useful if marking should happen from *inside* a
  session rather than after the fact.

## Design v1: pure shell, mark after the fact
Store marks in `~/.claudemarks` as one line per mark
(`name<TAB>dir<TAB>session_id<TAB>note<TAB>date`). Sourced shell functions:

```bash
# save: bookmark the most recent session for the current directory
cms () {
  local name="$1"; shift
  local note="$*"
  local proj="$HOME/.claude/projects/$(pwd | sed 's/[\/.]/-/g')"
  local sid
  sid="$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1 | xargs -r basename | sed 's/\.jsonl$//')"
  [ -n "$sid" ] || { echo "no claude sessions found for $(pwd)" >&2; return 1; }
  grep -v "^$name	" "$HOME/.claudemarks" 2>/dev/null > "$HOME/.claudemarks.tmp" || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$PWD" "$sid" "$note" "$(date +%F)" >> "$HOME/.claudemarks.tmp"
  mv "$HOME/.claudemarks.tmp" "$HOME/.claudemarks"
}

# go: cd to the mark's dir and resume its session
cmg () {
  local line; line="$(grep "^$1	" "$HOME/.claudemarks")" || { echo "no such mark" >&2; return 1; }
  cd "$(echo "$line" | cut -f2)" && claude --resume "$(echo "$line" | cut -f3)"
}

# list / delete
cml () { column -t -s'	' "$HOME/.claudemarks"; }
cmd () { grep -v "^$1	" "$HOME/.claudemarks" > "$HOME/.claudemarks.tmp" && mv "$HOME/.claudemarks.tmp" "$HOME/.claudemarks"; }
```

Weakness of v1: `cms` guesses "most recent session in this dir", which is
wrong if you've since opened another session here. Fine for the common
"bookmark what I just did" flow.

## Design v2 (maybe later): mark from inside the session
A tiny user-level slash command / skill (`/mark <name> <note>`) that has
Claude itself append the mark line — it knows the real session id and cwd,
so no guessing. Could also auto-generate the note from the conversation
("summarize this session in ≤10 words"), which is the part bashmarks
could never do. A SessionStart hook could alternatively log every
session's id+cwd+timestamp to a journal, so `cms` picks from a menu
instead of guessing.

## Context beyond the note
The jsonl itself contains the first user message — `cml` could show it as
a fallback note, or `cms` could extract it at save time so listing stays
fast. Keep it in the marks file (denormalized) so marks survive Claude
Code's own session cleanup/expiry.

## Open questions — resolved 2026-07-22 while building v1
- Path munging: verified against real project dirs (via the `cwd` field
  inside the jsonls, which is ground truth): every non-alphanumeric char
  of the cwd becomes `-`, so munge with `sed 's/[^A-Za-z0-9]/-/g'`.
- `CLAUDE_CONFIG_DIR` exists (this machine uses `~/.claude-personal` and
  `~/.claude-work` for two accounts) — each mark records its session's
  config dir and `cmg` resumes with it, so both accounts share one marks
  list. Guessing searches all `~/.claude*` dirs (override with
  `CLAUDEMARKS_CONFIG_DIRS`).
- Big v1 upgrade found: shells spawned from inside a session export
  `CLAUDE_CODE_SESSION_ID`, so `! cms foo` marks the *exact* session —
  the "guess most recent" fallback only applies outside a session. This
  makes most of v2's motivation moot.
- Session expiry: handled defensively — `cmg` still cd's and warns if the
  jsonl is gone; the first-message preview is denormalized into the marks
  file at save time so listings survive expiry. (Whether/when Claude Code
  actually GCs jsonls: still unknown, but it no longer matters much.)
- Verbs: settled on `xs/xg/xl/xd` after several rounds — `cm*` felt wrong
  once the tool went multi-agent, and the obvious `as` (from agentmarks)
  is the GNU assembler, which gcc finds via PATH, so an `as` wrapper in
  ~/.local/bin would hijack every C/Fortran build. The x* namespace is
  collision-free (xs/xl are Xen tools, but only on Xen hosts). `xg` with
  no args fzf-picks if fzf is installed (it isn't, currently).
- Name: renamed claudemarks → agentmarks when Codex support landed
  (2026-07-22). A dead archived kanywst/claudemarks exists on GitHub
  (different design: a SessionEnd hook journaling every session);
  "agentmarks" was free.

## Codex support (added same day)
Codex CLI has the same primitives: `codex resume <uuid>`, sessions as
jsonl under `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`
with a first-line `session_meta` record carrying id + cwd (ground truth).
No per-project layout, so "newest session for this dir" scans recent
rollout files for a matching cwd. Marks record tool + home dir (field 8 +
7); `xg` dispatches to the right resume command with the right
CLAUDE_CONFIG_DIR / CODEX_HOME. Codex exports no session id to child
shells, so exact in-session marking stays Claude-only.

## Status
Built, tested, installed: `agentmarks/` in this repo (agentmarks.sh,
xs dispatcher, Makefile, README). `make install` → ~/.local/bin;
`source ~/.local/bin/agentmarks.sh` in .bashrc (above the interactive
guard). Marks in ~/.agentmarks. Do v2 (auto-generated notes via /mark
skill) only if this sticks.
