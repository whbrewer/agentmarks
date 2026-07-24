# xmarks

Bashmarks-style bookmarks for coding-agent sessions (Claude Code and Codex
CLI): save a mark, later jump back with one command that cd's into the
directory *and* resumes the exact session. See `DESIGN.md` for the
design notes.

## Install

```bash
make install
echo 'source ~/.local/bin/xmarks.sh' >> ~/.bashrc
```

`make install` puts `xmarks.sh` plus the `xs/xg/xl/xd` command wrappers
into `~/.local/bin` (override with `PREFIX=...`); `make uninstall` removes
them. The wrappers exist because shells inside a Claude Code session
(`! xs ...`) never read `.bashrc`; in interactive shells the sourced
functions shadow them. Only `xg` truly needs to be a function — the wrapper
version resumes fine but can't leave your shell in the mark's directory,
which is why the `source` line is still worth adding (put it above your
bashrc's "not interactive" guard).

Requires `jq` (for first-message previews). `fzf` is optional — if present,
`xg` with no argument opens a fuzzy picker.

Sourcing `xmarks.sh` also registers bash tab completion for `xg`, `xd`,
and `xs` — press `<TAB>` after any of them to complete an existing mark
name. No separate step; it's set up wherever the `source` line runs.

## Usage

```bash
xs <name> [note...]   # save a mark for the session in the current dir
xg <name>             # cd there and resume the session
xl [-l|--long]        # list marks; -l adds the first-message preview column
xd <name>             # remove a mark
xq                    # is this session saved? (inside a session: `! xq`)
xj [pattern]          # journal of past sessions, cross-referenced with marks
```

The best way to save a mark is from *inside* the session you want to keep:

```
! xs pact-schema the one where we designed the pact schema
```

Shells spawned by Claude Code export `CLAUDE_CODE_SESSION_ID`, so this marks
the exact session — no guessing. Run outside a session, `xs` falls back to
the most recent session for the current directory, across all tools and
accounts.

## /mark skill: let Claude write the note

`make install-skill` installs a `/mark` skill into every `~/.claude*`
config dir. Inside a session, `/mark` (or `/mark <name>`) has Claude pick
a mark name, write a ≤10-word summary of what the session actually did,
and save it via `xs` — the part of a bookmark bashmarks could never
automate. New sessions pick the skill up automatically.

Marks are stored in `~/.xmarks/marks.jsonl` (one JSON object per line,
override with `$XMARKS_FILE`). Each mark keeps a copy of the session's first user
message, so listings stay meaningful even after the agent expires the
session file itself. If a session is gone, `xg` still cd's to the
directory and warns.

All xmarks state lives under `~/.xmarks/` (marks, journal, and
their lock/tmp files during writes) rather than loose dotfiles in `$HOME`.
Upgrading from an older version migrates automatically the first time any
command runs — the old `~/.xmarks` file and `~/.xmarks-journal`
are moved in place, and TSV `marks.tsv`/`journal.tsv` from a pre-JSONL
version are converted to `marks.jsonl`/`journal.jsonl` (the originals are
kept as `marks.tsv.bak`/`journal.tsv.bak`). Nothing is lost.

## Session journal: auto-summaries on exit

`make install-hook` registers a `SessionEnd` hook in every `~/.claude*`
settings.json (each backed up to `.bak` first). When a Claude Code session
ends, the hook appends one row to `~/.xmarks/journal.jsonl`: date, session
id, dir, account, and an auto-generated summary — by default it asks haiku
via `claude -p` for ≤12 words about the transcript (a few seconds, a
fraction of a cent per session); set `XMARKS_AUTOSUMMARY=first` to
skip the LLM and use the session's first user message instead.

Browse with `xj` (newest first, last 20) or `xj <pattern>` to filter. Each
row's MARK column shows the mark name if that session was also `xs`'d
(looked up by session id against `~/.xmarks/marks.jsonl`), or `-` if not — so you
can tell at a glance which journaled sessions are already bookmarked.
Unlike marks, the journal itself is automatic and unnamed — it's the
safety net for sessions you forgot to mark. `make uninstall-hook` removes
the hook.

The hook itself always returns in well under a second: it writes the
heuristic summary synchronously, then — if an LLM summary is wanted —
launches a fully detached background job (`xmarks-summarize-async`,
via `setsid`) that asks haiku and patches the row in place once it's
ready. This matters because SessionEnd hooks get killed if they run too
long; earlier versions called `claude -p` inline and could be cancelled
outright (losing the journal entry) if that call stalled — e.g. from a
spend-limit block. Now a stalled or failed LLM call just leaves the
heuristic summary in place; the hook itself never waits on it.

## Multiple accounts and tools

Each mark records which tool it belongs to (`claude` or `codex`) and the
home dir its session lives in (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`, e.g.
`~/.claude-personal` vs `~/.claude-work`). `xg` dispatches accordingly —
`CLAUDE_CONFIG_DIR=... claude --resume` or `CODEX_HOME=... codex resume` —
so marks from every account and both tools share one list, and `xl` shows
an ACCOUNT column for each (plus a TOOL column, but only when marks from
both `claude` and `codex` actually coexist — otherwise it's dropped as a
repeated no-op value).

When saving from inside a Claude Code session, the session's own id and
config dir are used (Codex doesn't export a session id to child shells, so
there's no Codex equivalent). When guessing from a plain shell, `xs`
searches every existing `~/.claude*` and `~/.codex*` home and takes the
newest session for the current dir, whichever tool it came from. Codex has
no per-project session layout, so its side of the search scans recent
rollout files for a matching `cwd`. Restrict or reorder candidates with
`XMARKS_CONFIG_DIRS` / `XMARKS_CODEX_HOMES` (colon-separated).
