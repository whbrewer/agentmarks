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
name (`xg` also completes journal HASHes, see below). No separate step;
it's set up wherever the `source` line runs.

## Usage

```bash
xs <name> [note...]   # star the session in the current dir; [note...] is
                      # optional and always overwrites whatever
                      # description (auto or previous) was showing
xg <name|hash>        # cd there and resume the session (a starred name
                      # from xl, or any session's HASH from xj — no xs
                      # needed)
xl [-l|--long]        # list starred sessions; -l shows ACCOUNT, the full
                      # path, and the untruncated NOTE/SUMMARY
xd <name>             # un-star a session (kept in xj, just drops out of
                      # xl — nothing is deleted)
xq                    # is this session/dir starred? (inside a session: `! xq`)
xj [-l|--long] [pattern]  # every session, oldest to newest; -l shows
                      # ACCOUNT and the full path
```

The best way to star a session is from *inside* it:

```
! xs pact-schema the one where we designed the pact schema
```

Shells spawned by Claude Code export `CLAUDE_CODE_SESSION_ID`, so this marks
the exact session — no guessing. Run outside a session, `xs` falls back to
the most recent session for the current directory, across all tools and
accounts. The `[note...]` is optional — if you skip it, `xl`/`xj` fall
back to the session's auto-generated summary once one exists (see below),
so a session never needs a manual description to show up meaningfully.

## /mark skill: let Claude write the note

`make install-skill` installs a `/mark` skill into every `~/.claude*`
config dir. Inside a session, `/mark` (or `/mark <name>`) has Claude pick
a mark name, write a ≤10-word summary of what the session actually did,
and save it via `xs` — the part of a bookmark bashmarks could never
automate. New sessions pick the skill up automatically.

All state lives in one file, `~/.xmarks/sessions.jsonl` (one JSON object
per line, one per session, override with `$XMARKS_SESSIONS`). Starring
a session with `xs` doesn't create a separate record — it just sets
`starred`/`name`/`note` on that session's existing row, alongside the
`date`/`reason`/`summary` fields the hooks already track (see below). If
a session's transcript is gone, `xg` still cd's to the directory and
warns.

Upgrading from an older version migrates automatically the first time any
command runs — the old `~/.xmarks` file and `~/.xmarks-journal` are moved
in place, TSV `marks.tsv`/`journal.tsv` from a pre-JSONL version are
converted to `marks.jsonl`/`journal.jsonl`, and — the last step — those
two files are merged into one `sessions.jsonl` (a mark becomes
`starred: true` plus `name`/`note` on the journal row for the same
session id; a marked session with no journal row at all, e.g. a Codex
mark or one that predates the journal, becomes its own starred-only row).
Every intermediate file is kept as `.bak`, never deleted, so a conversion
mistake is always recoverable.

## Session journal: auto-summaries on exit (and before)

`make install-hook` registers a `SessionEnd` hook and a `UserPromptSubmit`
hook in every `~/.claude*` settings.json (each backed up to `.bak` first).
When a Claude Code session ends, the SessionEnd hook updates that
session's row with the real outcome: `reason` and an auto-generated
`summary` — by default it asks haiku via `claude -p` for ≤12 words about
the transcript (a few seconds, a fraction of a cent per session); set
`XMARKS_AUTOSUMMARY=first` to skip the LLM and use the session's first
user message instead. Starred sessions keep their `name`/`note`
untouched — this only ever updates `date`/`reason`/`summary`.

The UserPromptSubmit hook writes an earlier, cheaper version of that same
update the moment the *first* prompt is sent — no LLM call, just that
prompt's own text (truncated) as the summary, with `reason` set to
`in_progress`. This exists for sessions that never reach a clean exit —
an SSH connection dropping partway through, say — which would otherwise
vanish entirely; the first prompt is usually the best one-line summary of
the session's intent anyway. If SessionEnd does fire afterward, it
overwrites `reason`/`summary` with the real outcome as usual — never two
rows for one session. Later prompts in the same session are a no-op for
this hook (it exits as soon as it sees a row already exists).

Browse everything with `xj` (oldest to newest, latest at the bottom; last
20 by default) or `xj <pattern>` to filter. Each row's MARK column shows
the session's name if it's starred, or `-` if not, and every row also
gets a HASH column (the first 6 characters of its session id) that
`xg <hash>` resumes directly — so a session never needs an `xs` at all to
be one command away. The default view hides ACCOUNT, shows just the dir's
basename, and shortens SUMMARY to keep things narrow; `xj -l`/`--long`
shows ACCOUNT and the full path/untruncated SUMMARY. `make uninstall-hook`
removes both hooks.

The SessionEnd hook itself always returns in well under a second: it
writes the heuristic summary synchronously, then — if an LLM summary is
wanted — launches a fully detached background job
(`xmarks-summarize-async`, via `setsid`) that asks haiku and patches the
row in place once it's ready. This matters because SessionEnd hooks get
killed if they run too long; earlier versions called `claude -p` inline
and could be cancelled outright (losing the update) if that call stalled
— e.g. from a spend-limit block. Now a stalled or failed LLM call just
leaves the heuristic summary in place; the hook itself never waits on it.

## Multiple accounts and tools

Each row records which tool it belongs to (`claude` or `codex`) and the
home dir its session lives in (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`, e.g.
`~/.claude-personal` vs `~/.claude-work`). `xg` dispatches accordingly —
`CLAUDE_CONFIG_DIR=... claude --resume` or `CODEX_HOME=... codex resume` —
so sessions from every account and both tools share one file, and `xl`
shows an ACCOUNT column for each (plus a TOOL column, but only when
starred sessions from both `claude` and `codex` actually coexist —
otherwise it's dropped as a repeated no-op value).

When saving from inside a Claude Code session, the session's own id and
config dir are used (Codex doesn't export a session id to child shells, so
there's no Codex equivalent). When guessing from a plain shell, `xs`
searches every existing `~/.claude*` and `~/.codex*` home and takes the
newest session for the current dir, whichever tool it came from. Codex has
no per-project session layout, so its side of the search scans recent
rollout files for a matching `cwd`. Restrict or reorder candidates with
`XMARKS_CONFIG_DIRS` / `XMARKS_CODEX_HOMES` (colon-separated).
